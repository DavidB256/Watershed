library(lbfgs)
library(Rcpp)
library(dplyr)
sourceCpp("crf_exact_updates.cpp")
#sourceCpp("crf_variational_updates.cpp") # Currently has compilation errors, is only needed for VI
sourceCpp("logistic_regression.cpp")
sourceCpp("crf_pseudolikelihood_updates.cpp")
sourceCpp("data_manip.cpp")

# Load in and parse Watershed input file
load_watershed_data <- function(input_file, number_of_dimensions, pvalue_fraction, pvalue_threshold) {
	raw_data <- read.table(input_file, header=TRUE)

	# Normalize feature (G) space
	feat_cols <- 3:(ncol(raw_data)-number_of_dimensions-1)
	mean_feat <- apply(raw_data[,feat_cols], 2, mean)
	sd_feat <- apply(raw_data[,feat_cols], 2, sd)
	raw_data[,feat_cols] <- scale(raw_data[,feat_cols], center=mean_feat, scale=sd_feat)

	pheno_cols <- (ncol(raw_data)-number_of_dimensions):(ncol(raw_data)-1)

	# Pvalues of outlier status of a particular sample (rows) for a particular outlier type (columns)
	ungrouped_feat <- as.matrix(raw_data[,feat_cols])
	ungrouped_outlier_pvalues <- as.matrix(raw_data[,pheno_cols])
	number_of_groups <- length(unique(raw_data$group_ID))
	group_sizes <- table(raw_data$group_ID)
	max_group_size <- max(group_sizes)
	# Rcpp function from `data_manip.cpp`
	grouped_outlier_pvalues <- group_outliers_cpp(raw_data[, "group_ID"], ungrouped_outlier_pvalues, number_of_dimensions, number_of_groups, max_group_size)
	grouped_outlier_pvalues <- as.matrix(grouped_outlier_pvalues)

	rd_grouping <- raw_data %>% group_by(group_ID) # intermediate for the sake of computational efficiency
	rd_grouped <- left_join(rd_grouping %>% summarize_at(1, paste, collapse="_"), # SubjectID ("_"-concatenated)
			  			    rd_grouping %>% summarize_at(2, first), by="group_ID") %>% # GeneName
		left_join(rd_grouping %>% summarize_at(3:(pheno_cols[1]-1), first), by="group_ID") %>% # feat
		select(-1) # remove `group_ID` 
	grouped_groupings <- rd_grouping %>% summarize %>% pull(1) %>% as.vector()
	

	# Get genomic features (first 2 columns are group/ind. subject identifiers)
	grouped_feat <- as.matrix(rd_grouped %>% select(-1, -2))
	# sample name as SubjectID:GeneName

	# TODO: This should probably be removed
	# Convert outlier status into binary random variables
	# grouped_fraction_outliers_binary <- ifelse(abs(grouped_outlier_pvalues)<=.1, 1, 0) # Strictly for initialization of binary output matrix
	# for (dimension_num in 1:ncol(grouped_outlier_pvalues)) {
	# 	ordered <- sort(abs(grouped_outlier_pvalues[,dimension_num]))
	# 	max_val <- ordered[floor(length(ordered)*pvalue_fraction)]
	# 	grouped_fraction_outliers_binary[,dimension_num] <- ifelse(abs(grouped_outlier_pvalues[,dimension_num]) <= max_val,1,0)
	# }

  	grouped_outliers_binary <- as.matrix(ifelse(abs(grouped_outlier_pvalues)<=pvalue_threshold, 1, 0))
	ungrouped_outliers_binary <- as.matrix(ifelse(abs(ungrouped_outlier_pvalues)<=pvalue_threshold, 1, 0))

	# Convert outlier status into discretized random variables
	# From `data_manip.cpp`
	grouped_outliers_discrete <- discretize_outliers_cpp(grouped_outlier_pvalues)
	ungrouped_outliers_discrete <- discretize_outliers_cpp(ungrouped_outlier_pvalues)

	# Copy of `group_ID` column, but with the IDs of singletons replaced with `NA`
	groupings <- ifelse(raw_data[, "group_ID"] %in% names(group_sizes)[group_sizes == 1], 
						NA, raw_data[, "group_ID"])
	groupings <- factor(groupings, levels=unique(groupings))
	# Put all data into compact data structure
	data_input <- list(grouped_feat=grouped_feat, ungrouped_feat=ungrouped_feat,
					   grouped_outlier_pvalues=grouped_outlier_pvalues, ungrouped_outlier_pvalues=ungrouped_outlier_pvalues, 
					   grouped_outliers_binary=grouped_outliers_binary, ungrouped_outliers_binary=ungrouped_outliers_binary, 
					   grouped_outliers_discrete=grouped_outliers_discrete, ungrouped_outliers_discrete=ungrouped_outliers_discrete,
					   groupings=groupings, grouped_groupings=grouped_groupings)

	return(data_input)
}

