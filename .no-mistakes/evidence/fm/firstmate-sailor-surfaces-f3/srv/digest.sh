#!/usr/bin/env bash
cd "$WT"
bin/fm-session-start.sh > "$EV/session-start-full.txt" 2>&1; echo "rc=$?" >> "$EV/session-start-full.txt"
echo DONE >> "$EV/session-start-full.txt"
