import pandas as pd

# Method for importing VCF into Pandas, if individual names are immediately needed:
# https://gist.github.com/dceoy/99d976a2c01e7f0ba1c813778f9db744

def main():
    # Setup
    wd = "/data/abattle4/"
    vcf_file = wd + "GTEx_muscle_splicing/GTEx_Analysis_2017-06-05_v8_WholeGenomeSeq_838Indiv_Analysis_Freeze.SHAPEIT2_phased.gnomAD_nonFinnishEuropean_rare.vcf.gz"
    num_cols_before_GTs = 9 # Default for the VCF
    # Ultimately, we will want the output file to be an annotation file to which
    # we append a column for r.v. group.
    output_file = "rv_group_test_output.tsv"

    get_rv_groups(vcf_file, num_cols_before_GTs, output_file)

def get_rv_groups(vcf_file, num_cols_before_GTs, output_file):
    vcf = pd.read_csv(vcf_file, sep="\t", comment="#", header=None)
    
    """
    Adapt this code to create rare variant groups based on identical columns of
    the VCF. This may depend on some notion of compression of the columns, e.g.
    converting them to strings. Use df.iloc[:, i] to access the columns.

    Testing is difficult because the VCF-of-interest is too big to reliably load
    without entering an interactive session.

    index_dict = {}
    for i, elem in enumerate(arr):
        if elem in index_dict:
            index_dict[elem].append(i)
        else:
            index_dict[elem] = [i]
    return list(index_dict.values())
    """

    # The output will be of the form [[0, 7], [1, 3], [2, 5, 6], [4]],
    # with indices of members of each r.v. group in each sub-list.



if __name__ == "__main__":
    main()