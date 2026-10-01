#!/usr/bin/env bash
set -euo pipefail

# logging

# verbose=1 prints detailed paths and intermediate values
# no_color=1 disables ansi colors
# force_color=1 forces colors outside a tty
# log_timestamps=0 disables timestamps

VERBOSE="${VERBOSE:-1}"
LOG_TIMESTAMPS="${LOG_TIMESTAMPS:-1}"
LOG_CONTEXT="${LOG_CONTEXT:-}"

if [[ -z "${NO_COLOR:-}" ]] && \
   { [[ -t 2 ]] || [[ "${FORCE_COLOR:-0}" == "1" ]]; } && \
   [[ "${TERM:-}" != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
fi

log_message() {
    local level="${1:-INFO}"
    local color="${2:-}"
    shift 2 || true

    local timestamp=""
    local context=""

    if [[ "${LOG_TIMESTAMPS:-1}" != "0" ]]; then
        timestamp="[$(date '+%H:%M:%S')] "
    fi

    if [[ -n "${LOG_CONTEXT:-}" ]]; then
        context="[${LOG_CONTEXT}] "
    fi

    printf '%s%b[%-5s]%b %s%s\n' \
        "$timestamp" "$color" "$level" "$C_RESET" "$context" "$*" >&2
}

log_info()  { log_message "INFO"  "$C_CYAN" "$@"; }
log_ok()    { log_message "OK"    "$C_GREEN" "$@"; }
log_warn()  { log_message "WARN"  "$C_YELLOW" "$@"; }
log_error() { log_message "ERROR" "$C_RED" "$@"; }
log_step()  { log_message "STEP"  "$C_MAGENTA" "$@"; }

log_debug() {
    case "${VERBOSE:-0}" in
        1|true|TRUE|yes|YES) log_message "DEBUG" "$C_DIM" "$@" ;;
    esac
}

log_section() {
    local title="${1:-}"
    printf '\n%b%s%b\n' "$C_BOLD$C_BLUE" "============================================================" "$C_RESET" >&2
    printf '%b%s%b\n' "$C_BOLD$C_BLUE" "$title" "$C_RESET" >&2
    printf '%b%s%b\n' "$C_BOLD$C_BLUE" "============================================================" "$C_RESET" >&2
}


# config and paths

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
metric_explorer_rmd="$script_dir/metric_explorer.Rmd"
no_temp_cleanup=0
config_file="${1:-}"
shift || true

bids_filter=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --bids-filter|--bids_filter)
            if [[ "$#" -lt 2 || "$2" == -* ]]; then
                echo "ERROR: $1 requires a JSON file." >&2
                exit 1
            fi

            bids_filter="$2"
            shift 2
            ;;

        --no-temp-cleanup)
            no_temp_cleanup=1
            shift
            ;;

        *)
            echo "ERROR: Unknown runner option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$config_file" ]]; then
    log_error "Missing config file."
    log_info "Usage: $(basename -- "$0") <config.yaml>"
    exit 1
fi

if [[ ! -f "$config_file" ]]; then
    log_error "Config file does not exist: $config_file"
    exit 1
fi

for required_file in \
    "$script_dir/utils.sh" \
    "$script_dir/metrics.sh" \
    "$script_dir/dataset_utils.py" \
    "$script_dir/boldref_manifest.py"
do
    if [[ ! -f "$required_file" ]]; then
        log_error "Required project file is missing: $required_file"
        exit 1
    fi
done

# shellcheck source=/dev/null
source "$script_dir/utils.sh"
# shellcheck source=/dev/null
source "$script_dir/metrics.sh"

# general helpers

is_mni_space() {
    local value="${1:-}"
    local upper
    upper=$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')
    [[ "$upper" == *MNI* ]]
}

normalize_resolution() {
    local resolution="${1:-}"

    if [[ -z "$resolution" ]]; then
        return 0
    fi

    if [[ "$resolution" =~ ^[0-9]+$ ]]; then
        printf '%d\n' "$((10#$resolution))"
    else
        printf '%s\n' "$resolution"
    fi
}

templateflow_resolution_label() {
    local resolution
    resolution=$(normalize_resolution "${1:-}")

    if [[ "$resolution" =~ ^[0-9]+$ ]]; then
        printf '%02d\n' "$resolution"
    else
        printf '%s\n' "$resolution"
    fi
}