# Compute log-likelihood of L2-regularized logistic regression model
compute_logistic_regression_likelihood <- function(x, y, feat, lambda) {
	intercept <- x[1]
	theta <- x[2:length(x)]
	# Compute likelihood in CPP file ("logistic_regression.cpp")
	log_likelihood <- compute_logistic_regression_likelihood_exact_inference_cpp(y, feat, intercept, theta, lambda)
	return(-log_likelihood)
}

# Calculate gradient of L2-regularized logistic regression model
compute_logistic_regression_gradient <- function(x, y, feat, lambda) {
	# Extract intercept and coefficients
	intercept <- x[1]
	theta <- x[2:length(x)]

	# Make predictions in CPP file ("logistic_regression.cpp")
	predictions <- logistic_regression_predictions(feat, intercept, theta)

	# Compute Gradient of singleton terms (intercepts)
	grad_singleton <- (colSums(y) - colSums(predictions)) * (1 / nrow(y))

	# Compute Gradient of theta terms (betas)
	grad_theta <- c()
	dimension <- 1
	temp_grad <- colSums(y[,dimension]*feat) - colSums(predictions[, dimension] * feat)
	grad_theta <- c(grad_theta, temp_grad)
	# add regularization
	grad_theta <- grad_theta*(1/nrow(y)) - lambda*theta

	grad <- c(grad_singleton, grad_theta)
	return(-grad)
}

# Compute number of edge pairs, which equals (N choose 2) for N > 1, 1 if N = 1
get_number_of_edge_pairs <- function(number_of_dimensions) {
  return(max(1, 
  			 choose(number_of_dimensions, 2)))
}

