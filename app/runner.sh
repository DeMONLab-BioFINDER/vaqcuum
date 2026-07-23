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


# ============================================================
# PATHS AND CONFIGURATION
# ============================================================

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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

zip_archive_layout() {
    local archive="${1:-}"

    if [[ -z "$archive" || ! -f "$archive" ]]; then
        return 1
    fi

    unzip -Z1 "$archive" \
        | awk '
            function unsafe(path) {
                return path ~ /^\// || path == ".." || path ~ /^\.\.\// || path ~ /\/\.\.\// || path ~ /\/\.\.$/
            }

            {
                sub(/\r$/, "", $0)
                while (sub(/^\.\//, "", $0)) {}

                if ($0 == "") {
                    next
                }

                if (unsafe($0)) {
                    print "unsafe"
                    fatal = 1
                    exit
                }

                # Ignore common macOS ZIP metadata when deciding whether the
                # archive already contains one meaningful top-level folder.
                if ($0 == ".DS_Store" || $0 ~ /(^|\/)\.DS_Store$/ || $0 ~ /^__MACOSX\//) {
                    next
                }

                meaningful += 1

                slash = index($0, "/")
                if (slash == 0) {
                    has_top_level_file = 1
                    root = $0
                } else {
                    root = substr($0, 1, slash - 1)
                }

                roots[root] = 1
            }

            END {
                if (fatal) {
                    exit
                }

                if (meaningful == 0) {
                    print "empty"
                    exit
                }

                root_count = 0
                for (root in roots) {
                    root_count += 1
                    only_root = root
                }

                if (root_count == 1 && !has_top_level_file) {
                    print "single_root\t" only_root
                } else {
                    print "multiple_or_flat"
                }
            }
        '
}

extract_one_zip_archive() {
    local archive="${1:-}"

    if [[ -z "$archive" || ! -f "$archive" ]]; then
        log_error "ZIP archive does not exist: ${archive:-<empty>}"
        return 1
    fi

    local layout
    if ! layout=$(zip_archive_layout "$archive"); then
        log_error "Could not inspect ZIP archive: $archive"
        return 1
    fi

    local archive_filename="${archive##*/}"
    local archive_stem="${archive_filename%.*}"
    local destination

    case "$layout" in
        single_root$'\t'*)
            destination="$input_dir"
            log_debug \
                "zip=$archive layout=single-root destination=$destination"
            ;;

        multiple_or_flat)
            destination="$input_dir/$archive_stem"
            log_debug \
                "zip=$archive layout=flat-or-multiple destination=$destination"
            ;;

        unsafe)
            log_error "Unsafe parent or absolute path found in ZIP archive: $archive"
            return 1
            ;;

        empty)
            log_error "ZIP archive contains no usable entries: $archive"
            return 1
            ;;

        *)
            log_error "Could not determine ZIP layout for $archive: $layout"
            return 1
            ;;
    esac

    mkdir -p "$destination"

    # -n makes extraction safe to rerun: existing files are not overwritten.
    if ! unzip -q -n "$archive" -d "$destination"; then
        log_error "Could not extract ZIP archive: $archive"
        return 1
    fi

    log_ok "Extracted ${archive_filename} -> ${destination}"
}

