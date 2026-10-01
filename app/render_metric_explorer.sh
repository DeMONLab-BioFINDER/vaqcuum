#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  render_metric_explorer.sh <qc_metrics.csv> [output_dir]

Examples:
  app/render_metric_explorer.sh extracted_metrics.csv
  app/render_metric_explorer.sh extracted_metrics.csv reports/metric-explorer
USAGE
}

qc_csv="${1:-}"
output_root="${2:-}"

if [[ -z "$qc_csv" ]]; then
    usage
    exit 1
fi

if [[ ! -f "$qc_csv" ]]; then
    echo "ERROR: QC metrics CSV not found: $qc_csv" >&2
    exit 1
fi

if ! command -v Rscript >/dev/null 2>&1; then
    echo "ERROR: Rscript is required to render the metric explorer" >&2
    exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
metric_explorer_rmd="$script_dir/metric_explorer.Rmd"

if [[ ! -f "$metric_explorer_rmd" ]]; then
    echo "ERROR: Metric explorer not found: $metric_explorer_rmd" >&2
    exit 1
fi

# normalize the csv path before R changes working directories during rendering
qc_dir=$(cd -- "$(dirname -- "$qc_csv")" && pwd)
qc_csv="$qc_dir/$(basename -- "$qc_csv")"

if [[ -z "$output_root" ]]; then
    output_root="$qc_dir/metric-explorer"
else
    mkdir -p -- "$output_root"
    output_root=$(cd -- "$output_root" && pwd)
fi

# check the packages needed by the report before rendering any spaces
if ! Rscript -e 'pkgs <- c("rmarkdown", "tidyverse", "robustbase", "reticulate", "plotly", "htmlwidgets", "htmltools"); missing <- pkgs[!vapply(pkgs, requireNamespace, quietly=TRUE, FUN.VALUE=logical(1))]; if (length(missing)) { message("missing R packages: ", paste(missing, collapse=", ")); quit(status=1) }'; then
    echo "ERROR: Required R packages are missing" >&2
    exit 1
fi

mkdir -p -- "$output_root"
spaces_file=$(mktemp "${TMPDIR:-/tmp}/vaqcuum_metric_spaces.XXXXXX")
trap 'rm -f -- "$spaces_file"' EXIT

# discover output spaces directly from the final qc csv
Rscript - "$qc_csv" >"$spaces_file" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
qc <- read.csv(args[[1]], stringsAsFactors = FALSE, check.names = FALSE)

if (!"space" %in% names(qc)) {
  stop("qc csv has no space column")
}

spaces <- trimws(as.character(qc$space))
spaces <- sort(unique(spaces[!is.na(spaces) & nzchar(spaces)]))
cat(spaces, sep = "\n")
RSCRIPT

if [[ ! -s "$spaces_file" ]]; then
    echo "ERROR: No output spaces found in QC metrics CSV" >&2
    exit 1
fi

failed=0
while IFS= read -r space; do
    [[ -z "$space" ]] && continue

    safe_space=$(printf '%s' "$space" | sed 's/[^A-Za-z0-9_.-]/_/g')
    space_dir="$output_root/$safe_space"
    report_file="metric_explorer_${safe_space}.html"
    mkdir -p -- "$space_dir"

    echo "Rendering metric explorer for space=$space" >&2

    if Rscript - \
        "$metric_explorer_rmd" \
        "$qc_csv" \
        "$space" \
        "$space_dir" \
        "$report_file" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)

rmarkdown::render(
  input = args[[1]],
  params = list(
    qc_csv = args[[2]],
    space = args[[3]],
    output_dir = args[[4]]
  ),
  output_file = args[[5]],
  output_dir = args[[4]],
  envir = new.env(parent = globalenv()),
  quiet = TRUE
)
RSCRIPT
    then
        echo "Metric explorer ready: $space_dir/$report_file" >&2
    else
        echo "ERROR: Metric explorer failed for space=$space" >&2
        failed=1
    fi
done <"$spaces_file"

if (( failed )); then
    exit 1
fi

echo "Metric explorer output: $output_root" >&2
