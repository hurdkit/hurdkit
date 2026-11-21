#!/usr/bin/env bash
# Boot the Hurd guest with QEMU's virtio-net device and run the network
# test matrix (scripts/virtio_net_test.py): --status, the Phase 1/2
# selftest (handshake, status flavors, write policy, NET_RCV_MSG
# delivery), the optional raw TX/RX traffic probe, a daemon smoke test
# and a Mach-device translator smoke test, plus the no-device negative
# test.
#
# The guest boots from a throw-away overlay of the staged image, so the
# image stays pristine.  The virtio-net device gets its own backend
# (user-mode networking) independent of the e1000 line that carries SSH.
# In MODE=stall the backend is a stream socket instead, whose far end is
# the matrix: it stops reading to stall the device's transmit queue.
# QEMU connects to the matrix (server=off), since QEMU writes blocking to
# a connection it accepts, which would stop the whole guest in a stall.
#
# On failure QEMU is left running and the serial log is kept, so the
# guest can be inspected by hand (see the printed SSH command; GDB=1
# makes the harness attach gdb to the stuck driver first).
#
# Environment:
#   VIRTIO_DIR  source directory of the virtio drivers (default
#               ~/src/virtio; a workbranch overrides this)
#   VIRTIO_NET_BIN
#               net binary to install (default $VIRTIO_DIR/virtio-net)
#   SSH_HOST / SSH_PORT
#               address QEMU forwards the guest SSH port to (default
#               127.0.0.1 / 2222; "0" lets QEMU pick a free port)
#   REUSE       "1" run the matrix against the guest already listening on
#               SSH_PORT instead of booting a fresh overlay
#   MODE        which matrix to run: main (default), nodev, stress or stall
#   VNET_STALL_SOCKET
#               in MODE=stall, the Unix socket that the matrix listens on
#               and QEMU connects to as the device's backend (default
#               img/tmp/virtio-net-test-stall.sock; needs QEMU 9.2 or newer)
#   GDB         "1" installs gdb in the guest and dumps stacks on failure
#   BASE_IMG    base image for the overlay (default img/hurd.packages.qcow2)
#   RAM_MB      guest memory in MiB (default 2048)
#   VNET_ADDR   PCI slot of the virtio-net device; default 0x6 keeps it
#               off the e1000's line.  An empty override restores the
#               shared-line configuration.
#   E1000_ADDR  PCI slot of the e1000 (default: QEMU's next free slot)
#   QEMU_EXTRA  extra arguments passed to QEMU

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_IMG="${BASE_IMG:-${REPO_ROOT}/img/hurd.packages.qcow2}"
VIRTIO_DIR="${VIRTIO_DIR:-${HOME}/src/virtio}"
# Prefer the virtio-net branch when it is available.
if [[ ! -f "${VIRTIO_DIR}/virtio-net" && -f "${HOME}/src/virtio/virtio-net" ]]; then
    VIRTIO_DIR="${HOME}/src/virtio"
fi
VIRTIO_NET_BIN="${VIRTIO_NET_BIN:-${VIRTIO_DIR}/virtio-net}"
VIRTIO_NET_CLIENT_BIN="${VIRTIO_NET_CLIENT_BIN:-${VIRTIO_DIR}/vnet-client}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
MODE="${MODE:-main}"
VNET_ADDR="${VNET_ADDR-0x6}"
E1000_ADDR="${E1000_ADDR-}"
RAM_MB="${RAM_MB:-2048}"
SSH_KEY_DIR="${SSH_KEY_DIR:-${REPO_ROOT}/img/keys}"
SSH_KEY="${SSH_KEY_DIR}/root_ed25519"

for f in "$BASE_IMG" "$SSH_KEY" "$VIRTIO_NET_BIN" "$VIRTIO_NET_CLIENT_BIN"; do
    if [[ ! -f "$f" ]]; then
        echo "virtio-net-test: missing $f" >&2
        echo "  (for $BASE_IMG: make stage STAGE=packages VARIANT=img/hurd.packages.qcow2)" >&2
        exit 1
    fi
done

TMP_DIR="${REPO_ROOT}/img/tmp"
mkdir -p "$TMP_DIR"
VNET_STALL_SOCKET="${VNET_STALL_SOCKET:-${TMP_DIR}/virtio-net-test-stall.sock}"
FAILED=0
REUSE="${REUSE:-0}"

VT_NAME="virtio-net-test"
VT_TMP_DIR="$TMP_DIR"
VT_QEMU_LOG="${TMP_DIR}/virtio-net-test-qemu.log"
VT_PIDFILE="${TMP_DIR}/virtio-net-test-qemu.pid"
VT_SSH_HOST="$SSH_HOST"
VT_SSH_PORT="$SSH_PORT"
VT_SSH_KEY="$SSH_KEY"
VT_BASE_IMG="$BASE_IMG"
VT_MEM_MB="$RAM_MB"
VT_E1000_ADDR="$E1000_ADDR"
VT_TRACE="virtio_net*"
VT_QTRACE="${QTRACE:-}"
VT_QEMU_EXTRA="${QEMU_EXTRA:-}"
VT_RERUN_HINT="rerun the matrix against it with: REUSE=1 MODE=$MODE make virtio-net-test"
source "$SCRIPT_DIR/virtio_boot_lib.sh"

vt_check_pidfile "$REUSE"
trap 'vt_cleanup "$FAILED" "$REUSE"' EXIT

if [[ "$REUSE" == "1" ]]; then
    : > "$VT_QEMU_LOG"
    if ! vt_ssh_alive; then
        echo "virtio-net-test: REUSE=1 but no guest answers on port $VT_SSH_PORT" >&2
        exit 1
    fi
    echo "virtio-net-test: reusing the guest already running on port $VT_SSH_PORT"
else
    vt_make_overlay
    vnet_backend="user,id=vnet0"
    if [[ "$MODE" == "stall" ]]; then
        rm -f "$VNET_STALL_SOCKET"
        vnet_backend="stream,id=vnet0,server=off,reconnect-ms=1000,addr.type=unix,addr.path=$VNET_STALL_SOCKET"
    fi
    echo "virtio-net-test: booting with the virtio-net device..."
    vt_boot \
        -netdev "$vnet_backend" \
        -device "virtio-net-pci,netdev=vnet0,disable-legacy=off${VNET_ADDR:+,addr=$VNET_ADDR}"
fi
SSH_PORT="$VT_SSH_PORT"

export SSH_HOST SSH_PORT SSH_KEY VIRTIO_NET_BIN VIRTIO_NET_CLIENT_BIN QEMU_LOG="$VT_QEMU_LOG"
export VNET_STALL_SOCKET
export RAM_MB REUSE GDB="${GDB:-0}"

python3 "$SCRIPT_DIR/virtio_net_test.py" "$MODE" || FAILED=1

if [[ "$REUSE" == "1" ]]; then
    if [[ "$FAILED" -eq 1 ]]; then
        exit 1
    fi
    echo "virtio-net-test: REUSE=1; guest left running"
    exit 0
fi

if [[ "$FAILED" -eq 1 ]]; then
    exit 1
fi

if [[ "$MODE" == "main" ]]; then
    if [[ -n "$VT_QEMU_PID" ]]; then
        vt_wait_poweroff || FAILED=1
    fi
    if [[ "$FAILED" -eq 1 ]]; then
        exit 1
    fi

    echo "virtio-net-test: rebooting without the device for the negative test..."
    vt_boot
    python3 "$SCRIPT_DIR/virtio_net_test.py" nodev || FAILED=1
fi

vt_wait_poweroff
echo "virtio-net-test: done."
