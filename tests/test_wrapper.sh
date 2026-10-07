#!/usr/bin/env bash
# Validation tests for bin/libd-ai-sandbox. Run on a compute or transfer node:
#   tests/test_wrapper.sh
# Uses an isolated synthetic home and config dir under $MYSCRATCH, never the
# user's real sandbox home. Every write attempted against a read-only location is
# checked on the host afterwards; leaked files are reported as failures and removed.
# The real home is only ever mounted read-only by these tests.
set -uo pipefail
REPO=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
SBX=$REPO/bin/libd-ai-sandbox
TAG=sbx_probe_$$
T=$MYSCRATCH/.sbx_test_$$
mkdir -p "$T/config/skel" "$T/ro_in_scratch"
export LIBD_AI_SANDBOX_HOME=$T/home
export LIBD_AI_SANDBOX_CONFIG_DIR=$T/config
export LIBD_AI_SANDBOX_STATE=$T/state
REAL_HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
cleanup_files=()

expect_refusal() {   # DESCRIPTION SUBSTRING -- wrapper args...
    local desc=$1 want=$2; shift 3
    local out rc
    out=$("$SBX" --dry-run "$@" 2>&1); rc=$?
    if [ $rc -ne 0 ] && [[ "$out" == *"$want"* ]]; then ok "refuses: $desc"
    else bad "refuses: $desc (rc=$rc) :: $out"; fi
}
writable_probe_dir() {   # a host dir the user can write under $1
    local root=$1 d
    [ -w "$root" ] && { echo "$root"; return; }
    d=$(timeout 20 find "$root" -mindepth 1 -maxdepth 3 -type d -writable -print -quit 2>/dev/null)
    [ -n "$d" ] && echo "$d"
}

echo "== refusals (no container started)"
WT=$REPO/tests/.sbx_write_target
mkdir -p "$WT"
expect_refusal "autofs map root as --read"        "autofs map"            -- --read /dcs04
expect_refusal "whole export as --write"          "whole read-only mount" -- --write /dcs04/lieber
expect_refusal "missing --write dir"              "must be an existing"   -- --write "$REPO/tests/.sbx_does_not_exist"
expect_refusal "--write /"                        "real home"             -- --write /
expect_refusal "--write system path"              "system/shared path"    -- --write /usr/local
expect_refusal "--write under /jhpce/shared"      "system/shared path"    -- --write /jhpce/shared/libd
expect_refusal "--write real home"                "real home"             -- --write "$REAL_HOME"
expect_refusal "--read real home (synthetic mode)" "real-ro"              -- --read "$REAL_HOME"
expect_refusal "--write autofs parent of a ro mount" "entire filesystem" -- --write /dcs04
expect_refusal "--write whole scratch filesystem" "entire filesystem"     -- --write /fastscratch/myscratch
expect_refusal "bad --home-mode"                  "--home-mode must be"   -- --home-mode bogus
LIBD_AI_SANDBOX_HOME=/dcs04/lieber expect_refusal "synthetic home = whole ro export" "whole read-only mount" --
LIBD_AI_SANDBOX_HOME=$REAL_HOME expect_refusal "synthetic home = real home" "real home" --
printf '/dcs04/lieber/lcolladotor /dcs04/lieber/lcolladotor rw no\n' > "$T/bad.tsv"
LIBD_AI_SANDBOX_MOUNTS_EXTRA=$T/bad.tsv expect_refusal "rw entry in mounts file" "mode must be 'ro'" --
printf '/dcs05 /dcs05 ro no\n' > "$T/bad.tsv"
LIBD_AI_SANDBOX_MOUNTS_EXTRA=$T/bad.tsv expect_refusal "autofs root in mounts file" "autofs map" --

out=$("$SBX" --dry-run --write "$WT" 2>&1) && [[ "$out" == *"rw   $WT"* ]] && ok "dry-run lists --write target" || bad "dry-run :: $out"
[ ! -e "$T/home" ] && [ ! -e "$T/state" ] && ok "dry-run creates nothing" || bad "dry-run created files"
out=$("$SBX" --dry-run --home-mode real-rw 2>&1) && [[ "$out" == *"[REAL home, writable]"* ]] && ok "real-rw shown in bind table" || bad "real-rw dry-run :: $out"
if grep -q " $REAL_HOME/" /proc/mounts; then
    out=$("$SBX" --print-binds --home-mode real-ro 2>&1)
    [[ "$out" == *"[nested in $REAL_HOME]"* ]] && ok "real-ro rebinds nested mounts in home read-only" || bad "nested rebind :: $out"
