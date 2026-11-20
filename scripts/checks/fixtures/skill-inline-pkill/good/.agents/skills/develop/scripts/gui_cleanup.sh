#!/usr/bin/env bash
# The sanctioned form (G16): the inline full-cmdline match lives in a script file,
# so the rule must not report it — scripts are the fix, not the defect.
set -euo pipefail

PAT=${1:-wezterm-gui.*pi_gui_test}
pids=$(pgrep -af "$PAT" | awk '{print $1}')
for pid in $pids; do
    kill "$pid"
done

pkill -f "$PAT"