## Fit Genomic Annotation Model (GAM)
logistic_regression_genomic_annotation_model_cv <- function(feat_train, binary_outliers_train, number_of_dimensions, nfolds, lambda_costs, lambda_init) {
	##################################
	# Some pre-processing
	##################################
	# Extract dimensionality of space from the data
	number_of_features <- ncol(feat_train)

	cat("Number of features: ", number_of_features, "\n")
	cat("dim of feat_train: ", dim(feat_train), "\n")

	# Initialize logistic regression model parameters to zeros
	gradient_variable_vec <- rep(0, number_of_features+1)
	
	# Shuffle the data
	random_shuffling_indices <- sample(nrow(feat_train))
	feat_train_shuff <- as.matrix(feat_train[random_shuffling_indices,])
	binary_outliers_train_shuff <- as.matrix(binary_outliers_train[random_shuffling_indices,])

	##################################
	# Select value of lambda to use
	##################################
	# If `lambda_init == NA`, we will do k-fold cross validation to select the optimal lambda
	if (is.na(lambda_init)) {
		#Create `nfolds` equal-size "folds," i.e. partitioning subsets of the data
		folds <- cut(seq(1,nrow(feat_train_shuff)), breaks=nfolds, labels=FALSE)
		# Initialize array to keep track of the average area under (precision-recall curve) across different values of lambda (lambda_costs)
		avg_aucs <- c()

		# Iterate over `lambda` values in `lambda_costs` 
		for (lambda in lambda_costs) {
			# Initialize array to keep track of auc in each of the n-folds
			aucs <- c()
			# Loop through n-folds
			for(i in 1:nfolds){
				# Initialize array to keep track of logistic regression probabiliites 
				# in test samples (put in 'pos' array if we know test sample is 
				# positive via held out label. Other way around for 'neg' array)
				pos <- c()
				neg <- c()
    			# Segment your data into training and test for this fold
    			test_indices <- which(folds==i, arr.ind=TRUE)
    			feat_test_fold <- feat_train_shuff[test_indices,]
    			outliers_test_fold <- as.matrix(binary_outliers_train_shuff[test_indices,])
				# Use as training data all that is not test data
    			feat_train_fold <- feat_train_shuff[-test_indices,]
    			outliers_train_fold <- as.matrix(binary_outliers_train_shuff[-test_indices,])

    			# Perform logistic regression in each dimension separately
    			for (dimension in 1:number_of_dimensions) {
    				# Remove any samples with NA for this outlier dimension
    				observed_training_indices <- !is.na(outliers_train_fold[,dimension])
    				observed_training_outliers <- as.matrix(outliers_train_fold[observed_training_indices, dimension])
    				observed_training_feat <- feat_train_fold[observed_training_indices,]

    				observed_testing_indices <- !is.na(outliers_test_fold[,dimension])
    				observed_testing_outliers <- as.matrix(outliers_test_fold[observed_testing_indices, dimension])
    				observed_testing_feat <- feat_test_fold[observed_testing_indices,]
    			
    				# Optimize logistic gregression using LBFGS
    				lbfgs_output <- lbfgs(compute_logistic_regression_likelihood, compute_logistic_regression_gradient, gradient_variable_vec, y=observed_training_outliers, feat=observed_training_feat, lambda=lambda, invisible=1)
    			 
    				if (lbfgs_output$convergence != 0 & lbfgs_output$convergence != 2) {
    					print("Error: Optimization for logistic regression in GAM failed to converge.")
    					print(lbfgs_output$convergence)
    				}

    				# Make predictions on test data using learned Logistic regression model
    				predictions <- c(logistic_regression_predictions(observed_testing_feat, lbfgs_output$par[1], lbfgs_output$par[2:length(lbfgs_output$par)]))
    				# Add precictions to array
    				pos <- c(pos, predictions[observed_testing_outliers==1])
    				neg <- c(neg, predictions[observed_testing_outliers==0])
    			}

    			# Compute Precision recall curve for this fold
    			pr_obj <- pr.curve(scores.class0=pos, scores.class1=neg,curve=T)
    			# Get area under precision-recall curve
    			auc <- pr_obj$auc.integral
    			aucs <- c(aucs, auc)
			}
			# Compute the median across
			avg_aucs <- c(avg_aucs, median(aucs))
		}
		# Get best lambda (ie, the one with highest avg auc across folds)
		best_index <- which(avg_aucs==max(avg_aucs))[1]  # [1] for tie breakers
		best_lambda <- lambda_costs[best_index]
	# If lambda_init != NA, use the user-specified values
  	} else {
  		best_lambda <- lambda_init
  	}

	##################################
	# Using optimal lambda, run GAM on full data to:
	## 1. Train GAM
	## 2. Use parameters in GAM to initialize watershed parameters
	##################################
	# Initialize parameter variables
	theta_pair <- matrix(0, 1, get_number_of_edge_pairs(number_of_dimensions))
	beta_init <- matrix(0,number_of_features+1, number_of_dimensions)
	theta_singleton <- beta_init[1,]
	theta <- as.matrix(beta_init[2:(number_of_features+1),])
	gam_parameters <- list(theta_pair=theta_pair, theta_singleton=theta_singleton, theta=theta)

	# Run GAM in each dimension
  	for (dimension in 1:number_of_dimensions) {
  		# Remove any samples with NA for this outlier dimension
  		observed_training_indices <- !is.na(binary_outliers_train_shuff[,dimension])
  		observed_training_outliers <- as.matrix(binary_outliers_train_shuff[observed_training_indices, dimension])
  		observed_training_feat <- feat_train_shuff[observed_training_indices,]

  		# Run Logistic regression
  		lbfgs_output <- lbfgs(compute_logistic_regression_likelihood, compute_logistic_regression_gradient, gradient_variable_vec, y=observed_training_outliers, feat=observed_training_feat, lambda=best_lambda, invisible=1)

  		if (lbfgs_output$convergence != 0 & lbfgs_output$convergence != 2) {
    		print("Error: L-BFGS algorithm fitting logistic regression model failed to converge.")
    		print(lbfgs_output$convergence)
    	}
    	# Add optimal GAM parameters to data structure
    	gam_parameters$theta_singleton[dimension] <- lbfgs_output$par[1]
    	gam_parameters$theta[,dimension] <- lbfgs_output$par[2:length(lbfgs_output$par)]
  	}

  	return(list(lambda=best_lambda, gam_parameters=gam_parameters))
}

# Compute MAP estimates of the coefficients defined by P(outlier_status | G)
map_phi_initialization <- function(discrete_outliers, posterior, number_of_dimensions, pseudocounts, num_bins=3) {
	# `num_bins` is the number of bins supported by the categorical distributions
	# of each outlier variable E_k.

	# Initialize output matrices
	phi_outlier <- matrix(1, number_of_dimensions, num_bins)  
	phi_inlier <- matrix(1, number_of_dimensions, num_bins)
	# Count number of times we fall into each bin
	for (bin_number in 1:num_bins) {
		phi_outlier[,bin_number] <- 0
		phi_inlier[,bin_number] <- 0
		for (ind in seq(1, ncol(discrete_outliers), by=number_of_dimensions)) {
			discrete_outliers_ind <- discrete_outliers[,ind:(ind+number_of_dimensions-1)]

			phi_outlier[,bin_number] <- phi_outlier[,bin_number] + colSums(((discrete_outliers_ind == bin_number) * posterior), na.rm=TRUE)
			phi_inlier[,bin_number] <- phi_inlier[,bin_number] + colSums(((discrete_outliers_ind == bin_number) * (1 - posterior)), na.rm=TRUE)
		}
	}
	# Incorporate prior information by adding pseudocounts
	for (dimension_number in 1:number_of_dimensions) {
		phi_outlier[dimension_number,] <- phi_outlier[dimension_number,] + pseudocounts
		phi_inlier[dimension_number,] <- phi_inlier[dimension_number,] + pseudocounts
	}
	# Normalize
	phi_outlier <- phi_outlier / rowSums(phi_outlier)
	phi_inlier <- phi_inlier / rowSums(phi_inlier)

	# Combine into compact object
	phi_init <- list(inlier_component=phi_inlier, outlier_component=phi_outlier)

	return(phi_init)
}

