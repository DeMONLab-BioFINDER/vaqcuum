#!/usr/bin/env bash
set -euo pipefail

# shared shell helpers

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
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

# read a value from the yaml config
read_yaml() {
    local key="$1"
    yq -r "$key" "$config_file"
}

# expand supported config placeholders
expand_config_vars() {
    local value="$1"

    value="${value//\{tmp_dir\}/${tmp_dir-}}"
    value="${value//\{output_dir\}/${output_dir-}}"
    value="${value//\{extracted_metrics_file\}/${extracted_metrics_file-}}"

    value="${value//\{input_dir\}/${input_dir-}}"

    echo "$value"
}

# find exactly one file in a search tree
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

# ensure templateflow files are available in the local cache
fetch_templateflow() {
    local template="$1"
    local resolution="$2"

    "$python_bin" - "$template" "$resolution" <<'PY'
import sys

try:
    from templateflow import api as tflow
except ImportError:
    raise SystemExit(
        "ERROR: Python package 'templateflow' is required for MNI work items"
    )

template = sys.argv[1]
resolution = int(sys.argv[2]) if sys.argv[2] not in ("", "null", "None") else None

tflow.get(
    template,
    resolution=resolution,
    suffix="T1w",
    extension=".nii.gz",
    raise_empty=True,
)

tflow.get(
    template,
    resolution=resolution,
    suffix="mask",
    extension=".nii.gz",
    desc="brain",
    raise_empty=True,
)
PY
}

# resample t1w functional inputs to the anatomical grid
resample_to_t1() {
    local mask_func_space="$1"
    local refbold_space="$2"
    local ref_anatmask="$3"
    local ref_t1="$4"

    # keep generated images inside the worker scratch directory
    mask_func_anatres="$id_tmp_dir/func_mask_anatres.nii.gz"
    refbold_anatres="$id_tmp_dir/boldref_anatres.nii.gz"

    antsApplyTransforms \
        -d 3 \
        -i "$mask_func_space" \
        -r "$ref_anatmask" \
        -o "$mask_func_anatres" \
        -n NearestNeighbor

    antsApplyTransforms \
        -d 3 \
        -i "$refbold_space" \
        -r "$ref_t1" \
        -o "$refbold_anatres" \
        -n BSpline
}
