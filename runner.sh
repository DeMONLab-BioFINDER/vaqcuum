#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION / INPUT SOURCING
# ============================================================

config_file="${1:-}"

if [[ -z "$config_file" ]]; then
    echo "ERROR: Missing config file." >&2
    echo "Usage: runner.sh <config.yaml>" >&2
    exit 1
fi

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Config file does not exist: $config_file" >&2
    exit 1
fi

# ============================================================
# BASIC UTILITIES
# ============================================================

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
}

require_file() {
    local file="$1"
    local label="$2"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: Missing $label: $file" >&2
        exit 1
    fi
}

require_dir() {
    local dir="$1"
    local label="$2"

    if [[ ! -d "$dir" ]]; then
        echo "ERROR: Missing $label directory: $dir" >&2
        exit 1
    fi
}

read_yaml() {
    local key="$1"
    yq -r "$key" "$config_file"
}

extract_sub_id() {
    local file="$1"
    local base

    base=$(basename "$file")
    echo "${base%%_*}"
}

extract_ses_id() {
    local file="$1"
    local base
    local without_sub

    base=$(basename "$file")
    without_sub="${base#*_}"
    echo "${without_sub%%_*}"
}

check_matching_ids() {
    local reference_file="$1"
    shift

    local ref_sub
    local ref_ses

    ref_sub=$(extract_sub_id "$reference_file")
    ref_ses=$(extract_ses_id "$reference_file")

    local file
    local file_sub
    local file_ses

    for file in "$@"; do
        file_sub=$(extract_sub_id "$file")
        file_ses=$(extract_ses_id "$file")

        if [[ "$file_sub" != "$ref_sub" || "$file_ses" != "$ref_ses" ]]; then
            echo "ERROR: Subject/session mismatch detected." >&2
            echo "Reference: $reference_file -> $ref_sub $ref_ses" >&2
            echo "Mismatch:  $file -> $file_sub $file_ses" >&2
            exit 1
        fi
    done
}

find_single_file() {
    local search_dir="$1"
    local pattern="$2"
    local exclude_pattern="${3:-}"

    local result

    if [[ -n "$exclude_pattern" ]]; then
        result=$(find "$search_dir" -type f -name "$pattern" | grep -v "$exclude_pattern" || true)
    else
        result=$(find "$search_dir" -type f -name "$pattern" || true)
    fi

    local count
    count=$(echo "$result" | sed '/^$/d' | wc -l | awk '{print $1}')

    if [[ "$count" -eq 0 ]]; then
        echo "ERROR: No file found for pattern '$pattern' in $search_dir" >&2
        exit 1
    elif [[ "$count" -gt 1 ]]; then
        echo "ERROR: Multiple files found for pattern '$pattern' in $search_dir:" >&2
        echo "$result" >&2
        exit 1
    fi

    echo "$result"
}

# ============================================================
# READ CONFIG
# ============================================================

read_config() {
    tmp_dir=$(read_yaml '.paths.tmp_dir')

    mni=$(read_yaml '.paths.mni')
    mni_mask=$(read_yaml '.paths.mni_mask')
    mni_type_res=$(read_yaml '.paths.mni_type_res')

    extracted_metrics_file=$(read_yaml '.outputs.extracted_metrics_file')

    anat_dir=$(read_yaml '.inputs.anat_dir')
    mask_anat=$(read_yaml '.inputs.mask_anat')
    mask_func=$(read_yaml '.inputs.mask_func')
    boldref=$(read_yaml '.inputs.boldref')
    refbold=$(read_yaml '.inputs.refbold')
    refbold_mni=$(read_yaml '.inputs.refbold_mni')
    gm_seg=$(read_yaml '.inputs.gm_seg')

    gm_threshold=$(read_yaml '.settings.gm_threshold')
    dropout_percentile=$(read_yaml '.settings.dropout_percentile')
    mattes_bins=$(read_yaml '.settings.mattes_bins')

    mkdir -p "$tmp_dir"
}

# ============================================================
# CHECKS
# ============================================================

check_dependencies() {
    require_command yq
    require_command fslstats
    require_command fslmaths
    require_command python3

    require_command antsApplyTransforms
    require_command MeasureImageSimilarity
    require_command ImageIntensityStatistics
}

check_inputs() {
    require_dir "$anat_dir" "anatomical"

    require_file "$mask_anat" "anatomical mask"
    require_file "$mask_func" "functional mask"
    require_file "$boldref" "BOLD reference"
    require_file "$refbold" "reference BOLD"
    require_file "$refbold_mni" "reference BOLD in MNI space"
    require_file "$gm_seg" "gray matter segmentation"

    require_file "$mni" "MNI template"
    require_file "$mni_mask" "MNI mask"

    check_matching_ids \
        "$mask_anat" \
        "$mask_func" \
        "$boldref" \
        "$refbold" \
        "$refbold_mni" \
        "$gm_seg"
}

# ============================================================
# OUTPUT INITIALIZATION
# ============================================================

