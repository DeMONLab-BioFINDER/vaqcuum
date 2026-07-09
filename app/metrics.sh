

# ============================================================
# METRIC 1: DICE
# ============================================================

extract_dice_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local anat_mask_mni="$3"
    local func_mask_mni="$4"

    local intersection
    intersection="$id_tmp_dir/${sub_id}_${ses_id}_mask_intersection.nii.gz"

    local anat_voxels
    local func_voxels
    local intersection_voxels
    local dice_val
    local metric_file

    metric_file="$dice_dir/${sub_id}_${ses_id}.csv"

    echo "Computing Dice for $sub_id $ses_id" >&2

    anat_voxels=$(fslstats "$anat_mask_mni" -V | awk '{print $1}')
    func_voxels=$(fslstats "$func_mask_mni" -V | awk '{print $1}')

    fslmaths "$anat_mask_mni" -mul "$func_mask_mni" "$intersection"

    intersection_voxels=$(fslstats "$intersection" -V | awk '{print $1}')

    dice_val=$(python3 -c "print(round(2 * $intersection_voxels / ($anat_voxels + $func_voxels), 3))")

    rm -f "$intersection"

    {
        echo "sub_id,ses_id,dice_val"
        echo "$sub_id,$ses_id,$dice_val"
    } > "$metric_file"
}

# ============================================================
# METRIC 2: DROPOUT
# ============================================================

