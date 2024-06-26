library(optparse)
source("watershed.R")

#######################################
## Train Watershed model on training data
#######################################
learn_watershed_model_parameters_from_training_data <- function(training_input_file, number_of_dimensions, model_name, pseudocounts, lambda_init, binary_pvalue_threshold, lambda_costs, nfolds, vi_step_size, vi_threshold) {
	########################
	## Load in data
	########################
	data_input <- load_watershed_data(training_input_file, number_of_dimensions, .01, binary_pvalue_threshold)

	#######################################
	## Standardize Genomic Annotations (features)
	#######################################
	mean_feat <- apply(data_input$ungrouped_feat, 2, mean)
	sd_feat <- apply(data_input$ungrouped_feat, 2, sd)
 	ungrouped_feat_normalized <- scale(data_input$ungrouped_feat, center=mean_feat, scale=sd_feat)

	mean_feat <- apply(data_input$grouped_feat, 2, mean)
	sd_feat <- apply(data_input$grouped_feat, 2, sd)
 	grouped_feat_normalized <- scale(data_input$grouped_feat, center=mean_feat, scale=sd_feat)

	cat(paste0("Dimensions of ungrouped_feat_normalized: ", dim(ungrouped_feat_normalized), "\n"))
	cat(paste0("Dimensions of ungrouped_outliers_binary: ", dim(data_input$ungrouped_outliers_binary), "\n"))

  	#######################################
	## Fit Genomic Annotation Model (GAM)
	#######################################
	gam_data <- logistic_regression_genomic_annotation_model_cv(ungrouped_feat_normalized, data_input$ungrouped_outliers_binary, number_of_dimensions, nfolds, lambda_costs, lambda_init)
	# Report optimal lambda learned from cross-validation data (if applicable)
	if (is.na(lambda_init)) {
		cat(paste0(nfolds, "-fold cross validation on GAM yielded optimal lambda of ", gam_data$lambda, "\n"))
	}

	#######################################
	### Initialize phi using alpha and beta from GAM
	#######################################
	# Compute GAM Predictions on data via function in `crf_exact_updates.cpp`
	# TODO: What is going on in the latter arguments to this function?
	gam_posterior_obj <- update_marginal_probabilities_exact_inference_cpp(ungrouped_feat_normalized, data_input$ungrouped_outliers_binary, gam_data$gam_parameters$theta_singleton, gam_data$gam_parameters$theta_pair, gam_data$gam_parameters$theta, 
																		   matrix(0,2,2), matrix(0,2,2), number_of_dimensions, get_number_of_edge_pairs(number_of_dimensions), FALSE)
	gam_posteriors <- gam_posterior_obj$probability
	# Initialize phi using GAM posteriors, i.e. compute MAP estimates of the 
	# coefficients defined by P(outlier_status| FR)
	phi_init <- map_phi_initialization(data_input$ungrouped_outliers_discrete, gam_posteriors, number_of_dimensions, pseudocounts)

	#######################################
	### Fit Watershed Model
	#######################################
	watershed_model <- train_watershed_model(grouped_feat_normalized, data_input$grouped_outliers_discrete, phi_init, gam_data$gam_parameters$theta_pair, gam_data$gam_parameters$theta_singleton, gam_data$gam_parameters$theta, pseudocounts, gam_data$lambda, number_of_dimensions, model_name, vi_step_size, vi_threshold)

	return(list(mean_feat=mean_feat, sd_feat=sd_feat, model_params=watershed_model, gam_model_params=gam_data))
}

