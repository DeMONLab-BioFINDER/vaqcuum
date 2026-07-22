#### note to self:
# account for run- string too. DONE but NOT TESTED
# add bids filter DONE and TESTED
# add keep or delete working files DONE and TESTED

# investigate session type: multi or single session DONE but NOT TESTED
# if longitudinal dataset and cant find anat in later sessions, it means its in the very first one. use that for all the sessions. aka anat_earliest_ses: "yes"

#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  vaqcuum --config-file <config.yaml> [--bids-filter <filter.json>] [--no-temp-cleanup]

Options:
  --config-file, --config_file
      Path to the YAML configuration file.

  --bids-filter, --bids_filter
      Optional BIDS filter JSON file.

  --no-temp-cleanup
      Keep per-work-item temporary files. By default, they are deleted.

  -h, --help
      Show this help message.
EOF
}

config_file=""
bids_filter=""
no_temp_cleanup=0

if [[ "$#" -eq 0 ]]; then
    usage
    exit 1
fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --config_file|--config-file)
            if [[ "$#" -lt 2 || "$2" == -* ]]; then
                echo "ERROR: $1 requires a YAML file." >&2
                usage >&2
                exit 1
            fi

            config_file="$2"
            shift 2
            ;;

        --bids_filter|--bids-filter)
            if [[ "$#" -lt 2 || "$2" == -* ]]; then
                echo "ERROR: $1 requires a JSON file." >&2
                usage >&2
                exit 1
            fi

            bids_filter="$2"
            shift 2
            ;;

        --no-temp-cleanup)
            no_temp_cleanup=1
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        --)
            shift

            if [[ "$#" -gt 0 ]]; then
                echo "ERROR: Unexpected positional arguments: $*" >&2
                usage >&2
                exit 1
            fi
            ;;

        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$config_file" ]]; then
    echo "ERROR: You must specify --config-file or --config_file." >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Config file does not exist or is not a file: $config_file" >&2
    exit 1
fi

case "${config_file,,}" in
    *.yaml|*.yml)
        ;;
    *)
        echo "ERROR: Config file must have a .yaml or .yml extension: $config_file" >&2
        exit 1
        ;;
esac

if [[ -n "$bids_filter" ]]; then
    if [[ ! -f "$bids_filter" ]]; then
        echo "ERROR: BIDS filter does not exist or is not a file: $bids_filter" >&2
        exit 1
    fi

    case "${bids_filter,,}" in
        *.json)
            ;;
        *)
            echo "ERROR: BIDS filter must have a .json extension: $bids_filter" >&2
            exit 1
            ;;
    esac
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "Running vaqcuum with:"
echo "  Config file: $config_file"

runner_args=("$config_file")

if [[ -n "$bids_filter" ]]; then
    echo "  BIDS filter: $bids_filter"
    runner_args+=(--bids-filter "$bids_filter")
fi

if (( no_temp_cleanup )); then
    runner_args+=(--no-temp-cleanup)
fi

bash "$script_dir/runner.sh" "${runner_args[@]}"