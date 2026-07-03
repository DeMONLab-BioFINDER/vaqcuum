#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: vaqcuum --fmriprep --output_space <MNI|mni> -i <input_dir> -o <output_dir>"
}

if [[ "$#" -lt 6 ]]; then
    usage
    exit 1
fi

mode=""
output_space=""
input_dir=""
output_dir=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --fmriprep)
            mode="fmriprep"
            shift
            ;;

        --output_space)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: --output_space requires a value." >&2
                usage
                exit 1
            fi
            output_space="$2"
            shift 2
            ;;

        -i|--input)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: -i/--input requires a directory." >&2
                usage
                exit 1
            fi
            input_dir="$2"
            shift 2
            ;;

        -o|--output)
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: -o/--output requires a directory." >&2
                usage
                exit 1
            fi
            output_dir="$2"
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

if [[ -z "$output_space" ]]; then
    echo "ERROR: You must specify --output_space <MNI|mni>." >&2
    usage
    exit 1
fi

if [[ "$output_space" != "MNI" && "$output_space" != "mni" ]]; then
    echo "ERROR: --output_space must be either MNI or mni." >&2
    usage
    exit 1
fi

if [[ -z "$input_dir" ]]; then
    echo "ERROR: You must specify an input directory with -i or --input." >&2
    usage
    exit 1
fi

if [[ -z "$output_dir" ]]; then
    echo "ERROR: You must specify an output directory with -o or --output." >&2
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

echo "Running vaqcuum on fMRIPrep input:"
echo "  Input directory:  $input_dir"
echo "  Output directory: $output_dir"
echo "  Output space:     $output_space"

bash runner.sh "$input_dir" "$output_dir" "$output_space"