predict_watershed_posteriors <- function(watershed_object, prediction_input_file, number_dimensions) {
	########################
	## Load in prediction data
	########################
	prediction_data_input <- load_watershed_data(prediction_input_file, number_of_dimensions, .01, .01)
	# Parse data_input for relevent data
	predictions_feat <- prediction_data_input$feat
	predictions_discretized_outliers <- prediction_data_input$outliers_discrete
	# Scale prediction features (according to mean and standard deviation from training data)
	predictions_feat <- scale(predictions_feat, center=watershed_object$mean_feat, scale=watershed_object$sd_feat) 

	########################
	## Inference to compute Watershed posterior probabilities
	########################
	watershed_info <- update_marginal_posterior_probabilities(predictions_feat, predictions_discretized_outliers, watershed_object$model_params, posterior_bool=TRUE)
	watershed_posteriors <- watershed_info$probability  # Marginal posteriors

	########################
	# Add row names and column names to posterior predictions matrix
	########################
	posterior_mat <- cbind(rownames(predictions_feat), watershed_posteriors)
	colnames(posterior_mat) = c("sample_names", paste0("Watershed_posterior_outlier_signal_", 1:number_dimensions))

	return(posterior_mat)
}

#########################################
# Command line arguments
#########################################
arguments <- parse_args(OptionParser(usage = "%prog [options]", description="Watershed command line args",
	option_list=list(
		make_option(c("-t","--training_input"), default = NULL, help="The Watershed input file containing instances used to train the model [default %default]"),
		make_option(c("-i","--prediction_input"), default = NULL, help="The Watershed input file containing instances to predict on"),
		make_option(c("-d","--number_dimensions"), default=1, help="The number of outlier variables."),
		make_option(c("-m","--model_name"), default="Watershed_exact", help="Name of model. Options are Watershed_exact, Watershed_approximate, RIVER"),
		make_option(c("-p","--dirichlet_prior_parameter"), default=10, help="Parameter defining Dirichlet distribution the acts as a prior a Phi (the model parameters defining E|Z"),
		make_option(c("-l","--l2_prior_parameter"), default=.01, help="Parameter defining L2 (gaussian) distribution the acts as a prior on the parameters of the conditional random Field (the model parameters defining Z|G"),
		make_option(c("-o","--output_prefix"), default="watershed", help="Prefix of file name to save results to"),
		make_option(c("-b","--binary_pvalue_threshold"), default=.1, help="Absolute p-value threshold used to create binary outliers used for Genomic Annotation Model"))
))

# process command line args
training_input_file <- arguments$training_input
prediction_input_file <- arguments$prediction_input
number_of_dimensions <- arguments$number_dimensions
model_name <- arguments$model_name
pseudocounts <- arguments$dirichlet_prior_parameter
lambda_init <- arguments$l2_prior_parameter
if (lambda_init == "NA") {
	lambda_init <- NA
}
output_stem <- arguments$output_prefix
binary_pvalue_threshold <- arguments$binary_pvalue_threshold

# Change model to RIVER if there is only 1 dimension.
if (number_of_dimensions==1 & model_name != "RIVER") {
	cat("Only RIVER can be run on data with 1 dimension.\n Changing model to RIVER.\n")
	model_name <- "RIVER"
}

#########################################
# Fixed Parameters
#########################################
# If arguments$l2_prior_parameter == NA, perform grid search over the following values of lambda to determine optimal lambda
lambda_costs <- c(1e-1, 1e-2, 1e-3)
# If arguments$l2_prior_parameter == NA, k for k-fold cross validation for genomic annotation model
nfolds <- 5
# Parameters used for Variational Optimization (only applies if `arguments$model_name=="Watershed_approximate"`)
vi_step_size <- .8
vi_threshold <- 1e-8

# Set seed for reproducability (feel free to change!)
set.seed(1)

#######################################
## Train Watershed model on training data
#######################################
watershed_object <- learn_watershed_model_parameters_from_training_data(training_input_file, number_of_dimensions, model_name, pseudocounts, lambda_init, binary_pvalue_threshold, lambda_costs, nfolds, vi_step_size, vi_threshold)

#######################################
## Save trained object as .rds file
#######################################
saveRDS(watershed_object, paste0(output_stem, "_prediction_object.rds"))


#######################################
## Estimate Watershed posteriors using trained watershed_object
#######################################
posteriors <- predict_watershed_posteriors(watershed_object, prediction_input_file, number_of_dimensions)


#######################################
## Save Watershed posterior predictions to outputfile
#######################################
output_file <- paste0(output_stem, "_posterior_probability.txt")
write.table(posteriors, file=output_file, sep="\t", quote=FALSE, row.names=FALSE)

