#!/usr/bin/env bash
# Boot the Hurd guest with QEMU's virtio-blk device and run the disk test
# matrix (scripts/virtio_blk_test.py): the driver selftest (raw read/
# write/flush plus the Mach device semantics layer), two-sided data
# checks -- the guest reads ranges the host seeded into the disk image
# and the host verifies the guest's writes in the image afterwards --
# trace-backed device-model evidence, and the no-device negative boot.
#
# Data safety (plan D5): the tested disk is a disposable raw image in
# img/tmp/, recreated and re-seeded on every non-REUSE run; the guest's
# --write-test destroys only its sector 0.  The boot disk is a throwaway
# overlay of the staged image, exactly like the other harnesses.
#
# The virtio_blk* QEMU trace events are enabled for every boot: they show
# every request the device model saw (handle_read/handle_write with
# sector and nsectors, rw_complete with the backend status), which is the
# host-side evidence for the datapath assertions.
#
# On failure QEMU is left running and the serial log is kept, so the
# guest can be inspected by hand (see the printed SSH command; GDB=1
# makes the harness attach gdb to the stuck driver first).
#
# The boot scaffolding (overlay, pidfile discipline, SSH probe, monitor
# socket, poweroff wait) lives in scripts/virtio_boot_lib.sh, shared with
# the other virtio harnesses.
#
# Environment:
#   VIRTIO_DIR  source directory of the virtio drivers (default
#               ~/src/virtio; a workbranch overrides this)
#   VIRTIO_BLK_BIN
#               blk binary to install (default $VIRTIO_DIR/virtio-blk)
#   VBLK_CLIENT_BIN
#               direct Mach device RPC client to install (default
#               $VIRTIO_DIR/vblk-client)
#   SSH_HOST / SSH_PORT
#               address QEMU forwards the guest SSH port to (default
#               127.0.0.1 / 2222; "0" lets QEMU pick a free port)
#   REUSE       "1" run the matrix against the guest already listening on
#               SSH_PORT instead of booting a fresh overlay (the state
#               left behind by a failed run); the disk image is not
#               re-seeded and the negative test is skipped
#   MODE        which matrix to run: main (default), nodev or stress
#   GDB         "1" installs gdb in the guest and dumps stacks on failure
#   BASE_IMG    base image for the boot overlay
#               (default img/hurd.packages.qcow2)
#   DISK_MB     size of the disposable test disk in MiB (default 64)
#   VBLK_ADDR   PCI slot of the virtio-blk device; the default 0x5 routes
#               through PIRQ A (IRQ 10), off the e1000's line, like the
#               other harnesses' devices.  An empty override restores the
#               shared-line configuration.
#   E1000_ADDR  PCI slot of the e1000 (default: QEMU's next free slot)
#   QEMU_EXTRA  extra arguments passed to QEMU
#   SSH_PROBE_ATTEMPTS
#               boot patience: number of 2-5 s SSH probes before the boot
#               is declared timed out (default 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The packages variant of the image pipeline: it carries the account SSH
# keys (accounts stage) and the guest packages, unlike the raw base, so
# the harness can log in.  make virtio-blk-test builds the stage chain
# (base -> accounts -> packages) automatically when it is missing or
# stale; standalone runs can point BASE_IMG anywhere.
BASE_IMG="${BASE_IMG:-${REPO_ROOT}/img/hurd.packages.qcow2}"
VIRTIO_DIR="${VIRTIO_DIR:-${HOME}/src/virtio}"
VIRTIO_BLK_BIN="${VIRTIO_BLK_BIN:-${VIRTIO_DIR}/virtio-blk}"
VBLK_CLIENT_BIN="${VBLK_CLIENT_BIN:-${VIRTIO_DIR}/vblk-client}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
MODE="${MODE:-main}"
# Keep the blk device off the e1000's IRQ line by default (see VBLK_ADDR
# above).  An empty override restores the shared-line configuration.
VBLK_ADDR="${VBLK_ADDR-0x5}"
E1000_ADDR="${E1000_ADDR-}"
DISK_MB="${DISK_MB:-64}"
SSH_KEY_DIR="${SSH_KEY_DIR:-${REPO_ROOT}/img/keys}"
SSH_KEY="${SSH_KEY_DIR}/root_ed25519"

for f in "$BASE_IMG" "$SSH_KEY" "$VIRTIO_BLK_BIN" "$VBLK_CLIENT_BIN"; do
    if [[ ! -f "$f" ]]; then
        echo "virtio-blk-test: missing $f" >&2
        echo "  (for $BASE_IMG: make stage STAGE=packages VARIANT=img/hurd.packages.qcow2)" >&2
        exit 1
    fi
