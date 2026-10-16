. "$EV/srv/run.sh"
echo '$ fm-fleet-snapshot.sh --json | jq .sailors'
r bin/fm-fleet-snapshot.sh --json > "$EV/snapshot.json"; echo "rc=$?"
jq '.sailors' "$EV/snapshot.json"
