#####
# GROUPED
#####

# example
model="Watershed_exact"  # Can take on "Watershed_exact", "Watershed_approximate", "RIVER"
number_of_dimensions="3" # Can take on any real number greater than or equal to one
input_file="example_data/watershed_example_data_grouped.txt" # Input file
output_prefix="example_grouped"
Rscript evaluate_watershed.R --input $input_file --number_dimensions $number_of_dimensions --output_prefix $output_prefix --model_name $model

# AFR MAGE
model="Watershed_exact"  # Can take on "Watershed_exact", "Watershed_approximate", "RIVER"
number_of_dimensions="1" # Can take on any real number greater than or equal to one
input_file="/data/abattle4/david/data/annotations/MAGE_AFR_grouped.tsv"
output_prefix="AFR_grouped"
Rscript evaluate_watershed.R --input $input_file --number_dimensions $number_of_dimensions --output_prefix $output_prefix --model_name $model

# EUR MAGE
model="Watershed_exact"  # Can take on "Watershed_exact", "Watershed_approximate", "RIVER"
number_of_dimensions="1" # Can take on any real number greater than or equal to one
input_file="/data/abattle4/david/data/annotations/MAGE_EUR_grouped.tsv"
output_prefix="EUR_grouped"
Rscript evaluate_watershed.R --input $input_file --number_dimensions $number_of_dimensions --output_prefix $output_prefix --model_name $model

#####
# UNGROUPED
#####

model="Watershed_exact"  # Can take on "Watershed_exact", "Watershed_approximate", "RIVER"
number_of_dimensions="3" # Can take on any real number greater than or equal to one
input_file="example_data/watershed_example_data.txt" # Input file
output_prefix="example_ungrouped"
Rscript evaluate_watershed.R --input $input_file --number_dimensions $number_of_dimensions --output_prefix $output_prefix --model_name $model
