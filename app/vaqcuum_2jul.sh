#### note to self:
# need to test native t1 space. multiple spaces. TESTED, but:
# make sure nmi is computed also for t1 space. its empty now, kinda fine bc we got mni space ones, which also does t1 space, but gotta fix that
# account for run- string too
# add bids filter
# add keep or delete working files
# investigate session type: multi or single session

#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: vaqcuum --config_file <config.yaml>"
}

config_file=""

if [[ "$#" -eq 0 ]]; then
    usage
    exit 1
fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --config_file|--config-file)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: --config_file|--config-file requires a YAML file." >&2
                usage
                exit 1
            fi
            config_file="$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$config_file" ]]; then
    echo "ERROR: You must specify --config_file|--config-file." >&2
    usage
    exit 1
fi

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Config file does not exist or is not a file: $config_file" >&2
    exit 1
fi

case "$config_file" in
    *.yaml|*.yml)
        ;;
    *)
        echo "ERROR: Config file must have .yaml or .yml extension: $config_file" >&2
        exit 1
        ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running vaqcuum with config file:"
echo "  $config_file"

bash "$script_dir/runner.sh" "$config_file"