# Put model parameters in an easy to handle data structure
initialize_model_params <- function(num_samples, num_genomic_features, number_of_dimensions, phi_init, theta_pair_init, theta_singleton_init, theta_init, pseudocounts, lambda, model_name, vi_step_size, vi_thresh) {
	model_params <- list(theta_pair = theta_pair_init, 
						 theta_singleton = theta_singleton_init,
						 theta = theta_init,
						 mu = matrix(.5, num_samples, number_of_dimensions),
						 mu_pairwise = matrix(.5, num_samples, get_number_of_edge_pairs(number_of_dimensions)),
						 posterior = matrix(.5, num_samples, number_of_dimensions),
						 posterior_pairwise = matrix(.5, num_samples, get_number_of_edge_pairs(number_of_dimensions)),
						 num_samples = num_samples,
						 num_genomic_features = num_genomic_features,
						 number_of_dimensions = number_of_dimensions,
						 phi = phi_init,
						 lambda = lambda,
						 lambda_singleton = 0,  # No regularization of intercepts
						 lambda_pair = lambda,
						 pseudocounts = pseudocounts,
						 vi_step_size = vi_step_size,
						 vi_thresh = vi_thresh,
						 model_name = model_name)
   return(model_params)
}


# E-Step: Infer P(Z | G, E, theta, phi) if `posterior_bool` is TRUE,
# infer P(Z | G, theta) if `posterior_bool` is FALSE
update_marginal_posterior_probabilities <- function(feat, discrete_outliers, model_params, posterior_bool) {
	# Done seperately depending on model
	if (model_params$model_name %in% c("Watershed_exact", "RIVER")) {
		# Compute Expectation in CPP file ("crf_exact_updates.cpp")
		posterior_list <- update_marginal_probabilities_exact_inference_cpp(feat, discrete_outliers, model_params$theta_singleton, model_params$theta_pair, model_params$theta, model_params$phi$inlier_component, model_params$phi$outlier_component, model_params$number_of_dimensions, get_number_of_edge_pairs(model_params$number_of_dimensions),
																			posterior_bool=posterior_bool)
	} else if (model_params$model_name == "Watershed_approximate") {
		# Compute Expectation in CPP file ("crf_variational_updates.cpp")
		posterior_list <- update_marginal_probabilities_vi_cpp(feat, discrete_outliers, model_params$theta_singleton, model_params$theta_pair, model_params$theta, model_params$phi$inlier_component, model_params$phi$outlier_component, model_params$number_of_dimensions, get_number_of_edge_pairs(model_params$number_of_dimensions), model_params$vi_step_size, model_params$vi_thresh, model_params$posterior,
															   posterior_bool=posterior_bool)
	}
	return(posterior_list)
}

# Extract gradient variable vector
# First model_params$number_of_dimensions terms are intercepts for each dimension
# Next there are model_params$number_of_dimensions chunks of length $number_of_genomic_features (each chunk is that dimension's beta)
# Next there are model_params$number_of_dimensions choose 2 theta_pairs
extract_gradient_variable_vector <- function(model_params) {
	# Initialize vector
	x <- c()
	# Add theta_singleton (intercepts)
	x <- c(x, model_params$theta_singleton)
	# Add theta for each dimension (betas)
	for (dimension in 1:model_params$number_of_dimensions) {
		x <- c(x, model_params$theta[, dimension])
	}
	# Add theta_pair (edges between unobserved nodes)
	# x <- c(x, model_params$theta_pair[1,])
	# Add theta_pair (edges between unobserved nodes)
	for (row_number in 1:(dim(model_params$theta_pair)[1])) {
		x <- c(x, model_params$theta_pair[row_number,])
	}

	return(x)
}