extract_dropout_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local gm_seg_file="$3"
    local anat_mask_mni="$4"
    local func_mask_mni="$5"
    local refbold_mni_file="$6"

    local mask_gm_thr
    local mask_merged
    local refbold_masked
    local new_mask_func
    local new_mask_func_inv
    local mask_dropout
    local mask_gm_thr_clean
    local metric_file

    local thresh
    local vol_dropout
    local nvox_dropout
    local vol_gm
    local nvox_gm
    local intensity_gm
    local intensity_dropout
    local dropout_intensity
    local dropout_size
    local dropout_compo

    metric_file="$dropout_dir/${sub_id}_${ses_id}.csv"

    mask_gm_thr="$id_tmp_dir/${sub_id}_${ses_id}_gm_thr.nii.gz"
    mask_merged="$id_tmp_dir/${sub_id}_${ses_id}_merged_mask.nii.gz"
    refbold_masked="$id_tmp_dir/${sub_id}_${ses_id}_desc-mask_boldref.nii.gz"
    new_mask_func="$id_tmp_dir/${sub_id}_${ses_id}_new_func_mask.nii.gz"
    new_mask_func_inv="$id_tmp_dir/${sub_id}_${ses_id}_new_func_mask_inv.nii.gz"
    mask_dropout="$id_tmp_dir/${sub_id}_${ses_id}_dropout_mask.nii.gz"
    mask_gm_thr_clean="$id_tmp_dir/${sub_id}_${ses_id}_gm_thr_clean.nii.gz"

    echo "Computing dropout for $sub_id $ses_id" >&2

    fslmaths "$gm_seg_file" \
        -thr "$gm_threshold" \
        -bin "$mask_gm_thr"

    fslmaths "$anat_mask_mni" \
        -add "$func_mask_mni" \
        -thr 1 \
        -bin "$mask_merged"

    fslmaths "$refbold_mni_file" \
        -mul "$mask_merged" \
        "$refbold_masked"

    thresh=$(fslstats "$refbold_masked" -l 0.001 -P "$dropout_percentile" 2>/dev/null | awk '{print $1}')

    if [[ -z "$thresh" || "$thresh" == "nan" || "$thresh" == "NaN" ]]; then
        echo "ERROR: Could not calculate dropout threshold for $sub_id $ses_id" >&2
        exit 1
    fi

    echo "Dropout threshold for $sub_id $ses_id: $thresh" >&2

    fslmaths "$refbold_masked" \
        -thr "$thresh" \
        -bin "$new_mask_func"

    fslmaths "$new_mask_func" \
        -binv "$new_mask_func_inv"

    fslmaths "$mask_gm_thr" \
        -mul "$new_mask_func_inv" \
        "$mask_dropout"

    vol_dropout=$(fslstats "$mask_dropout" -V | awk '{print $2}')
    nvox_dropout=$(fslstats "$mask_dropout" -V | awk '{print $1}')

    vol_gm=$(fslstats "$mask_gm_thr" -V | awk '{print $2}')
    nvox_gm=$(fslstats "$mask_gm_thr" -V | awk '{print $1}')

    fslmaths "$mask_gm_thr" \
        -sub "$mask_dropout" \
        "$mask_gm_thr_clean"

    intensity_gm=$(fslstats "$refbold_mni_file" -k "$mask_gm_thr_clean" -M)
    intensity_dropout=$(fslstats "$refbold_mni_file" -k "$mask_dropout" -M)

    dropout_intensity=$(python3 - "$intensity_dropout" "$intensity_gm" <<'PY'
import sys
import math

numerator = float(sys.argv[1])
denominator = float(sys.argv[2])

if denominator == 0 or math.isnan(denominator):
    print("nan")
else:
    print(numerator / denominator)
PY
)

    dropout_size=$(python3 - "$vol_dropout" "$vol_gm" <<'PY'
import sys
import math

numerator = float(sys.argv[1])
denominator = float(sys.argv[2])

if denominator == 0 or math.isnan(denominator):
    print("nan")
else:
    print(numerator / denominator)
PY
)

    dropout_compo=$(python3 - "$dropout_intensity" "$dropout_size" <<'PY'
import sys
import math

dropout_intensity = float(sys.argv[1])
dropout_size = float(sys.argv[2])

if math.isnan(dropout_intensity) or math.isnan(dropout_size):
    print("nan")
else:
    print((1 - dropout_intensity) + dropout_size)
PY
)

    echo "$sub_id $ses_id | GM: $vol_gm $intensity_gm | Dropout: $vol_dropout $intensity_dropout | Composite: $dropout_compo" >&2

    rm -f \
        "$mask_gm_thr_clean" \
        "$mask_merged" \
        "$refbold_masked" \
        "$new_mask_func_inv"

    {
        echo "sub_id,ses_id,volume_gm,nvox_gm,intensity_gm,volume_dropout,nvox_dropout,intensity_dropout,dropout_intensity,dropout_size,dropout_compo"
        echo "$sub_id,$ses_id,$vol_gm,$nvox_gm,$intensity_gm,$vol_dropout,$nvox_dropout,$intensity_dropout,$dropout_intensity,$dropout_size,$dropout_compo"
    } > "$metric_file"
}

# ============================================================
# METRIC 3: MATTES / ENTROPY
# ============================================================

transform_bold_t1space() {
    local sub_id="$1"
    local ses_id="$2"
    local anat_directory="$3"
    local func_directory="$4"
    local refbold_file="$5"

    local bold_t1space
    local t1
    local matrix

    bold_t1space="${id_tmp_dir}/${sub_id}_${ses_id}_space-T1w_desc-coreg_boldref.nii.gz"

    t1=$(find_single_file \
        "$anat_directory" \
        "${sub_id}_${ses_id}_*desc-preproc_T1w.nii.gz" \
        "$mni_type_res")

    matrix=$(find_single_file \
        "$func_directory" \
        "${sub_id}_${ses_id}*from-boldref_to-T1w_mode-image_desc-coreg_xfm.txt" \
        "$mni_type_res")

    echo "Transforming BOLD reference to T1w space for $sub_id $ses_id" >&2
    echo "  refbold: $refbold_file" >&2
    echo "  t1:      $t1" >&2
    echo "  matrix:  $matrix" >&2
    echo "  output:  $bold_t1space" >&2

    antsApplyTransforms \
        -d 3 \
        -i "$refbold_file" \
        -r "$t1" \
        -o "$bold_t1space" \
        -t "$matrix" \
        --interpolation LanczosWindowedSinc \
        >&2

    echo "$bold_t1space"
}

