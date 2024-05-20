import pandas as pd

def main():
    # Setup
    data_dir = "/data/abattle4/david/data/annotations/"
    annotation_file = data_dir + "final-EUR-rv.mergedannotation.plusN2pair.Pvalthresbased.tsv"
    output_file = data_dir + "MAGE_EUR_grouped.tsv"

    get_rv_groups(annotation_file, output_file)

def get_rv_groups(annotion_file, output_file):
    ann_df = pd.read_csv(annotion_file, sep="\t")

    # Label (ind., gene) pairs by their belonging to rare variant groups.
    # This code uses the `N2pair` column to determine group membership, but a more
    # robust approach uses a corresponding VCF file.
    group_ID_col = []
    pair_ID_to_group_ID = {}
    group_ID = 0
    for N2_val in ann_df.N2pair:
        if N2_val == "NA":
            group_ID_col.append(group_ID)
            group_ID += 1
        else:
            if N2_val in pair_ID_to_group_ID:
                group_ID_col.append(pair_ID_to_group_ID[N2_val])
            else:
                group_ID_col.append(group_ID)
                pair_ID_to_group_ID[N2_val] = group_ID
                group_ID += 1

    # `group_ID` records the group that each (ind., gene) pair belongs to 
    ann_df["group_ID"] = group_ID_col
    # # `is_in_group` records whether each (ind., gene) pair is in a group or is a
    # # unique rare variant
    # ann_df["is_in_group"] = ann_df.N2pair.apply(lambda x: not pd.isna(x))
    # Remove obsolete `N2pair` column
    ann_df.drop("N2pair", inplace=True, axis=1)

    # Export replicate of annotation file with group information
    ann_df.to_csv(output_file, sep="\t", index=False)

if __name__ == "__main__":
    main()