lookup_template_field() {
    local requested_space="${1-}"
    local requested_resolution="${2-}"
    local field_index="${3-}"
    local field_label="${4-template value}"
    local lookup_file="${template_lookup_tsv-}"

    requested_resolution=$(normalize_resolution "$requested_resolution")

    if [[ -z "$requested_space" || -z "$requested_resolution" || -z "$field_index" ]]; then
        log_error "Template lookup requires space, resolution, and field index."
        return 1
    fi

    if [[ -z "$lookup_file" || ! -f "$lookup_file" ]]; then
        log_error "Template lookup file is missing: ${lookup_file:-<unset>}"
        return 1
    fi

    local value
    value=$(
        awk -F $'\t' \
            -v wanted_space="$requested_space" \
            -v wanted_res="$requested_resolution" \
            -v field="$field_index" '
                $1 == wanted_space && $2 == wanted_res {
                    print $field
                    found = 1
                    exit
                }
                END { if (!found) exit 1 }
            ' "$lookup_file"
    ) || {
        log_error "No ${field_label} found for space=${requested_space}, res=${requested_resolution}."
        return 1
    }

    if [[ -z "$value" ]]; then
        log_error "Empty ${field_label} for space=${requested_space}, res=${requested_resolution}."
        return 1
    fi

    printf '%s\n' "$value"
}

lookup_template_entropy() {
    lookup_template_field "${1-}" "${2-}" 3 "template entropy"
}

lookup_template_t1() {
    lookup_template_field "${1-}" "${2-}" 4 "TemplateFlow T1"
}

lookup_template_mask() {
    lookup_template_field "${1-}" "${2-}" 5 "TemplateFlow mask"
}


# config loading

read_config() {
    tmp_dir=$(read_yaml '.paths.tmp_dir')
    output_dir=$(read_yaml '.paths.output_dir')
    extracted_metrics_file=$(read_yaml '.paths.extracted_metrics_file')
    input_dir=$(read_yaml '.paths.input_dir')
    templateflow_dir=$(read_yaml '.paths.templateflow_dir // ""')

    tmp_dir=$(expand_config_vars "$tmp_dir")
    output_dir=$(expand_config_vars "$output_dir")
    input_dir=$(expand_config_vars "$input_dir")
    extracted_metrics_file=$(expand_config_vars "$extracted_metrics_file")

    if [[ -n "$templateflow_dir" && "$templateflow_dir" != "null" ]]; then
        templateflow_dir=$(expand_config_vars "$templateflow_dir")
    else
        templateflow_dir=""
    fi

    gm_threshold=$(read_yaml '.settings.gm_threshold')
    dropout_percentile=$(read_yaml '.settings.dropout_percentile')
    mattes_bins=$(read_yaml '.settings.mattes_bins')
    n_jobs=$(read_yaml '.parallelization.n_jobs')

    metric_explorer_enabled=$(read_yaml '.reporting.metric_explorer // true')
    metric_explorer_dir=$(read_yaml '.reporting.output_dir // ""')

    if [[ -n "$metric_explorer_dir" && "$metric_explorer_dir" != "null" ]]; then
        metric_explorer_dir=$(expand_config_vars "$metric_explorer_dir")
    else
        metric_explorer_dir="$output_dir/metric-explorer"
    fi
}

# dependency and input checks

check_dependencies() {
    log_step "Checking required commands and Python packages"

    require_command yq
    require_command fslstats
    require_command fslmaths
    require_command parallel

    require_command antsApplyTransforms
    require_command MeasureImageSimilarity
    require_command ImageIntensityStatistics

    if command -v python >/dev/null 2>&1 && \
       python -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
        python_bin="python"
    elif command -v python3 >/dev/null 2>&1 && \
         python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
        python_bin="python3"
    else
        log_error "Python 3.10 or newer is required"
        exit 1
    fi

    "$python_bin" - <<'PY'
import pandas  # noqa: F401
PY

    log_ok "All dependencies are available"
}

check_inputs_global() {
    log_step "Validating configuration and input paths"

    local config_name config_value
    while IFS=$'\t' read -r config_name config_value; do
        if [[ -z "$config_value" || "$config_value" == "null" ]]; then
            log_error "$config_name is missing from config"
            exit 1
        fi
    done <<EOF
paths.tmp_dir	$tmp_dir
paths.output_dir	$output_dir
paths.extracted_metrics_file	$extracted_metrics_file
paths.input_dir	$input_dir
settings.gm_threshold	$gm_threshold
settings.dropout_percentile	$dropout_percentile
settings.mattes_bins	$mattes_bins
parallelization.n_jobs	$n_jobs
EOF

    require_dir "$input_dir" "input"

    if ! "$python_bin" - "$gm_threshold" "$dropout_percentile" "$mattes_bins" <<'PY'
import math
import sys

gm_threshold, dropout_percentile, mattes_bins = sys.argv[1:]

for name, value in (
    ("settings.gm_threshold", gm_threshold),
    ("settings.dropout_percentile", dropout_percentile),
):
    try:
        parsed = float(value)
    except ValueError:
        raise SystemExit(f"ERROR: {name} must be numeric")
    if not math.isfinite(parsed):
        raise SystemExit(f"ERROR: {name} must be finite")

try:
    bins = int(mattes_bins, 10)
except ValueError:
    raise SystemExit("ERROR: settings.mattes_bins must be a positive integer")
if bins < 1:
    raise SystemExit("ERROR: settings.mattes_bins must be a positive integer")
PY
    then
        exit 1
    fi

    if ! [[ "$n_jobs" =~ ^[0-9]+$ ]]; then
        log_error "parallelization.n_jobs must be an integer"
        exit 1
    fi

    if (( n_jobs < 1 )); then
        log_error "parallelization.n_jobs must be >= 1"
        exit 1
    fi

    case "$metric_explorer_enabled" in
        true|false) ;;
        *)
            log_error "reporting.metric_explorer must be true or false"
            exit 1
            ;;
    esac

    mkdir -p "$tmp_dir" "$output_dir"

    log_ok "Configuration validation passed"
}

