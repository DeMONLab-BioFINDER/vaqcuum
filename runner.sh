#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION
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

expand_config_vars() {
    local value="$1"

    value="${value//\{tmp_dir\}/${tmp_dir-}}"
    value="${value//\{output_dir\}/${output_dir-}}"
    value="${value//\{extracted_metrics_file\}/${extracted_metrics_file-}}"

    value="${value//\{input_dir\}/${input_dir-}}"
    value="${value//\{derivative_dir\}/${derivative_dir-}}"
    value="${value//\{anat_dir\}/${anat_dir-}}"
    value="${value//\{func_dir\}/${func_dir-}}"

    value="${value//\{sub_id\}/${sub_id-}}"
    value="${value//\{ses_id\}/${ses_id-}}"

    value="${value//\{mni\}/${mni-}}"
    value="${value//\{mni_mask\}/${mni_mask-}}"
    value="${value//\{mni_type_res\}/${mni_type_res-}}"

    echo "$value"
}

resolve_glob_one() {
    local pattern="$1"
    local label="$2"

    local matches=()

    while IFS= read -r match; do
        matches+=("$match")
    done < <(compgen -G "$pattern" || true)

    if [[ "${#matches[@]}" -eq 0 ]]; then
        echo "ERROR: No match found for $label." >&2
        echo "Pattern: $pattern" >&2
        exit 1
    elif [[ "${#matches[@]}" -gt 1 ]]; then
        echo "ERROR: Multiple matches found for $label." >&2
        echo "Pattern: $pattern" >&2
        printf '%s\n' "${matches[@]}" >&2
        exit 1
    fi

    echo "${matches[0]}"
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
        echo "ERROR: No file found." >&2
        echo "  Search dir: $search_dir" >&2
        echo "  Pattern:    $pattern" >&2
        if [[ -n "$exclude_pattern" ]]; then
            echo "  Excluding:  $exclude_pattern" >&2
        fi
        exit 1
    elif [[ "$count" -gt 1 ]]; then
        echo "ERROR: Multiple files found." >&2
        echo "  Search dir: $search_dir" >&2
        echo "  Pattern:    $pattern" >&2
        if [[ -n "$exclude_pattern" ]]; then
            echo "  Excluding:  $exclude_pattern" >&2
        fi
        echo "Matches:" >&2
        echo "$result" >&2
        exit 1
    fi

    echo "$result"
}

