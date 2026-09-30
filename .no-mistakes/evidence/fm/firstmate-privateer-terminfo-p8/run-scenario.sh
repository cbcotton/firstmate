#!/usr/bin/env bash
# run-scenario.sh <label> <bin-dir> <TERM> [TERMINFO] : real fm-privateer.sh start/stop in a throwaway lab home under a pty
set -u
label=$1 bindir=$2 term=$3 terminfo=${4-}
EV=/Users/cotton/.no-mistakes/evidence/01M3SAPE7YASAYYVGM6FK9WJG9
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
home=$LAB/home root=$LAB/root fakebin=$LAB/fakebin
mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects" "$fakebin"
printf 'tiller/coder\n' > "$home/config/privateer"
printf 'opencode\n' > "$home/config/crew-harness"
: > "$home/config/sailor-sandbox"
printf '%s\n' '{"sailors":{"tiller":{"title":"Tiller","endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["coder"],"model_settings":{"coder":{"limit":{"context":131072,"output":16384}}}}},"default":{"harness":"opencode","sailor":"tiller","model":"coder"}}' > "$home/config/crew-dispatch.json"
git init -q "$root" && git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# only the sailor model-server probe is faked (no local model server on this machine)
printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'{\"data\":[{\"id\":\"coder\"}]}'" > "$fakebin/curl"; chmod +x "$fakebin/curl"
cat > "$LAB/primary" <<P
#!/usr/bin/env bash
env > '$home/primary.env'; infocmp 2>&1 | head -2 >> '$home/primary.env'; sleep 30
P
chmod +x "$LAB/primary"
envf=$LAB/envfile
{ echo "HOME=$HOME"; echo "PATH=$fakebin:$PATH"; echo "USER=$USER"; echo "SHELL=/bin/zsh"; echo "TERM=$term"
  [ -z "$terminfo" ] || echo "TERMINFO=$terminfo"
  echo "FM_HOME=$home"; echo "FM_ROOT_OVERRIDE=$root"; echo "FM_TEST_SEAM=1"; echo "FM_PRIVATEER_PRIMARY=$LAB/primary"; } > "$envf"
echo "=== $label: TERM=$term TERMINFO=${terminfo:-<unset>} launcher=$bindir/fm-privateer.sh"
echo "\$ fm-privateer.sh start"
python3 $EV/drive.py "$bindir/fm-privateer.sh" "$envf" start
sock=$(printf '%s' "$(cd "$home" && pwd -P)" | shasum -a 256 | cut -c1-12)
sleep 2
echo "\$ tmux -L fm-privateer-$sock list-sessions"
tmux -L fm-privateer-$sock list-sessions 2>&1
echo "--- first mate's environment (TERM*/FM_HOME) and infocmp inside session:"
grep -E '^(TERM|TERMINFO|TERMINFO_DIRS)=|xterm|Reconstructed|couldn' "$home/primary.env" 2>/dev/null || echo "(first mate never ran)"
echo "\$ fm-privateer.sh stop"
python3 $EV/drive.py "$bindir/fm-privateer.sh" "$envf" stop
tmux -L fm-privateer-$sock kill-server 2>/dev/null
rm -rf "$LAB"