# output setup

initialize_outputs() {
    log_step "Preparing clean output and working directories"

    metrics_dir="$tmp_dir/metrics"
    dice_dir="$metrics_dir/dice"
    dropout_dir="$metrics_dir/dropout"
    nmi_dir="$metrics_dir/nmi"
    work_dir="$tmp_dir/work"

    rm -rf "$metrics_dir" "$work_dir"
    mkdir -p "$dice_dir" "$dropout_dir" "$nmi_dir" "$work_dir"

    log_ok "Metric directories ready: $metrics_dir"
    log_debug "Working directory: $work_dir"
}

# work item discovery and inputs

build_work_items() {
    local output_file="${1:-}"

    if [[ -z "$output_file" ]]; then
        log_error "build_work_items requires an output file."
        return 1
    fi

    log_step "Discovering work items from canonical *_boldref.nii.gz files"

    local -a manifest_command=(
        "$python_bin"
        "$script_dir/boldref_manifest.py"
        "$input_dir"
    )

    if [[ -n "${bids_filter:-}" ]]; then
        manifest_command+=(
            --bids-filter
            "$bids_filter"
        )
        log_info "Applying functional BIDS filter to boldref work items: $bids_filter"
    fi

    if ! "${manifest_command[@]}" >"$output_file"; then
        log_error "BOLD-reference work-item discovery failed."
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        log_error "No functional work items were generated from BOLD references."
        return 1
    fi

    local count
    count=$(awk 'NF {count++} END {print count + 0}' "$output_file")
    log_ok "Built $count BOLD-reference work item(s)"
}

load_work_item_inputs() {
    log_step "Loading fully resolved inputs from the boldref manifest"

    local subject_id="${work_item_subject_id:-}"
    local session_id="${work_item_session_id:-}"

    refbold_space="${work_item_boldref:-}"
    mask_func_space="${work_item_func_mask:-}"
    anat_t1="${work_item_anat_t1:-}"
    mask_anat_native="${work_item_anat_mask_native:-}"
    gm_seg_native="${work_item_gm_native:-}"
    anat_mni="${work_item_anat_mni:-}"
    mask_anat_mni="${work_item_anat_mask_mni:-}"
    gm_seg_mni="${work_item_gm_mni:-}"
    refbold_t1w="${work_item_refbold_t1w:-}"
    refbold_native="${work_item_refbold_native:-}"
    matrix="${work_item_matrix:-}"
    anat_dir="${work_item_anat_dir:-}"
    func_dir="${work_item_func_dir:-}"

    [[ "$session_id" == "__NONE__" ]] && session_id=""
    [[ "$anat_mni" == "__NONE__" ]] && anat_mni=""
    [[ "$mask_anat_mni" == "__NONE__" ]] && mask_anat_mni=""
    [[ "$gm_seg_mni" == "__NONE__" ]] && gm_seg_mni=""
    [[ "$refbold_t1w" == "__NONE__" ]] && refbold_t1w=""
    [[ "$refbold_native" == "__NONE__" ]] && refbold_native=""
    [[ "$matrix" == "__NONE__" ]] && matrix=""

    if [[ -z "$subject_id" ]]; then
        log_error "Work item is missing subject identity: $id_key"
        return 1
    fi

    local required_file
    for required_file in \
        "$refbold_space" \
        "$mask_func_space" \
        "$anat_t1" \
        "$mask_anat_native" \
        "$gm_seg_native"
    do
        if [[ ! -f "$required_file" ]]; then
            log_error "Resolved work-item input is missing: $required_file"
            return 1
        fi
    done

    if is_mni_space "$func_space"; then
        for required_file in \
            "$anat_mni" \
            "$mask_anat_mni" \
            "$gm_seg_mni"
        do
            if [[ ! -f "$required_file" ]]; then
                log_error "Resolved MNI work-item input is missing: $required_file"
                return 1
            fi
        done

        if [[ -z "$refbold_t1w" ]]; then
            if [[ ! -f "$refbold_native" || ! -f "$matrix" ]]; then
                log_error "MNI work item needs either a T1w boldref or native boldref + BOLD-to-T1w transform."
                return 1
            fi
        fi
    else
        # use the canonical t1w boldref as the native functional reference
        refbold_native="$refbold_space"
    fi

    task="$func_task"
    acq="$func_acq"
    run="$func_run"
    space="$func_space"
    resolution="$func_res"
    export task acq run space resolution

    log_ok "Manifest inputs loaded"
    log_info "Entities: task=${func_task:-<none>} acq=${func_acq:-<none>} run=${func_run:-<none>} space=${func_space:-native} res=${func_res:-<none>}"
    log_info "Subject/session: $subject_id / ${session_id:-<none>}"
    log_debug "canonical_boldref=$refbold_space"
    log_debug "anat_dir=$anat_dir"
    log_debug "func_dir=$func_dir"
    log_debug "anat_t1=$anat_t1"
    log_debug "mask_anat_native=$mask_anat_native"
    log_debug "gm_seg_native=$gm_seg_native"
    log_debug "matrix=${matrix:-}"
    log_debug "mask_func_space=$mask_func_space"
    log_debug "refbold_native=${refbold_native:-}"
    log_debug "refbold_t1w=${refbold_t1w:-}"
    log_debug "anat_mni=${anat_mni:-}"
    log_debug "mask_anat_mni=${mask_anat_mni:-}"
    log_debug "gm_seg_mni=${gm_seg_mni:-}"
}

