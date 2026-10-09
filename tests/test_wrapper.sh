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
mkdir -p "$T/config/skel" "$T/config/profiles" "$T/ro_in_scratch"
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

echo "== help"
out=$("$SBX" --help 2>&1) && [[ "$out" == *"--home-mode"* ]] && ok "--help works" || bad "--help :: $out"

echo "== refusals (no container started)"
WT=$REPO/tests/.sbx_write_target
mkdir -p "$WT"
expect_refusal "autofs map root as --read"        "autofs map"            -- --read /dcs04
expect_refusal "whole export as --write"          "whole read-only mount" -- --write /dcs04/lieber
expect_refusal "missing --write dir"              "must already exist"   -- --write "$REPO/tests/.sbx_does_not_exist"
expect_refusal "--write /"                        "real home"             -- --write /
expect_refusal "--write system path"              "system/shared path"    -- --write /usr/local
expect_refusal "--write under /jhpce/shared"      "system/shared path"    -- --write /jhpce/shared/libd
expect_refusal "--write real home"                "real home"             -- --write "$REAL_HOME"
expect_refusal "--read real home (synthetic mode)" "real-ro"              -- --read "$REAL_HOME"
expect_refusal "--write autofs parent of a ro mount" "refusing --write /dcs04" -- --write /dcs04
expect_refusal "--write whole scratch filesystem" "entire filesystem"     -- --write /fastscratch/myscratch
expect_refusal "bad --home-mode"                  "--home-mode must be"   -- --home-mode bogus
LIBD_AI_SANDBOX_HOME=/dcs04/lieber expect_refusal "synthetic home = whole ro export" "whole read-only mount" --
LIBD_AI_SANDBOX_HOME=$REAL_HOME expect_refusal "synthetic home = real home" "real home" --
{ cat "$REPO/etc/mounts.tsv"; printf '/dcs04/lieber/lcolladotor /dcs04/lieber/lcolladotor rw no\n'; } > "$T/bad.tsv"
LIBD_AI_SANDBOX_MOUNTS=$T/bad.tsv expect_refusal "rw entry in site mounts file" "mode must be 'ro'" --
printf 'read = /dcs05\n' > "$T/config/profiles/autofsroot.conf"
expect_refusal "autofs root as profile read"      "autofs map"            -- --profile autofsroot
printf 'write = %s\n' "$T/no_such_dir" > "$T/config/profiles/missingwrite.conf"
expect_refusal "profile write to a missing folder" "must already exist"   -- --profile missingwrite

