#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SOURCING FUNCTIONS
# ============================================================

source $(dirname "$0")/utils.sh
source $(dirname "$0")/bids_filter.sh
source $(dirname "$0")/metrics.sh


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
    derivative_dir_template=$(read_yaml '.inputs.derivative_structure')
    anat_earliest_ses=$(read_yaml '.inputs.anat_earliest_ses // "no"')

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

read_bids_filter_values() {
    t1w_datatype=$(jq -r '.t1w.datatype // "anat"' "$bids_filter_json")
    t1w_acquisition=$(jq -r '.t1w.acquisition // "*"' "$bids_filter_json")
    t1w_suffix=$(jq -r '.t1w.suffix // "T1w"' "$bids_filter_json")

    bold_datatype=$(jq -r '.bold.datatype // "func"' "$bids_filter_json")
    bold_suffix=$(jq -r '.bold.suffix // "bold"' "$bids_filter_json")
    bold_task=$(jq -r '.bold.task // "rest"' "$bids_filter_json")
}

# ============================================================
# CHECKS
# ============================================================

check_dependencies() {
    require_command yq
    require_command jq
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

    anat_earliest_ses=$(echo "$anat_earliest_ses" | tr '[:upper:]' '[:lower:]')

    if [[ "$anat_earliest_ses" != "yes" && "$anat_earliest_ses" != "no" ]]; then
        echo "ERROR: settings.anat_earliest_ses must be 'yes' or 'no'." >&2
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

discover_subject_session_paths() {
    local output_csv="$1"
    local tmp_csv="${output_csv}.tmp"

    local uses_flat_structure=0
    local uses_nested_structure=0

    rm -f "$tmp_csv"
    echo "Discovering subject/session paths from: $input_dir" >&2
    echo "Template: $derivative_dir_template" >&2

    if [[ "$derivative_dir_template" == *"{sub_id}_{ses_id}"* ]]; then
        uses_flat_structure=1
    elif [[ "$derivative_dir_template" == *"{sub_id}/{ses_id}"* ]]; then
        uses_nested_structure=1
    else
        echo "ERROR: derivative_dir must contain either:" >&2
        echo '  {sub_id}_{ses_id}' >&2
        echo 'or:' >&2
        echo '  {sub_id}/{ses_id}' >&2
        echo "Current value: $derivative_dir_template" >&2
        exit 1
    fi

    echo "Discovering subject/session paths from: $input_dir" >&2
    echo "Template: $derivative_dir_template" >&2

    if [[ "$uses_flat_structure" -eq 1 ]]; then
        echo "Using flat structure discovery: sub-*_ses-*" >&2

        find "$input_dir" \
            -maxdepth 1 \
            -type d \
            -name "sub-*_ses-*" \
            -printf '%f\n' 2>/dev/null \
            | sort -u > "$tmp_csv"

    elif [[ "$uses_nested_structure" -eq 1 ]]; then
        echo "Using nested structure discovery: sub-*/ses-*" >&2

        find "$input_dir" \
            -mindepth 2 \
            -maxdepth 2 \
            -type d \
            -path "*/sub-*/ses-*" \
            | while IFS= read -r ses_dir; do
                local ses_id
                local sub_id

                ses_id=$(basename "$ses_dir")
                sub_id=$(basename "$(dirname "$ses_dir")")

                if [[ "$sub_id" == sub-* && "$ses_id" == ses-* ]]; then
                    echo "${sub_id}/${ses_id}"
                fi
            done \
            | sort -u > "$tmp_csv"
    fi

    if [[ ! -s "$tmp_csv" ]]; then
        echo "ERROR: No subject/session paths discovered." >&2
        echo "Input dir: $input_dir" >&2
        echo "Template:  $derivative_dir_template" >&2
        echo "Debug: first few directories under input_dir:" >&2
        find "$input_dir" -maxdepth 3 -type d | head -50 >&2
        rm -f "$tmp_csv"
        exit 1
    fi

    {
        echo "sub_ses_path"
        cat "$tmp_csv"
    } > "$output_csv"

    rm -f "$tmp_csv"
}

split_subject_session_path() {
    local sub_ses_path="$1"

    if [[ "$sub_ses_path" =~ ^(sub-[^/]+)/(ses-[^/]+)$ ]]; then
        sub_id="${BASH_REMATCH[1]}"
        ses_id="${BASH_REMATCH[2]}"

    elif [[ "$sub_ses_path" =~ ^(sub-[^_]+)_(ses-[^_]+).* ]]; then
        sub_id="${BASH_REMATCH[1]}"
        ses_id="${BASH_REMATCH[2]}"

    else
        echo "ERROR: Could not parse subject/session path: $sub_ses_path" >&2
        exit 1
    fi
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

    if [[ "$derivative_dir" == */"$sub_id"/"$ses_id" ]]; then
    # Nested structure:
    # {input_dir}/{sub_id}/{ses_id}

        local subject_dir
        subject_dir="$(dirname "$derivative_dir")"

        if [[ "$anat_earliest_ses" == "yes" ]]; then
            anat_dir=$(get_earliest_anat_dir \
                "$subject_dir" \
                "$sub_id")
        else
            anat_dir=$(resolve_glob_one \
                "$derivative_dir/anat" \
                "anatomical directory for $sub_id $ses_id")
        fi

        func_dir=$(resolve_glob_one \
            "$derivative_dir/func" \
            "functional directory for $sub_id $ses_id")

    else
        # Flat fMRIPrep-like structure:
        # {input_dir}/{sub_id}_{ses_id}_fmriprep*

        anat_dir=$(find_single_dir \
            "$derivative_dir" \
            "$sub_id/$ses_id/anat" \
            "anatomical directory for $sub_id $ses_id")

        func_dir=$(find_single_dir \
            "$derivative_dir" \
            "$sub_id/$ses_id/func" \
            "functional directory for $sub_id $ses_id")
    fi

    anat_ses_id=$(basename "$(dirname "$anat_dir")")
    
    mask_anat=$(find_single_file \
    "$anat_dir" \
        "${sub_id}_${anat_ses_id}_${t1w_pattern}*desc-brain_mask.nii.gz" \
        "$mni_type_res")

    mask_anat_mni=$(find_single_file \
        "$anat_dir" \
        "${sub_id}_${anat_ses_id}_${t1w_pattern}*space-${mni_type_res}*_desc-brain_mask.nii.gz")

    gm_seg_mni=$(find_single_file \
        "$anat_dir" \
        "${sub_id}_${anat_ses_id}_${t1w_pattern}*space-${mni_type_res}*label-GM_probseg.nii.gz")

    mask_func_mni=$(find_single_file \
        "$func_dir" \
        "${sub_id}_${ses_id}_${bold_pattern}*space-${mni_type_res}*_desc-brain_mask.nii.gz")

    refbold=$(find_single_file \
        "$func_dir" \
        "${sub_id}_${ses_id}_${bold_pattern}*desc-coreg_boldref.nii.gz" \
        "$mni_type_res")

    refbold_mni=$(find_single_file \
        "$func_dir" \
        "${sub_id}_${ses_id}_${bold_pattern}*space-${mni_type_res}*_boldref.nii.gz")

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
# PROCESS ONE SUBJECT/SESSION
# ============================================================

process_subject_session() {
    local sub_ses_path="$1"

    split_subject_session_path "$sub_ses_path"

    echo "============================================================" >&2
    echo "Processing $sub_id $ses_id" >&2
    echo "============================================================" >&2

    resolve_subject_session_inputs

    if [[ "$anat_earliest_ses" == "yes" ]]; then
        check_matching_subjects \
            "$sub_id" \
            "$mask_anat_mni" \
            "$mask_func_mni" \
            "$refbold" \
            "$refbold_mni" \
            "$gm_seg_mni"
    else
        check_matching_ids \
            "$mask_anat_mni" \
            "$mask_func_mni" \
            "$refbold" \
            "$refbold_mni" \
            "$gm_seg_mni"
    fi

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
    export anat_earliest_ses

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
    export t1w_pattern
    export bold_pattern
    export bids_filter_json
    export -f bids_filter_pattern
    
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
    export -f split_subject_session_path
    export -f discover_subject_session_paths
    export -f check_matching_ids
    export -f resolve_subject_session_inputs
    export -f get_earliest_anat_dir
    export -f check_matching_subjects

    export -f extract_dice_metric
    export -f extract_dropout_metric
    export -f transform_bold_t1space
    export -f extract_nmi_metric
    export -f process_subject_session
    
}


run_dataset() {
    local subject_session_paths_csv
    subject_session_paths_csv="$tmp_dir/subject_session_paths.csv"

    discover_subject_session_paths "$subject_session_paths_csv"

    echo "Discovered subject/session paths:" >&2
    cat "$subject_session_paths_csv" >&2

    initialize_outputs
    export_parallel_context

    tail -n +2 "$subject_session_paths_csv" | parallel \
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

    bids_filter_json="$tmp_dir/bids_filter.json"
    create_bids_filter_json "$config_file" "$bids_filter_json" >&2

    t1w_pattern=$(bids_filter_pattern "t1w")
    bold_pattern=$(bids_filter_pattern "bold")

    check_inputs_global
    run_dataset
}

main "$@"