select_metric_space_files() {
    if is_mni_space "$func_space"; then
        mask_anat_space="$mask_anat_mni"
        gm_seg_space="$gm_seg_mni"
    else
        mask_anat_space="$mask_anat_native"
        gm_seg_space="$gm_seg_native"
    fi

    metric_space="${func_space:-native}"

    space="$metric_space"
    resolution="${func_res:-}"
    export space resolution

    log_ok "Selected metric space: $metric_space"
}
# process one work item

publish_worker_metric_csvs() {
    local source_dir="${1:-}"
    local destination_dir="${2:-}"
    local prefix="${3:-work_item}"
    local metric_file

    mkdir -p "$destination_dir"

    while IFS= read -r -d '' metric_file; do
        cp -- "$metric_file" \
            "$destination_dir/${prefix}_$(basename -- "$metric_file")"
    done < <(
        find "$source_dir" \
            -maxdepth 1 \
            -type f \
            -name '*.csv' \
            -print0
    )
}

process_work_item() {
    id_key="${1:-}"

    local task_token="${2:-__NONE__}"
    local acq_token="${3:-__NONE__}"
    local run_token="${4:-__NONE__}"
    local space_token="${5:-__NONE__}"
    local resolution_token="${6:-__NA__}"
    local work_item_boldref="${7:-}"
    local work_item_func_mask="${8:-}"
    local work_item_anat_t1="${9:-}"
    local work_item_anat_mask_native="${10:-}"
    local work_item_gm_native="${11:-}"
    local work_item_anat_mni="${12:-}"
    local work_item_anat_mask_mni="${13:-}"
    local work_item_gm_mni="${14:-}"
    local work_item_refbold_t1w="${15:-}"
    local work_item_refbold_native="${16:-}"
    local work_item_matrix="${17:-}"
    local work_item_subject_id="${18:-}"
    local work_item_session_id="${19:-__NONE__}"
    local work_item_anat_dir="${20:-}"
    local work_item_func_dir="${21:-}"

    if [[ -z "$id_key" ]]; then
        log_error "process_work_item requires a work-item key."
        return 1
    fi

    if [[ "$id_key" != sub-* ]]; then
        log_error "Work-item key must start with 'sub-': $id_key"
        return 1
    fi

    func_task=""
    func_acq=""
    func_run=""
    func_space="$space_token"
    func_res=""

    if [[ "$task_token" != "__NONE__" ]]; then
        func_task="$task_token"
    fi

    if [[ "$acq_token" != "__NONE__" ]]; then
        func_acq="$acq_token"
    fi

    if [[ "$run_token" != "__NONE__" ]]; then
        func_run="$run_token"
    fi

    if [[ "$resolution_token" != "__NA__" ]]; then
        func_res="$resolution_token"
    fi

    task="$func_task"
    acq="$func_acq"
    run="$func_run"
    space="$func_space"
    resolution="$func_res"

    export task acq run space resolution

    local work_item_id="$id_key"
    work_item_id+="_task-${func_task:-none}"
    work_item_id+="_acq-${func_acq:-none}"
    work_item_id+="_run-${func_run:-none}"
    work_item_id+="_space-${func_space:-none}"
    work_item_id+="_res-${func_res:-none}"

    id_tmp_dir="$work_dir/$work_item_id"

    rm -rf -- "$id_tmp_dir"
    mkdir -p -- "$id_tmp_dir"

    cleanup_work_item_tmp() {
        rm -rf -- "$id_tmp_dir"
    }

    if [[ "${no_temp_cleanup:-0}" == "1" ]]; then
        log_info "Temporary work files will be kept: $id_tmp_dir"
    else
        trap cleanup_work_item_tmp RETURN
    fi

    LOG_CONTEXT="$work_item_id"
    log_section "Processing $work_item_id"

    local central_metrics_dir="$metrics_dir"
    local central_dice_dir="$dice_dir"
    local central_dropout_dir="$dropout_dir"
    local central_nmi_dir="$nmi_dir"

    metrics_dir="$id_tmp_dir/metrics"
    dice_dir="$metrics_dir/dice"
    dropout_dir="$metrics_dir/dropout"
    nmi_dir="$metrics_dir/nmi"

    mkdir -p \
        "$dice_dir" \
        "$dropout_dir" \
        "$nmi_dir"

    load_work_item_inputs
    select_metric_space_files


    log_debug "mask_anat_space=$mask_anat_space"
    log_debug "mask_func_space=$mask_func_space"
    log_debug "refbold_space=$refbold_space"
    log_debug "gm_seg_space=$gm_seg_space"

    case "$func_space" in
        T1w)
            # t1w inputs may share coordinates but use different voxel grids
            # resample functional inputs to the anatomical grid for dice and dropout
            local ref_anatmask="$mask_anat_space"
            local ref_t1="$anat_t1"
            log_step \
                "Resampling T1w-spaced functional inputs to the T1w grid"

            if ! resample_to_t1 \
                "$mask_func_space" \
                "$refbold_native" \
                "$ref_anatmask" \
                "$ref_t1"
            then
                log_error \
                    "Could not resample T1w functional inputs to the anatomical grid"
                return 1
            fi

            mask_func_space="$mask_func_anatres"
            refbold_space="$refbold_anatres"

            log_debug \
                "resampled_mask_func_space=$mask_func_space"
            log_debug \
                "resampled_refbold_space=$refbold_space"
            ;;

        *MNI*)
            # mni derivatives are already in the requested template space and resolution
            ;;

        *)
            log_error \
                "Unsupported functional work-item space: ${func_space:-<empty>}"
            return 1
            ;;
    esac

    if ! extract_dice_metric \
        "$id_key" \
        "$mask_anat_space" \
        "$mask_func_space" \
        "$metric_space" \
        "$func_task" \
        "$func_acq" \
        "$func_run" \
        "$func_res"
    then
        log_error "Dice metric failed"
        return 1
    fi

    if ! extract_dropout_metric \
        "$id_key" \
        "$gm_seg_space" \
        "$mask_anat_space" \
        "$mask_func_space" \
        "$refbold_space" \
        "$metric_space" \
        "$func_task" \
        "$func_acq" \
        "$func_run" \
        "$func_res"
    then
        log_error "Dropout metric failed"
        return 1
    fi

    # compute t1/bold nmi on a boldref grid for every work item
    # preserve the original t1w boldref grid and functional resolution for t1w nmi
    # mni work items also compute warped-t1/mni nmi against templateflow
    local refbold_t1space
    local template_t1=""
    local template_mask=""
    local entropy_mni="NA"

    if is_mni_space "$metric_space"; then
        if ! refbold_t1space=$(
            transform_bold_t1space \
                "$id_key" \
                "$anat_t1" \
                "${matrix:-}" \
                "${refbold_native:-}" \
                "${refbold_t1w:-}"
        )
        then
            log_error "BOLD-to-T1 transform failed"
            return 1
        fi

        local template_space="$func_space"
        local template_resolution="$func_res"

        if [[ -z "$template_resolution" ]]; then
            log_error \
                "Missing template resolution for MNI work item: $work_item_id"
            return 1
        fi

        if ! entropy_mni=$(
            lookup_template_entropy \
                "$template_space" \
                "$template_resolution"
        )
        then
            log_error "Template entropy lookup failed"
            return 1
        fi

        if ! template_t1=$(
            lookup_template_t1 \
                "$template_space" \
                "$template_resolution"
        )
        then
            log_error "TemplateFlow T1 lookup failed"
            return 1
        fi

        if ! template_mask=$(
            lookup_template_mask \
                "$template_space" \
                "$template_resolution"
        )
        then
            log_error "TemplateFlow mask lookup failed"
            return 1
        fi
    else
        # keep the canonical t1w boldref on its original functional grid
        # extract_nmi_metric resamples t1 and t1 mask to this grid
        refbold_t1space="$refbold_native"
        log_info "Computing T1/BOLD NMI on the native T1w BOLD-reference grid"
    fi

    if ! extract_nmi_metric \
        "$id_key" \
        "$anat_t1" \
        "$mask_anat_native" \
        "$refbold_t1space" \
        "${anat_mni:-}" \
        "$template_t1" \
        "$entropy_mni" \
        "$template_mask" \
        "$metric_space" \
        "$func_task" \
        "$func_acq" \
        "$func_run" \
        "$func_res"
    then
        log_error "NMI metric failed"
        return 1
    fi

    publish_worker_metric_csvs \
        "$dice_dir" \
        "$central_dice_dir" \
        "$work_item_id"

    publish_worker_metric_csvs \
        "$dropout_dir" \
        "$central_dropout_dir" \
        "$work_item_id"

    publish_worker_metric_csvs \
        "$nmi_dir" \
        "$central_nmi_dir" \
        "$work_item_id"

    metrics_dir="$central_metrics_dir"
    dice_dir="$central_dice_dir"
    dropout_dir="$central_dropout_dir"
    nmi_dir="$central_nmi_dir"

    log_ok "All applicable metrics completed successfully"
}

