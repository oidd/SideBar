#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/run-hover-tracking.py "$@"