# Calculate likelihood of crf (fxn formatted to be used in LBFGS)
compute_exact_crf_likelihood_for_lbfgs <- function(x, feat, discrete_outliers, number_of_dimensions, posterior, posterior_pairwise, phi, lambda, lambda_pair, lambda_singleton, model_name) {
	# Extract relevent scalers describing data
	num_genomic_features <- ncol(feat)
	num_samples <- nrow(feat)

	# Get crf coefficients back into standard vector format
	theta_singleton <- x[1:number_of_dimensions]
	theta <- matrix(0,num_genomic_features,number_of_dimensions)
	for (dimension in 1:number_of_dimensions) {
		theta[,dimension] <- x[(number_of_dimensions + 1 + num_genomic_features * (dimension-1)):
							   (number_of_dimensions + num_genomic_features * (dimension))]
	}
	theta_pair <- matrix(x[(number_of_dimensions + (number_of_dimensions * num_genomic_features) + 1):length(x)], 
						 ncol=get_number_of_edge_pairs(number_of_dimensions),
						 byrow=TRUE)

	# TODO: Does this need a case for `Watershed_approximate`?
	# Compute likelihood with function in `crf_exact_updates.cpp`
	log_likelihood <- compute_crf_likelihood_exact_inference_cpp(posterior, posterior_pairwise, feat, discrete_outliers, theta_singleton, theta_pair, theta, phi$inlier_component, phi$outlier_component, number_of_dimensions, lambda, lambda_pair, lambda_singleton)

	return(-log_likelihood)
}

# Calculate gradient of CRF likelihood (fxn formatted to be used in LBFGS)
compute_exact_crf_gradient_for_lbfgs <- function(x, feat, discrete_outliers, number_of_dimensions, posterior, posterior_pairwise, phi, lambda, lambda_pair, lambda_singleton, model_name) {
	# Extract relevent scalers describing data
	num_genomic_features <- ncol(feat)
	num_samples <- nrow(feat)

	# Get crf coefficients back into inference format
	theta_singleton <- x[1:number_of_dimensions]
	theta <- matrix(0,num_genomic_features,number_of_dimensions)
	for (dimension in 1:number_of_dimensions) {
		theta[,dimension] <- x[(number_of_dimensions + 1 + num_genomic_features*(dimension-1)):(number_of_dimensions + num_genomic_features*(dimension))]
	}
	theta_pair <- matrix(x[(number_of_dimensions + (number_of_dimensions*num_genomic_features) + 1):length(x)], ncol=get_number_of_edge_pairs(number_of_dimensions), byrow=TRUE)

	# Compute expected value of the CRFs (mu). 
	# Following function comes from `crf_exact_updates.cpp`
	mu_list <- update_marginal_probabilities_exact_inference_cpp(feat, discrete_outliers, theta_singleton, theta_pair, theta, phi$inlier_component, phi$outlier_component, number_of_dimensions, get_number_of_edge_pairs(number_of_dimensions), 
	                 											 FALSE)
	mu <- mu_list$probability
	mu_pairwise <- mu_list$probability_pairwise

	# Gradient of singleton terms (intercepts)
	grad_singleton <- (colSums(posterior) - colSums(mu))*(1/nrow(posterior)) - lambda_singleton*theta_singleton

	# Gradient of theta terms (betas)
	theta_vec <- x[(number_of_dimensions+1):(length(x)-(get_number_of_edge_pairs(number_of_dimensions)*nrow(theta_pair)))]
	grad_theta <- c()
	for (dimension in 1:number_of_dimensions) {
		temp_grad <- colSums(posterior[,dimension]*feat) - colSums(mu[,dimension]*feat)
		grad_theta <- c(grad_theta, temp_grad)
	}
	grad_theta <- grad_theta*(1/nrow(posterior)) - lambda*theta_vec

	# Gradient of theta-pair terms
	# Different closed formed gradients used for CRF (ie Watershed_exact) and logistic regression (RIVER)
	if (model_name == "Watershed_exact") {
		grad_pair <- (colSums(posterior_pairwise) - colSums(mu_pairwise))*(1/nrow(posterior_pairwise)) - lambda_pair*theta_pair[1,]
	} else if (model_name == "RIVER"){
		grad_pair <- numeric(nrow(posterior_pairwise))
	}

	# Merge all gradients into one vector (to be returned to the LBFGS optimizer)
	grad <- c(grad_singleton, grad_theta, grad_pair)
	return(-grad)
}