parallel_worker() {
    set +u
    set -e
    set -o pipefail
    process_work_item "$@"
}
# templateflow inputs

get_template_entropy() {
    local space="${1:-}"
    local resolution
    resolution=$(normalize_resolution "${2:-}")

    if [[ -z "$space" || -z "$resolution" ]]; then
        log_error "get_template_entropy requires space and resolution."
        return 1
    fi

    if [[ -z "$templateflow_dir" ]]; then
        templateflow_dir="$tmp_dir/templateflow"
        mkdir -p "$templateflow_dir"
        log_info "TemplateFlow directory not specified; using $templateflow_dir"
    else
        log_debug "Using TemplateFlow directory: $templateflow_dir"
    fi

    export TEMPLATEFLOW_HOME="$templateflow_dir"

    log_info "Preparing TemplateFlow ${space} res-${resolution}"
    fetch_templateflow "$space" "$resolution"

    local res_label
    res_label=$(templateflow_resolution_label "$resolution")

    local template_path template_mask_path
    template_path=$(find_single_file \
        "$templateflow_dir" \
        "tpl-${space}_res-${res_label}_T1w.nii.gz")

    template_mask_path=$(find_single_file \
        "$templateflow_dir" \
        "tpl-${space}_res-${res_label}_desc-brain_mask.nii.gz")

    ImageIntensityStatistics 3 "$template_path" "$template_mask_path" \
        | awk 'NR == 2 {print $6}'
}

