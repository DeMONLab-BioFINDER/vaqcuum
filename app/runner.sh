#!/usr/bin/env bash
set -euo pipefail

## note to future self:

# add task and acq to final csv
# metrics should be extracted for all the spaces available in the dir
# add space col in csv
# DONE. should have an initial funciotn that does some 'exploration' and extracts data structure and info like space, acq, task, etc. and then use that to extract metrics
# DONE. delete wbold-mni 
# DONE. NMI between t1 and refbold is masked by the t1 based anat mask. no intersection and such
# DONE. NMI in template space is masked by the template mask. no intersection and such
# Dice in users space
# dropout in users space
# no bids filter
# config file to minimum
# fetch templateflow if not present
# please provide path to template flow directory if no internet access. else leave empty and itll be fetched automatically from the net
# 13/07: log out and err for each ID?

# ============================================================
# SOURCING FUNCTIONS
# ============================================================

source $(dirname "$0")/utils.sh
#source $(dirname "$0")/bids_filter.sh
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
    output_dir=$(read_yaml '.paths.output_dir')
    extracted_metrics_file=$(read_yaml '.paths.extracted_metrics_file')
    input_dir=$(read_yaml '.paths.input_dir')
    templateflow_dir=$(read_yaml '.paths.templateflow_dir')


    tmp_dir=$(expand_config_vars "$tmp_dir")
    output_dir=$(expand_config_vars "$output_dir")
    input_dir=$(expand_config_vars "$input_dir")
    extracted_metrics_file=$(expand_config_vars "$extracted_metrics_file")

    gm_threshold=$(read_yaml '.settings.gm_threshold')
    dropout_percentile=$(read_yaml '.settings.dropout_percentile')
    mattes_bins=$(read_yaml '.settings.mattes_bins')
    n_jobs=$(read_yaml '.parallelization.n_jobs')

    mkdir -p "$tmp_dir"
    mkdir -p "$output_dir"
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
# SUBJECT/SESSION FILE RESOLUTION
# ============================================================
cleanup_json_array() {
    echo "$1" | jq -r '.[0] // empty'
}

clean_json_value() {
    jq -r '
        if type == "array" then
            map(select(. != null)) | unique | .[0] // empty
        elif . == null then
            empty
        else
            .
        end
    '
}

