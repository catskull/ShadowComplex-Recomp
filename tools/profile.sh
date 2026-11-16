#!/bin/sh
# Profile the running native build for 10 seconds (run it while playing a slow section).
# Writes ~/sc.txt (full call-tree sample) for analysis.
PID=$(pgrep -x ShadowComplexRemastered | head -1)
if [ -z "$PID" ]; then echo "the game is not running"; exit 1; fi
echo "sampling ShadowComplexRemastered (pid $PID) for 10 seconds - keep playing..."
sample "$PID" 10 -file "$HOME/sc.txt" >/dev/null 2>&1
echo "saved $HOME/sc.txt"