# Calculate pseudolikelihood of CRF (fxn formatted to be used in LBFGS)
compute_exact_crf_pseudolikelihood_for_lbfgs <- function(x, feat, discrete_outliers, number_of_dimensions, posterior, posterior_pairwise, phi, lambda, lambda_pair, lambda_singleton) {
	# Extract relevent scalers describing data
	num_genomic_features <- ncol(feat)
	num_samples <- nrow(feat)

	# Get crf coefficients back into inference format
	theta_singleton <- x[1:number_of_dimensions]
	theta <- matrix(0,num_genomic_features,number_of_dimensions)
	for (dimension in 1:number_of_dimensions) {
		theta[,dimension] <- x[(number_of_dimensions + 1 + num_genomic_features*(dimension-1)):(number_of_dimensions + num_genomic_features*(dimension))]
	}
	theta_pair <- matrix(x[(number_of_dimensions + (number_of_dimensions*num_genomic_features) + 1):length(x)], ncol=choose(number_of_dimensions, 2),byrow=TRUE)

	# Compute pseudolikelihood in cpp function: 'crf_pseudolikelihood_updates.cpp'
	log_likelihood <- compute_pseudolikelihood_crf_likelihood_exact_inference_cpp(posterior, posterior_pairwise, feat, discrete_outliers, theta_singleton, theta_pair, theta, phi$inlier_component, phi$outlier_component, number_of_dimensions, lambda, lambda_pair, lambda_singleton)

	return(-log_likelihood)
}

# Calculate gradient of CRF likelihood using pseudolikelihood (fxn formatted to be used in L-BFGS)
compute_exact_crf_pseudolikelihood_gradient_for_lbfgs <- function(x, feat, discrete_outliers, posterior, posterior_pairwise, phi, lambda, lambda_pair, lambda_singleton) {
	# Extract relevent scalers describing data
	num_genomic_features <- ncol(feat)
	num_samples <- nrow(feat)

	# Get crf coefficients back into inference format
	theta_singleton <- x[1:number_of_dimensions]
	theta <- matrix(0,num_genomic_features,number_of_dimensions)
	for (dimension in 1:number_of_dimensions) {
		theta[,dimension] <- x[(number_of_dimensions + 1 + num_genomic_features*(dimension-1)):(number_of_dimensions + num_genomic_features*(dimension))]
	}
	theta_pair <- matrix(x[(number_of_dimensions + (number_of_dimensions*num_genomic_features) + 1):length(x)], ncol=choose(number_of_dimensions, 2),byrow=TRUE)

	# Compute expected value of the CRFs (mu)
	# Uses CPP function in 'crf_pseudolikelihood_updates.cpp'
	mu_list <- update_pseudolikelihood_marginal_probabilities_exact_inference_cpp(feat, discrete_outliers, posterior, theta_singleton, theta_pair, theta, phi$inlier_component, phi$outlier_component, number_of_dimensions, choose(number_of_dimensions, 2), FALSE)
	mu <- mu_list$probability
	mu_pairwise1 <- mu_list$probability_pairwise1
	mu_pairwise2 <- mu_list$probability_pairwise2

	# Gradient of singleton terms (intercepts)
	grad_singleton <- (colSums(posterior) - colSums(mu))*(1/nrow(posterior)) - lambda_singleton*theta_singleton

	# Gradient of theta terms (betas)
	theta_vec <- x[(number_of_dimensions+1):(length(x)-(choose(number_of_dimensions, 2)*nrow(theta_pair)))]
	grad_theta <- c()
	for (dimension in 1:number_of_dimensions) {
		temp_grad <- colSums(posterior[,dimension]*feat) - colSums(mu[,dimension]*feat)
		grad_theta <- c(grad_theta, temp_grad)
	}
	grad_theta <- grad_theta*(1/nrow(posterior)) - lambda*theta_vec

	# Gradient of theta pair terms (edges)
	grad_pair <- (2.0*colSums(posterior_pairwise) - colSums(mu_pairwise1) - colSums(mu_pairwise2))*(1/nrow(posterior_pairwise)) - 2.0*lambda_pair*theta_pair[1,]
	
	# Merge all gradients into one vector to be returned to LBFGS optimizer
	grad <- c(grad_singleton, grad_theta, grad_pair)
	return(-grad)
}