extract_zipped_input_directories() {
    local archive
    local -a archives=()

    while IFS= read -r -d '' archive; do
        archives+=("$archive")
    done < <(
        find "$input_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            -iname '*.zip' \
            -print0
    )

    if (( ${#archives[@]} == 0 )); then
        log_debug "No top-level ZIP archives found in $input_dir"
        return 0
    fi

    log_step \
        "Inspecting and extracting ${#archives[@]} ZIP archive(s) with $n_jobs parallel job(s)"

    # GNU Parallel starts a fresh shell for each archive. Export the helper and
    # logging functions plus the values they need.
    export SHELL=/bin/bash
    export input_dir
    export C_RESET C_RED C_GREEN C_YELLOW C_CYAN C_DIM
    export LOG_TIMESTAMPS LOG_CONTEXT VERBOSE
    export -f log_message log_info log_ok log_warn log_error log_debug
    export -f zip_archive_layout extract_one_zip_archive

    if ! parallel \
        --jobs "$n_jobs" \
        --halt soon,fail=1 \
        --line-buffer \
        extract_one_zip_archive '{}' \
        ::: "${archives[@]}"
    then
        log_error "One or more input ZIP archives could not be extracted."
        return 1
    fi

    log_ok "ZIP input extraction completed"
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


anat_dir_has_t1w() {
    local anat_path="${1:-}"

    [[ -n "$anat_path" && -d "$anat_path" ]] || return 1

    find "$anat_path" \
        -maxdepth 1 \
        -type f \
        -name '*_T1w.nii.gz' \
        -print -quit \
        | grep -q .
}


subject_session_count() {
    local subject_id="${1:-}"

    if [[ -z "$subject_id" ]]; then
        printf '0\n'
        return 0
    fi

    local subject_dir="$input_dir/$subject_id"
    local count=0

    # Standard layout: input_dir/sub-*/ses-*
    if [[ -d "$subject_dir" ]]; then
        count=$(
            find "$subject_dir" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                -name 'ses-*' \
                -print \
                | sed 's#.*/##' \
                | sort -u \
                | awk 'NF {count++} END {print count + 0}'
        )

        if (( count > 0 )); then
            printf '%s\n' "$count"
            return 0
        fi
    fi

    # Wrapped layout: one top-level wrapper per subject/session. Ignore any
    # provenance suffix after the session label and count unique sessions.
    count=$(
        find "$input_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name "${subject_id}_ses-*" \
            -print \
            | sed 's#.*/##' \
            | sed -nE \
                "s/^${subject_id}_(ses-[A-Za-z0-9]+)(_.+)?$/\1/p" \
            | sort -u \
            | awk 'NF {count++} END {print count + 0}'
    )

    printf '%s\n' "$count"
}


find_wrapped_session_anat_dir() {
    local subject_id="${1:-}"
    local session_id="${2:-}"

    if [[ -z "$subject_id" || -z "$session_id" ]]; then
        return 1
    fi

    # A wrapped directory may contain a provenance/version suffix, for example:
    #   sub-31728786_ses-0_fmriprep-25-2-5
    local wrapper_prefix="${subject_id}_${session_id}"
    local wrapper_dir=""
    local candidate=""
    local session_count
    local -a session_matches=()
    local -a shared_matches=()

    session_count=$(subject_session_count "$subject_id")

    while IFS= read -r -d '' wrapper_dir; do
        while IFS= read -r -d '' candidate; do
            anat_dir_has_t1w "$candidate" || continue
            session_matches+=("$candidate")
        done < <(
            find "$wrapper_dir" \
                -type d \
                -path "*/${subject_id}/${session_id}/anat" \
                -print0
        )
    done < <(
        find "$input_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            \( -name "$wrapper_prefix" -o -name "${wrapper_prefix}_*" \) \
            -print0
    )

    if (( ${#session_matches[@]} == 1 )); then
        printf '%s
' "${session_matches[0]}"
        return 0
    fi

    if (( ${#session_matches[@]} > 1 )); then
        log_error "Multiple wrapped session anat directories contain T1w files for ${subject_id}_${session_id}:"
        printf '  - %s
' "${session_matches[@]}" >&2
        return 1
    fi

    # Shared anatomy outside ses-* is valid only for a genuinely
    # multi-session subject in a longitudinal dataset.
    if [[ "${anat_outside_ses_enabled:-0}" == "1" ]] \
        && (( session_count > 1 ))
    then
        while IFS= read -r -d '' wrapper_dir; do
            while IFS= read -r -d '' candidate; do
                anat_dir_has_t1w "$candidate" || continue
                shared_matches+=("$candidate")
            done < <(
                find "$wrapper_dir" \
                    -type d \
                    -path "*/${subject_id}/anat" \
                    -print0
            )
        done < <(
            find "$input_dir" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                \( -name "$wrapper_prefix" -o -name "${wrapper_prefix}_*" \) \
                -print0
        )
    fi

    if (( ${#shared_matches[@]} == 1 )); then
        printf '%s
' "${shared_matches[0]}"
        return 0
    fi

    if (( ${#shared_matches[@]} > 1 )); then
        log_error "Multiple wrapped subject-level anat directories contain T1w files for ${subject_id}_${session_id}:"
        printf '  - %s
' "${shared_matches[@]}" >&2
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
    local subject_dir="$input_dir/$subject_id"
    local session_dir="$subject_dir/$session_id"
    local session_count

    session_count=$(subject_session_count "$subject_id")

    if [[ -d "$session_dir" ]]; then
        local anat_path
        local -a session_matches=()

        while IFS= read -r -d '' anat_path; do
            anat_dir_has_t1w "$anat_path" || continue
            session_matches+=("$anat_path")
        done < <(
            find "$session_dir" \
                -mindepth 1 \
                -type d \
                -name anat \
                -print0
        )

        if (( ${#session_matches[@]} == 1 )); then
            printf '%s
' "${session_matches[0]}"
            return 0
        elif (( ${#session_matches[@]} > 1 )); then
            log_error \
                "Found multiple anat directories containing T1w files for ${subject_id}/${session_id}"
            printf '  - %s
' "${session_matches[@]}" >&2
            return 1
        fi

        # If this is longitudinal and the session has no T1w image, use the
        # subject-level anat directory one level above the ses-* directories.
        local shared_anat_dir="$subject_dir/anat"

        if [[ "${anat_outside_ses_enabled:-0}" == "1" ]] \
            && (( session_count > 1 )) \
            && anat_dir_has_t1w "$shared_anat_dir"
        then
            printf '%s
' "$shared_anat_dir"
            return 0
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

        # Layout 1:
        #   input_dir/sub-*/ses-*/**/anat
        # or, for longitudinal datasets with shared anatomy:
        #   input_dir/sub-*/anat
        if [[ "$child_name" =~ ^sub-[A-Za-z0-9]+$ ]]; then
            local session_dir session_name anat_path
            local session_count=0
            local invalid_subject=0
            local -a session_t1w_matches=()
            local -a sessions_without_t1w=()

            while IFS= read -r -d '' session_dir; do
                session_name=${session_dir##*/}
                [[ ! "$session_name" =~ ^ses-[A-Za-z0-9]+$ ]] && continue

                ((session_count += 1))
                session_t1w_matches=()

                while IFS= read -r -d '' anat_path; do
                    anat_dir_has_t1w "$anat_path" || continue
                    session_t1w_matches+=("$anat_path")
                done < <(
                    find "$session_dir" \
                        -mindepth 1 \
                        -type d \
                        -name anat \
                        -print0
                )

                if (( ${#session_t1w_matches[@]} == 1 )); then
                    log_debug \
                        "standard_session=${child_name}/${session_name} anat=${session_t1w_matches[0]}"
                elif (( ${#session_t1w_matches[@]} == 0 )); then
                    sessions_without_t1w+=("$session_name")
                else
                    invalid_entries+=(
                        "$session_dir :: found multiple anat directories containing _T1w.nii.gz"
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
                    "$child_dir :: expected at least one ses-* directory"
                )
                ((invalid_count += 1))
                invalid_subject=1
            elif (( ${#sessions_without_t1w[@]} > 0 )); then
                local shared_anat_dir="$child_dir/anat"

                if (( session_count == 1 )); then
                    invalid_entries+=(
                        "$child_dir :: its only session (${sessions_without_t1w[0]}) must contain _T1w.nii.gz inside that session"
                    )
                    ((invalid_count += 1))
                    invalid_subject=1
                elif [[ "${anat_outside_ses_enabled:-0}" == "1" ]] \
                    && anat_dir_has_t1w "$shared_anat_dir"
                then
                    log_debug \
                        "shared_anat=${shared_anat_dir} missing_sessions=${sessions_without_t1w[*]}"
                else
                    invalid_entries+=(
                        "$child_dir :: multi-session subject has session(s) without _T1w.nii.gz (${sessions_without_t1w[*]}) but no usable subject-level anat/_T1w.nii.gz"
                    )
                    ((invalid_count += 1))
                    invalid_subject=1
                fi
            fi

            if (( invalid_subject == 0 )); then
                ((standard_count += 1))
            fi

            continue
        fi

        # Layout 2: input_dir/sub-*_ses-*[_suffix]/**/sub-*/ses-*/anat
        # A wrapped longitudinal result may instead keep anatomy at
        # **/sub-*/anat when its session folder has no T1w image.
        if [[ "$child_name" =~ ^(sub-[A-Za-z0-9]+)_(ses-[A-Za-z0-9]+)(_.+)?$ ]]; then
            local wrapped_subject wrapped_session wrapped_anat
            local wrapped_subject_session_count
            wrapped_subject="${BASH_REMATCH[1]}"
            wrapped_session="${BASH_REMATCH[2]}"
            wrapped_subject_session_count=$(
                subject_session_count "$wrapped_subject"
            )

            local -a wrapped_session_matches=()
            local -a wrapped_shared_matches=()

            while IFS= read -r -d '' wrapped_anat; do
                anat_dir_has_t1w "$wrapped_anat" || continue
                wrapped_session_matches+=("$wrapped_anat")
            done < <(
                find "$child_dir" \
                    -type d \
                    -path "*/${wrapped_subject}/${wrapped_session}/anat" \
                    -print0
            )

            if (( ${#wrapped_session_matches[@]} == 0 )) \
                && (( wrapped_subject_session_count > 1 )) \
                && [[ "${anat_outside_ses_enabled:-0}" == "1" ]]
            then
                while IFS= read -r -d '' wrapped_anat; do
                    anat_dir_has_t1w "$wrapped_anat" || continue
                    wrapped_shared_matches+=("$wrapped_anat")
                done < <(
                    find "$child_dir" \
                        -type d \
                        -path "*/${wrapped_subject}/anat" \
                        -print0
                )
            fi

            if (( ${#wrapped_session_matches[@]} == 1 )); then
                ((wrapped_count += 1))
                log_debug \
                    "wrapped_session=$child_name anat=${wrapped_session_matches[0]}"
            elif (( ${#wrapped_session_matches[@]} > 1 )); then
                invalid_entries+=(
                    "$child_dir :: found multiple session anat directories containing _T1w.nii.gz"
                )
                ((invalid_count += 1))
            elif (( ${#wrapped_shared_matches[@]} == 1 )); then
                ((wrapped_count += 1))
                log_debug \
                    "wrapped_session=$child_name shared_anat=${wrapped_shared_matches[0]}"
            elif (( ${#wrapped_shared_matches[@]} == 0 )); then
                if (( wrapped_subject_session_count <= 1 )); then
                    invalid_entries+=(
                        "$child_dir :: a one-session subject must contain _T1w.nii.gz inside its session anat directory"
                    )
                else
                    invalid_entries+=(
                        "$child_dir :: no session-level or subject-level anat directory contains _T1w.nii.gz"
                    )
                fi
                ((invalid_count += 1))
            else
                invalid_entries+=(
                    "$child_dir :: found multiple subject-level anat directories containing _T1w.nii.gz"
                )
                ((invalid_count += 1))
            fi

            continue
        fi

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
        printf '  1. %s/sub-*/ses-*/**/anat
' "$input_dir" >&2
        printf '  2. %s/sub-*/anat for shared longitudinal anatomy
' \
            "$input_dir" >&2
        printf '  3. %s/sub-*_ses-*[_suffix]/**/sub-*/{ses-*/,}anat
' \
            "$input_dir" >&2

        local entry
        for entry in "${invalid_entries[@]}"; do
            printf '  - %s
' "$entry" >&2
        done

        return 1
    fi

    if (( standard_count + wrapped_count == 0 )); then
        log_error "No valid subject/session directories were found in: $input_dir"
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
    require_command unzip

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

    log_step "Building one work item per filtered T1w/MNI functional combination"

    python - "$dataset_summary_json" >"$output_file" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


summary_path = Path(sys.argv[1])
summary = json.loads(
    summary_path.read_text(encoding="utf-8")
)

NONE = "__NONE__"
NO_RESOLUTION = "__NA__"

ENTITY_PATTERNS = {
    name: re.compile(
        rf"(?:^|_){name}-([^_.]+)"
    )
    for name in (
        "task",
        "acq",
        "run",
        "space",
        "res",
    )
}


def values(value: Any) -> list[Any]:
    if isinstance(value, list):
        return [
            item
            for item in value
            if item not in (None, "")
        ]

    if value in (None, ""):
        return []

    return [value]


def paths(value: Any) -> list[Path]:
    if isinstance(value, list):
        return [
            Path(item)
            for item in value
            if item not in (None, "")
        ]

    if value in (None, ""):
        return []

    return [Path(value)]


def entity(filename: str, name: str) -> str:
    match = ENTITY_PATTERNS[name].search(filename)
    return match.group(1) if match else ""


def text(value: Any) -> str:
    if value in (None, ""):
        return ""

    return str(value)


def token(
    value: str,
    missing: str = NONE,
) -> str:
    return value if value else missing


def normalize_resolution(value: Any) -> str:
    if value in (None, ""):
        return ""

    normalized = str(value)

    try:
        return str(int(normalized, 10))
    except ValueError:
        return normalized


def is_t1w_space(space: str) -> bool:
    return space.casefold() == "t1w"


def is_mni_space(space: str) -> bool:
    return "mni" in space.casefold()


def is_allowed_space(space: str) -> bool:
    return (
        is_t1w_space(space)
        or is_mni_space(space)
    )


def normalize_space(value: Any) -> str:
    space = text(value)

    if is_t1w_space(space):
        return "T1w"

    return space


def natural_sort_key(value: Any) -> tuple:
    parts = re.split(r"(\d+)", str(value))

    return tuple(
        (
            0,
            int(part),
        )
        if part.isdigit()
        else (
            1,
            part.casefold(),
        )
        for part in parts
        if part != ""
    )


def read_selected_combinations(
    func: dict[str, Any],
) -> set[tuple[str, str, str, str, str]]:
    """Read exact filtered functional combinations from the summary."""
    selected: set[
        tuple[str, str, str, str, str]
    ] = set()

    combinations = func.get(
        "selected_combinations",
        [],
    )

    if not isinstance(combinations, list):
        return selected

    for combination in combinations:
        if not isinstance(combination, dict):
            continue

        space = normalize_space(
            combination.get("space")
        )

        # Native/no-space files are deliberately excluded. They are
        # auxiliary inputs, not metric-space work items.
        if not is_allowed_space(space):
            continue

        selected.add(
            (
                text(combination.get("task")),
                text(combination.get("acq")),
                text(combination.get("run")),
                space,
                normalize_resolution(
                    combination.get("res")
                ),
            )
        )

    return selected


def selected_resolutions_for(
    selected_combinations: set[
        tuple[str, str, str, str, str]
    ],
    *,
    task: str,
    acq: str,
    run: str,
    space: str,
) -> set[str]:
    """Return selected resolutions for one task/acq/run/space key."""
    return {
        selected_resolution
        for (
            selected_task,
            selected_acq,
            selected_run,
            selected_space,
            selected_resolution,
        ) in selected_combinations
        if (
            selected_task == task
            and selected_acq == acq
            and selected_run == run
            and selected_space == space
        )
    }


def format_combination(
    combination: tuple[str, str, str, str, str],
) -> str:
    task, acq, run, space, resolution = combination

    return (
        f"task={task or '<none>'}, "
        f"acq={acq or '<none>'}, "
        f"run={run or '<none>'}, "
        f"space={space or '<none>'}, "
        f"res={resolution or '<none>'}"
    )


records: set[
    tuple[str, str, str, str, str, str]
] = set()

session_summary = summary.get(
    "session_summary",
    {},
)

if not isinstance(session_summary, dict):
    raise SystemExit(
        "dataset_summary.json does not contain a valid "
        "session_summary object"
    )

session_items = sorted(
    session_summary.items(),
    key=lambda item: natural_sort_key(
        item[0]
    ),
)

for id_key, session in session_items:
    if not isinstance(session, dict):
        continue

    func = session.get("func", {}) or {}

    if not isinstance(func, dict):
        continue

    func_dirs = paths(func.get("path"))

    # New summaries contain this field even when the selected list is empty.
    # Its presence distinguishes the new filtered format from older summaries.
    has_selected_combinations = (
        "selected_combinations" in func
    )

    selected_combinations = (
        read_selected_combinations(func)
    )

    # The filtered summary explicitly selected no functional T1w/MNI
    # combinations for this session.
    if (
        has_selected_combinations
        and not selected_combinations
    ):
        continue

    if not func_dirs:
        if has_selected_combinations:
            raise SystemExit(
                f"No functional path was recorded for selected "
                f"session {id_key}"
            )

        continue

    # Used only for summaries created before selected_combinations existed.
    summary_resolutions = {
        normalize_resolution(item)
        for item in values(func.get("res"))
    }

    session_records: set[
        tuple[str, str, str, str, str, str]
    ] = set()

    matched_selected_combinations: set[
        tuple[str, str, str, str, str]
    ] = set()

    for func_dir in func_dirs:
        if not func_dir.is_dir():
            raise SystemExit(
                f"Functional directory does not exist for "
                f"{id_key}: {func_dir}"
            )

        boldref_files = sorted(
            func_dir.rglob("*boldref.nii.gz"),
            key=lambda path: natural_sort_key(
                str(path)
            ),
        )

        for file_path in boldref_files:
            filename = file_path.name

            if not filename.startswith(
                str(id_key)
            ):
                continue

            task = entity(filename, "task")
            acq = entity(filename, "acq")
            run = entity(filename, "run")
            space = entity(filename, "space")

            # No space-* means native functional space. Native is resolved
            # later only when it is needed as an auxiliary NMI input.
            if not space:
                continue

            if not is_allowed_space(space):
                continue

            normalized_space = normalize_space(
                space
            )

            resolution = normalize_resolution(
                entity(filename, "res")
            )

            if has_selected_combinations:
                possible_resolutions = (
                    selected_resolutions_for(
                        selected_combinations,
                        task=task,
                        acq=acq,
                        run=run,
                        space=normalized_space,
                    )
                )

                # This task/acq/run/space combination was removed by the
                # BIDS filter.
                if not possible_resolutions:
                    continue

                if not resolution:
                    # Prefer an explicitly resolution-free selection.
                    if "" in possible_resolutions:
                        resolution = ""
                    else:
                        nonempty_resolutions = {
                            value
                            for value in possible_resolutions
                            if value
                        }

                        if len(nonempty_resolutions) == 1:
                            resolution = next(
                                iter(nonempty_resolutions)
                            )
                        else:
                            raise SystemExit(
                                f"Cannot determine the resolution for "
                                f"{file_path}. The filtered combination "
                                f"has multiple possible resolutions: "
                                f"{sorted(nonempty_resolutions)!r}"
                            )

                candidate_combination = (
                    task,
                    acq,
                    run,
                    normalized_space,
                    resolution,
                )

                if (
                    candidate_combination
                    not in selected_combinations
                ):
                    continue

                matched_selected_combinations.add(
                    candidate_combination
                )

            else:
                # Compatibility with older summaries: an MNI boldref may
                # omit res-* even though the session summary has one
                # unambiguous resolution.
                if (
                    not resolution
                    and is_mni_space(normalized_space)
                ):
                    if len(summary_resolutions) == 1:
                        resolution = next(
                            iter(summary_resolutions)
                        )
                    elif len(summary_resolutions) > 1:
                        raise SystemExit(
                            f"Cannot determine the resolution for "
                            f"{file_path}. The session summary contains "
                            f"multiple resolutions: "
                            f"{sorted(summary_resolutions)!r}"
                        )

            session_records.add(
                (
                    str(id_key),
                    token(task),
                    token(acq),
                    token(run),
                    normalized_space,
                    token(
                        resolution,
                        NO_RESOLUTION,
                    ),
                )
            )

    if has_selected_combinations:
        missing_combinations = (
            selected_combinations
            - matched_selected_combinations
        )

        if missing_combinations:
            details = "\n".join(
                f"  - {format_combination(combination)}"
                for combination in sorted(
                    missing_combinations,
                    key=lambda item: tuple(
                        natural_sort_key(value)
                        for value in item
                    ),
                )
            )

            raise SystemExit(
                f"Could not find a matching T1w/MNI boldref for "
                f"the following filtered combinations in {id_key}:\n"
                f"{details}"
            )

    if not session_records:
        continue

    records.update(session_records)

if not records:
    raise SystemExit(
        "No explicit T1w or MNI functional BOLD-reference "
        "work items were discovered after applying the BIDS filter"
    )

for record in sorted(
    records,
    key=lambda item: tuple(
        natural_sort_key(value)
        for value in item
    ),
):
    print(*record, sep="\t")
PY

    if [[ ! -s "$output_file" ]]; then
        log_error "No functional work items were generated."
        return 1
    fi

    local count
    count=$(
        awk '
            NF {
                count++
            }
            END {
                print count + 0
            }
        ' "$output_file"
    )

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
    local recorded_anat_dir
    local subject_id session_id
    local anat_id_prefix

    # These are resolved conditionally for MNI NMI processing. When an
    # entity-matched BOLD reference already exists in T1w space, neither the
    # native/coregistered BOLD reference nor its transform matrix is needed.
    matrix=""
    refbold_native=""
    refbold_t1w=""

    subject_id=$(jq -r --arg key "$id_key" \
        '.session_summary[$key].subject // empty' "$dataset_summary_json")
    session_id=$(jq -r --arg key "$id_key" \
        '.session_summary[$key].session // empty' "$dataset_summary_json")

    if [[ -z "$subject_id" ]]; then
        subject_id=$(grep -oE '^sub-[A-Za-z0-9]+' <<<"$id_key" | head -n 1 || true)
    fi

    anat_dir_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].anat.path // null' "$dataset_summary_json")
    func_dir_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].func.path // null' "$dataset_summary_json")

    recorded_anat_dir=$(json_single_value \
        "$anat_dir_json" "anat.path" "$id_key")
    func_dir=$(json_single_value \
        "$func_dir_json" "func.path" "$id_key")

    anat_dir=""
    anat_outside_ses_for_item=0

    if anat_dir_has_t1w "$recorded_anat_dir"; then
        anat_dir="$recorded_anat_dir"
    elif [[ "${anat_outside_ses_enabled:-0}" == "1" ]] \
        && [[ -n "$subject_id" && -n "$session_id" ]]
    then
        if ! anat_dir=$(find_session_anat_dir \
            "$subject_id" "$session_id")
        then
            log_error \
                "Could not resolve session or shared longitudinal anatomy for $id_key."
            return 1
        fi
    fi

    if [[ -z "$anat_dir" || -z "$func_dir" ]]; then
        log_error "Could not read usable anat/func paths for $id_key."
        return 1
    fi

    if [[ -n "$session_id" ]]; then
        case "/${anat_dir%/}/" in
            *"/$session_id/"*)
                anat_outside_ses_for_item=0
                ;;
            *)
                if [[ "${anat_outside_ses_enabled:-0}" == "1" ]]; then
                    anat_outside_ses_for_item=1
                fi
                ;;
        esac
    fi

    if (( anat_outside_ses_for_item )); then
        anat_id_prefix="$subject_id"
    else
        anat_id_prefix="$id_key"
    fi

    func_task_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].func.task // null' "$dataset_summary_json")
    anat_acq_json=$(jq -c --arg key "$id_key" \
        '.session_summary[$key].anat.acq // null' "$dataset_summary_json")

    anat_acq=$(json_single_value "$anat_acq_json" "anat.acq" "$id_key")

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

    # Session summaries do not inventory subject-level anat directories.
    # Let the unique-file resolver determine acquisition in that case.
    if (( anat_outside_ses_for_item )); then
        anat_acq_spec="__ANY__"
    elif [[ -n "$anat_acq" ]]; then
        anat_acq_spec="$anat_acq"
    fi

    [[ -n "$func_task" ]] && task_spec="$func_task"
    [[ -n "$func_acq" ]] && func_acq_spec="$func_acq"
    [[ -n "$func_run" ]] && func_run_spec="$func_run"
    [[ -n "$func_space" && "$func_space" != "native" ]] && func_space_spec="$func_space"
    [[ -n "$func_res" ]] && func_res_spec="$func_res"

    anat_t1=$(find_single_bids_file \
        "$anat_dir" "$anat_id_prefix" "desc-preproc_T1w.nii.gz" \
        "native anatomical T1w" \
        __ANY__ "$anat_acq_spec" __ANY__ __NONE__ __ANY__)

    mask_anat_native=$(find_single_bids_file \
        "$anat_dir" "$anat_id_prefix" "desc-brain_mask.nii.gz" \
        "native anatomical brain mask" \
        __ANY__ "$anat_acq_spec" __ANY__ __NONE__ __ANY__)

    gm_seg_native=$(find_single_bids_file \
        "$anat_dir" "$anat_id_prefix" "label-GM_probseg.nii.gz" \
        "native anatomical GM probability map" \
        __ANY__ "$anat_acq_spec" __ANY__ __NONE__ __ANY__)

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

    if is_mni_space "$func_space"; then
        anat_space="$func_space"

        if ! anat_mni=$(find_single_bids_file \
            "$anat_dir" "$anat_id_prefix" "desc-preproc_T1w.nii.gz" \
            "anatomical T1w in $func_space" \
            __ANY__ "$anat_acq_spec" __ANY__ "$func_space" "$func_res_spec" optional)
        then
            anat_mni=$(find_single_bids_file \
                "$anat_dir" "$anat_id_prefix" "desc-preproc_T1w.nii.gz" \
                "anatomical T1w in $func_space" \
                __ANY__ "$anat_acq_spec" __ANY__ "$func_space" __ANY__)
        fi

        if ! mask_anat_mni=$(find_single_bids_file \
            "$anat_dir" "$anat_id_prefix" "desc-brain_mask.nii.gz" \
            "anatomical brain mask in $func_space" \
            __ANY__ "$anat_acq_spec" __ANY__ "$func_space" "$func_res_spec" optional)
        then
            mask_anat_mni=$(find_single_bids_file \
                "$anat_dir" "$anat_id_prefix" "desc-brain_mask.nii.gz" \
                "anatomical brain mask in $func_space" \
                __ANY__ "$anat_acq_spec" __ANY__ "$func_space" __ANY__)
        fi

        if ! gm_seg_mni=$(find_single_bids_file \
            "$anat_dir" "$anat_id_prefix" "label-GM_probseg.nii.gz" \
            "anatomical GM probability map in $func_space" \
            __ANY__ "$anat_acq_spec" __ANY__ "$func_space" "$func_res_spec" optional)
        then
            gm_seg_mni=$(find_single_bids_file \
                "$anat_dir" "$anat_id_prefix" "label-GM_probseg.nii.gz" \
                "anatomical GM probability map in $func_space" \
                __ANY__ "$anat_acq_spec" __ANY__ "$func_space" __ANY__)
        fi

        # Prefer an entity-matched BOLD reference that is already in T1w
        # space. The MNI work-item resolution must not be applied here because
        # a T1w-space boldref may use a different grid or omit res-* entirely.
        if refbold_t1w=$(find_single_bids_file \
            "$func_dir" "$id_key" "boldref.nii.gz" \
            "existing BOLD reference in T1w space" \
            "$task_spec" "$func_acq_spec" "$func_run_spec" \
            T1w __ANY__ optional)
        then
            log_info \
                "Using existing T1w-space BOLD reference for T1-to-BOLD NMI"
            log_debug "refbold_t1w=$refbold_t1w"
        else
            refbold_t1w=""

            log_info \
                "No existing T1w-space BOLD reference found; resolving native BOLD and transform"

            refbold_native=$(find_single_bids_file \
                "$func_dir" "$id_key" "desc-coreg_boldref.nii.gz" \
                "native/coregistered BOLD reference" \
                "$task_spec" "$func_acq_spec" "$func_run_spec" \
                __NONE__ __ANY__)

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
        refbold_native="$refbold_space"
        refbold_t1w=""
        matrix=""
    fi

    log_ok "Input files resolved"
    log_info "Entities: task=${func_task:-<none>} acq=${func_acq:-<none>} run=${func_run:-<none>} space=${func_space:-native} res=${func_res:-<none>}"
    log_info \
        "Anatomy source: $([[ $anat_outside_ses_for_item -eq 1 ]] && printf 'subject-level anat outside ses-*' || printf 'session-level anat')"
    log_debug "dataset_type=${dataset_type:-unknown}"
    log_debug "anat_outside_ses_summary=${anat_outside_ses_summary:-null}"
    log_debug "anat_outside_ses_enabled=${anat_outside_ses_enabled:-0}"
    log_debug "anat_outside_ses_for_item=$anat_outside_ses_for_item"
    log_debug "anat_id_prefix=$anat_id_prefix"
    log_debug "anat_dir=$anat_dir"
    log_debug "func_dir=$func_dir"
    log_debug "anat_t1=$anat_t1"
    log_debug "mask_anat_native=$mask_anat_native"
    log_debug "gm_seg_native=$gm_seg_native"
    log_debug "matrix=${matrix:-}"
    log_debug "mask_func_space=$mask_func_space"
    log_debug "refbold_space=$refbold_space"
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
    local space_token="${5:-__NONE__}"
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

    cleanup_subject_tmp() {
        rm -rf -- "$id_tmp_dir"
    }

    if [[ "${no_temp_cleanup:-0}" == "1" ]]; then
        log_info "Temporary work files will be kept: $id_tmp_dir"
    else
        trap cleanup_subject_tmp RETURN
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

    resolve_subject_session_inputs
    select_metric_space_files

    log_step \
        "Checking that resolved files belong to the expected subject/session"

    if (( anat_outside_ses_for_item )); then
        local expected_subject
        expected_subject=$(extract_sub_id "$id_key")

        if [[ -z "$expected_subject" ]]; then
            log_error "Could not extract subject ID from work item: $id_key"
            return 1
        fi

        check_matching_subjects \
            "$expected_subject" \
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

    log_debug "mask_anat_space=$mask_anat_space"
    log_debug "mask_func_space=$mask_func_space"
    log_debug "refbold_space=$refbold_space"
    log_debug "gm_seg_space=$gm_seg_space"

    case "$func_space" in
        T1w)
            # The functional files are already in T1w coordinates, but they
            # may have a different voxel grid or resolution from the
            # anatomical T1w image. Resample them onto the anatomical grid
            # before calculating Dice and dropout.
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
                "resampled_refbold_native=$refbold_native"
            ;;

        *MNI*)
            # MNI functional inputs and MNI anatomical inputs are already
            # selected at their requested template space and resolution.
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

    # TemplateFlow and NMI processing apply only to MNI work items.
    if is_mni_space "$metric_space"; then
        local refbold_t1space

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

        local res_label
        local template_t1
        local template_mask

        if ! res_label=$(
            templateflow_resolution_label \
                "$template_resolution"
        )
        then
            log_error "Could not format template resolution"
            return 1
        fi

        if ! template_t1=$(
            find_single_file \
                "$templateflow_dir" \
                "tpl-${template_space}_res-${res_label}_T1w.nii.gz"
        )
        then
            log_error "Could not locate TemplateFlow T1"
            return 1
        fi

        if ! template_mask=$(
            find_single_file \
                "$templateflow_dir" \
                "tpl-${template_space}_res-${res_label}_desc-brain_mask.nii.gz"
        )
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
        log_info \
            "Skipping TemplateFlow NMI for non-MNI space: $metric_space"
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
    export no_temp_cleanup
    export tmp_dir output_dir extracted_metrics_file input_dir
    export templateflow_dir dataset_summary_json entropy_lookup_tsv
    export dataset_type anat_outside_ses_summary anat_outside_ses_enabled
    export gm_threshold dropout_percentile mattes_bins
    export metrics_dir dice_dir dropout_dir nmi_dir work_dir
    export VERBOSE LOG_TIMESTAMPS
    export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN

    export -f log_message log_info log_ok log_warn log_error log_step log_debug log_section

    export -f require_command require_file require_dir
    export -f read_yaml expand_config_vars
    export -f resolve_glob_one find_single_file find_single_dir
    export -f extract_sub_id extract_ses_id
    export -f check_matching_ids check_matching_subjects

    export -f is_mni_space json_single_value normalize_resolution
    export -f anat_dir_has_t1w subject_session_count
    export -f find_wrapped_session_anat_dir find_session_anat_dir
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

    if (( no_temp_cleanup )); then
        log_info "Cleanup of temporary files: disabled"
    else
        log_info "Cleanup of temporary files: enabled"
    fi

    local subject_id_keys_file="$tmp_dir/subject_id_keys.txt"
    work_items_tsv="$tmp_dir/functional_work_items.tsv"
    dataset_summary_json="$tmp_dir/dataset_summary.json"

    # The input layout cannot be discovered or validated until any archived
    # top-level subject/session directories have been extracted.
    extract_zipped_input_directories

    log_step "Exploring dataset structure"
    structure_command=(
        python
        "$script_dir/dataset_utils.py"
        "$input_dir"
    )

    if [[ -n "${bids_filter:-}" ]]; then
        structure_command+=(
            --bids-filter
            "$bids_filter"
        )
        log_ok "BIDS filter detected: $bids_filter"
    fi

    "${structure_command[@]}" >"$dataset_summary_json"

    log_ok "Dataset summary written: $dataset_summary_json"

    if ! jq -e '.session_summary | type == "object"' \
        "$dataset_summary_json" >/dev/null; then
        log_error "dataset_utils.py did not produce a session_summary object."
        exit 1
    fi

    dataset_type=$(jq -r '.dataset_type // "unknown"' \
        "$dataset_summary_json")
    anat_outside_ses_summary=$(jq -c '.anat_outside_ses // null' \
        "$dataset_summary_json")

    case "$dataset_type" in
        longitudinal|cross_sectional|unknown) ;;
        *)
            log_error "Unsupported dataset_type in dataset summary: $dataset_type"
            exit 1
            ;;
    esac

    if [[ "$dataset_type" != "longitudinal" \
        && "$anat_outside_ses_summary" != "null" ]]
    then
        log_error \
            "anat_outside_ses must be null unless dataset_type is longitudinal."
        exit 1
    fi

    if [[ "$dataset_type" == "longitudinal" ]] \
        && ! jq -e '
            (.anat_outside_ses | type) == "array"
            and (.anat_outside_ses | length) == 1
            and (
                .anat_outside_ses[0] == "yes"
                or .anat_outside_ses[0] == "no"
            )
        ' "$dataset_summary_json" >/dev/null
    then
        log_error \
            "Longitudinal anat_outside_ses must be exactly [\"yes\"] or [\"no\"]."
        exit 1
    fi

    anat_outside_ses_enabled=0
    if [[ "$dataset_type" == "longitudinal" ]] \
        && jq -e '.anat_outside_ses == ["yes"]' \
            "$dataset_summary_json" >/dev/null
    then
        anat_outside_ses_enabled=1
    fi

    log_info "Dataset type: $dataset_type"
    if [[ "$dataset_type" == "longitudinal" ]]; then
        log_info "Shared anatomy summary: $anat_outside_ses_summary"
        log_info \
            "Subject-level anatomy fallback: $([[ $anat_outside_ses_enabled -eq 1 ]] && printf enabled || printf disabled)"
    fi

    # The layout validator needs the discovered dataset-level anatomy mode,
    # so run it only after dataset_summary.json has been parsed.
    validate_input_subject_directories

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
        --results "$tmp_dir/parallel_logs/{#}_{1}_task-{2}_acq-{3}_run-{4}_space-{5}_res-{6}.stdout" \
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

    check_inputs_global
    run_dataset
}

main "$@"