printf 'write = /tmp\n' > "$T/config/config"
expect_refusal "write in config file"            "only allowed in profiles" --
unlink "$T/config/config"
printf 'colour = blue\n' > "$T/config/profiles/badkey.conf"
expect_refusal "unknown key in profile"          "unknown key"           -- --profile badkey
expect_refusal "missing profile"                 "not found"             -- --profile nosuchprofile
expect_refusal "invalid module name"             "invalid module name"   -- --module 'x;true'
expect_refusal "--yolo without an agent"         "--yolo needs"          -- --yolo
expect_refusal "--cmd with --agent codex"        "--cmd runs a shell"    -- --agent codex --cmd true
expect_refusal "missing seed folder"             "seed folder not found" -- --codex-seed "$T/no_such_seed"
expect_refusal "--seed-credentials alone"        "needs --codex-seed"    -- --seed-credentials
out=$("$SBX" --dry-run --write "$WT" 2>&1) && [[ "$out" == *"rw   $WT"* ]] && ok "dry-run lists --write target" || bad "dry-run :: $out"
out=$("$SBX" --print-binds 2>&1)
[[ "$out" == *"/dcs04/lieber   [profile default]"* ]] && ok "default profile applied when no --profile is given" || bad "default profile :: $out"
printf 'description = no data\n' > "$T/config/profiles/nodata.conf"
out=$("$SBX" --print-binds --profile nodata 2>&1)
[[ "$out" != *"/dcs04/lieber "* ]] && ok "a profile without include = default has no data folders" || bad "nodata :: $out"
printf 'include = default\ninclude = loopy\nread = %s/no_such_dir\nhome = %s/home_from_profile\n' "$T" "$T" > "$T/config/profiles/loopy.conf"
out=$("$SBX" --print-binds --profile loopy 2>&1)
[[ "$out" == *"/dcs04/lieber   [profile default]"* ]] && ok "include = default inherits data folders; self-include is harmless" || bad "include :: $out"
[[ "$out" == *"not found, skipped: $T/no_such_dir"* ]] && ok "missing profile read folder is skipped with a warning" || bad "missing read :: $out"
[[ "$out" == *"$T/home_from_profile "*"[synthetic home]"* ]] && ok "profile 'home' sets the session home" || bad "profile home :: $out"
out=$("$SBX" --print-binds --profile loopy --home-dir "$T/home_cli" 2>&1)
[[ "$out" == *"$T/home_cli "*"[synthetic home]"* ]] && ok "--home-dir overrides the profile home" || bad "--home-dir :: $out"
[ ! -e "$T/home_from_profile" ] && [ ! -e "$T/home_cli" ] && ok "print-binds created no home" || bad "home created by print-binds"
[ ! -e "$T/home" ] && [ ! -e "$T/state" ] && ok "dry-run creates nothing" || bad "dry-run created files"
out=$("$SBX" --dry-run --home-mode real-rw 2>&1) && [[ "$out" == *"[REAL home, writable]"* ]] && ok "real-rw shown in bind table" || bad "real-rw dry-run :: $out"
if grep -q " $REAL_HOME/" /proc/mounts; then
    out=$("$SBX" --print-binds --home-mode real-ro 2>&1)
    [[ "$out" == *"[nested in $REAL_HOME]"* ]] && ok "real-ro rebinds nested mounts in home read-only" || bad "nested rebind :: $out"
fi

echo "== live: synthetic home"
printf 'from skel\n' > "$T/config/skel/.sbx_skel_marker"
printf 'read = %s\n' "$T/ro_in_scratch" > "$T/config/config"   # read-only folder inside writable $MYSCRATCH
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