done

TMP_DIR="${REPO_ROOT}/img/tmp"
mkdir -p "$TMP_DIR"
FAILED=0
REUSE="${REUSE:-0}"

# The disposable test disk.  Fresh for every real run (REUSE keeps the
# guest's live view of it); the seeding recipe lives in the python matrix
# so the host-side expectations and the image content cannot drift apart.
TEST_DISK="${TMP_DIR}/virtio-blk-test-disk.img"
if [[ "$REUSE" != "1" ]]; then
    rm -f "$TEST_DISK"
    python3 "$SCRIPT_DIR/virtio_blk_test.py" seed "$TEST_DISK" "$DISK_MB"
elif [[ ! -f "$TEST_DISK" ]]; then
    echo "virtio-blk-test: REUSE=1 but the test disk $TEST_DISK is gone" >&2
    exit 1
fi

VT_NAME="virtio-blk-test"
VT_TMP_DIR="$TMP_DIR"
VT_QEMU_LOG="${TMP_DIR}/virtio-blk-test-qemu.log"
VT_PIDFILE="${TMP_DIR}/virtio-blk-test-qemu.pid"
VT_SSH_HOST="$SSH_HOST"
VT_SSH_PORT="$SSH_PORT"
VT_SSH_KEY="$SSH_KEY"
VT_BASE_IMG="$BASE_IMG"
VT_E1000_ADDR="$E1000_ADDR"
VT_TRACE="virtio_blk*"
VT_QTRACE="${QTRACE:-}"
VT_QEMU_EXTRA="${QEMU_EXTRA:-}"
VT_RERUN_HINT="rerun the matrix against it with: REUSE=1 MODE=$MODE make virtio-blk-test"
source "$SCRIPT_DIR/virtio_boot_lib.sh"

vt_check_pidfile "$REUSE"
trap 'vt_cleanup "$FAILED" "$REUSE"' EXIT

if [[ "$REUSE" == "1" ]]; then
    # Trace assertions grep this log; a reused guest has the traces of
    # every earlier run in it, so restart the evidence from zero.  The
    # QEMU process keeps its open fd, so truncation does not disturb it.
    : > "$VT_QEMU_LOG"
    if ! vt_ssh_alive; then
        echo "virtio-blk-test: REUSE=1 but no guest answers on port $VT_SSH_PORT" >&2
        echo "  boot one first (without REUSE) or leave a failed run's QEMU running" >&2
        exit 1
    fi
    echo "virtio-blk-test: reusing the guest already running on port $VT_SSH_PORT"
else
    vt_make_overlay
    echo "virtio-blk-test: booting with the virtio-blk device (disk ${DISK_MB} MiB)..."
    vt_boot \
        -drive "if=none,id=vd0,file=$TEST_DISK,format=raw,cache=writeback" \
        -device "virtio-blk-pci,drive=vd0,disable-legacy=off${VBLK_ADDR:+,addr=$VBLK_ADDR}"
fi
SSH_PORT="$VT_SSH_PORT"

export SSH_HOST SSH_PORT SSH_KEY VIRTIO_BLK_BIN VBLK_CLIENT_BIN
export QEMU_LOG="$VT_QEMU_LOG"
export TEST_DISK DISK_MB REUSE GDB="${GDB:-0}"

python3 "$SCRIPT_DIR/virtio_blk_test.py" "$MODE" || FAILED=1

if [[ "$REUSE" == "1" ]]; then
    # The reused guest keeps running for further inspection or another
    # REUSE run; only the python matrix decides pass/fail here.
    if [[ "$FAILED" -eq 1 ]]; then
        exit 1
    fi
    echo "virtio-blk-test: REUSE=1; guest left running"
    exit 0
fi

if [[ "$FAILED" -eq 1 ]]; then
    exit 1
fi

if [[ "$MODE" == "main" ]]; then
    # The main matrix's python powers the guest off on success; wait for
    # that QEMU to exit and release the forwarded port before the
    # no-device boot binds the same port, or the new QEMU dies on the bind
    # race.
    if [[ -n "$VT_QEMU_PID" ]]; then
        vt_wait_poweroff || FAILED=1
    fi
    if [[ "$FAILED" -eq 1 ]]; then
        exit 1
    fi

    echo "virtio-blk-test: rebooting without the device for the negative test..."
    # No drive, no device: the negative test needs a guest where the
    # driver finds nothing on the bus.
    vt_boot
    python3 "$SCRIPT_DIR/virtio_blk_test.py" nodev || FAILED=1
fi

vt_wait_poweroff
echo "virtio-blk-test: done."