fi

echo "== live: synthetic home"
printf 'from skel\n' > "$T/config/skel/.sbx_skel_marker"
printf '%s %s ro yes\n' "$T/ro_in_scratch" "$T/ro_in_scratch" > "$T/config/mounts.tsv"
RO_TARGETS=()
for root in /dcs04/lieber /dcs05/lieber /dcs07/lieber /jhpce/shared/libd; do
    [ -e "$root" ] || continue
    d=$(writable_probe_dir "$root")
    if [ -n "$d" ]; then RO_TARGETS+=("$d"); else echo "  skip  no host-writable dir found under $root"; fi
done
RO_TARGETS+=("$REPO" "$T/ro_in_scratch")
READ_LINK=""
for l in "$REAL_HOME"/*; do [ -L "$l" ] && [ -d "$l" ] && { READ_LINK=$l; break; }; done

INNER=$(cat <<'INNER_EOF'
# no set -u here: Lmod shell functions reference unset variables
tag=$1; shift; wt=$1; shift; rl=$1; shift
r() { printf '%s\t%s\n' "$1" "$2"; }
r home_path "$HOME"
echo x > "$HOME/$tag" 2>/dev/null && r home_write ok || r home_write fail
echo x > "$MYSCRATCH/$tag" 2>/dev/null && r scratch_write ok || r scratch_write fail
echo x > "$wt/$tag" 2>/dev/null && r writetarget_write ok || r writetarget_write fail
echo x > "/tmp/$tag" 2>/dev/null && r tmp_write ok || r tmp_write fail
for d in "$@"; do
    if echo x > "$d/$tag" 2>/dev/null; then r "ro_write:$d" LEAK; else r "ro_write:$d" blocked; fi
done
r skel "$(cat ~/.sbx_skel_marker 2>/dev/null)"
r editor "$EDITOR"
r cache "$XDG_CACHE_HOME"
if [ -n "$rl" ]; then
    [ -d "$rl" ] && r readlink_visible yes || r readlink_visible no
    echo x > "$rl/$tag" 2>/dev/null && r readlink_write LEAK || r readlink_write blocked
fi
sbatch --wrap true >/dev/null 2>&1; r sbatch_rc $?
ssh -o BatchMode=yes localhost true >/dev/null 2>&1; r ssh_rc $?
[ -e /run/munge/munge.socket.2 ] && r munge visible || r munge absent
r user "$(id -un)"
module load conda_R/4.5.x >/dev/null 2>&1
r R "$(command -v R)"
Rscript -e 'suppressMessages(library(SummarizedExperiment)); cat("ok")' 2>/dev/null | tail -c 2 | { read -r v; r se_load "${v:-fail}"; }
INNER_EOF
)
READ_ARGS=(); [ -n "$READ_LINK" ] && READ_ARGS=(--read "$READ_LINK")
OUT=$("$SBX" --quiet --write "$WT" "${READ_ARGS[@]}" -- bash -c "$INNER" inner "$TAG" "$WT" "$READ_LINK" "${RO_TARGETS[@]}" 2>&1)
get() { printf '%s\n' "$OUT" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

[ "$(get home_path)" = "$REAL_HOME" ] && ok "HOME keeps real path ($REAL_HOME)" || bad "HOME path :: $(get home_path) :: $OUT"
[ "$(get home_write)" = ok ] && [ -f "$T/home/$TAG" ] && [ ! -e "$REAL_HOME/$TAG" ] \
    && ok "home writes land in synthetic home ($T/home), real home untouched" || bad "synthetic home"
[ "$(get scratch_write)" = ok ] && ok "\$MYSCRATCH writable" || bad "\$MYSCRATCH write"
[ "$(get writetarget_write)" = ok ] && [ -f "$WT/$TAG" ] && ok "--write target writable" || bad "--write target"
[ "$(get tmp_write)" = ok ] && [ -f "$MYSCRATCH/ai-sandbox/work/tmp/$TAG" ] && ok "/tmp is scratch-backed" || bad "/tmp"
for d in "${RO_TARGETS[@]}"; do
    v=$(get "ro_write:$d")
    if [ "$v" = blocked ] && [ ! -e "$d/$TAG" ]; then ok "write blocked: $d"
    else bad "write NOT blocked: $d ($v)"; [ -e "$d/$TAG" ] && unlink "$d/$TAG"; fi
done
[ "$(get skel)" = "from skel" ] && ok "skel file copied into synthetic home" || bad "skel :: $(get skel)"
[ "$(get editor)" = nano ] && ok "EDITOR=nano from generated .bashrc" || bad "EDITOR :: $(get editor)"
[ "$(get cache)" = "$MYSCRATCH/ai-sandbox/cache" ] && ok "XDG_CACHE_HOME in scratch" || bad "cache :: $(get cache)"
if [ -n "$READ_LINK" ]; then
    [ "$(get readlink_visible)" = yes ] && [ "$(get readlink_write)" = blocked ] && [ ! -e "$READ_LINK/$TAG" ] \
        && ok "--read of symlinked $READ_LINK visible at its own path, read-only" || bad "--read symlink :: $(get readlink_visible)/$(get readlink_write)"
fi
[ "$(get sbatch_rc)" = 126 ] && ok "sbatch denied" || bad "sbatch rc=$(get sbatch_rc)"
[ "$(get ssh_rc)" = 126 ] && ok "ssh denied" || bad "ssh rc=$(get ssh_rc)"
[ "$(get munge)" = absent ] && ok "munge socket absent" || bad "munge socket visible"
[ "$(get user)" = "$(id -un)" ] && ok "user name resolves" || bad "user :: $(get user)"
[[ "$(get R)" == /jhpce/shared/community/core/conda_R/* ]] && ok "module load conda_R/4.5.x" || bad "conda_R :: $(get R)"
[ "$(get se_load)" = ok ] && ok "SummarizedExperiment loads" || bad "SummarizedExperiment"
ls "$T"/state/logs/*.json >/dev/null 2>&1 && ok "launch log written to state dir" || bad "no launch log"

echo "== live: --home-mode real-ro"
OUT=$("$SBX" --quiet --home-mode real-ro -- bash -c '
r() { printf "%s\t%s\n" "$1" "$2"; }
r home "$HOME"; [ -f ~/.bashrc ] && r real_bashrc yes || r real_bashrc no
echo x > ~/'"$TAG"' 2>/dev/null && r home_write LEAK || r home_write blocked
for m in $(awk -v h="$HOME/" "index(\$2,h)==1{print \$2}" /proc/mounts); do
  echo x > "$m/'"$TAG"'" 2>/dev/null && r "nested:$m" LEAK || r "nested:$m" blocked
done' 2>&1)
[ "$(get home)" = "$REAL_HOME" ] && [ "$(get real_bashrc)" = yes ] && ok "real home visible at \$HOME" || bad "real-ro home :: $OUT"
[ "$(get home_write)" = blocked ] && [ ! -e "$REAL_HOME/$TAG" ] && ok "real home not writable" || { bad "real home WRITABLE"; [ -e "$REAL_HOME/$TAG" ] && unlink "$REAL_HOME/$TAG"; }
while IFS=$'\t' read -r k v; do
    [[ "$k" == nested:* ]] || continue
    m=${k#nested:}
    [ "$v" = blocked ] && [ ! -e "$m/$TAG" ] && ok "nested mount read-only: $m" || { bad "nested mount writable: $m"; [ -e "$m/$TAG" ] && unlink "$m/$TAG"; }
done <<<"$OUT"

# cleanup (explicit files only)
for f in "$T/home/$TAG" "$MYSCRATCH/$TAG" "$WT/$TAG" "$MYSCRATCH/ai-sandbox/work/tmp/$TAG"; do
    [ -e "$f" ] && unlink "$f"
done
rmdir "$WT" 2>/dev/null
if [ -z "${KEEP_TEST_STATE:-}" ]; then
    case "$T" in "$MYSCRATCH"/.sbx_test_[0-9]*) rm -rf -- "$T" ;; esac
else
    echo "   (test state kept in $T)"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