build_template_lookup() {
    log_step "Building TemplateFlow lookup"

    local pairs_file="$tmp_dir/template_space_resolution.tsv"
    template_lookup_tsv="$tmp_dir/template_lookup.tsv"

    if [[ -z "$templateflow_dir" ]]; then
        templateflow_dir="$tmp_dir/templateflow"
    fi
    mkdir -p "$templateflow_dir"
    export TEMPLATEFLOW_HOME="$templateflow_dir"

    "$python_bin" - "$work_items_tsv" >"$pairs_file" <<'PY'
import sys
from pathlib import Path

work_items = Path(sys.argv[1])
pairs = set()

for line in work_items.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue

    fields = line.split("\t")
    if len(fields) < 6:
        raise SystemExit(f"Malformed work-item row: {line!r}")

    _, _, _, _, space, resolution = fields[:6]
    if "MNI" not in space.upper():
        continue
    if resolution == "__NA__":
        raise SystemExit(
            f"MNI work item is missing a resolution: {line!r}"
        )

    try:
        resolution = str(int(resolution, 10))
    except ValueError:
        pass

    pairs.add((space, resolution))

for space, resolution in sorted(pairs):
    print(f"{space}\t{resolution}")
PY

    : >"$template_lookup_tsv"

    if [[ ! -s "$pairs_file" ]]; then
        log_warn "No MNI space/resolution pairs were found; warped-T1/MNI NMI will be skipped. T1/BOLD NMI still runs."
        return 0
    fi

    local pair_count
    pair_count=$(awk 'NF {count++} END {print count+0}' "$pairs_file")
    log_info "Found $pair_count MNI template space/resolution pair(s)"

    local template_space template_resolution entropy res_label template_t1 template_mask
    while IFS=$'	' read -r template_space template_resolution; do
        [[ -z "$template_space" || -z "$template_resolution" ]] && continue
        entropy=$(get_template_entropy "$template_space" "$template_resolution")
        res_label=$(templateflow_resolution_label "$template_resolution")
        template_t1=$(find_single_file \
            "$templateflow_dir" \
            "tpl-${template_space}_res-${res_label}_T1w.nii.gz")
        template_mask=$(find_single_file \
            "$templateflow_dir" \
            "tpl-${template_space}_res-${res_label}_desc-brain_mask.nii.gz")
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$template_space" "$template_resolution" "$entropy" \
            "$template_t1" "$template_mask" \
            >>"$template_lookup_tsv"
        log_ok "Template inputs ready: ${template_space} res-${template_resolution}"
    done <"$pairs_file"

    log_ok "Template lookup written: $template_lookup_tsv"
}