# bash
resolve_subject_session_inputs() {
    echo "Resolving files for $sub_id $ses_id" >&2

    local session_key
    session_key="${sub_id}_${ses_id}"

    local anat_dir func_dir
    anat_dir=$(jq -r --arg key "$session_key" '.session_summary[$key].anat.path // empty' "$dataset_summary_json")
    func_dir=$(jq -r --arg key "$session_key" '.session_summary[$key].func.path // empty' "$dataset_summary_json")

    if [[ -z "$anat_dir" || -z "$func_dir" ]]; then
        echo "ERROR: Could not read anat/func paths from JSON for $session_key" >&2
        exit 1
    fi

    local func_task func_acq func_space
    func_task=$(jq -r --arg key "$session_key" '.session_summary[$key].func.task // empty' "$dataset_summary_json")
    func_acq=$(jq -r --arg key "$session_key" '.session_summary[$key].func.acq // empty' "$dataset_summary_json")
    func_space=$(jq -r --arg key "$session_key" '.session_summary[$key].func.space // empty' "$dataset_summary_json")

    local anat_acq anat_space
    anat_acq=$(jq -r --arg key "$session_key" '.session_summary[$key].anat.acq // empty' "$dataset_summary_json")
    anat_space=$(jq -r --arg key "$session_key" '.session_summary[$key].anat.space // empty' "$dataset_summary_json")

    local anat_prefix func_prefix
    anat_prefix="${sub_id}_${ses_id}"
    func_prefix="${sub_id}_${ses_id}"

    anat_acq=$(cleanup_json_array "$anat_acq")
    anat_space=$(cleanup_json_array "$anat_space")
    func_acq=$(cleanup_json_array "$func_acq")
    func_space=$(cleanup_json_array "$func_space")
    func_task=$(cleanup_json_array "$func_task")

    if [[ -n "$anat_acq" ]]; then
        anat_acq_string="_acq-${anat_acq}"
    else
        anat_acq_string=""
    fi

    if [[ -n "$anat_space" ]]; then
        anat_space_string="_space-${anat_space}"
    else
        anat_space_string=""
    fi

    if [[ -n "$func_task" ]]; then
        task_prefix="_task-${func_task}"
    else
        task_prefix=""
    fi

    if [[ -n "$func_acq" ]]; then
        func_acq_string="_acq-${func_acq}"
    else
        func_acq_string=""
    fi

    if [[ -n "$func_space" ]]; then
        func_space_string="_space-${func_space}"
    else
        func_space_string=""
    fi

    anat_t1=$(find_single_file \
        "$anat_dir" \
        "${session_key}*${anat_acq_string}_*desc-preproc_T1w.nii.gz" \
        "$anat_space")

    mask_anat_native=$(find_single_file \
        "$anat_dir" \
        "${session_key}*${anat_acq_string}*desc-brain_mask.nii.gz" \
        "$anat_space")

    anat_mni=$(find_single_file \
        "$anat_dir" \
        "${session_key}*${anat_acq_string}*${anat_space_string}*_desc-preproc_T1w.nii.gz")

    mask_anat_mni=$(find_single_file \
        "$anat_dir" \
        "${session_key}*${anat_acq_string}*${anat_space_string}*_desc-brain_mask.nii.gz")

    matrix=$(find_single_file \
        "$func_dir" \
        "${session_key}*from-boldref_to-T1w_mode-image_desc-coreg_xfm.txt" \
        "$anat_space")

    gm_seg_mni=$(find_single_file \
        "$anat_dir" \
        "${session_key}*${anat_acq_string}*${anat_space_string}*label-GM_probseg.nii.gz")

    gm_seg_native=$(find_single_file \
        "$anat_dir" \
        "${session_key}*${anat_acq_string}*label-GM_probseg.nii.gz" \
        "$anat_space")

    mask_func_mni=$(find_single_file \
        "$func_dir" \
        "${func_prefix}*${task_prefix}*${func_acq_string}*${func_space_string}*desc-brain_mask.nii.gz")

    mask_func_native=$(find_single_file \
        "$func_dir" \
        "${func_prefix}*${task_prefix}*${func_acq_string}*desc-brain_mask.nii.gz" \
        "$func_space")

    refbold=$(find_single_file \
        "$func_dir" \
        "${session_key}*${task_prefix}*${func_acq_string}*desc-coreg_boldref.nii.gz" \
        "$func_space")

    refbold_mni=$(find_single_file \
        "$func_dir" \
        "${session_key}*${task_prefix}*${func_acq_string}*${func_space_string}*_boldref.nii.gz")

    # debug output
    echo "#============================================================" >&2
    echo "  session_key:    $session_key" >&2
    echo "  anat_dir:       $anat_dir" >&2
    echo "  func_dir:       $func_dir" >&2
    echo "  anat_prefix:    $anat_prefix" >&2
    echo "  func_prefix:    $func_prefix" >&2
    echo " " >&2
    echo "  anat_t1:        $anat_t1" >&2
    echo "  mask_anat:      $mask_anat_native" >&2
    echo "  anat_mni:       $anat_mni" >&2
    echo "  mask_anat_mni:  $mask_anat_mni" >&2
    echo "  gm_seg_mni:     $gm_seg_mni" >&2
    echo "  gm_seg_native:  $gm_seg_native" >&2
    echo "  matrix:         $matrix" >&2
    echo "  mask_func_mni:  $mask_func_mni" >&2
    echo "  mask_func:      $mask_func_native" >&2
    echo "  refbold:        $refbold" >&2
    echo "  refbold_mni:    $refbold_mni" >&2
    echo "#============================================================" >&2
}

# ============================================================
# PROCESS ONE SUBJECT/SESSION
# ============================================================

process_subject_session() {
    local sub_ses_path="$1"

    sub_id=$(printf '%s\n' "$sub_ses_path" | grep -oE 'sub-[^_/]+' | head -n1)
    ses_id=$(printf '%s\n' "$sub_ses_path" | grep -oE 'ses-[^_/]+' | head -n1)

    id_tmp_dir="$tmp_dir/work/${sub_id}_${ses_id}"
    rm -rf "$id_tmp_dir"
    mkdir -p "$id_tmp_dir"

    cleanup_subject_tmp() {
        rm -rf "$id_tmp_dir"
    }

    trap cleanup_subject_tmp RETURN

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

# if space contains MNI, then mask_anat_space=mask_anat_mni, mask_func_space=mask_func_mni
    echo "anat_space: $anat_space" >&2
    if [[ "$anat_space" == *"MNI"* ]]; then
        mask_anat_space="$mask_anat_mni"
        mask_func_space="$mask_func_mni"
        gm_seg_space="$gm_seg_mni"
        refbold_space="$refbold_mni"
    else
        mask_anat_space="$mask_anat_native"
        mask_func_space="$mask_func_native"
        gm_seg_space="$gm_seg_native"
        refbold_space="$refbold_native"
    fi

    extract_dice_metric \
        "$sub_id" \
        "$ses_id" \
        "$mask_anat_space" \
        "$mask_func_space"

    extract_dropout_metric \
        "$sub_id" \
        "$ses_id" \
        "$gm_seg_space" \
        "$mask_anat_space" \
        "$mask_func_space" \
        "$refbold_space"

    local refbold_t1space

    refbold_t1space=$(transform_bold_t1space \
        "$sub_id" \
        "$ses_id" \
        "$anat_t1" \
        "$matrix" \
        "$refbold")

    extract_nmi_metric \
        "$sub_id" \
        "$ses_id" \
        "$anat_t1" \
        "$mask_anat_native" \
        "$refbold_t1space" \
        "$anat_mni" \
        "$entropy_mni" \
        "$mask_anat_mni"

    echo "Finished $sub_id $ses_id" >&2
}

