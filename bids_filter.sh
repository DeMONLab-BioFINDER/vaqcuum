#!/usr/bin/env bash
set -euo pipefail

# if entries under 'filtering' in yaml are empty, then skip for that field. Otherwise, filter for that field. If both are empty, then include all files.
