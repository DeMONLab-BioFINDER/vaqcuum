#!/usr/bin/env bash
set -euo pipefail

# script containing helper functions for vaqcuum

# ============================================================
# BASIC UTILITIES
# ============================================================

# Require a command to be available on PATH before continuing.
require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
}

# Find structure of the data, available spaces, tasks and acquisitions in the input directory.

# Require a file to exist and stop with a clear error if it does not.
require_file() {
    local file="$1"
    local label="$2"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: Missing $label: $file" >&2
        exit 1
    fi
}

# Require a directory to exist and stop with a clear error if it does not.
require_dir() {
    local dir="$1"
    local label="$2"

    if [[ ! -d "$dir" ]]; then
        echo "ERROR: Missing $label directory: $dir" >&2
        exit 1
    fi
}

# Read a value from the YAML config file using yq.
read_yaml() {
    local key="$1"
    yq -r "$key" "$config_file"
}

# Expand config placeholders like {tmp_dir} using current shell variables.
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

# Resolve a glob pattern to exactly one match.
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

# Find exactly one file matching a name pattern, optionally excluding matches.
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

# Find exactly one directory with a path ending in the requested suffix.
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

# Extract the subject ID from a file name prefix before the first underscore.
extract_sub_id() {
    local file="$1"
    local base

    base=$(basename "$file")
    echo "${base%%_*}"
}

# Extract the session ID from a file name segment after the subject prefix.
extract_ses_id() {
    local file="$1"
    local base
    local without_sub

    base=$(basename "$file")
    without_sub="${base#*_}"
    echo "${without_sub%%_*}"
}

# Split a combined subject-session ID into separate shell variables.
split_subject_session_id() {
    local sub_ses_id="$1"

    sub_id="${sub_ses_id%%_ses-*}"
    ses_id="ses-${sub_ses_id#*_ses-}"
}

# Verify that all files match the subject/session of a reference file.
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

#Verify that all files belong to the expected subject.
check_matching_subjects() {
    local expected_sub="$1"
    shift

    local file
    local file_sub

    for file in "$@"; do
        file_sub=$(extract_sub_id "$file")

        if [[ "$file_sub" != "$expected_sub" ]]; then
            echo "ERROR: Subject mismatch detected." >&2
            echo "Expected: $expected_sub" >&2
            echo "File:     $file -> $file_sub" >&2
            exit 1
        fi
    done
}

# fetch templateflow based on templates found
fetch_templateflow() {
    local template="$1"
    local resolution="$2"

    python - "$template" "$resolution" <<'PY'
import sys
from templateflow import api as tflow

template = sys.argv[1]
resolution = int(sys.argv[2]) if sys.argv[2] not in ("", "null", "None") else None

path = tflow.get(
    template,
    resolution=resolution,
    suffix="T1w",
    extension=".nii.gz",
    raise_empty=True,
)

mask = tflow.get(
    template,
    resolution=resolution,
    suffix="mask",
    extension=".nii.gz",
    desc="brain",
    raise_empty=True,
)

PY
}


# Return the earliest anat directory found under a subject directory.
get_earliest_anat_dir() {
    local subject_dir="$1"
    local label="$2"

    local anat_dirs=()

    while IFS= read -r dir; do
        anat_dirs+=("$dir")
    done < <(
        find "$subject_dir" \
            -mindepth 2 \
            -maxdepth 2 \
            -type d \
            -path "*/ses-*/anat" \
            | sort
    )

    if [[ "${#anat_dirs[@]}" -eq 0 ]]; then
        echo "ERROR: No anat directory found for $label." >&2
        echo "  Subject dir: $subject_dir" >&2
        exit 1
    fi

    echo "${anat_dirs[0]}"
}

resample_to_t1() {
    local mask_func_space="$1"
    local refbold_space="$2"
    local reference_file="$3"

    mask_func_anatres=${mask_func_space%.nii.gz}_anatres.nii.gz
    refbold_anatres=${refbold_space%.nii.gz}_anatres.nii.gz
    echo "$mask_func_space"
    echo "$refbold_space"
    echo "$reference_file"
    echo "$mask_func_anatres"
    echo "$refbold_anatres"

    antsApplyTransforms \
        -d 3 \
        -i "$mask_func_space" \
        -r "$reference_file" \
        -o "$mask_func_anatres" \
        -n NearestNeighbor

    antsApplyTransforms \
        -d 3 \
        -i "$refbold_space" \
        -r "$reference_file" \
        -o "$refbold_anatres" \
        -n BSpline
}