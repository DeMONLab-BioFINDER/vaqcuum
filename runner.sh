#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SOURCING FUNCTIONS
# ============================================================

source ./utils.sh
source ./bids_filter.sh
source ./metrics.sh


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
    bids_filter_json="$tmp_dir/bids_filter.json"
    create_bids_filter_json "$config_file" "$bids_filter_json" >&2
    check_inputs_global
    run_dataset
}

main "$@"