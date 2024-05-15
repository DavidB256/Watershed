#include <unordered_map>
#include <cmath>
#include <Rcpp.h>
using namespace Rcpp;

// [[Rcpp::export]]
NumericMatrix group_outliers_cpp(IntegerVector group_IDs, NumericMatrix outlier_pvalues, int number_of_dimensions, int number_of_groups, int max_group_size) {
	int max_number_of_signals = number_of_dimensions * max_group_size;
	std::unordered_map<int, int> group_ID_appearances;

	// Initialize `group_outlier_pvalues`, the return value
	// Fill with 2, an impossible value for a p-value, to denote missingness in
	// groups with fewer than the maximum number of individuals.
	NumericMatrix grouped_outlier_pvalues(number_of_groups, max_number_of_signals);
	for (int i = 0; i < number_of_groups; i++) {
		for (int j = 0; j < max_number_of_signals; j++) {
			grouped_outlier_pvalues(i, j) = 2;
		}
	}

	for (int i = 0; i < group_IDs.size(); i++) {
		int group_ID = group_IDs[i];
		for (int j = 0; j < number_of_dimensions; j++) {
			int outlier_column_offset = number_of_dimensions * group_ID_appearances[group_ID]; 
			grouped_outlier_pvalues(group_ID, outlier_column_offset + j) = outlier_pvalues(i, j);
		}
		
		group_ID_appearances[group_ID]++;
	}

	return grouped_outlier_pvalues;
}

bool col_contains_negatives(NumericMatrix mat, int col) {
	for (int i = 0; i < mat.nrow(); i++) {
		if (mat(i, col) < 0)
			return true;
	}
	return false;
}

// [[Rcpp::export]]
NumericMatrix discretize_outliers_cpp(NumericMatrix outlier_pvalues) {
	NumericMatrix outliers_discrete(outlier_pvalues.nrow(), outlier_pvalues.ncol());

	for (int col = 0; col < outlier_pvalues.ncol(); col++) {
		if (col_contains_negatives(outlier_pvalues, col)) {
			for (int row = 0; row < outlier_pvalues.nrow(); row++) {
				// Encode missingness due to raggedness as 0. I.e., since we have
				// variable numbers of observations per group, we need to distinguish
				// the values that exist purely as padding (in rows encoding groups
				// with fewer than the maximum number of individuals) as 0s.
				if (outlier_pvalues(row, col) == 2) {
					outliers_discrete(row, col) = 0;
				} else {
					float log_pvalue = -1 * log10(fabsf(outlier_pvalues(row, col)) + 1e-6);
					// If `under_expression`, i.e. if the p-value is negative to indicate
					// low expression, negate the log-p-value.
					if (!isnan(outlier_pvalues(row, col)) && outlier_pvalues(row, col) < 0)
						log_pvalue *= -1;

					// TODO: Consider alleviating this hardcoding by replacing with
					// an `ordered_map` object over which we iterate.
					if (log_pvalue < -1) {
						outliers_discrete(row, col) = 1;
					} else if (log_pvalue < 1) {
						outliers_discrete(row, col) = 2;
					} else {
						outliers_discrete(row, col) = 3;
					}
				}
			}
		} else {
			for (int row = 0; row < outlier_pvalues.nrow(); row++) {
				// ditto above comments to this code in the above `if` block
				if (outlier_pvalues(row, col) == 2) {
					outliers_discrete(row, col) = 0;
				} else {
					float log_pvalue = -1 * log10(outlier_pvalues(row, col) + 1e-6);

					// TODO: Consider alleviating this hardcoding by replacing with
					// an `ordered_map` object over which we iterate.
					if (log_pvalue < 1) {
						outliers_discrete(row, col) = 1;
					} else if (log_pvalue < 4) {
						outliers_discrete(row, col) = 2;
					} else {
						outliers_discrete(row, col) = 3;
					}
				}
			}
		}
	}

	return outliers_discrete;
}

// TODO: delete this debugging function
// [[Rcpp::export]]
int printeroni_cpp(NumericMatrix outliers_discrete) {
	Rcpp::Rcout << outliers_discrete(1, 1) - 1 << std::endl;
	return 0;
}

// TODO: delete this testing function
// [[Rcpp::export]]
int test_NAs(NumericMatrix arr) {
	NumericMatrix tbp(2, 3);

	for (int i = 0; i < 2; i++) {
		for (int j = 0; j < 3; j++) {
			tbp(i, j) = 2;
		}
	}

	Rcpp::Rcout << tbp << std::endl;

	for (int i = 0; i < 2; i++) {
		for (int j = 0; j < 3; j++) {
			tbp(i, j) = arr(i, j);
		}
	}

	Rcpp::Rcout << tbp << std::endl;

	return 1;
}
