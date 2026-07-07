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