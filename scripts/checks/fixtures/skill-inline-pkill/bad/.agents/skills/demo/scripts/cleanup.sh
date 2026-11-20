#!/usr/bin/env bash
# G16 fixture: a script file may match full cmdlines, because its own cmdline is
# `bash /path/cleanup.sh` — the pattern never appears in the process table.
set -euo pipefail

PAT=${1:-wezterm-gui.*pi_gui_test}
pids=$(pgrep -af "$PAT" | awk '{print $1}')
[ -n "$pids" ] && pkill -f "$PAT"
