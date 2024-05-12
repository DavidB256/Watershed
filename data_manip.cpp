#include <unordered_map>
#include <Rcpp.h>
using namespace Rcpp;

// [[Rcpp::export]]
NumericMatrix group_outliers_cpp(IntegerVector group_IDs, NumericMatrix outliers, int number_of_dimensions, int number_of_groups, int max_group_size) {
	int max_number_of_outliers = number_of_dimensions * max_group_size;
	NumericMatrix grouped_outliers(number_of_groups, max_number_of_outliers);
	std::unordered_map<int, int> group_ID_appearances;

	for (int i = 0; i < group_IDs.size(); i++) {
		int group_ID = group_IDs[i];
		for (int j = 0; j < number_of_dimensions; j++) {
			int outlier_column_offset = number_of_dimensions * group_ID_appearances[group_ID]; 
			grouped_outliers(group_ID, outlier_column_offset + j) = outliers(i, j);
		}
		
		group_ID_appearances[group_ID]++;
	}

	return grouped_outliers;
}