extract_nmi_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local anat_directory="$3"
    local refbold_t1space="$4"
    local refbold_mni_file="$5"
    local entropy_mni="$6"

    local t1
    local t1_mask
    local wt1
    local metric_file

    metric_file="$nmi_dir/${sub_id}_${ses_id}.csv"

    t1=$(find_single_file \
        "$anat_directory" \
        "${sub_id}_${ses_id}_*desc-preproc_T1w.nii.gz" \
        "$mni_type_res")

    t1_mask=$(find_single_file \
        "$anat_directory" \
        "${sub_id}_${ses_id}_*desc-brain_mask.nii.gz" \
        "$mni_type_res")

    wt1=$(find_single_file \
        "$anat_directory" \
        "${sub_id}_${ses_id}_*space-${mni_type_res}*_desc-preproc_T1w.nii.gz")

    local t1_mask_bold_space
    local t1_resampled

    t1_mask_bold_space="${id_tmp_dir}/${sub_id}_${ses_id}_space-bold_desc-brain_T1wmask.nii.gz"
    t1_resampled="$id_tmp_dir/${sub_id}_${ses_id}_space-bold_T1w.nii.gz"

    echo "Computing Mattes / entropy metrics for $sub_id $ses_id" >&2

    antsApplyTransforms \
        -d 3 \
        -i "$t1_mask" \
        -r "$refbold_t1space" \
        -o "$t1_mask_bold_space" \
        -n NearestNeighbor \
        >&2

    antsApplyTransforms \
        -d 3 \
        -i "$t1" \
        -r "$refbold_t1space" \
        -o "$t1_resampled" \
        -n BSpline \
        >&2

    local mattes_t1_bold
    local mattes_wt1_mni

    mattes_t1_bold=$(MeasureImageSimilarity \
        -d 3 \
        -m Mattes["$t1_resampled","$refbold_t1space",1,"$mattes_bins"] \
        -x "$t1_mask")

    mattes_wt1_mni=$(MeasureImageSimilarity \
        -d 3 \
        -m Mattes["$wt1","$mni",1,"$mattes_bins"] \
        -x "$mni_mask")

    # mattes_wbold_mni=$(MeasureImageSimilarity \
    #     -d 3 \
    #     -m Mattes["$refbold_mni_file","$mni",1,"$mattes_bins"] \
    #     -x "$mni_mask")

    local entropy_t1
    local entropy_bold
    local entropy_wt1
    local entropy_mni

    entropy_t1=$(ImageIntensityStatistics 3 "$t1_resampled" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
    entropy_bold=$(ImageIntensityStatistics 3 "$refbold_t1space" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
    entropy_wt1=$(ImageIntensityStatistics 3 "$wt1" "$mni_mask" | awk 'NR==2 {print $6}')
    entropy_mni=$(ImageIntensityStatistics 3 "$mni" "$mni_mask" | awk 'NR==2 {print $6}')

    echo "$sub_id $ses_id | Mattes T1/BOLD: $mattes_t1_bold | wT1/MNI: $mattes_wt1_mni" >&2
    echo "$sub_id $ses_id | Entropy T1: $entropy_t1 | BOLD: $entropy_bold | wT1: $entropy_wt1 | MNI: $entropy_mni" >&2
    rm -f "$t1_mask_bold_space" "$t1_resampled"

    {
        echo "sub_id,ses_id,mattes_t1_bold,mattes_wt1_mni,entropy_t1,entropy_bold,entropy_wt1,entropy_mni"
        echo "$sub_id,$ses_id,$mattes_t1_bold,$mattes_wt1_mni,$entropy_t1,$entropy_bold,$entropy_wt1,$entropy_mni"
    } > "$metric_file"
}

compute_nmi_merge_metrics() {
    python - "$dice_dir" "$dropout_dir" "$nmi_dir" "$extracted_metrics_file" <<'PY'
import sys
from pathlib import Path
import pandas as pd
import numpy as np

dice_dir, dropout_dir, nmi_dir, output_file = map(Path, sys.argv[1:5])

keys = ["sub_id", "ses_id"]

def read_metric_dir(metric_dir: Path, label: str) -> pd.DataFrame:
    files = sorted(metric_dir.glob("*.csv"))

    if not files:
        raise SystemExit(f"ERROR: No CSV files found for {label}: {metric_dir}")

    frames = []
    for file in files:
        df = pd.read_csv(file)

        if df.empty:
            raise SystemExit(f"ERROR: Empty CSV file for {label}: {file}")

        frames.append(df)

    out = pd.concat(frames, ignore_index=True)

    duplicates = out[out.duplicated(keys, keep=False)]
    if not duplicates.empty:
        raise SystemExit(
            f"ERROR: Duplicate sub_id/ses_id rows found in {label} metrics:\n"
            f"{duplicates.to_string(index=False)}"
        )

    return out


def numeric_col(df: pd.DataFrame, col: str) -> pd.Series:
    if col not in df.columns:
        raise SystemExit(f"ERROR: Missing required NMI column: {col}")

    return pd.to_numeric(df[col], errors="coerce")


def safe_nmi(entropy_a: pd.Series, entropy_b: pd.Series, joint_term: pd.Series) -> pd.Series:
    out = (entropy_a + entropy_b) / joint_term
    out = out.replace([np.inf, -np.inf], np.nan)
    return out


dice = read_metric_dir(dice_dir, "dice")
dropout = read_metric_dir(dropout_dir, "dropout")

required_dropout_cols = [
    "intensity_dropout",
    "intensity_gm",
    "volume_dropout",
    "volume_gm",
]

for col in required_dropout_cols:
    if col not in dropout.columns:
        raise SystemExit(f"ERROR: Missing required dropout column: {col}")

for col in required_dropout_cols:
    dropout[col] = pd.to_numeric(dropout[col], errors="coerce")

dropout["dropout_intensity"] = dropout["intensity_dropout"] / dropout["intensity_gm"]
dropout["dropout_size"] = dropout["volume_dropout"] / dropout["volume_gm"]
dropout["dropout_compo"] = (1 - dropout["dropout_intensity"]) + dropout["dropout_size"]

dropout = dropout.replace([np.inf, -np.inf], np.nan)

# Keep only this dropout metric in the final merged CSV
dropout = dropout[keys + ["dropout_compo"]].copy()

nmi_raw = read_metric_dir(nmi_dir, "nmi")

# Compute NMI from entropy terms and Mattes/joint term.
nmi = nmi_raw[keys].copy()

nmi["nmi_t1_bold"] = safe_nmi(
    numeric_col(nmi_raw, "entropy_t1"),
    numeric_col(nmi_raw, "entropy_bold"),
    numeric_col(nmi_raw, "mattes_t1_bold"),
)

nmi["nmi_wt1_mni"] = safe_nmi(
    numeric_col(nmi_raw, "entropy_wt1"),
    numeric_col(nmi_raw, "entropy_mni"),
    numeric_col(nmi_raw, "mattes_wt1_mni"),
)

# nmi["nmi_wbold_mni"] = safe_nmi(
#     numeric_col(nmi_raw, "entropy_wbold"),
#     numeric_col(nmi_raw, "entropy_mni"),
#     numeric_col(nmi_raw, "mattes_wbold_mni"),
# )

merged = (
    dice
    .merge(dropout, on=keys, how="outer", validate="one_to_one")
    .merge(nmi, on=keys, how="outer", validate="one_to_one")
)

merged = merged.sort_values(keys).reset_index(drop=True)

output_file.parent.mkdir(parents=True, exist_ok=True)
merged.to_csv(output_file, index=False)

print(f"Wrote merged metrics to: {output_file}", file=sys.stderr)
PY
}