#!/usr/bin/env bash
set -euo pipefail

# parse cli options and hand control to runner.sh

usage() {
    cat <<'USAGE'
Usage:
  vaqcuum.sh --config-file <config.yaml> [--bids-filter <filter.json>] [--no-temp-cleanup]

Options:
  --config-file, --config_file
      Path to the YAML configuration file.

  --bids-filter, --bids_filter
      Optional BIDS filter JSON file.

  --no-temp-cleanup
      Keep per-work-item temporary files. By default, they are deleted.

  -h, --help
      Show this help message.
USAGE
}

# portable lowercase conversion for older bash versions
to_lower() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

config_file=""
bids_filter=""
no_temp_cleanup=0

if [[ "$#" -eq 0 ]]; then
    usage
    exit 1
fi

# parse cli options
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

        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# validate config and optional filter
if [[ -z "$config_file" ]]; then
    echo "ERROR: You must specify --config-file or --config_file." >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Config file does not exist or is not a file: $config_file" >&2
    exit 1
fi

config_file_lower="$(to_lower "$config_file")"
case "$config_file_lower" in
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

    bids_filter_lower="$(to_lower "$bids_filter")"
    case "$bids_filter_lower" in
        *.json)
            ;;
        *)
            echo "ERROR: BIDS filter must have a .json extension: $bids_filter" >&2
            exit 1
            ;;
    esac
fi

# resolve runner relative to this script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# reuse the current bash interpreter
exec "$BASH" "$script_dir/runner.sh" "${runner_args[@]}"
