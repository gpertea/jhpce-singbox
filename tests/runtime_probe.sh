#!/usr/bin/env bash
# Phase 0 runtime probe: exercise the containment flags the wrapper will rely on
# against a given Singularity/Apptainer binary and a test SIF image.
#
# Usage:
#   tests/runtime_probe.sh <runtime-binary> <image.sif> [ro-test-dir-you-own]
#
# Example (setuid Singularity, the recommended runtime):
#   tests/runtime_probe.sh /jhpce/shared/jhpce/core/singularity/3.11.4/bin/singularity \
#       $MYSCRATCH/ai-sandbox/images/rocky9.sif /dcs04/lieber/<lab>/<your-dir>
#
# All scratch state goes under $MYSCRATCH/ai-sandbox-probe and is removed at the end.
# Any file that unexpectedly appears in the read-only test dir is reported and removed.
set -u
BIN="${1:?runtime binary}"; IMG="${2:?sif image}"
PROJ="${3:-/dcs04/lieber/lcolladotor/dbDev_LIBD001/jhpce-singbox}"
RO_ROOT=$(echo "$PROJ" | cut -d/ -f1-3)          # e.g. /dcs04/lieber
: "${MYSCRATCH:?MYSCRATCH must be set}"
T=$MYSCRATCH/ai-sandbox-probe
mkdir -p "$T/home" "$T/work" "$T/out" "$T/payload"
HOME_FLAGS=(--contain --cleanenv --home "$T/home:$HOME")

echo "########## $("$BIN" --version)"
run() { echo "--- $1"; shift; "$@" 2>&1 | sed 's/^/    /'; echo "    [exit ${PIPESTATUS[0]}]"; }

run "basic exec" "$BIN" exec "$IMG" cat /etc/os-release
run "synthetic home: HOME path kept, write lands in scratch" "$BIN" exec "${HOME_FLAGS[@]}" "$IMG" \
    sh -c 'echo HOME=$HOME; echo hi > ~/synth_write_test && ls -l ~/synth_write_test; ls -a ~; ls ~/.ssh 2>&1'
ls -l "$T/home/synth_write_test"; rm -f "$T/home/synth_write_test"
run "RO bind $RO_ROOT: read ok" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$RO_ROOT:$RO_ROOT:ro" "$IMG" \
    sh -c "ls $PROJ | head -3"
run "RO bind: create/modify/delete MUST fail" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$RO_ROOT:$RO_ROOT:ro" "$IMG" \
    sh -c "touch $PROJ/.ro_probe; echo rc=\$?; mkdir $PROJ/.ro_probe_d; echo rc=\$?; f=\$(ls $PROJ | head -1); echo x >> $PROJ/\$f; echo rc=\$?"
ls "$PROJ"/.ro_probe "$PROJ"/.ro_probe_d 2>/dev/null && { echo "    !!!! LEAK: created on host, removing"; rm -rf "$PROJ"/.ro_probe "$PROJ"/.ro_probe_d; }
run "unlisted storage roots invisible under --contain" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$RO_ROOT:$RO_ROOT:ro" "$IMG" \
    sh -c 'ls /dcs05 /dcs07 2>&1'
run "cwd not auto-bound (run from RO dir)" bash -c "cd -P '$PROJ' && env -u PWD '$BIN' exec ${HOME_FLAGS[*]} --no-mount cwd --pwd '$HOME' '$IMG' sh -c 'pwd; ls $PROJ 2>&1 | head -1'"
run "/agent_out rw + RO parent" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$RO_ROOT:$RO_ROOT:ro" --bind "$T/out:/agent_out" "$IMG" \
    sh -c "touch /agent_out/ok && ls /agent_out; touch $PROJ/.leak; echo rc=\$?"
rm -f "$T/out/ok"
run "same-path rw under RO parent (ordering)" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$RO_ROOT:$RO_ROOT:ro" --bind "$T/out:$PROJ/probe_out" "$IMG" \
    sh -c "touch $PROJ/probe_out/ok; echo rc=\$?; touch $PROJ/.leak; echo rc=\$?"
rm -f "$T/out/ok"
run "payload RO" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$T/payload:/payload:ro" "$IMG" sh -c 'touch /payload/x; echo rc=$?'
run "/tmp without --workdir (expect 64M tmpfs)" "$BIN" exec "${HOME_FLAGS[@]}" "$IMG" sh -c 'df -h /tmp | tail -1'
run "/tmp with --workdir (expect scratch)" "$BIN" exec "${HOME_FLAGS[@]}" --workdir "$T/work" "$IMG" sh -c 'df -h /tmp | tail -1'
run "scheduler / remote cmds absent" "$BIN" exec "${HOME_FLAGS[@]}" "$IMG" \
    sh -c 'for c in sbatch srun salloc scancel ssh scp rsync; do command -v $c || echo "no $c"; done'
run "network none (expect only lo; silently ignored on non-setuid runtimes)" "$BIN" exec "${HOME_FLAGS[@]}" --net --network none "$IMG" ls /sys/class/net
run "cleanenv: no host secrets leak" env OPENAI_API_KEY=probe ANTHROPIC_API_KEY=probe "$BIN" exec "${HOME_FLAGS[@]}" "$IMG" \
    sh -c 'env | grep -ciE "^(SLURM|OPENAI|ANTHROPIC)"'
run "mount table" "$BIN" exec "${HOME_FLAGS[@]}" --bind "$RO_ROOT:$RO_ROOT:ro" "$IMG" sh -c "mount | grep -E '$RO_ROOT| / ' | cut -c1-100"
rm -rf "$T"