# Compute MAP estimates theta (i.e. the coefficients defining the conditional random field (CRF))
map_crf <- function(feat, discrete_outliers, model_params) {
	# Get single vector describing model parameters of the CRF
	# It is necessary to do this because this is the format necessary for the LBFGS function
	gradient_variable_vec <- extract_gradient_variable_vector(model_params)

	# Optimize parameters of model using LBFGS (seperate for each of the models)
	if (model_params$model_name == "RIVER" | model_params$model_name == "Watershed_exact") {
		lbfgs_output <- lbfgs(compute_exact_crf_likelihood_for_lbfgs, compute_exact_crf_gradient_for_lbfgs, gradient_variable_vec, feat=feat, discrete_outliers=discrete_outliers, number_of_dimensions=model_params$number_of_dimensions, posterior=model_params$posterior, posterior_pairwise=model_params$posterior_pairwise, phi=model_params$phi, lambda=model_params$lambda, lambda_pair=model_params$lambda_pair, lambda_singleton=model_params$lambda_singleton, model_name=model_params$model_name, invisible=1)
	} else if (model_params$model_name == "Watershed_approximate") {
		lbfgs_output <- lbfgs(compute_exact_crf_pseudolikelihood_for_lbfgs, compute_exact_crf_pseudolikelihood_gradient_for_lbfgs, gradient_variable_vec, feat=feat, discrete_outliers=discrete_outliers, number_of_dimensions=model_params$number_of_dimensions, posterior=model_params$posterior, posterior_pairwise=model_params$posterior_pairwise, phi=model_params$phi, lambda=model_params$lambda, lambda_pair=model_params$lambda_pair, lambda_singleton=0, invisible=1)
	}

	# Check to make sure LBFGS converged OK
	if (lbfgs_output$convergence != 0 & lbfgs_output$convergence != 2) {
		print(paste0("LBFGS optimization on CRF did not converge. It reported convergence error of: ", lbfgs_output$convergence))
		print(lbfgs_output$message)
	}

	# Get optimized crf coefficients back iyr into model_params format
	model_params$theta_singleton <- lbfgs_output$par[1:model_params$number_of_dimensions]
	for (dimension in 1:model_params$number_of_dimensions) {
		model_params$theta[,dimension] <- lbfgs_output$par[(model_params$number_of_dimensions + 1 + ncol(feat)*(dimension-1)):(model_params$number_of_dimensions + ncol(feat)*(dimension))]
	}
 	model_params$theta_pair <- matrix(lbfgs_output$par[(model_params$number_of_dimensions + (model_params$number_of_dimensions*ncol(feat)) + 1):length(lbfgs_output$par)], ncol=get_number_of_edge_pairs(model_params$number_of_dimensions), byrow=TRUE)

	return(model_params)
}

# Compute MAP estimates of phi (i.e. the coefficients defined by P(outlier_status | FR))
map_phi <- function(discrete_outliers, model_params) {
	# TODO: Fix this hardcoding of the number of values that each outlier signal
	# can take on.
	num_bins = 3
	# Initialize phi matrices
	phi_outlier <- matrix(1,model_params$number_of_dimensions, num_bins)	
	phi_inlier <- matrix(1,model_params$number_of_dimensions, num_bins)
	
	# Count number of times an expression outlier falls into each bin
	for (bin_number in 1:num_bins) {
		phi_outlier[,bin_number] <- 0
		phi_inlier[,bin_number] <- 0
		for (ind in seq(1, ncol(discrete_outliers), by=number_of_dimensions)) {
			discrete_outliers_ind <- discrete_outliers[,ind:(ind+number_of_dimensions-1)]
			phi_outlier[,bin_number] <- phi_outlier[,bin_number] + colSums(((discrete_outliers_ind == bin_number) * model_params$posterior), na.rm=TRUE)
			phi_inlier[,bin_number] <- phi_inlier[,bin_number] + colSums(((discrete_outliers_ind == bin_number) * (1 - model_params$posterior)), na.rm=TRUE)
		}
    }

    # Add constant Dirichlet prior to count table
    for (dimension_number in 1:model_params$number_of_dimensions) {
    	phi_outlier[dimension_number,] <- phi_outlier[dimension_number,] + pseudocounts
    	phi_inlier[dimension_number,] <- phi_inlier[dimension_number,] + pseudocounts
    }
    # Normalize
    phi_outlier <- phi_outlier/rowSums(phi_outlier)
    phi_inlier <- phi_inlier/rowSums(phi_inlier)

	# Add update phi's model_params
	model_params$phi$outlier_component <- phi_outlier
	model_params$phi$inlier_component <- phi_inlier
	return(model_params)
}