find_single_dir() {
    local search_dir="$1"
    local path_suffix="$2"
    local label="$3"

    local result
    result=$(find "$search_dir" -type d -path "*/$path_suffix" | sort)

    local count
    count=$(echo "$result" | sed '/^$/d' | wc -l | awk '{print $1}')

    if [[ "$count" -eq 0 ]]; then
        echo "ERROR: No directory found for $label." >&2
        echo "  Search dir: $search_dir" >&2
        echo "  Suffix:     $path_suffix" >&2
        exit 1
    elif [[ "$count" -gt 1 ]]; then
        echo "ERROR: Multiple directories found for $label." >&2
        echo "  Search dir: $search_dir" >&2
        echo "  Suffix:     $path_suffix" >&2
        echo "Matches:" >&2
        echo "$result" >&2
        exit 1
    fi

    echo "$result"
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

split_subject_session_id() {
    local sub_ses_id="$1"

    sub_id="${sub_ses_id%%_ses-*}"
    ses_id="ses-${sub_ses_id#*_ses-}"
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

# ============================================================
# READ CONFIG
# ============================================================

read_config() {
    tmp_dir=$(read_yaml '.paths.tmp_dir')
    mni=$(read_yaml '.paths.mni')
    mni_mask=$(read_yaml '.paths.mni_mask')
    mni_type_res=$(read_yaml '.paths.mni_type_res')

    output_dir=$(read_yaml '.outputs.output_dir')
    extracted_metrics_file=$(read_yaml '.outputs.extracted_metrics_file')

    input_dir=$(read_yaml '.inputs.input_dir')
    derivative_dir_template=$(read_yaml '.inputs.derivative_dir')

    tmp_dir=$(expand_config_vars "$tmp_dir")
    mni=$(expand_config_vars "$mni")
    mni_mask=$(expand_config_vars "$mni_mask")
    output_dir=$(expand_config_vars "$output_dir")
    input_dir=$(expand_config_vars "$input_dir")
    extracted_metrics_file=$(expand_config_vars "$extracted_metrics_file")

    gm_threshold=$(read_yaml '.settings.gm_threshold')
    dropout_percentile=$(read_yaml '.settings.dropout_percentile')
    mattes_bins=$(read_yaml '.settings.mattes_bins')
    n_jobs=$(read_yaml '.settings.n_jobs')

    mkdir -p "$tmp_dir"
    mkdir -p "$output_dir"
    mkdir -p "$tmp_dir/rows"
}

# ============================================================
# CHECKS
# ============================================================

check_dependencies() {
    require_command yq
    require_command fslstats
    require_command fslmaths
    require_command python

    require_command antsApplyTransforms
    require_command MeasureImageSimilarity
    require_command ImageIntensityStatistics

    python - <<'PY'
import pandas
PY
}

check_inputs_global() {
    require_dir "$input_dir" "input"
    require_file "$mni" "MNI template"
    require_file "$mni_mask" "MNI mask"

    if [[ -z "$n_jobs" || "$n_jobs" == "null" ]]; then
        echo "ERROR: settings.n_jobs is missing from config." >&2
        exit 1
    fi

    if ! [[ "$n_jobs" =~ ^[0-9]+$ ]]; then
        echo "ERROR: settings.n_jobs must be an integer." >&2
        exit 1
    fi

    if [[ "$n_jobs" -lt 1 ]]; then
        echo "ERROR: settings.n_jobs must be >= 1." >&2
        exit 1
    fi
}

# ============================================================
# OUTPUT INITIALIZATION
# ============================================================

initialize_outputs() {
    metrics_dir="$tmp_dir/metrics"

    dice_dir="$metrics_dir/dice"
    dropout_dir="$metrics_dir/dropout"
    nmi_dir="$metrics_dir/nmi"

    rm -rf "$metrics_dir"

    mkdir -p "$dice_dir"
    mkdir -p "$dropout_dir"
    mkdir -p "$nmi_dir"
}

# ============================================================
# DISCOVER SUBJECT/SESSION IDS
# ============================================================

discover_subject_sessions() {
    local derivative_pattern
    derivative_pattern="$derivative_dir_template"

    # During discovery, sub_id/ses_id are not known yet.
    # Replace them with wildcards.
    derivative_pattern="${derivative_pattern//\{input_dir\}/$input_dir}"
    derivative_pattern="${derivative_pattern//\{sub_id\}/sub-*}"
    derivative_pattern="${derivative_pattern//\{ses_id\}/ses-*}"

    local dirs=()

    while IFS= read -r dir; do
        dirs+=("$dir")
    done < <(compgen -G "$derivative_pattern" || true)

    if [[ "${#dirs[@]}" -eq 0 ]]; then
        echo "ERROR: No derivative folders found." >&2
        echo "Pattern: $derivative_pattern" >&2
        exit 1
    fi

    local dir
    local base
    local id

    for dir in "${dirs[@]}"; do
        base=$(basename "$dir")

        # Extract sub-XXX_ses-YYY from folder names like:
        # sub-XXX_ses-YYY_fmriprep...
        id=$(echo "$base" | grep -o '^sub-[^_]*_ses-[^_]*' || true)

        if [[ -n "$id" ]]; then
            echo "$id"
        else
            echo "WARNING: Could not extract sub/ses ID from derivative folder: $dir" >&2
        fi
    done | sort -u
}

# ============================================================
# SUBJECT/SESSION FILE RESOLUTION
# ============================================================

resolve_subject_session_inputs() {
    echo "Resolving files for $sub_id $ses_id" >&2

    local derivative_pattern
    derivative_pattern=$(expand_config_vars "$derivative_dir_template")

    derivative_dir=$(resolve_glob_one \
        "$derivative_pattern" \
        "derivative directory for $sub_id $ses_id")

    anat_dir=$(find_single_dir \
        "$derivative_dir" \
        "$sub_id/$ses_id/anat" \
        "anatomical directory for $sub_id $ses_id")

    func_dir=$(find_single_dir \
        "$derivative_dir" \
        "$sub_id/$ses_id/func" \
        "functional directory for $sub_id $ses_id")

    mask_anat=$(find_single_file \
        "$anat_dir" \
        "${sub_id}_${ses_id}_*desc-brain_mask.nii.gz" \
        "$mni_type_res")

    mask_anat_mni=$(find_single_file \
        "$anat_dir" \
        "${sub_id}_${ses_id}_space-${mni_type_res}*_desc-brain_mask.nii.gz")

    mask_func_mni=$(find_single_file \
        "$func_dir" \
        "${sub_id}_${ses_id}_task-rest*_space-${mni_type_res}*_desc-brain_mask.nii.gz")

    refbold=$(find_single_file \
        "$func_dir" \
        "${sub_id}_${ses_id}_task-rest*_desc-coreg_boldref.nii.gz" \
        "$mni_type_res")

    refbold_mni=$(find_single_file \
        "$func_dir" \
        "${sub_id}_${ses_id}_task-rest*_space-${mni_type_res}*_boldref.nii.gz")

    gm_seg_mni=$(find_single_file \
        "$anat_dir" \
        "${sub_id}_${ses_id}_*space-${mni_type_res}*label-GM_probseg.nii.gz")

    echo "#============================================================" >&2
    echo "  derivative_dir: $derivative_dir" >&2
    echo "  anat_dir:       $anat_dir" >&2
    echo "  func_dir:       $func_dir" >&2
    echo "  mask_anat_mni:  $mask_anat_mni" >&2
    echo "  mask_func_mni:  $mask_func_mni" >&2
    echo "  refbold:        $refbold" >&2
    echo "  refbold_mni:    $refbold_mni" >&2
    echo "  gm_seg_mni:     $gm_seg_mni" >&2
    echo "#============================================================" >&2
}

# ============================================================
# METRIC 1: DICE
# ============================================================

extract_dice_metric() {
    local sub_id="$1"
    local ses_id="$2"
    local anat_mask_mni="$3"
    local func_mask_mni="$4"

    local intersection
    intersection="$tmp_dir/${sub_id}_${ses_id}_mask_intersection.nii.gz"

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

    metric_file="$dropout_dir/${sub_id}_${ses_id}.csv"

    mask_gm_thr="$tmp_dir/${sub_id}_${ses_id}_gm_thr.nii.gz"
    mask_merged="$tmp_dir/${sub_id}_${ses_id}_merged_mask.nii.gz"
    refbold_masked="$tmp_dir/${sub_id}_${ses_id}_desc-mask_boldref.nii.gz"
    new_mask_func="$tmp_dir/${sub_id}_${ses_id}_new_func_mask.nii.gz"
    new_mask_func_inv="$tmp_dir/${sub_id}_${ses_id}_new_func_mask_inv.nii.gz"
    mask_dropout="$tmp_dir/${sub_id}_${ses_id}_dropout_mask.nii.gz"
    mask_gm_thr_clean="$tmp_dir/${sub_id}_${ses_id}_gm_thr_clean.nii.gz"

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

    local thresh
    thresh=$(fslstats "$refbold_masked" -l 0.001 -P "$dropout_percentile" 2>/dev/null | awk '{print $1}')

    echo "Dropout threshold for $sub_id $ses_id: $thresh" >&2

    fslmaths "$refbold_masked" \
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

    intensity_gm=$(fslstats "$refbold_mni_file" -k "$mask_gm_thr_clean" -M)
    intensity_dropout=$(fslstats "$refbold_mni_file" -k "$mask_dropout" -M)

    echo "$sub_id $ses_id | GM: $vol_gm $intensity_gm | Dropout: $vol_dropout $intensity_dropout" >&2

    rm -f \
        "$mask_gm_thr_clean" \
        "$mask_merged" \
        "$refbold_masked" \
        "$new_mask_func_inv"

    {
        echo "sub_id,ses_id,volume_gm,nvox_gm,intensity_gm,volume_dropout,nvox_dropout,intensity_dropout"
        echo "$sub_id,$ses_id,$vol_gm,$nvox_gm,$intensity_gm,$vol_dropout,$nvox_dropout,$intensity_dropout"
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

    bold_t1space="${tmp_dir}/${sub_id}_${ses_id}_space-T1w_desc-coreg_boldref.nii.gz"

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

    t1_mask_bold_space="${tmp_dir}/${sub_id}_${ses_id}_space-bold_desc-brain_T1wmask.nii.gz"
    t1_resampled="$tmp_dir/${sub_id}_${ses_id}_space-bold_T1w.nii.gz"

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
    local mattes_wbold_mni

    mattes_t1_bold=$(MeasureImageSimilarity \
        -d 3 \
        -m Mattes["$t1_resampled","$refbold_t1space",1,"$mattes_bins"] \
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
    entropy_bold=$(ImageIntensityStatistics 3 "$refbold_t1space" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
    entropy_wt1=$(ImageIntensityStatistics 3 "$wt1" "$mni_mask" | awk 'NR==2 {print $6}')
    entropy_wbold=$(ImageIntensityStatistics 3 "$refbold_mni_file" "$mni_mask" | awk 'NR==2 {print $6}')
    entropy_mni=$(ImageIntensityStatistics 3 "$mni" "$mni_mask" | awk 'NR==2 {print $6}')

    echo "$sub_id $ses_id | Mattes T1/BOLD: $mattes_t1_bold | wT1/MNI: $mattes_wt1_mni | wBOLD/MNI: $mattes_wbold_mni" >&2
    echo "$sub_id $ses_id | Entropy T1: $entropy_t1 | BOLD: $entropy_bold | wT1: $entropy_wt1 | wBOLD: $entropy_wbold | MNI: $entropy_mni" >&2
    rm -f "$t1_mask_bold_space" "$t1_resampled"

    {
        echo "sub_id,ses_id,mattes_t1_bold,mattes_wt1_mni,mattes_wbold_mni,entropy_t1,entropy_bold,entropy_wt1,entropy_wbold,entropy_mni"
        echo "$sub_id,$ses_id,$mattes_t1_bold,$mattes_wt1_mni,$mattes_wbold_mni,$entropy_t1,$entropy_bold,$entropy_wt1,$entropy_wbold,$entropy_mni"
    } > "$metric_file"
}

# ============================================================
# PROCESS ONE SUBJECT/SESSION
# ============================================================

process_subject_session() {
    local sub_ses_id="$1"

    split_subject_session_id "$sub_ses_id"

    echo "============================================================" >&2
    echo "Processing $sub_id $ses_id" >&2
    echo "============================================================" >&2

    resolve_subject_session_inputs

    check_matching_ids \
        "$mask_anat_mni" \
        "$mask_func_mni" \
        "$refbold" \
        "$refbold_mni" \
        "$gm_seg_mni"

    extract_dice_metric \
        "$sub_id" \
        "$ses_id" \
        "$mask_anat_mni" \
        "$mask_func_mni"

    extract_dropout_metric \
        "$sub_id" \
        "$ses_id" \
        "$gm_seg_mni" \
        "$mask_anat_mni" \
        "$mask_func_mni" \
        "$refbold_mni"

    local refbold_t1space

    refbold_t1space=$(transform_bold_t1space \
        "$sub_id" \
        "$ses_id" \
        "$anat_dir" \
        "$func_dir" \
        "$refbold")

    extract_nmi_metric \
        "$sub_id" \
        "$ses_id" \
        "$anat_dir" \
        "$refbold_t1space" \
        "$refbold_mni" \
        "$entropy_mni"

    echo "Finished $sub_id $ses_id" >&2
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

nmi["nmi_wbold_mni"] = safe_nmi(
    numeric_col(nmi_raw, "entropy_wbold"),
    numeric_col(nmi_raw, "entropy_mni"),
    numeric_col(nmi_raw, "mattes_wbold_mni"),
)

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

# ============================================================
# RUN DATASET
# ============================================================
export_parallel_context() {
    export config_file

    export tmp_dir
    export output_dir
    export extracted_metrics_file

    export input_dir
    export derivative_dir_template

    export mni
    export mni_mask
    export mni_type_res

    export gm_threshold
    export dropout_percentile
    export mattes_bins

    export metrics_dir
    export dice_dir
    export dropout_dir
    export nmi_dir

    export -f require_command
    export -f require_file
    export -f require_dir
    export -f read_yaml
    export -f expand_config_vars
    export -f resolve_glob_one
    export -f find_single_file
    export -f find_single_dir
    export -f extract_sub_id
    export -f extract_ses_id
    export -f split_subject_session_id
    export -f check_matching_ids
    export -f resolve_subject_session_inputs

    export -f extract_dice_metric
    export -f extract_dropout_metric
    export -f transform_bold_t1space
    export -f extract_nmi_metric
    export -f process_subject_session
}


run_dataset() {
    local subject_sessions=()

    while IFS= read -r id; do
        subject_sessions+=("$id")
    done < <(discover_subject_sessions)

    echo "Found ${#subject_sessions[@]} subject/session IDs." >&2

    initialize_outputs
    export_parallel_context

    printf '%s\n' "${subject_sessions[@]}" | parallel \
        --jobs "$n_jobs" \
        --halt soon,fail=1 \
        --line-buffer \
        --joblog "$tmp_dir/parallel_joblog.tsv" \
        process_subject_session {}

    compute_nmi_merge_metrics
}

# ============================================================
# MAIN
# ============================================================

main() {
    check_dependencies
    read_config
    check_inputs_global
    run_dataset
}

main "$@"