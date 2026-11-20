#!/bin/bash
# Shared plumbing for the filesystem translator tests (exfatfs_test.sh,
# squashfs_test.sh): PASS/FAIL/KNOWN bookkeeping, the host work directory and its
# loop mount, booting or reusing the guest, and bounded guest commands.
#
# The caller sets these, then sources this file:
#   FT_NAME        message prefix and make target, e.g. "exfatfs-test"
#   WORK           host work directory; $WORK/mnt is the only loop mount point
#   REUSE          1: run against the guest a failed run left up
#   GUEST_TIMEOUT  seconds each guest step may take
#   BASE_IMG       image the guest overlay is based on
#   SSH_HOST / SSH_PORT / SSH_KEY
#   TMP_DIR        img/tmp: QEMU log, pidfile, overlay
# Sourcing installs the EXIT trap.  Call ft_prepare_work before building
# images and ft_boot before the first guest command.

for f in "$BASE_IMG" "$SSH_KEY"; do
    [[ -f "$f" ]] || { echo "$FT_NAME: missing $f (make packages)" >&2; exit 1; }
done

FAILED=0
PASSES=()
FAILS=()
KNOWNS=()
GUEST_UP=0

pass() { PASSES+=("$1"); echo "$FT_NAME: PASS $1"; }
fail() { FAILS+=("$1"); FAILED=1; echo "$FT_NAME: FAIL $1"; }
# known NAME REASON STATUS: check NAME fails because of REASON, a gap in an
# interface outside the translator, and does not fail the run.  STATUS is
# the exit status of the check's comparison, which still runs: 0 means the
# gap has closed, and the check fails until it is made an ordinary one.
known() {
    if [[ "$3" == 0 ]]; then
        fail "$1 (known gap closed; promote this check)"
    else
        KNOWNS+=("$1: $2")
        echo "$FT_NAME: KNOWN $1 ($2)"
    fi
}
finish() {
    echo
    echo "$FT_NAME: ${#PASSES[@]} passed, ${#FAILS[@]} failed${KNOWNS[0]+, ${#KNOWNS[@]} known gaps}"
    for f in "${FAILS[@]}"; do echo "  FAIL $f"; done
    for k in "${KNOWNS[@]}"; do echo "  KNOWN $k"; done
    if [[ "$REUSE" == 1 && "$FAILED" == 0 ]]; then
        echo "$FT_NAME: REUSE=1; guest left running"
    fi
    exit "$FAILED"
}

# $WORK/mnt is the only host mount point.  A loop mount left there by an
# aborted run would make rm -rf "$WORK" delete the files inside the image.
unmount_work() {
    if mountpoint -q "$WORK/mnt" 2>/dev/null; then
        sudo umount "$WORK/mnt"
    fi
}
# Any non-zero exit after the guest is up is a failure, so the guest is
# kept for inspection.  vt_cleanup exits, so it runs last.
on_exit() {
    local rc=$?
    unmount_work || echo "$FT_NAME: could not unmount $WORK/mnt" >&2
    if [[ "$GUEST_UP" == 1 ]]; then
        [[ $rc -eq 0 ]] || FAILED=1
        vt_cleanup "$FAILED" "$REUSE"
    fi
    exit "$rc"
}
trap on_exit EXIT

ft_prepare_work() {
    unmount_work
    rm -rf "$WORK"
    mkdir -p "$WORK/mnt"
}

VT_NAME="$FT_NAME"
VT_TMP_DIR="$TMP_DIR"
VT_QEMU_LOG="$TMP_DIR/$FT_NAME-qemu.log"
VT_PIDFILE="$TMP_DIR/$FT_NAME-qemu.pid"
VT_SSH_HOST="$SSH_HOST"
VT_SSH_PORT="$SSH_PORT"
VT_SSH_KEY="$SSH_KEY"
VT_BASE_IMG="$BASE_IMG"
VT_TRACE=""
VT_RERUN_HINT="rerun the checks against it with: REUSE=1 make $FT_NAME; or stop it with: /bin/kill \$(cat $VT_PIDFILE)"
source "$(dirname "${BASH_SOURCE[0]}")/virtio_boot_lib.sh"

ft_boot() {
    vt_check_pidfile "$REUSE"
    if [[ "$REUSE" == 1 ]]; then
        if ! vt_ssh_alive; then
            echo "$FT_NAME: REUSE=1 but no guest answers on port $VT_SSH_PORT" >&2
            echo "  boot one first (without REUSE) or leave a failed run's QEMU running" >&2
            exit 1
        fi
        GUEST_UP=1
        echo "$FT_NAME: reusing the guest already running on port $VT_SSH_PORT"
    else
        GUEST_UP=1
        vt_make_overlay
        echo "$FT_NAME: booting the guest..."
        vt_boot
    fi
}

ssh_opts=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
# Every guest step runs under a timeout: a hung translator must fail its
# check, not hang the run.
bounded() {
    local rc=0
    timeout -k 10 "$GUEST_TIMEOUT" "$@" || rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "$FT_NAME: timed out after ${GUEST_TIMEOUT}s: ${*: -1}" >&2
    fi
    return "$rc"
}
g() { bounded ssh -n "${ssh_opts[@]}" -p "$VT_SSH_PORT" root@"$SSH_HOST" "$@"; }
# An active translator inherits settrans's stdout and stderr, and ssh waits
# for every holder of its channel to close it, so a successful mount would
# never return.  Route settrans through a guest-side log instead.
mount_fs() {
    g "settrans -ac $1 $2 ${4---readonly} -T file $3 </dev/null >/tmp/settrans.log 2>&1; rc=\$?; cat /tmp/settrans.log; exit \$rc"
}
put() { bounded scp -q "${ssh_opts[@]}" -P "$VT_SSH_PORT" "$@" root@"$SSH_HOST":/tmp/; }
get() { bounded scp -q "${ssh_opts[@]}" -P "$VT_SSH_PORT" root@"$SSH_HOST":"$1" "$2"; }