get_entropy_mni() {
    local space="$1"
    local resolution="$2"
    local -n out_paths="$3"

    if [[ -z "${templateflow_dir:-}" || "$templateflow_dir" == "null" ]]; then
        echo "TemplateFlow directory not specified in config. Fetching from the internet..." >&2
        templateflow_dir="$tmp_dir/templateflow"
        mkdir -p "$templateflow_dir"
        export TEMPLATEFLOW_HOME="$templateflow_dir"
    else
        echo "Using specified TemplateFlow directory: $templateflow_dir" >&2
        export TEMPLATEFLOW_HOME="$templateflow_dir"
    fi

    fetch_templateflow "$space" "$res"

    local key
    key="${space}_res-0${res}"

    out_paths["${key}_T1w"]=$(find_single_file \
        "$templateflow_dir" \
        "tpl-${space}_res-0${res}_T1w.nii.gz")

    out_paths["${key}_mask"]=$(find_single_file \
        "$templateflow_dir" \
        "tpl-${space}_res-0${res}_desc-brain_mask.nii.gz")


    local template_path template_mask_path entropy
    template_path="${out_paths["${key}_T1w"]}"
    template_mask_path="${out_paths["${key}_mask"]}"

    entropy=$(ImageIntensityStatistics 3 "$template_path" "$template_mask_path" | awk 'NR==2 {print $6}')
    echo "$entropy"
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
    export work_dir
    export entropy_values
    export entropy_mni

    export t1w_pattern
    export bold_pattern
    export bids_filter_json
    export dataset_summary_json

    export anat_space

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
    export -f check_matching_ids
    export -f check_matching_subjects
    export -f get_earliest_anat_dir
    export -f resolve_subject_session_inputs
    export -f cleanup_json_array

    export -f extract_dice_metric
    export -f extract_dropout_metric
    export -f transform_bold_t1space
    export -f extract_nmi_metric
    export -f process_subject_session
}


run_dataset() {
    local subject_session_paths_csv
    local dataset_summary_json

    subject_session_paths_csv="$tmp_dir/subject_session_paths.csv"
    dataset_summary_json="$tmp_dir/dataset_summary.json"
    
    # Python-based exploration step
    python "$(dirname "$0")/dataset_utils.py" "$input_dir" > "$dataset_summary_json"
    cat "$dataset_summary_json" >&2
    # Build the session list from the exploration output
    
    jq -r '
      .session_summary
      | keys[]
    ' "$dataset_summary_json" | sort > "$subject_session_paths_csv"

    {
        echo "sub_ses_path"
        cat "$subject_session_paths_csv"
    } > "$subject_session_paths_csv.tmp" && mv "$subject_session_paths_csv.tmp" "$subject_session_paths_csv"

    echo "Discovered subject/session paths:" >&2
    cat "$subject_session_paths_csv" >&2

    # here you add extraction of template flow 
    # check config file. if template flow dir is specified, use that. else fetch from net.

    #read template flow entry in config
    # find all the different values for entry space in the dataset summary json.
    spaces=$(jq -r '.session_summary | .[] | .func.space // empty' "$dataset_summary_json" | sort -u)
    resolution=$(jq -r '.session_summary | .[] | .func.res // empty' "$dataset_summary_json" | sort -u)

    # extract array of values from values in brakcets and remove []
    spaces=$(printf '%s' "$spaces" | clean_json_value)
    resolutions=$(printf '%s' "$resolution" | clean_json_value)

    echo "Discovered spaces: $spaces" >&2
    echo "Discovered resolutions: $resolutions" >&2

    declare -A template_paths=()
    declare -A entropy_values=()

    for space in $spaces; do
        for res in $resolutions; do
            entropy_mni=$(get_entropy_mni "$space" "$res" template_paths)
            entropy_values["${space}_${res}"]=$entropy_mni
            echo "Entropy for ${space} res-${res}: $entropy_mni" >&2
        done
    done

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

    check_inputs_global
    run_dataset
}

main "$@"