#!/usr/bin/env bash
# Validation tests for bin/libd-ai-sandbox. Run on a compute or transfer node:
#   tests/test_wrapper.sh
# Every write attempted against a read-only location is checked on the host
# afterwards; any file that leaked is reported as a failure and removed.
set -uo pipefail
REPO=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
SBX=$REPO/bin/libd-ai-sandbox
TAG=sbx_probe_$$
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

# expect_refusal DESCRIPTION EXPECTED_SUBSTRING -- wrapper args...
expect_refusal() {
    local desc=$1 want=$2; shift 3
    local out rc
    out=$("$SBX" --dry-run "$@" 2>&1); rc=$?
    if [ $rc -ne 0 ] && [[ "$out" == *"$want"* ]]; then ok "refuses: $desc"
    else bad "refuses: $desc (rc=$rc) :: $out"; fi
}

# Host directories the user can write to under each read-only root, so the
# in-container write test is meaningful (a write that would succeed on the host).
writable_probe_dir() {
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
expect_refusal "--write /"                        "refusing to make / writable" -- --write /
expect_refusal "--write system path"              "system/shared path"    -- --write /usr/local
expect_refusal "--write under /jhpce/shared"      "system/shared path"    -- --write /jhpce/shared/libd
expect_refusal "--write real home"                "real home"             -- --write "$HOME"
expect_refusal "--write parent of a ro mount"     "contains the read-only mount" -- --write /dcs04
expect_refusal "--write whole scratch filesystem" "entire filesystem"     -- --write /fastscratch/myscratch
EXTRA=$(mktemp "$MYSCRATCH/.sbx_mounts_XXXX")
printf '/dcs04/lieber/lcolladotor /dcs04/lieber/lcolladotor rw no\n' > "$EXTRA"
LIBD_AI_SANDBOX_MOUNTS_EXTRA=$EXTRA expect_refusal "rw entry in mounts file" "mode must be 'ro'" --
printf '/dcs05 /dcs05 ro no\n' > "$EXTRA"
LIBD_AI_SANDBOX_MOUNTS_EXTRA=$EXTRA expect_refusal "autofs root in mounts file" "autofs map" --
unlink "$EXTRA"
out=$("$SBX" --dry-run --write "$WT" 2>&1) && [[ "$out" == *"rw   $WT"* ]] && ok "dry-run lists --write target" || bad "dry-run :: $out"

echo "== live container tests"
RO_TARGETS=()
for root in /dcs04/lieber /dcs05/lieber /dcs07/lieber /jhpce/shared/libd /etc /usr; do
    [ -e "$root" ] || continue
    d=$(writable_probe_dir "$root")
    if [ -n "$d" ]; then RO_TARGETS+=("$d")
    else echo "  skip  no host-writable dir found under $root"; fi
done
RO_TARGETS+=("$REPO")   # owned by the tester, always host-writable

INNER=$(cat <<'INNER_EOF'
# no set -u here: Lmod shell functions reference unset variables
tag=$1; shift; wt=$1; shift
r() { printf '%s\t%s\n' "$1" "$2"; }
r home_path "$HOME"
echo x > "$HOME/$tag" 2>/dev/null && r home_write ok || r home_write fail
echo x > "$MYSCRATCH/$tag" 2>/dev/null && r scratch_write ok || r scratch_write fail
echo x > "$wt/$tag" 2>/dev/null && r writetarget_write ok || r writetarget_write fail
echo x > "/tmp/$tag" 2>/dev/null && r tmp_write ok || r tmp_write fail
for d in "$@"; do
    if echo x > "$d/$tag" 2>/dev/null; then r "ro_write:$d" LEAK; else r "ro_write:$d" blocked; fi
done
sbatch --wrap true >/dev/null 2>&1; r sbatch_rc $?
ssh -o BatchMode=yes localhost true >/dev/null 2>&1; r ssh_rc $?
[ -e /run/munge/munge.socket.2 ] && r munge visible || r munge absent
r user "$(id -un)"
module load conda_R/4.5.x >/dev/null 2>&1
r R "$(command -v R)"
Rscript -e 'suppressMessages(library(SummarizedExperiment)); cat("ok")' 2>/dev/null | tail -c 2 | { read -r v; r se_load "${v:-fail}"; }
INNER_EOF
)
OUT=$("$SBX" --quiet --write "$WT" -- bash -c "$INNER" inner "$TAG" "$WT" "${RO_TARGETS[@]}" 2>&1)
get() { printf '%s\n' "$OUT" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

[ "$(get home_path)" = "$HOME" ] && ok "HOME keeps real path ($HOME)" || bad "HOME path :: $(get home_path)"
[ "$(get home_write)" = ok ] && [ -f "$MYSCRATCH/ai-sandbox/home/$TAG" ] && [ ! -e "$HOME/$TAG" ] \
    && ok "home writes land in synthetic home, real home untouched" || bad "synthetic home"
[ "$(get scratch_write)" = ok ] && ok "\$MYSCRATCH writable" || bad "\$MYSCRATCH write"
[ "$(get writetarget_write)" = ok ] && [ -f "$WT/$TAG" ] && ok "--write target writable" || bad "--write target"
[ "$(get tmp_write)" = ok ] && [ -f "$MYSCRATCH/ai-sandbox/work/tmp/$TAG" ] && ok "/tmp is scratch-backed" || bad "/tmp"
for d in "${RO_TARGETS[@]}"; do
    v=$(get "ro_write:$d")
    if [ "$v" = blocked ] && [ ! -e "$d/$TAG" ]; then ok "write blocked: $d"
    else bad "write NOT blocked: $d ($v)"; [ -e "$d/$TAG" ] && unlink "$d/$TAG"; fi
done
[ "$(get sbatch_rc)" = 126 ] && ok "sbatch denied" || bad "sbatch rc=$(get sbatch_rc)"
[ "$(get ssh_rc)" = 126 ] && ok "ssh denied" || bad "ssh rc=$(get ssh_rc)"
[ "$(get munge)" = absent ] && ok "munge socket absent" || bad "munge socket visible"
[ "$(get user)" = "$(id -un)" ] && ok "user name resolves" || bad "user :: $(get user)"
[[ "$(get R)" == /jhpce/shared/community/core/conda_R/* ]] && ok "module load conda_R/4.5.x" || bad "conda_R :: $(get R)"
[ "$(get se_load)" = ok ] && ok "SummarizedExperiment loads" || bad "SummarizedExperiment"

for f in "$MYSCRATCH/ai-sandbox/home/$TAG" "$MYSCRATCH/$TAG" "$WT/$TAG" "$MYSCRATCH/ai-sandbox/work/tmp/$TAG"; do
    [ -e "$f" ] && unlink "$f"
done
rmdir "$WT" 2>/dev/null

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