initialize_outputs() {
    echo "sub_id,ses_id,dice_val,volume_gm,nvox_gm,intensity_gm,volume_dropout,nvox_dropout,intensity_dropout,mattes_t1_bold,mattes_wt1_mni,mattes_wbold_mni,entropy_t1,entropy_bold,entropy_wt1,entropy_wbold,entropy_mni" > "$extracted_metrics_file"
}

# ============================================================
# METRIC 1: DICE
# ============================================================

extract_dice_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local anat_mask="$3"
    local func_mask="$4"

    local intersection
    intersection="$tmp_dir/${sub_id}_${ses_id}_mask_intersection.nii.gz"

    local anat_voxels
    local func_voxels
    local intersection_voxels
    local dice_val

    echo "Computing Dice for $sub_id $ses_id" >&2

    anat_voxels=$(fslstats "$anat_mask" -V | awk '{print $1}')
    func_voxels=$(fslstats "$func_mask" -V | awk '{print $1}')

    fslmaths "$anat_mask" -mul "$func_mask" "$intersection"

    intersection_voxels=$(fslstats "$intersection" -V | awk '{print $1}')

    dice_val=$(python3 -c "print(round(2 * $intersection_voxels / ($anat_voxels + $func_voxels), 3))")

    rm -f "$intersection"

    echo "$dice_val"
}

# ============================================================
# METRIC 2: DROPOUT
# ============================================================

extract_dropout_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local gm_seg_file="$3"
    local anat_mask="$4"
    local func_mask="$5"
    local boldref_file="$6"

    local mask_gm_thr
    local mask_merged
    local boldref_masked
    local new_mask_func
    local new_mask_func_inv
    local mask_dropout
    local mask_gm_thr_clean

    mask_gm_thr="$tmp_dir/${sub_id}_${ses_id}_gm_thr.nii.gz"
    mask_merged="$tmp_dir/${sub_id}_${ses_id}_merged_mask.nii.gz"
    boldref_masked="$tmp_dir/${sub_id}_${ses_id}_boldref_masked.nii.gz"
    new_mask_func="$tmp_dir/${sub_id}_${ses_id}_new_func_mask.nii.gz"
    new_mask_func_inv="$tmp_dir/${sub_id}_${ses_id}_new_func_mask_inv.nii.gz"
    mask_dropout="$tmp_dir/${sub_id}_${ses_id}_dropout_mask.nii.gz"
    mask_gm_thr_clean="$tmp_dir/${sub_id}_${ses_id}_gm_thr_clean.nii.gz"

    echo "Computing dropout for $sub_id $ses_id" >&2

    fslmaths "$gm_seg_file" \
        -thr "$gm_threshold" \
        -bin "$mask_gm_thr"

    fslmaths "$anat_mask" \
        -add "$func_mask" \
        -thr 1 \
        -bin "$mask_merged"

    fslmaths "$boldref_file" \
        -mul "$mask_merged" \
        "$boldref_masked"

    local thresh
    thresh=$(fslstats "$boldref_masked" -l 0.001 -P "$dropout_percentile" 2>/dev/null | awk '{print $1}')

    echo "Dropout threshold for $sub_id $ses_id: $thresh" >&2

    fslmaths "$boldref_masked" \
        -thr "$thresh" \
        -bin "$new_mask_func"

    fslmaths "$new_mask_func" \
        -binv "$new_mask_func_inv"

    fslmaths "$mask_gm_thr" \
        -mul "$new_mask_func_inv" \
        "$mask_dropout"

    local vol_dropout
    local nvox_dropout
    local vol_gm
    local nvox_gm
    local intensity_gm
    local intensity_dropout

    vol_dropout=$(fslstats "$mask_dropout" -V | awk '{print $2}')
    nvox_dropout=$(fslstats "$mask_dropout" -V | awk '{print $1}')

    vol_gm=$(fslstats "$mask_gm_thr" -V | awk '{print $2}')
    nvox_gm=$(fslstats "$mask_gm_thr" -V | awk '{print $1}')

    fslmaths "$mask_gm_thr" \
        -sub "$mask_dropout" \
        "$mask_gm_thr_clean"

    intensity_gm=$(fslstats "$boldref_file" -k "$mask_gm_thr_clean" -M)
    intensity_dropout=$(fslstats "$boldref_file" -k "$mask_dropout" -M)

    echo "$sub_id $ses_id | GM: $vol_gm $intensity_gm | Dropout: $vol_dropout $intensity_dropout" >&2

    rm -f \
        "$mask_gm_thr_clean" \
        "$mask_merged" \
        "$boldref_masked" \
        "$new_mask_func_inv"

    echo "$vol_gm,$nvox_gm,$intensity_gm,$vol_dropout,$nvox_dropout,$intensity_dropout"
}

# ============================================================
# METRIC 3: MATTES / ENTROPY / NMI-LIKE SIMILARITY METRICS
# ============================================================

