#!/usr/bin/env bash
#
# Executes CPS AI exposure build.
#   01_build_cps_exposure.do  (Stata)
#   02_boundary_diagnostic.do  (Stata)
#
# Usage:  ./code/run_all.sh
#

# ---- SET THIS: path to your Stata executable ----------------------------
STATA="/Applications/StataNow/StataSE.app/Contents/MacOS/stata-se"
PYTHON="/opt/anaconda3/bin/python3"
# -------------------------------------------------------------------------

set -euo pipefail

# Run from the code/ directory: 02_analysis.do derives its paths from c(pwd)/..
cd "$(dirname "$0")"

echo "=== [01 build cps exposure] $STATA -b do 01_build_cps_exposure.do ==="
if [ ! -x "$STATA" ] && ! command -v "$STATA" >/dev/null 2>&1; then
    echo "!!! Stata not found at '$STATA'. Edit the STATA variable at the top of this script." >&2
    exit 1
fi
"$STATA" -b do 01_build_cps_exposure.do

# Stata batch mode does not reliably return nonzero on a do-file error, so scan
# the log it just wrote for an "r(###);" error marker.
LOG="$(ls -t 01_build_cps_exposure*.log 2>/dev/null | head -n1)"
if [ -n "$LOG" ] && grep -Eq '^r\([0-9]+\);' "$LOG"; then
    echo "!!! [01 build cps exposure] Stata reported an error -- see $LOG" >&2
    exit 1
fi
[ -n "$LOG" ] && echo "    Stata log: $LOG"


echo "=== [02 diagnostics] $STATA -b do 02_boundary_diagnostic.do ==="
if [ ! -x "$STATA" ] && ! command -v "$STATA" >/dev/null 2>&1; then
    echo "!!! Stata not found at '$STATA'. Edit the STATA variable at the top of this script." >&2
    exit 1
fi
"$STATA" -b do 02_boundary_diagnostic.do

# Stata batch mode does not reliably return nonzero on a do-file error, so scan
# the log it just wrote for an "r(###);" error marker.
LOG="$(ls -t 02_boundary_diagnostic*.log 2>/dev/null | head -n1)"
if [ -n "$LOG" ] && grep -Eq '^r\([0-9]+\);' "$LOG"; then
    echo "!!! [02 diagnostics] Stata reported an error -- see $LOG" >&2
    exit 1
fi
[ -n "$LOG" ] && echo "    Stata log: $LOG"

echo ""
echo "All steps completed."
