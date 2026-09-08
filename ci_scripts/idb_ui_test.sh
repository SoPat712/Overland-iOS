#!/bin/bash
# Requires an IDB companion for SIM; use IDB_COMPANION to select its address.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$DIR/ci_scripts/idb_ui_test.py"
