#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run_synth.sh <jobs.txt> [out_dir] - run synth_ooc.tcl on a job list in ONE Vivado batch
# process. Waits while MAX_JOBS (default 2) or more Vivado processes run on the host, so a
# shared build machine is not overloaded. Needs vivado on PATH or VIVADO_SETTINGS.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(readlink -f "$1")"
OUT="$(readlink -m "${2:-$HERE/build}")"
MAX_JOBS="${MAX_JOBS:-2}"
mkdir -p "$OUT"
if ! command -v vivado >/dev/null 2>&1; then
    [ -n "${VIVADO_SETTINGS:-}" ] || { echo "put vivado on PATH or set VIVADO_SETTINGS" >&2; exit 1; }
    set +u
    # shellcheck disable=SC1090
    source "$VIVADO_SETTINGS"
    set -u
fi
nviv() { pgrep -a -x vivado | grep -c '/unwrapped/' || true; }
while [ "$(nviv)" -ge "$MAX_JOBS" ]; do
    echo "$(date +%T) waiting: $(nviv) Vivado jobs running"
    sleep 60
done
LOG="$OUT/$(basename "$JOBS" .txt)_$(date +%Y%m%d_%H%M%S).log"
echo "log: $LOG"
cd "$OUT" && vivado -mode batch -nojournal -nolog -notrace -source "$HERE/synth_ooc.tcl" \
    -tclargs "$JOBS" "$OUT" > "$LOG" 2>&1
grep -E "^(JOB_|=== JOB)" "$LOG"
