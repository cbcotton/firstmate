#!/usr/bin/env bash
cd "$WT"
for id in graded-scout-s1 plain-scout-s2; do bin/fm-teardown.sh "$id" --force; echo "rc=$?"; done
echo DONE