# parallel worker context

export_parallel_context() {
    export SHELL="${BASH:-/bin/bash}"

    export config_file python_bin
    export no_temp_cleanup
    export tmp_dir output_dir extracted_metrics_file input_dir
    export templateflow_dir template_lookup_tsv
    export gm_threshold dropout_percentile mattes_bins
    export metrics_dir dice_dir dropout_dir nmi_dir work_dir
    export VERBOSE LOG_TIMESTAMPS
    export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN

    export -f log_message log_info log_ok log_warn log_error log_step log_debug log_section

    export -f require_command require_dir
    export -f read_yaml expand_config_vars
    export -f find_single_file

    export -f is_mni_space normalize_resolution
    export -f templateflow_resolution_label lookup_template_field lookup_template_entropy lookup_template_t1 lookup_template_mask
    export -f load_work_item_inputs select_metric_space_files
    export -f publish_worker_metric_csvs

    export -f extract_dice_metric extract_dropout_metric
    export -f transform_bold_t1space extract_nmi_metric
    export -f process_work_item parallel_worker
    export -f resample_to_t1
}

# metric explorer

render_metric_explorer() {
    if [[ "$metric_explorer_enabled" != "true" ]]; then
        log_info "Metric explorer: disabled"
        return 0
    fi

    if [[ ! -f "$metric_explorer_rmd" ]]; then
        log_warn "Metric explorer skipped: file not found: $metric_explorer_rmd"
        return 0
    fi

    if ! command -v Rscript >/dev/null 2>&1; then
        log_warn "Metric explorer skipped: Rscript is not available"
        return 0
    fi

    if ! Rscript -e 'pkgs <- c("rmarkdown", "tidyverse", "robustbase", "reticulate", "plotly", "htmlwidgets", "htmltools"); missing <- pkgs[!vapply(pkgs, requireNamespace, quietly=TRUE, FUN.VALUE=logical(1))]; if (length(missing)) { message("missing R packages: ", paste(missing, collapse=", ")); quit(status=1) }' >/dev/null 2>&1; then
        log_warn "Metric explorer skipped: required R packages are missing"
        return 0
    fi

    local spaces_file="$tmp_dir/metric_explorer_spaces.txt"
    if ! "$python_bin" - "$extracted_metrics_file" >"$spaces_file" <<'PYSPACES'
import csv
import sys

path = sys.argv[1]
spaces = set()
with open(path, newline="", encoding="utf-8") as handle:
    reader = csv.DictReader(handle)
    if not reader.fieldnames or "space" not in reader.fieldnames:
        raise SystemExit("final qc csv has no space column")
    for row in reader:
        space = (row.get("space") or "").strip()
        if space:
            spaces.add(space)

for space in sorted(spaces):
    print(space)
PYSPACES
    then
        log_warn "Metric explorer skipped: could not read output spaces"
        return 0
    fi

    if [[ ! -s "$spaces_file" ]]; then
        log_warn "Metric explorer skipped: no output spaces found"
        return 0
    fi

    mkdir -p "$metric_explorer_dir"
    log_step "Rendering metric explorer reports"

    local space safe_space space_dir report_file
    while IFS= read -r space; do
        [[ -z "$space" ]] && continue

        safe_space=$(printf '%s' "$space" | tr -c '[:alnum:]_.-' '_')
        space_dir="$metric_explorer_dir/$safe_space"
        report_file="metric_explorer_${safe_space}.html"
        mkdir -p "$space_dir"

        if Rscript - \
            "$metric_explorer_rmd" \
            "$extracted_metrics_file" \
            "$space" \
            "$space_dir" \
            "$report_file" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)

rmarkdown::render(
  input = args[[1]],
  params = list(
    qc_csv = args[[2]],
    space = args[[3]],
    output_dir = args[[4]]
  ),
  output_file = args[[5]],
  output_dir = args[[4]],
  envir = new.env(parent = globalenv()),
  quiet = TRUE
)
RSCRIPT
        then
            log_ok "Metric explorer ready: $space_dir/$report_file"
        else
            log_warn "Metric explorer failed for space=$space; QC metrics remain available"
        fi
    done <"$spaces_file"
}