extract_nmi_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local anat_directory="$3"
    local refbold_file="$4"
    local refbold_mni_file="$5"

    local t1
    local t1_mask
    local wt1

    t1=$(find_single_file \
        "$anat_directory" \
        "*_desc-preproc_T1w.nii.gz" \
        "${mni_type_res}")

    t1_mask=$(find_single_file \
        "$anat_directory" \
        "*_desc-brain_mask.nii.gz" \
        "${mni_type_res}")

    wt1=$(find_single_file \
        "$anat_directory" \
        "*_${mni_type_res}_desc-preproc_T1w.nii.gz")

    local t1_mask_bold_space
    local t1_resampled

    t1_mask_bold_space="$tmp_dir/${sub_id}_${ses_id}_bold-space_T1wmask.nii.gz"
    t1_resampled="$tmp_dir/${sub_id}_${ses_id}_space-bold_T1w.nii.gz"

    echo "Computing Mattes / entropy metrics for $sub_id $ses_id" >&2

    # Resample T1 mask to BOLD space.
    antsApplyTransforms \
        -d 3 \
        -i "$t1_mask" \
        -r "$refbold_file" \
        -o "$t1_mask_bold_space" \
        -n NearestNeighbor

    # Resample T1 image to BOLD space.
    antsApplyTransforms \
        -d 3 \
        -i "$t1" \
        -r "$refbold_file" \
        -o "$t1_resampled" \
        -n BSpline

    local mattes_t1_bold
    local mattes_wt1_mni
    local mattes_wbold_mni

    mattes_t1_bold=$(MeasureImageSimilarity \
        -d 3 \
        -m Mattes["$t1_resampled","$refbold_file",1,"$mattes_bins"] \
        -x "$t1_mask_bold_space")

    mattes_wt1_mni=$(MeasureImageSimilarity \
        -d 3 \
        -m Mattes["$wt1","$mni",1,"$mattes_bins"] \
        -x "$mni_mask")

    mattes_wbold_mni=$(MeasureImageSimilarity \
        -d 3 \
        -m Mattes["$refbold_mni_file","$mni",1,"$mattes_bins"] \
        -x "$mni_mask")

    local entropy_t1
    local entropy_bold
    local entropy_wt1
    local entropy_wbold
    local entropy_mni

    entropy_t1=$(ImageIntensityStatistics 3 "$t1_resampled" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
    entropy_bold=$(ImageIntensityStatistics 3 "$refbold_file" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
    entropy_wt1=$(ImageIntensityStatistics 3 "$wt1" "$mni_mask" | awk 'NR==2 {print $6}')
    entropy_wbold=$(ImageIntensityStatistics 3 "$refbold_mni_file" "$mni_mask" | awk 'NR==2 {print $6}')
    entropy_mni=$(ImageIntensityStatistics 3 "$mni" "$mni_mask" | awk 'NR==2 {print $6}')

    echo "$sub_id $ses_id | Mattes T1/BOLD: $mattes_t1_bold | wT1/MNI: $mattes_wt1_mni | wBOLD/MNI: $mattes_wbold_mni" >&2

    rm -f "$t1_mask_bold_space" "$t1_resampled"

    echo "$mattes_t1_bold,$mattes_wt1_mni,$mattes_wbold_mni,$entropy_t1,$entropy_bold,$entropy_wt1,$entropy_wbold,$entropy_mni"
}

# ============================================================
# RUNNER
# ============================================================

run_all_metrics() {
    local anat_mask="$1"
    local func_mask="$2"
    local gm_seg_file="$3"
    local boldref_file="$4"
    local refbold_file="$5"
    local refbold_mni_file="$6"
    local anat_directory="$7"

    local sub_id
    local ses_id

    sub_id=$(extract_sub_id "$anat_mask")
    ses_id=$(extract_ses_id "$anat_mask")

    echo "============================================================" >&2
    echo "Running all metrics for $sub_id $ses_id" >&2
    echo "============================================================" >&2

    local dice_val
    local dropout_values
    local nmi_values

    dice_val=$(extract_dice_metric \
        "$sub_id" \
        "$ses_id" \
        "$anat_mask" \
        "$func_mask")

    dropout_values=$(extract_dropout_metric \
        "$sub_id" \
        "$ses_id" \
        "$gm_seg_file" \
        "$anat_mask" \
        "$func_mask" \
        "$boldref_file")

    nmi_values=$(extract_nmi_metric \
        "$sub_id" \
        "$ses_id" \
        "$anat_directory" \
        "$refbold_file" \
        "$refbold_mni_file")

    echo "$sub_id,$ses_id,$dice_val,$dropout_values,$nmi_values" >> "$extracted_metrics_file"

    echo "Finished all metrics for $sub_id $ses_id" >&2
}

# ============================================================
# MAIN
# ============================================================

main() {
    check_dependencies
    read_config
    check_inputs
    initialize_outputs

    run_all_metrics \
        "$mask_anat" \
        "$mask_func" \
        "$gm_seg" \
        "$boldref" \
        "$refbold" \
        "$refbold_mni" \
        "$anat_dir"
}

main "$@"