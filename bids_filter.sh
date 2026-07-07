#!/usr/bin/env bash
set -euo pipefail

# if entries under 'filtering' in yaml are empty, then skip for that field. Otherwise, filter for that field. If both are empty, then include all files.

create_bids_filter_json() {
    local config_file="$1"
    local output_json="$2"

    local overrides_json

    overrides_json=$(yq -o=json '.bids_filters // {}' "$config_file")

    jq -n \
        --argjson overrides "$overrides_json" '
        def deepmerge(a; b):
            reduce (b | keys_unsorted[]) as $key (
                a;
                .[$key] =
                    if ((a[$key] | type) == "object") and ((b[$key] | type) == "object")
                    then deepmerge(a[$key]; b[$key])
                    else b[$key]
                    end
            );

        deepmerge(
            {
                "t1w": {
                    "datatype": "anat",
                    "acquisition": "*",
                    "suffix": "T1w"
                },
                "bold": {
                    "datatype": "func",
                    "suffix": "bold",
                    "task": "rest"
                }
            };
            $overrides
        )
        ' > "$output_json"

    echo "$output_json"
}

bids_filter_get() {
    local entity="$1"
    local key="$2"
    local default="${3:-*}"

    jq -r \
        --arg entity "$entity" \
        --arg key "$key" \
        --arg default "$default" \
        '.[$entity][$key] // $default' \
        "$bids_filter_json"
}

bids_optional_entity_pattern() {
    local key="$1"
    local value="$2"

    if [[ -z "$value" || "$value" == "null" ]]; then
        echo ""
    else
        echo "${key}-${value}_"
    fi
}

bids_filter_pattern() {
    local modality="$1"

    python - "$bids_filter_json" "$modality" <<'PY'
import json
import sys

json_file = sys.argv[1]
modality = sys.argv[2]

with open(json_file) as f:
    filters = json.load(f)

entity_map = {
    "acquisition": "acq",
    "reconstruction": "rec",
    "direction": "dir",
    "task": "task",
    "run": "run",
    "echo": "echo",
    "space": "space",
    "desc": "desc",
    "label": "label",
}

skip_keys = {"datatype", "suffix"}

items = filters.get(modality, {})

parts = []

for key, value in items.items():
    if key in skip_keys:
        continue

    if value is None:
        continue

    value = str(value)

    if value in ("", "null", "None", "~"):
        continue

    bids_key = entity_map.get(key, key)

    parts.append(f"{bids_key}-{value}")

if parts:
    print("_".join(parts) + "_")
else:
    print("")
PY
}