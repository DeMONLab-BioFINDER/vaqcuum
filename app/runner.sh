#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CLI LOGGING
# ============================================================

# Controls:
#   VERBOSE=1        print detailed file paths and intermediate values
#   NO_COLOR=1       disable ANSI colors
#   FORCE_COLOR=1    force colors even when stderr is not a TTY
#   LOG_TIMESTAMPS=0 disable timestamps

VERBOSE="${VERBOSE:-2}"
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


# ============================================================
# PATHS AND CONFIGURATION
# ============================================================

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_file="${1:-}"

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
    "$script_dir/dataset_utils.py"
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

# ============================================================
# GENERAL HELPERS
# ============================================================

is_mni_space() {
    local value="${1:-}"
    [[ "${value^^}" == *MNI* ]]
}

# Accept a JSON scalar or array and return one non-null value.
# Use this only for fields that are genuinely singular for a work item. Fields
# such as functional space, resolution, acquisition, and run are expanded into
# separate work items before GNU Parallel is launched.
json_single_value() {
    local json_value="${1:-null}"
    local field_name="${2:-value}"
    local session_label="${3:-null}"
    local values count

    values=$(jq -r '
        if . == null then
            empty
        elif type == "array" then
            map(select(. != null and . != "")) | unique[]
        else
            select(. != "")
        end
    ' <<<"$json_value")

    count=$(awk 'NF {n++} END {print n+0}' <<<"$values")

    if (( count > 1 )); then
        log_error "Multiple files found values found for ${field_name} in ${session_label}:"
        sed 's/^/  - /' <<<"$values" >&2
        log_info "This runner needs one value per session key. Split these into separate"
        log_info "work items in dataset_utils.py before running the metrics."
        return 1
    fi

    head -n 1 <<<"$values"
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

lookup_template_entropy() {
    local requested_space="${1-}"
    local requested_resolution="${2-}"
    local lookup_file="${entropy_lookup_tsv-}"

    requested_resolution=$(normalize_resolution "$requested_resolution")

    if [[ -z "$requested_space" ]]; then
        log_error "Template space is missing."
        return 1
    fi

    if [[ -z "$requested_resolution" ]]; then
        log_error "Template resolution is missing."
        return 1
    fi

    if [[ -z "$lookup_file" || ! -f "$lookup_file" ]]; then
        log_error "Entropy lookup file is missing: ${lookup_file:-<unset>}"
        return 1
    fi

    local entropy
    entropy=$(
        awk -F $'\t' \
            -v wanted_space="$requested_space" \
            -v wanted_res="$requested_resolution" '
                $1 == wanted_space && $2 == wanted_res {
                    print $3
                    found = 1
                    exit
                }

                END {
                    if (!found) {
                        exit 1
                    }
                }
            ' "$lookup_file"
    ) || {
        log_error "No template entropy found for space=${requested_space}, res=${requested_resolution}."
        return 1
    }

    if [[ -z "$entropy" ]]; then
        log_error "Empty entropy value for space=${requested_space}, res=${requested_resolution}."
        return 1
    fi

    printf '%s\n' "$entropy"
}


find_wrapped_session_anat_dir() {
    local subject_id="${1:-}"
    local session_id="${2:-}"

    if [[ -z "$subject_id" || -z "$session_id" ]]; then
        return 1
    fi

    # A wrapped directory may contain a provenance/version suffix, for example:
    #   sub-31728786_ses-0_fmriprep-25-2-5
    # Match both the bare prefix and any underscore-delimited suffix.
    local wrapper_prefix="${subject_id}_${session_id}"
    local wrapper_dir=""
    local candidate=""
    local first_match=""
    local match_count=0

    while IFS= read -r -d '' wrapper_dir; do
        while IFS= read -r candidate; do
            [[ -z "$candidate" ]] && continue
            ((match_count += 1))
            if (( match_count == 1 )); then
                first_match="$candidate"
            fi
        done < <(
            find "$wrapper_dir" \
                -type d \
                -path "*/${subject_id}/${session_id}/anat" \
                -print
        )
    done < <(
        find "$input_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            \( -name "$wrapper_prefix" -o -name "${wrapper_prefix}_*" \) \
            -print0
    )

    if (( match_count == 1 )); then
        printf '%s\n' "$first_match"
        return 0
    fi

    if (( match_count > 1 )); then
        log_error "Multiple wrapped anat directories match ${subject_id}_${session_id}:"
        while IFS= read -r -d '' wrapper_dir; do
            find "$wrapper_dir" \
                -type d \
                -path "*/${subject_id}/${session_id}/anat" \
                -print \
                | sed 's/^/  - /' >&2
        done < <(
            find "$input_dir" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                \( -name "$wrapper_prefix" -o -name "${wrapper_prefix}_*" \) \
                -print0
        )
    fi

    return 1
}

find_session_anat_dir() {
    local subject_id="${1:-}"
    local session_id="${2:-}"

    if [[ -z "$subject_id" || -z "$session_id" ]]; then
        return 1
    fi

    # Layout 1: input_dir/sub-*/ses-*/**/anat
    local session_dir="$input_dir/$subject_id/$session_id"

    if [[ -d "$session_dir" ]]; then
        local anat_dir
        local -a anat_matches=()

        while IFS= read -r -d '' anat_dir; do
            anat_matches+=("$anat_dir")
        done < <(
            find "$session_dir" \
                -mindepth 1 \
                -type d \
                -name anat \
                -print0
        )

        if (( ${#anat_matches[@]} == 1 )); then
            printf '%s\n' "${anat_matches[0]}"
            return 0
        elif (( ${#anat_matches[@]} > 1 )); then
            log_error \
                "Found multiple anat directories for ${subject_id}/${session_id}"
            return 1
        fi
    fi

    # Layout 2: input_dir/sub-*_ses-*[_suffix]/**/sub-*/ses-*/anat
    find_wrapped_session_anat_dir "$subject_id" "$session_id"
}

validate_input_subject_directories() {
    log_step "Validating supported input directory structures"

    local child_dir child_name
    local standard_count=0
    local wrapped_count=0
    local ignored_count=0
    local invalid_count=0
    local -a invalid_entries=()
    local -a ignored_entries=()

    while IFS= read -r -d '' child_dir; do
        child_name=${child_dir##*/}

        # Layout 1: input_dir/sub-*/ses-*/**/anat
        if [[ "$child_name" =~ ^sub-[A-Za-z0-9]+$ ]]; then
            local session_dir session_name anat_dir
            local session_count=0
            local invalid_subject=0
            local -a anat_matches=()

            while IFS= read -r -d '' session_dir; do
                session_name=${session_dir##*/}
                [[ ! "$session_name" =~ ^ses-[A-Za-z0-9]+$ ]] && continue

                ((session_count += 1))
                anat_matches=()

                while IFS= read -r -d '' anat_dir; do
                    anat_matches+=("$anat_dir")
                done < <(
                    find "$session_dir" \
                        -mindepth 1 \
                        -type d \
                        -name anat \
                        -print0
                )

                if (( ${#anat_matches[@]} == 1 )); then
                    log_debug \
                        "standard_session=${child_name}/${session_name} anat=${anat_matches[0]}"
                elif (( ${#anat_matches[@]} == 0 )); then
                    invalid_entries+=(
                        "$session_dir :: missing nested anat directory"
                    )
                    ((invalid_count += 1))
                    invalid_subject=1
                else
                    invalid_entries+=(
                        "$session_dir :: found multiple nested anat directories"
                    )
                    ((invalid_count += 1))
                    invalid_subject=1
                fi
            done < <(
                find "$child_dir" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -type d \
                    -print0
            )

            if (( session_count == 0 )); then
                invalid_entries+=(
                    "$child_dir :: expected at least one ses-*/**/anat directory"
                )
                ((invalid_count += 1))
            elif (( invalid_subject == 0 )); then
                ((standard_count += 1))
            fi

            continue
        fi

        # Layout 2: input_dir/sub-*_ses-*[_suffix]/**/sub-*/ses-*/anat
        # Examples:
        #   sub-31728786_ses-0
        #   sub-31728786_ses-0_fmriprep-25-2-5
        if [[ "$child_name" =~ ^(sub-[A-Za-z0-9]+)_(ses-[A-Za-z0-9]+)(_.+)?$ ]]; then
            local wrapped_subject wrapped_session wrapped_anat
            wrapped_subject="${BASH_REMATCH[1]}"
            wrapped_session="${BASH_REMATCH[2]}"

            # Validate this specific wrapper, not another directory sharing the
            # same subject/session prefix.
            local -a wrapped_matches=()

            while IFS= read -r -d '' wrapped_anat; do
                wrapped_matches+=("$wrapped_anat")
            done < <(
                find "$child_dir" \
                    -type d \
                    -path "*/${wrapped_subject}/${wrapped_session}/anat" \
                    -print0
            )

            if (( ${#wrapped_matches[@]} == 1 )); then
                ((wrapped_count += 1))
                log_debug \
                    "wrapped_session=$child_name anat=${wrapped_matches[0]}"
            elif (( ${#wrapped_matches[@]} == 0 )); then
                invalid_entries+=(
                    "$child_dir :: missing nested ${wrapped_subject}/${wrapped_session}/anat directory"
                )
                ((invalid_count += 1))
            else
                invalid_entries+=(
                    "$child_dir :: found multiple nested ${wrapped_subject}/${wrapped_session}/anat directories"
                )
                ((invalid_count += 1))
            fi

            continue
        fi

        # Unrelated top-level directories are allowed.
        ignored_entries+=("$child_dir")
        ((ignored_count += 1))
        log_debug "Ignoring unrelated top-level directory: $child_dir"
    done < <(
        find "$input_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print0
    )

    if (( invalid_count > 0 )); then
        log_error "Input directory validation failed for $invalid_count path(s)."
        log_error "Supported layouts are:"
        printf '  1. %s/sub-*/ses-*/**/anat\n' "$input_dir" >&2
        printf '  2. %s/sub-*_ses-*[_suffix]/**/sub-*/ses-*/anat\n' \
            "$input_dir" >&2

        local entry
        for entry in "${invalid_entries[@]}"; do
            printf '  - %s\n' "$entry" >&2
        done

        return 1
    fi

    if (( standard_count + wrapped_count == 0 )); then
        log_error "No valid subject/session directories were found in: $input_dir"
        log_error \
            "Expected either sub-*/ses-*/**/anat or sub-*_ses-*[_suffix]/**/sub-*/ses-*/anat."
        return 1
    fi

    if (( ignored_count > 0 )); then
        log_info \
            "Ignored ${ignored_count} unrelated top-level director$([[ $ignored_count -eq 1 ]] && printf 'y' || printf 'ies')"

        if [[ "${VERBOSE:-0}" == "1" ]]; then
            local ignored_entry
            for ignored_entry in "${ignored_entries[@]}"; do
                log_debug "ignored=$ignored_entry"
            done
        fi
    fi

    log_ok \
        "Validated input layout: ${standard_count} standard subject folder(s), ${wrapped_count} wrapped session folder(s)"
}

validate_id_keys_file() {
    local keys_file="${1:-}"

    if [[ -z "$keys_file" || ! -f "$keys_file" ]]; then
        log_error "Session-key file is missing: ${keys_file:-<unset>}"
        return 1
    fi

    log_step "Validating discovered session keys against input folders"

    local id_key_value subject_id session_id anat_dir
    local key_count=0
    local invalid_count=0

    while IFS= read -r id_key_value || [[ -n "$id_key_value" ]]; do
        [[ -z "$id_key_value" ]] && continue
        ((key_count += 1))

        if [[ ! "$id_key_value" =~ ^sub-[A-Za-z0-9]+_ses-[A-Za-z0-9]+($|_) ]]; then
            log_error "Session key must begin with sub-<label>_ses-<label>: $id_key_value"
            ((invalid_count += 1))
            continue
        fi

        subject_id=$(grep -oE '^sub-[A-Za-z0-9]+' <<<"$id_key_value" | head -n 1 || true)
        session_id=$(grep -oE '(^|_)ses-[A-Za-z0-9]+' <<<"$id_key_value" | head -n 1 | sed 's/^_//' || true)

        if [[ -z "$subject_id" || -z "$session_id" ]]; then
            log_error "Could not parse subject/session IDs from key: $id_key_value"
            ((invalid_count += 1))
            continue
        fi
        echo "Validating session key: $id_key_value (subject=$subject_id, session=$session_id)"
        if anat_dir=$(find_session_anat_dir "$subject_id" "$session_id"); then
            log_debug "validated_id_key=$id_key_value anat_dir=$anat_dir"
        else
            log_error "Session key '$id_key_value' does not match either supported layout:"
            printf '  - %s/%s/%s/anat\n' "$input_dir" "$subject_id" "$session_id" >&2
            printf '  - %s/%s_%s/**/%s/%s/anat\n' \
                "$input_dir" "$subject_id" "$session_id" "$subject_id" "$session_id" >&2
            ((invalid_count += 1))
        fi
    done <"$keys_file"

    if (( invalid_count > 0 )); then
        log_error "Session-key validation failed for $invalid_count work item(s)."
        return 1
    fi

    if (( key_count == 0 )); then
        log_error "No non-empty session keys were available to validate."
        return 1
    fi

    log_ok "Validated $key_count session key(s) against both supported layouts"
}

# ============================================================
# READ CONFIG
# ============================================================

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
    anat_earliest_ses=$(read_yaml '.settings.anat_earliest_ses // "no"')
    n_jobs=$(read_yaml '.parallelization.n_jobs')

    mkdir -p "$tmp_dir" "$output_dir"
}

# ============================================================
# CHECKS
# ============================================================

check_dependencies() {
    log_step "Checking required commands and Python packages"

    require_command yq
    require_command jq
    require_command fslstats
    require_command fslmaths
    require_command python
    require_command parallel

    require_command antsApplyTransforms
    require_command MeasureImageSimilarity
    require_command ImageIntensityStatistics

    python - <<'PY'
import pandas  # noqa: F401
PY

    log_ok "All dependencies are available"
}

check_inputs_global() {
    log_step "Validating configuration and input paths"
    require_dir "$input_dir" "input"
    validate_input_subject_directories

    if [[ -z "$n_jobs" || "$n_jobs" == "null" ]]; then
        log_error "parallelization.n_jobs is missing from config."
        exit 1
    fi

    if ! [[ "$n_jobs" =~ ^[0-9]+$ ]]; then
        log_error "parallelization.n_jobs must be an integer."
        exit 1
    fi

    if (( n_jobs < 1 )); then
        log_error "parallelization.n_jobs must be >= 1."
        exit 1
    fi

    case "${anat_earliest_ses,,}" in
        yes|no) ;;
        *)
            log_error "settings.anat_earliest_ses must be 'yes' or 'no'."
            exit 1
            ;;
    esac

    log_ok "Configuration validation passed"
}

# ============================================================
# OUTPUT INITIALIZATION
# ============================================================

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

# ============================================================
# SUBJECT/SESSION FILE RESOLUTION
# ============================================================

build_work_items() {
    local output_file="${1:-}"

    if [[ -z "$output_file" ]]; then
        log_error "build_work_items requires an output file."
        return 1
    fi

    log_step "Building one work item per functional entity combination"

    python - "$dataset_summary_json" >"$output_file" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
summary = json.loads(summary_path.read_text(encoding="utf-8"))

NONE = "__NONE__"
NO_RESOLUTION = "__NA__"

ENTITY_PATTERNS = {
    name: re.compile(rf"(?:^|_){name}-([^_.]+)")
    for name in ("task", "acq", "run", "space", "res")
}


def values(value):
    if isinstance(value, list):
        return [item for item in value if item not in (None, "")]
    if value in (None, ""):
        return []
    return [value]


def paths(value):
    if isinstance(value, list):
        return [Path(item) for item in value if item not in (None, "")]
    if value in (None, ""):
        return []
    return [Path(value)]


def entity(filename: str, name: str) -> str:
    match = ENTITY_PATTERNS[name].search(filename)
    return match.group(1) if match else ""


def token(value: str, missing: str = NONE) -> str:
    return value if value else missing


def normalize_resolution(value: object) -> str:
    if value in (None, ""):
        return ""

    value = str(value)
    try:
        return str(int(value, 10))
    except ValueError:
        return value


records: set[tuple[str, str, str, str, str, str]] = set()

for id_key, session in sorted(summary.get("session_summary", {}).items()):
    func = session.get("func", {}) or {}
    func_dirs = paths(func.get("path"))
    summary_spaces = {str(item) for item in values(func.get("space"))}
    summary_resolutions = {
        normalize_resolution(item)
        for item in values(func.get("res"))
    }

    if not func_dirs:
        raise SystemExit(f"No functional path was recorded for {id_key}")

    session_records: set[tuple[str, str, str, str, str, str]] = set()
    coreg_records: set[tuple[str, str, str]] = set()

    for func_dir in func_dirs:
        if not func_dir.is_dir():
            raise SystemExit(
                f"Functional directory does not exist for {id_key}: {func_dir}"
            )

        for file_path in sorted(func_dir.rglob("*boldref.nii.gz")):
            filename = file_path.name
            if not filename.startswith(id_key):
                continue

            task = entity(filename, "task")
            acq = entity(filename, "acq")
            run = entity(filename, "run")
            space = entity(filename, "space")
            resolution = normalize_resolution(entity(filename, "res"))

            if not space:
                if filename.endswith("desc-coreg_boldref.nii.gz"):
                    coreg_records.add((task, acq, run))
                continue

            if not resolution and "MNI" in space.upper():
                if len(summary_resolutions) == 1:
                    resolution = next(iter(summary_resolutions))
                elif len(summary_resolutions) > 1:
                    raise SystemExit(
                        f"Cannot determine resolution for {file_path}; "
                        f"session summary contains {sorted(summary_resolutions)!r}"
                    )

            session_records.add(
                (
                    str(id_key),
                    token(task),
                    token(acq),
                    token(run),
                    space,
                    token(resolution, NO_RESOLUTION),
                )
            )

    # Some pipelines expose the T1w BOLD reference only as desc-coreg_boldref
    # without an explicit space-T1w entity. Preserve it as a T1w work item when
    # the dataset summary says T1w exists. If there are no explicit spaces at
    # all, preserve it as native.
    explicit_t1w_keys = {
        (record[1], record[2], record[3])
        for record in session_records
        if record[4].upper() == "T1W"
    }

    fallback_space = "T1w" if "T1w" in summary_spaces else "native"
    for task, acq, run in coreg_records:
        key = (token(task), token(acq), token(run))
        if key in explicit_t1w_keys:
            continue
        session_records.add(
            (
                str(id_key),
                key[0],
                key[1],
                key[2],
                fallback_space,
                NO_RESOLUTION,
            )
        )

    if not session_records:
        raise SystemExit(
            f"No functional BOLD-reference work items were found for {id_key}"
        )

    records.update(session_records)

if not records:
    raise SystemExit("No functional work items were discovered")

for record in sorted(records):
    print(*record, sep="\t")
PY

    if [[ ! -s "$output_file" ]]; then
        log_error "No functional work items were generated."
        return 1
    fi

    local count
    count=$(awk 'NF {count++} END {print count+0}' "$output_file")
    log_ok "Built $count functional work item(s)"
}

bids_entity_value() {
    local path_value="${1:-}"
    local entity_name="${2:-}"
    local filename="${path_value##*/}"

    if [[ -n "$entity_name" && "$filename" =~ (^|_)${entity_name}-([^_.]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    fi

    return 0
}

entity_spec_matches() {
    local path_value="${1:-}"
    local entity_name="${2:-}"
    local wanted="${3:-__ANY__}"
    local actual=""

    case "$wanted" in
        __ANY__)
            return 0
            ;;
    esac

    actual=$(bids_entity_value "$path_value" "$entity_name")

    if [[ "$wanted" == "__NONE__" ]]; then
        [[ -z "$actual" ]]
        return
    fi

    # Dataset discovery normalizes numeric resolutions (for example, res-02
    # becomes 2). Normalize the filename value as well before comparing.
    if [[ "$entity_name" == "res" ]]; then
        actual=$(normalize_resolution "$actual")
        wanted=$(normalize_resolution "$wanted")
    fi

    [[ "$actual" == "$wanted" ]]
}

find_single_bids_file() {
    local search_dir="${1:-}"
    local id_prefix="${2:-}"
    local suffix="${3:-}"
    local label="${4:-file}"
    local task_spec="${5:-__ANY__}"
    local acq_spec="${6:-__ANY__}"
    local run_spec="${7:-__ANY__}"
    local space_spec="${8:-__ANY__}"
    local res_spec="${9:-__ANY__}"
    local requirement="${10:-required}"

    local candidate
    local -a matches=()

    while IFS= read -r -d '' candidate; do
        entity_spec_matches "$candidate" task "$task_spec" || continue
        entity_spec_matches "$candidate" acq "$acq_spec" || continue
        entity_spec_matches "$candidate" run "$run_spec" || continue
        entity_spec_matches "$candidate" space "$space_spec" || continue
        entity_spec_matches "$candidate" res "$res_spec" || continue
        matches+=("$candidate")
    done < <(
        find "$search_dir" \
            -type f \
            -name "${id_prefix}*${suffix}" \
            -print0
    )

    if (( ${#matches[@]} == 1 )); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi

    if (( ${#matches[@]} == 0 )) && [[ "$requirement" == "optional" ]]; then
        return 1
    fi

    if (( ${#matches[@]} == 0 )); then
        log_error "No $label found."
        log_error "search_dir=$search_dir suffix=$suffix"
        log_error "entities: task=$task_spec acq=$acq_spec run=$run_spec space=$space_spec res=$res_spec"
    else
        log_error "Multiple files match $label:"
        printf '  - %s\n' "${matches[@]}" >&2
    fi

    return 1
}

resolve_subject_session_inputs() {
    log_step "Resolving anatomical and functional inputs"

    local anat_dir_json func_dir_json
    local func_task_json
    local anat_acq_json

    anat_dir_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].anat.path // null' "$dataset_summary_json")
    func_dir_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].func.path // null' "$dataset_summary_json")

    anat_dir=$(json_single_value "$anat_dir_json" "anat.path" "$id_key")
    func_dir=$(json_single_value "$func_dir_json" "func.path" "$id_key")

    if [[ -z "$anat_dir" || -z "$func_dir" ]]; then
        log_error "Could not read anat/func paths for $id_key."
        return 1
    fi

    func_task_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].func.task // null' "$dataset_summary_json")
    anat_acq_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].anat.acq // null' "$dataset_summary_json")

    anat_acq=$(json_single_value "$anat_acq_json" "anat.acq" "$id_key")

    # The work-item manifest already carries the concrete task. Consult the
    # session summary only for older summaries/jobs that do not provide one.
    # This avoids rejecting sessions whose func.task field is an array.
    if [[ -z "$func_task" ]]; then
        func_task=$(json_single_value "$func_task_json" "func.task" "$id_key")
    fi

    func_res=$(normalize_resolution "$func_res")

    task="$func_task"
    acq="$func_acq"
    run="$func_run"
    space="$func_space"
    resolution="$func_res"
    export task acq run space resolution

    local anat_acq_spec="__NONE__"
    local task_spec="__NONE__"
    local func_acq_spec="__NONE__"
    local func_run_spec="__NONE__"
    local func_space_spec="__NONE__"
    local func_res_spec="__ANY__"

    [[ -n "$anat_acq" ]] && anat_acq_spec="$anat_acq"
    [[ -n "$func_task" ]] && task_spec="$func_task"
    [[ -n "$func_acq" ]] && func_acq_spec="$func_acq"
    [[ -n "$func_run" ]] && func_run_spec="$func_run"
    [[ -n "$func_space" && "$func_space" != "native" ]] && func_space_spec="$func_space"
    [[ -n "$func_res" ]] && func_res_spec="$func_res"

    anat_t1=$(find_single_bids_file \
        "$anat_dir" "$id_key" "desc-preproc_T1w.nii.gz" \
        "native anatomical T1w" \
        __ANY__ "$anat_acq_spec" __ANY__ __NONE__ __ANY__)

    mask_anat_native=$(find_single_bids_file \
        "$anat_dir" "$id_key" "desc-brain_mask.nii.gz" \
        "native anatomical brain mask" \
        __ANY__ "$anat_acq_spec" __ANY__ __NONE__ __ANY__)

    gm_seg_native=$(find_single_bids_file \
        "$anat_dir" "$id_key" "label-GM_probseg.nii.gz" \
        "native anatomical GM probability map" \
        __ANY__ "$anat_acq_spec" __ANY__ __NONE__ __ANY__)

    if ! matrix=$(find_single_bids_file \
        "$func_dir" "$id_key" \
        "from-boldref_to-T1w_mode-image_desc-coreg_xfm.txt" \
        "entity-specific BOLD-to-T1w transform" \
        "$task_spec" "$func_acq_spec" "$func_run_spec" \
        __NONE__ __ANY__ optional)
    then
        matrix=$(find_single_bids_file \
            "$func_dir" "$id_key" \
            "from-boldref_to-T1w_mode-image_desc-coreg_xfm.txt" \
            "BOLD-to-T1w transform" \
            __ANY__ __ANY__ __ANY__ __NONE__ __ANY__)
    fi

    if ! mask_func_space=$(find_single_bids_file \
        "$func_dir" "$id_key" "desc-brain_mask.nii.gz" \
        "functional brain mask in $func_space" \
        "$task_spec" "$func_acq_spec" "$func_run_spec" \
        "$func_space_spec" "$func_res_spec" optional)
    then
        mask_func_space=$(find_single_bids_file \
            "$func_dir" "$id_key" "desc-brain_mask.nii.gz" \
            "functional brain mask in $func_space" \
            "$task_spec" "$func_acq_spec" "$func_run_spec" \
            "$func_space_spec" __ANY__)
    fi

    if ! refbold_space=$(find_single_bids_file \
        "$func_dir" "$id_key" "boldref.nii.gz" \
        "functional BOLD reference in $func_space" \
        "$task_spec" "$func_acq_spec" "$func_run_spec" \
        "$func_space_spec" "$func_res_spec" optional)
    then
        refbold_space=$(find_single_bids_file \
            "$func_dir" "$id_key" "boldref.nii.gz" \
            "functional BOLD reference in $func_space" \
            "$task_spec" "$func_acq_spec" "$func_run_spec" \
            "$func_space_spec" __ANY__)
    fi

    if ! refbold=$(find_single_bids_file \
        "$func_dir" "$id_key" "desc-coreg_boldref.nii.gz" \
        "native/coregistered BOLD reference" \
        "$task_spec" "$func_acq_spec" "$func_run_spec" \
        __NONE__ __ANY__ optional)
    then
        refbold="$refbold_space"
    fi

    if is_mni_space "$func_space"; then
        anat_space="$func_space"

        if ! anat_mni=$(find_single_bids_file \
            "$anat_dir" "$id_key" "desc-preproc_T1w.nii.gz" \
            "anatomical T1w in $func_space" \
            __ANY__ "$anat_acq_spec" __ANY__ "$func_space" "$func_res_spec" optional)
        then
            anat_mni=$(find_single_bids_file \
                "$anat_dir" "$id_key" "desc-preproc_T1w.nii.gz" \
                "anatomical T1w in $func_space" \
                __ANY__ "$anat_acq_spec" __ANY__ "$func_space" __ANY__)
        fi

        if ! mask_anat_mni=$(find_single_bids_file \
            "$anat_dir" "$id_key" "desc-brain_mask.nii.gz" \
            "anatomical brain mask in $func_space" \
            __ANY__ "$anat_acq_spec" __ANY__ "$func_space" "$func_res_spec" optional)
        then
            mask_anat_mni=$(find_single_bids_file \
                "$anat_dir" "$id_key" "desc-brain_mask.nii.gz" \
                "anatomical brain mask in $func_space" \
                __ANY__ "$anat_acq_spec" __ANY__ "$func_space" __ANY__)
        fi

        if ! gm_seg_mni=$(find_single_bids_file \
            "$anat_dir" "$id_key" "label-GM_probseg.nii.gz" \
            "anatomical GM probability map in $func_space" \
            __ANY__ "$anat_acq_spec" __ANY__ "$func_space" "$func_res_spec" optional)
        then
            gm_seg_mni=$(find_single_bids_file \
                "$anat_dir" "$id_key" "label-GM_probseg.nii.gz" \
                "anatomical GM probability map in $func_space" \
                __ANY__ "$anat_acq_spec" __ANY__ "$func_space" __ANY__)
        fi

        mask_func_mni="$mask_func_space"
        refbold_mni="$refbold_space"
        mask_func_native=""
    else
        anat_space=""
        anat_mni=""
        mask_anat_mni=""
        gm_seg_mni=""
        mask_func_mni=""
        refbold_mni=""
        mask_func_native="$mask_func_space"
    fi

    log_ok "Input files resolved"
    log_info "Entities: task=${func_task:-<none>} acq=${func_acq:-<none>} run=${func_run:-<none>} space=${func_space:-native} res=${func_res:-<none>}"
    log_debug "anat_dir=$anat_dir"
    log_debug "func_dir=$func_dir"
    log_debug "anat_t1=$anat_t1"
    log_debug "mask_anat_native=$mask_anat_native"
    log_debug "gm_seg_native=$gm_seg_native"
    log_debug "matrix=$matrix"
    log_debug "mask_func_space=$mask_func_space"
    log_debug "refbold_space=$refbold_space"
    log_debug "refbold=$refbold"
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
# ============================================================
# PROCESS ONE SUBJECT/SESSION
# ============================================================

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

process_subject_session() {
    id_key="${1:-}"
    local task_token="${2:-__NONE__}"
    local acq_token="${3:-__NONE__}"
    local run_token="${4:-__NONE__}"
    local space_token="${5:-native}"
    local resolution_token="${6:-__NA__}"

    if [[ -z "$id_key" ]]; then
        log_error "process_subject_session requires a session key."
        return 1
    fi

    if [[ "$id_key" != sub-* ]]; then
        log_error "Session key must start with 'sub-': $id_key"
        return 1
    fi

    func_task=""
    func_acq=""
    func_run=""
    func_space="$space_token"
    func_res=""

    [[ "$task_token" != "__NONE__" ]] && func_task="$task_token"
    [[ "$acq_token" != "__NONE__" ]] && func_acq="$acq_token"
    [[ "$run_token" != "__NONE__" ]] && func_run="$run_token"
    [[ "$resolution_token" != "__NA__" ]] && func_res="$resolution_token"

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
    work_item_id+="_space-${func_space:-native}"
    work_item_id+="_res-${func_res:-none}"

    id_tmp_dir="$work_dir/$work_item_id"
    rm -rf "$id_tmp_dir"
    mkdir -p "$id_tmp_dir"

    cleanup_subject_tmp() {
        rm -rf "$id_tmp_dir"
    }
    trap cleanup_subject_tmp RETURN

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
    mkdir -p "$dice_dir" "$dropout_dir" "$nmi_dir"

    resolve_subject_session_inputs
    select_metric_space_files

    log_step "Checking that resolved files belong to the expected subject/session"
    if [[ "${anat_earliest_ses,,}" == "yes" ]]; then
        check_matching_subjects \
            "$id_key" \
            "$mask_anat_space" \
            "$mask_func_space" \
            "$refbold_space" \
            "$gm_seg_space"
    else
        check_matching_ids \
            "$mask_anat_space" \
            "$mask_func_space" \
            "$refbold_space" \
            "$gm_seg_space"
    fi
    log_ok "Input identity checks passed"

    echo "mask_anat_space=$mask_anat_space"
    echo "mask_func_space=$mask_func_space"
    echo "refbold_space=$refbold_space"
    echo "gm_seg_space=$gm_seg_space"

    # if space doesnt contain mni, then apply function to resample to t1
    if [[ "$func_space" != *"MNI"* ]]; then
        ref_img="$mask_anat_space"
        echo "$ref_img"
        resample_to_t1 $mask_func_space $refbold_space $ref_img
        mask_func_space=$mask_func_anatres
        refbold_space=$refbold_anatres
    fi

    if ! extract_dice_metric \
        "$id_key" \
        "$mask_anat_space" \
        "$mask_func_space" \
        "$metric_space" \
        "$func_task" \
        "$func_acq"
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
        "$func_acq"
    then
        log_error "Dropout metric failed"
        return 1
    fi

    local refbold_t1space
    if ! refbold_t1space=$(transform_bold_t1space \
        "$id_key" \
        "$gm_seg_space" \
        "$mask_anat_space" \
        "$mask_func_space" \
        "$refbold_space" \
        "$metric_space" \
        "$func_task" \
        "$func_acq")
    then
        log_error "BOLD-to-T1 transform failed"
        return 1
    fi

    if is_mni_space "$metric_space"; then
        local template_space="$func_space"
        local template_resolution="$func_res"

        if [[ -z "$template_resolution" ]]; then
            log_error "Missing template resolution for MNI work item: $work_item_id"
            return 1
        fi

        local entropy_mni
        if ! entropy_mni=$(
            lookup_template_entropy \
                "$template_space" \
                "$template_resolution"
        )
        then
            log_error "Template entropy lookup failed"
            return 1
        fi

        local res_label template_t1 template_mask
        if ! res_label=$(templateflow_resolution_label "$template_resolution"); then
            log_error "Could not format template resolution"
            return 1
        fi

        if ! template_t1=$(find_single_file \
            "$templateflow_dir" \
            "tpl-${template_space}_res-${res_label}_T1w.nii.gz")
        then
            log_error "Could not locate TemplateFlow T1"
            return 1
        fi

        if ! template_mask=$(find_single_file \
            "$templateflow_dir" \
            "tpl-${template_space}_res-${res_label}_desc-brain_mask.nii.gz")
        then
            log_error "Could not locate TemplateFlow mask"
            return 1
        fi

        if ! extract_nmi_metric \
            "$id_key" \
            "$anat_t1" \
            "$mask_anat_native" \
            "$refbold_t1space" \
            "$anat_mni" \
            "$template_t1" \
            "$entropy_mni" \
            "$template_mask" \
            "$metric_space" \
            "$func_task" \
            "$func_acq"
        then
            log_error "NMI metric failed"
            return 1
        fi
    else
        log_info "Skipping TemplateFlow NMI for non-MNI space: $metric_space"
    fi

    publish_worker_metric_csvs \
        "$dice_dir" "$central_dice_dir" "$work_item_id"
    publish_worker_metric_csvs \
        "$dropout_dir" "$central_dropout_dir" "$work_item_id"
    publish_worker_metric_csvs \
        "$nmi_dir" "$central_nmi_dir" "$work_item_id"

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
    process_subject_session "$@"
}
# ============================================================
# TEMPLATEFLOW ENTROPY
# ============================================================

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

build_template_entropy_lookup() {
    log_step "Building TemplateFlow entropy lookup"

    local pairs_file="$tmp_dir/template_space_resolution.tsv"
    entropy_lookup_tsv="$tmp_dir/template_entropy.tsv"

    if [[ -z "$templateflow_dir" ]]; then
        templateflow_dir="$tmp_dir/templateflow"
    fi
    mkdir -p "$templateflow_dir"
    export TEMPLATEFLOW_HOME="$templateflow_dir"

    python - "$work_items_tsv" >"$pairs_file" <<'PY'
import sys
from pathlib import Path

work_items = Path(sys.argv[1])
pairs = set()

for line in work_items.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue

    fields = line.split("\t")
    if len(fields) != 6:
        raise SystemExit(f"Malformed work-item row: {line!r}")

    _, _, _, _, space, resolution = fields
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

    : >"$entropy_lookup_tsv"

    if [[ ! -s "$pairs_file" ]]; then
        log_warn "No MNI space/resolution pairs were found; TemplateFlow NMI will be skipped."
        return 0
    fi

    local pair_count
    pair_count=$(awk 'NF {count++} END {print count+0}' "$pairs_file")
    log_info "Found $pair_count MNI template space/resolution pair(s)"

    local template_space template_resolution entropy
    while IFS=$'	' read -r template_space template_resolution; do
        [[ -z "$template_space" || -z "$template_resolution" ]] && continue
        entropy=$(get_template_entropy "$template_space" "$template_resolution")
        printf '%s\t%s\t%s\n' \
            "$template_space" "$template_resolution" "$entropy" \
            >>"$entropy_lookup_tsv"
        log_ok "Template entropy ready: ${template_space} res-${template_resolution} = $entropy"
    done <"$pairs_file"

    log_ok "Template entropy lookup written: $entropy_lookup_tsv"
}

# ============================================================
# GNU PARALLEL CONTEXT
# ============================================================

export_parallel_context() {
    export SHELL=/bin/bash

    export config_file
    export tmp_dir output_dir extracted_metrics_file input_dir
    export templateflow_dir dataset_summary_json entropy_lookup_tsv
    export gm_threshold dropout_percentile mattes_bins anat_earliest_ses
    export metrics_dir dice_dir dropout_dir nmi_dir work_dir
    export VERBOSE LOG_TIMESTAMPS
    export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN

    export -f log_message log_info log_ok log_warn log_error log_step log_debug log_section

    export -f require_command require_file require_dir
    export -f read_yaml expand_config_vars
    export -f resolve_glob_one find_single_file find_single_dir
    export -f extract_sub_id extract_ses_id
    export -f check_matching_ids check_matching_subjects
    export -f get_earliest_anat_dir

    export -f is_mni_space json_single_value normalize_resolution
    export -f templateflow_resolution_label lookup_template_entropy
    export -f bids_entity_value entity_spec_matches find_single_bids_file
    export -f resolve_subject_session_inputs select_metric_space_files
    export -f publish_worker_metric_csvs

    export -f extract_dice_metric extract_dropout_metric
    export -f transform_bold_t1space extract_nmi_metric
    export -f process_subject_session parallel_worker
    export -f resample_to_t1
}

# ============================================================
# RUN DATASET
# ============================================================

run_dataset() {
    log_section "Dataset metrics pipeline"
    log_info "Input directory: $input_dir"
    log_info "Temporary directory: $tmp_dir"
    log_info "Final CSV: $extracted_metrics_file"
    log_info "Parallel jobs: $n_jobs"

    local subject_id_keys_file="$tmp_dir/subject_id_keys.txt"
    work_items_tsv="$tmp_dir/functional_work_items.tsv"
    dataset_summary_json="$tmp_dir/dataset_summary.json"

    log_step "Exploring dataset structure"
    python "$script_dir/dataset_utils.py" "$input_dir" >"$dataset_summary_json"
    log_ok "Dataset summary written: $dataset_summary_json"

    if ! jq -e '.session_summary | type == "object"' \
        "$dataset_summary_json" >/dev/null; then
        log_error "dataset_utils.py did not produce a session_summary object."
        exit 1
    fi

    jq -r '.session_summary | keys[]' "$dataset_summary_json" \
        | sort >"$subject_id_keys_file"

    if [[ ! -s "$subject_id_keys_file" ]]; then
        log_error "No subject/session entries were discovered."
        exit 1
    fi

    validate_id_keys_file "$subject_id_keys_file"
    build_work_items "$work_items_tsv"
    build_template_entropy_lookup
    initialize_outputs
    export_parallel_context

    local job_count
    job_count=$(awk 'NF {count++} END {print count+0}' "$work_items_tsv")
    log_ok "Discovered $job_count functional work item(s)"

    local discovered_key discovered_task discovered_acq
    local discovered_run discovered_space discovered_res
    while IFS=$'	' read -r \
        discovered_key \
        discovered_task \
        discovered_acq \
        discovered_run \
        discovered_space \
        discovered_res
    do
        [[ -z "$discovered_key" ]] && continue
        [[ "$discovered_task" == "__NONE__" ]] && discovered_task="<none>"
        [[ "$discovered_acq" == "__NONE__" ]] && discovered_acq="<none>"
        [[ "$discovered_run" == "__NONE__" ]] && discovered_run="<none>"
        [[ "$discovered_res" == "__NA__" ]] && discovered_res="<none>"
        log_debug "work_item=$discovered_key task=$discovered_task acq=$discovered_acq run=$discovered_run space=$discovered_space res=$discovered_res"
    done <"$work_items_tsv"

    mkdir -p "$tmp_dir/parallel_logs"

    log_step "Launching $job_count work item(s) with $n_jobs parallel job(s)"
    parallel \
        --jobs "$n_jobs" \
        --halt soon,fail=1 \
        --line-buffer \
        --colsep '	' \
        --joblog "$tmp_dir/parallel_joblog.tsv" \
        --results "$tmp_dir/parallel_logs" \
        parallel_worker '{1}' '{2}' '{3}' '{4}' '{5}' '{6}' \
        :::: "$work_items_tsv"

    log_ok "All parallel workers completed"
    log_info "GNU Parallel job log: $tmp_dir/parallel_joblog.tsv"
    log_debug "Per-job stdout/stderr: $tmp_dir/parallel_logs"

    log_step "Merging Dice, dropout, and NMI CSV files"
    compute_nmi_merge_metrics

    local output_rows=0
    if [[ -f "$extracted_metrics_file" ]]; then
        output_rows=$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "$extracted_metrics_file")
    fi
    log_ok "Pipeline complete: wrote $output_rows row(s) to $extracted_metrics_file"
}

# ============================================================
# MAIN
# ============================================================

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
    log_debug "anat_earliest_ses=$anat_earliest_ses"

    check_inputs_global
    run_dataset
}

main "$@"