echo "== live: profile + personal libraries"
mkdir -p "$T/prof_out"
cat > "$T/config/profiles/t.conf" <<PROF
description = test profile
include = default
module = conda_R/4.5.x
write = $T/prof_out
PROF
OUT=$("$SBX" --quiet --profile t --cmd '
r() { printf "%s\t%s\n" "$1" "$2"; }
r rw "$LIBD_AI_SANDBOX_RW"
r preloaded "$(command -v R)"
Rscript -e "cat(.libPaths(), sep=\"\n\")" 2>/dev/null > /tmp/libpaths.'"$TAG"'
r lib1 "$(sed -n 1p /tmp/libpaths.'"$TAG"')"
r lib2 "$(sed -n 2p /tmp/libpaths.'"$TAG"')"
r pypath "$(/usr/bin/python3 -c "import sys; print(\":\".join(sys.path))")"
echo x > /host_home/R/'"$TAG"' 2>/dev/null && r hostlib_write LEAK || r hostlib_write blocked' 2>&1)
[[ "$(get rw)" == *"$T/prof_out"* ]] && ok "profile write path applied" || bad "profile write :: $OUT"
[[ "$(get preloaded)" == /jhpce/shared/community/core/conda_R/* ]] && ok "profile module preloaded" || bad "profile module :: $(get preloaded)"
if [ -d "$REAL_HOME/R" ]; then
    [ "$(get lib1)" = "$REAL_HOME/R/4.5.x" ] && ok "R: writable sandbox library first" || bad "R lib1 :: $(get lib1)"
    if [ -d "$REAL_HOME/R/4.5.x" ]; then
        [ "$(get lib2)" = /host_home/R/4.5.x ] && ok "R: real personal library second (read-only)" || bad "R lib2 :: $(get lib2)"
    fi
    [ "$(get hostlib_write)" = blocked ] && [ ! -e "$REAL_HOME/R/$TAG" ] && ok "personal R libs not writable" || bad "personal R libs WRITABLE"
fi
pyv=$(/usr/bin/python3 -c 'import sys; print("python%d.%d" % sys.version_info[:2])')
if [ -d "$REAL_HOME/.local/lib/$pyv/site-packages" ]; then
    [[ "$(get pypath)" == *"$REAL_HOME/.local/lib/$pyv/site-packages:/host_home/.local/lib/$pyv/site-packages"* ]] \
        && ok "Python: real user site appended after sandbox user site" || bad "python path :: $(get pypath)"
fi
OUT=$("$SBX" --quiet --no-personal-libs --cmd 'r() { printf "%s\t%s\n" "$1" "$2"; }; [ -e /host_home ] && r hosthome yes || r hosthome no' 2>&1)
[ "$(get hosthome)" = no ] && ok "--no-personal-libs hides /host_home" || bad "--no-personal-libs :: $OUT"

echo "== live: agent config folders and seeding (fake source folders)"
F=$T/fake_agents
mkdir -p "$F/.codex/skills/demo" "$F/.codex/skills/.system/x" "$F/.codex/sessions" "$F/.claude/commands"
printf '# my codex rules\n' > "$F/.codex/AGENTS.md"
printf 'model = "x"\n' > "$F/.codex/config.toml"
printf 'skill\n' > "$F/.codex/skills/demo/SKILL.md"
printf 'sys\n' > "$F/.codex/skills/.system/x/SKILL.md"
printf 'secret session\n' > "$F/.codex/sessions/s1.jsonl"
printf '{"auth_mode":"fake"}\n' > "$F/.codex/auth.json"
printf '{}\n' > "$F/.claude/settings.json"
printf 'cmd\n' > "$F/.claude/commands/c.md"
printf '{"claudeAiOauth":{}}\n' > "$F/.claude/.credentials.json"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"x":1},"userID":"u","projects":{"p":1}}\n' > "$F/.claude.json"
CX=$T/home/.codex; CL=$T/home/.claude
OUT=$("$SBX" --quiet --codex-seed "$F/.codex" --claude-seed "$F/.claude" --cmd '
r() { printf "%s\t%s\n" "$1" "$2"; }
r codex_home "$CODEX_HOME"; r claude_dir "$CLAUDE_CONFIG_DIR"
r codex_bin "$(command -v codex)"; r claude_bin "$(command -v claude)"' 2>&1)
[ "$(get codex_home)" = "$REAL_HOME/.codex" ] && [ "$(get claude_dir)" = "$REAL_HOME/.claude" ] \
    && ok "CODEX_HOME / CLAUDE_CONFIG_DIR point at the sandbox's own folders" || bad "agent dirs :: $OUT"
[ -f "$CX/config.toml" ] && [ -f "$CX/skills/demo/SKILL.md" ] && [ -f "$CL/settings.json" ] && [ -f "$CL/commands/c.md" ] \
    && ok "settings seeded" || bad "settings not seeded"
[ ! -e "$CX/auth.json" ] && [ ! -e "$CL/.credentials.json" ] && ok "credentials not seeded by default" || bad "credentials seeded without --seed-credentials"
[ ! -e "$CX/sessions" ] && [ ! -e "$CX/skills/.system" ] && ok "sessions and agent-managed .system skills not copied" || bad "unwanted files copied"
grep -q '^# my codex rules' "$CX/AGENTS.md" && grep -q 'libd-ai-sandbox:begin' "$CX/AGENTS.md" && grep -q 'libd-ai-sandbox:begin' "$CL/CLAUDE.md" \
    && ok "user instructions kept, sandbox notes block added" || bad "notes block"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sorted(d)==["hasCompletedOnboarding"] else 1)' "$CL/.claude.json" \
    && ok ".claude.json: only onboarding settings without credentials" || bad ".claude.json keys :: $(cat "$CL/.claude.json")"
"$SBX" --quiet --codex-seed "$F/.codex" --claude-seed "$F/.claude" --seed-credentials --cmd true >/dev/null 2>&1
[ "$(stat -c %a "$CX/auth.json" 2>/dev/null)" = 600 ] && [ "$(stat -c %a "$CL/.credentials.json" 2>/dev/null)" = 600 ] \
    && ok "--seed-credentials copies logins with mode 600" || bad "credential seeding"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "oauthAccount" in d and "projects" not in d else 1)' "$CL/.claude.json" \
    && ok ".claude.json: account added, history excluded" || bad ".claude.json account :: $(cat "$CL/.claude.json")"
n1=$(grep -c 'libd-ai-sandbox:begin' "$CX/AGENTS.md")
[ "$n1" = 1 ] && ok "notes block not duplicated across launches" || bad "notes block count $n1"
if [ -n "$(get codex_bin)" ]; then
    v=$("$SBX" --quiet --agent codex -- --version 2>/dev/null | grep -c codex-cli)
    [ "$v" -ge 1 ] && ok "--agent codex runs the mounted CLI" || bad "--agent codex"
else echo "  skip  codex CLI not found on PATH"; fi
if [ -n "$(get claude_bin)" ]; then
    v=$("$SBX" --quiet --agent claude -- --version 2>/dev/null | grep -c 'Claude Code')
    [ "$v" -ge 1 ] && ok "--agent claude runs the mounted CLI" || bad "--agent claude"
else echo "  skip  claude CLI not found on PATH"; fi

echo "== live: symlinks"
mkdir -p "$T/links"
ln -sfn /dcs04/lieber "$T/links/mounted"
ln -sfn /dcl01 "$T/links/unmounted_root"
ln -sfn /dcs04/hansen "$T/links/unmounted_export"
OUT=$("$SBX" --quiet -- bash -c 'for l in "$@"; do [ -e "$l" ] && printf "%s\tok\n" "${l##*/}" || printf "%s\tbroken\n" "${l##*/}"; done' x "$T"/links/* 2>&1)
[ "$(get mounted)" = ok ] && ok "symlink into mounted storage resolves" || bad "mounted link :: $OUT"
[ "$(get unmounted_root)" = broken ] && [ "$(get unmounted_export)" = broken ] \
    && ok "symlinks into unmounted storage are broken, not empty folders" || bad "unmounted links :: $OUT"

echo "== live: --home-mode real-ro"
OUT=$("$SBX" --quiet --home-mode real-ro -- bash -c '
r() { printf "%s\t%s\n" "$1" "$2"; }
r home "$HOME"; [ -f ~/.bashrc ] && r real_bashrc yes || r real_bashrc no
r ssh_entries "$(ls -A ~/.ssh 2>/dev/null | wc -l)"
echo x > ~/'"$TAG"' 2>/dev/null && r home_write LEAK || r home_write blocked
for m in $(awk -v h="$HOME/" "index(\$2,h)==1{print \$2}" /proc/mounts); do
  echo x > "$m/'"$TAG"'" 2>/dev/null && r "nested:$m" LEAK || r "nested:$m" blocked
done' 2>&1)
[ "$(get home)" = "$REAL_HOME" ] && [ "$(get real_bashrc)" = yes ] && ok "real home visible at \$HOME" || bad "real-ro home :: $OUT"
if [ -d "$REAL_HOME/.ssh" ]; then
    [ "$(get ssh_entries)" = 0 ] && ok "~/.ssh hidden in real-home mode" || bad "~/.ssh visible in real-ro: $(get ssh_entries) entries"
fi
out=$("$SBX" --print-binds --home-mode real-rw 2>&1)
[[ "$out" == *"$REAL_HOME/.ssh   [hide ~/.ssh]"* ]] || [ ! -d "$REAL_HOME/.ssh" ] && ok "~/.ssh hidden in real-rw mode" || bad "real-rw ~/.ssh :: $out"
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
