library(Rcpp)
library(dplyr)
sourceCpp("data_manip.cpp")

x <- matrix(c(9, 9, NA, 9, 9, 9),
			nrow=2, ncol=3, byrow=TRUE)

y <- test_NAs(x)

# # Convert outlier status into discretized random variables
# get_discretized_outliers <- function(outlier_pvalues) {
# 	# Initialize return value, a matrix of zeros with the same shape as the input
# 	outliers_discretized <- matrix(0, nrow(outlier_pvalues), ncol(outlier_pvalues))

# 	# Iterate through each outlier signal, each composing a dimension of the model.
# 	# `ncol(outlier_pvalues)` equals `number_of_dimensions` times the size of the 
# 	# largest rare variant group
# 	for (dimension in 1:ncol(outlier_pvalues)) {
# 		# Check whether the p-values represent "total expression," i.e. if they're
# 		# signed
# 		if (min(outlier_pvalues[, dimension], na.rm=TRUE) < 0) {
# 			under_expression <- outlier_pvalues[,dimension] < 0 & !is.na(outlier_pvalues[,dimension])
# 			log_pvalues <- -log10(abs(outlier_pvalues[,dimension]) + 1e-6)
# 			log_pvalues[under_expression] <- -1 * log_pvalues[under_expression]
# 			#discretized <- cut(log_pvalues,breaks=c(-6.01,-4,-2,-1,1,2,4,6.01))
# 			discretized <- cut(log_pvalues, breaks=c(-6.01, -1, 1, 6.01))
# 		} else {
# 			log_pvalues <- -log10(abs(outlier_pvalues[,dimension]) + 1e-6)
# 			discretized <- cut(log_pvalues, breaks=c(-.01, 1, 4, 6))
# 		}
# 		outliers_discretized[, dimension] <- as.numeric(discretized)
# 	}

# 	colnames(outliers_discretized) <- colnames(outlier_pvalues)
# 	return(outliers_discretized)
# }

# raw_data <- read.table("example_data/watershed_example_data_grouped.txt", header=TRUE)
# number_of_dimensions <- 3
# pvalue_fraction <- 0.1
# pvalue_threshold <- 0.1

# # Pvalues of outlier status of a particular sample (rows) for a particular outlier type (columns)
# outlier_pvalues <- as.matrix(raw_data[,(ncol(raw_data)-number_of_dimensions):(ncol(raw_data)-1)])
# number_of_groups <- length(unique(raw_data$group_ID))
# group_sizes <- table(raw_data$group_ID)
# max_group_size <- max(group_sizes)

# # From `data_manip.cpp`
# grouped_outlier_pvalues <- group_outliers_cpp(as.vector(raw_data[, "group_ID"]), outlier_pvalues, number_of_dimensions, number_of_groups, max_group_size)

# pheno_cols <- (ncol(raw_data)-number_of_dimensions):(ncol(raw_data)-1)
# rd_grouping <- raw_data %>% group_by(group_ID) # intermediate for the sake of computational efficiency
# rd_grouped <- left_join(rd_grouping %>% summarize_at(1, paste, collapse="_"), # SubjectID ("_"-concatenated)
#                         rd_grouping %>% summarize_at(2, first), by="group_ID") %>% # GeneName
#     left_join(rd_grouping %>% summarize_at(3:(pheno_cols[1]-1), first), by="group_ID") %>% # feat
#     select(-1) # remove `group_ID`

# # Get genomic features (first 2 columns are group/ind. subject identifiers)
# feat <- rd_grouped %>% select(-1, -2)
# # sample name as SubjectID:GeneName
# grouped_row_names <- paste(rd_grouped[,"SubjectID"], ":", rd_grouped[,"GeneName"], sep="")

# fraction_outliers_binary <- ifelse(abs(grouped_outlier_pvalues)<=.1,1,0) # Strictly for initialization of binary output matrix
# for (dimension_num in 1:ncol(grouped_outlier_pvalues)) {
#     ordered <- sort(abs(grouped_outlier_pvalues[,dimension_num]))
#     max_val <- ordered[floor(length(ordered)*pvalue_fraction)]
#     fraction_outliers_binary[,dimension_num] <- ifelse(abs(grouped_outlier_pvalues[,dimension_num]) <= max_val,1,0)
# }
# outliers_binary <- ifelse(abs(grouped_outlier_pvalues)<=pvalue_threshold, 1, 0)
# # Convert outlier status into discretized random variables
# outliers_discrete <- get_discretized_outliers(grouped_outlier_pvalues)

# delme <- printeroni_cpp(outliers_discrete)

# groupings <- ifelse(raw_data[, "group_ID"] %in% names(group_sizes)[group_sizes == 1], 
#                     NA, raw_data[, "group_ID"])
# groupings <- factor(groupings, levels=unique(groupings))

# # Put all data into compact data structure
# data_input <- list(feat=as.matrix(feat), outlier_pvalues=as.matrix(grouped_outlier_pvalues), outliers_binary=as.matrix(outliers_binary), fraction_outliers_binary=as.matrix(fraction_outliers_binary), outliers_discrete=outliers_discrete, groupings=groupings)
