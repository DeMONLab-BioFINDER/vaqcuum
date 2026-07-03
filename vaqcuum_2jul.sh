#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: vaqcuum --fmriprep -i <input_dir> -o <output_dir> --config_file <config.yaml>"
}

if [[ "$#" -lt 7 ]]; then
    usage
    exit 1
fi

mode=""
input_dir=""
output_dir=""
config_file=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --fmriprep)
            mode="fmriprep"
            shift
            ;;

        -i|--input|--i)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: -i/--i requires an input directory." >&2
                usage
                exit 1
            fi
            input_dir="$2"
            shift 2
            ;;

        -o|--output)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: -o requires an output directory." >&2
                usage
                exit 1
            fi
            output_dir="$2"
            shift 2
            ;;

        --config_file)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: --config_file requires a YAML file." >&2
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

if [[ "$mode" != "fmriprep" ]]; then
    echo "ERROR: You must specify --fmriprep." >&2
    usage
    exit 1
fi

if [[ -z "$input_dir" ]]; then
    echo "ERROR: You must specify an input directory with -i." >&2
    usage
    exit 1
fi

if [[ -z "$output_dir" ]]; then
    echo "ERROR: You must specify an output directory with -o." >&2
    usage
    exit 1
fi

if [[ -z "$config_file" ]]; then
    echo "ERROR: You must specify a config file with --config_file." >&2
    usage
    exit 1
fi

if [[ ! -d "$input_dir" ]]; then
    echo "ERROR: Input directory does not exist or is not a directory: $input_dir" >&2
    exit 1
fi

if [[ ! -d "$output_dir" ]]; then
    echo "ERROR: Output directory does not exist or is not a directory: $output_dir" >&2
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

echo "Running vaqcuum on fMRIPrep input:"
echo "  Input directory:  $input_dir"
echo "  Output directory: $output_dir"
echo "  Config file:      $config_file"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$script_dir/runner.sh" \
    "$input_dir" \
    "$output_dir" \
    "$config_file"