# Check convergence of Watershed
check_convergence <- function(model_params, phi_old, theta_old, theta_singleton_old, theta_pair_old, iter, max_iter) {
	# Initialize to not converged
	converged = FALSE

	# Number of parameters defining each parameter variable
	num_theta_param = (dim(model_params$theta)[1]*dim(model_params$theta)[2])
	num_theta_singleton_param = (dim(as.matrix(model_params$theta_singleton))[1]*dim(as.matrix(model_params$theta_singleton))[2])
	num_theta_pair_param = (dim(model_params$theta_pair)[1]*dim(model_params$theta_pair)[2])
	num_phi_param = dim(model_params$phi$inlier_component)[1]*dim(model_params$phi$inlier_component)[2]
	total_params_watershed = num_theta_param + num_theta_singleton_param + num_theta_pair_param + num_phi_param + num_phi_param
	total_params_river = num_theta_param + num_theta_singleton_param + num_phi_param + num_phi_param

	# Calculate average norm change in parameter estimates (seperately for RIVER and Watershed)
	# Done seperately because RIVER doesn't actually have theta_pair parameters
	if (model_params$model_name == "RIVER") {
		total_norm = (norm(model_params$theta - theta_old) + norm(as.matrix(model_params$theta_singleton) - as.matrix(theta_singleton_old)) + norm(model_params$phi$inlier_component - phi_old$inlier_component) + norm(model_params$phi$outlier_component - phi_old$outlier_component))/total_params_river
	} else {
		total_norm = (norm(model_params$theta - theta_old) + 
					  norm(as.matrix(model_params$theta_singleton) - as.matrix(theta_singleton_old)) + 
					  norm(model_params$theta_pair - theta_pair_old) + 
					  norm(model_params$phi$inlier_component - phi_old$inlier_component) + 
					  norm(model_params$phi$outlier_component - phi_old$outlier_component)) / 
					  total_params_watershed
	}

	cat(paste0("Average change in parameters: ", total_norm, "\n"))

	# Check for convergence
	if (total_norm < 1e-4) {
		converged = TRUE
		cat("Watershed converged\n")
	} else if (iter == max_iter) {
		converged = TRUE
		cat("Watershed converged due to reaching max iteration\n")
	}

	return(converged)
}

### Fit Watershed Model
train_watershed_model <- function(feat, discrete_outliers, phi_init, theta_pair_init, theta_singleton_init, theta_init, pseudocounts, lambda, number_of_dimensions, model_name, vi_step_size, vi_thresh) {
	# Put model parameters in an easy to handle data structure

	cat("we are here 2\n")
	cat("dim of feat:" , dim(feat), "\n")
	cat("dim of discrete_outliers:" , dim(discrete_outliers), "\n")
	cat("num dims to model: " , number_of_dimensions, "\n")

	model_params <- initialize_model_params(dim(feat)[1], dim(feat)[2], number_of_dimensions, phi_init, theta_pair_init, theta_singleton_init, theta_init, pseudocounts, lambda, model_name, vi_step_size, vi_thresh)

	##############################################
	# Start Iterative Expectation-Maximation here
	##############################################
	converged = FALSE
	iter = 1
	max_iter = 500
	# Iterate between E and M until convergence
	while (!converged) {
		cat('########################\n')
		cat(paste0("ITERATION ", iter, "\n"))
		##########################
		# Keep track of model parameters from the previous iteration
		##########################
		phi_old <- model_params$phi
		theta_old <- model_params$theta
		theta_singleton_old <- model_params$theta_singleton
		theta_pair_old <- model_params$theta_pair

		# cat(paste0("phi_old: ", phi_old, "\n"))
		# cat(paste0("theta_old: ", theta_old, "\n"))
		# cat(paste0("theta_singleton_old: ", theta_singleton_old, "\n"))
		# cat(paste0("theta_pair_old: ", theta_pair_old, "\n"))
		# cat("\n")

		##########################
		# E-Step: Infer P(Z | G, E, theta, phi)
		##########################
		expected_posteriors <- update_marginal_posterior_probabilities(feat, discrete_outliers, model_params, posterior_bool=TRUE)
		# Extract marginal posteriors and pairwise posteriors, respectively
		model_params$posterior <- expected_posteriors$probability
		model_params$posterior_pairwise <- expected_posteriors$probability_pairwise

		##########################
		# E-Step: Infer P(Z | G, theta)
		##########################
		expected_conditional_probability <- update_marginal_posterior_probabilities(feat, discrete_outliers, model_params, posterior_bool=FALSE)
		# Extract marginal posteriors and pairwise posteriors, respectively
		model_params$mu <- expected_conditional_probability$probability
		model_params$mu_pairwise <- expected_conditional_probability$probability_pairwise

		##########################
		# M-Step: Update theta and phi given most recent expectations from E-step 
		##########################
		# Compute MAP estimates theta (ie the coefficients defining the conditional random field (CRF))
		model_params <- map_crf(feat, discrete_outliers, model_params)
		# Compute MAP estimates of phi (ie the coefficients defined by P(outlier_status| FR))
		model_params <- map_phi(discrete_outliers, model_params)

		##########################
		# Check for convergence
		##########################
		converged = check_convergence(model_params, phi_old, theta_old, theta_singleton_old, theta_pair_old, iter, max_iter)
		iter = iter + 1
	}

  	return(model_params)
}