# run dataset

run_dataset() {
    log_section "Dataset metrics pipeline"
    log_info "Input directory: $input_dir"
    log_info "Temporary directory: $tmp_dir"
    log_info "Final CSV: $extracted_metrics_file"
    log_info "Parallel jobs: $n_jobs"

    if (( no_temp_cleanup )); then
        log_info "Cleanup of temporary files: disabled"
    else
        log_info "Cleanup of temporary files: enabled"
    fi

    work_items_tsv="$tmp_dir/functional_work_items.tsv"

    build_work_items "$work_items_tsv"
    build_template_lookup
    initialize_outputs
    export_parallel_context

    local job_count
    job_count=$(awk 'NF {count++} END {print count+0}' "$work_items_tsv")
    log_ok "Discovered $job_count canonical BOLD-reference work item(s)"

    local discovered_key discovered_task discovered_acq
    local discovered_run discovered_space discovered_res
    local discovered_boldref discovered_func_mask discovered_anat_t1
    local discovered_anat_mask discovered_gm discovered_anat_mni
    local discovered_anat_mask_mni discovered_gm_mni discovered_refbold_t1w
    local discovered_refbold_native discovered_matrix discovered_subject
    local discovered_session discovered_anat_dir discovered_func_dir

    while IFS=$'	' read -r \
        discovered_key \
        discovered_task \
        discovered_acq \
        discovered_run \
        discovered_space \
        discovered_res \
        discovered_boldref \
        discovered_func_mask \
        discovered_anat_t1 \
        discovered_anat_mask \
        discovered_gm \
        discovered_anat_mni \
        discovered_anat_mask_mni \
        discovered_gm_mni \
        discovered_refbold_t1w \
        discovered_refbold_native \
        discovered_matrix \
        discovered_subject \
        discovered_session \
        discovered_anat_dir \
        discovered_func_dir
    do
        [[ -z "$discovered_key" ]] && continue
        [[ "$discovered_task" == "__NONE__" ]] && discovered_task="<none>"
        [[ "$discovered_acq" == "__NONE__" ]] && discovered_acq="<none>"
        [[ "$discovered_run" == "__NONE__" ]] && discovered_run="<none>"
        [[ "$discovered_res" == "__NA__" ]] && discovered_res="<none>"
        [[ "$discovered_session" == "__NONE__" ]] && discovered_session="<none>"
        log_debug "work_item=$discovered_key task=$discovered_task acq=$discovered_acq run=$discovered_run space=$discovered_space res=$discovered_res session=$discovered_session"
        log_debug "canonical_boldref=$discovered_boldref anat=$discovered_anat_dir func=$discovered_func_dir"
    done <"$work_items_tsv"

    mkdir -p "$tmp_dir/parallel_logs"

    log_step "Launching $job_count work item(s) with $n_jobs parallel job(s)"
    parallel \
        --jobs "$n_jobs" \
        --halt soon,fail=1 \
        --line-buffer \
        --colsep '	' \
        --joblog "$tmp_dir/parallel_joblog.tsv" \
        --results "$tmp_dir/parallel_logs/{#}_{1}_task-{2}_acq-{3}_run-{4}_space-{5}_res-{6}.stdout" \
        parallel_worker '{1}' '{2}' '{3}' '{4}' '{5}' '{6}' '{7}' '{8}' '{9}' '{10}' '{11}' '{12}' '{13}' '{14}' '{15}' '{16}' '{17}' '{18}' '{19}' '{20}' '{21}' \
        :::: "$work_items_tsv"

    log_ok "All parallel workers completed"
    log_info "GNU Parallel job log: $tmp_dir/parallel_joblog.tsv"
    log_debug "Per-job stdout/stderr: $tmp_dir/parallel_logs"

    log_step "Merging Dice, dropout, and NMI CSV files"
    merge_metrics

    local output_rows=0
    if [[ -f "$extracted_metrics_file" ]]; then
        output_rows=$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "$extracted_metrics_file")
    fi
    log_ok "Metric extraction complete: wrote $output_rows row(s) to $extracted_metrics_file"

    render_metric_explorer

    log_ok "Pipeline complete"
}

# main

main() {
    log_section "Starting image-quality metrics runner"
    log_info "Configuration file: $config_file"
    log_info "Logging: VERBOSE=${VERBOSE}; colors=$([[ -n "$C_RESET" ]] && printf enabled || printf disabled)"

    check_dependencies

    log_step "Reading configuration"
    read_config
    log_ok "Configuration loaded"
    log_debug "gm_threshold=$gm_threshold"
    log_debug "dropout_percentile=$dropout_percentile"
    log_debug "mattes_bins=$mattes_bins"

    check_inputs_global
    run_dataset
}

main "$@"