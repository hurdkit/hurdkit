#!/usr/bin/env bash
# Provision the Hurd base qcow2 image by booting it once and applying
# the setup steps from the Debian GNU/Hurd image instructions:
#   https://www.gnu.org/software/hurd/hurd/running/flash_qemu_img.html
#
# The VM is booted and driven over SSH:
#   1. Wait for sshd to accept connections
#   2. Log in as root with the password set during offline preparation
#   3. Check the provision marker; if absent, run apt update/upgrade
#   4. Power off
#
# The SSH session itself is driven by scripts/provision_guest.py, which
# does the login, the commands and the poweroff.
#
# A marker file at /root/.provisioned makes the script idempotent.
#
# The provisioning runs on a private copy of the base image. Only a
# successful run replaces the base image, so a failed or interrupted
# provisioning never leaves a half-written base image behind.
#
# After the guest has powered off, the ext2 filesystem is repaired offline.
# The root filesystem of the Hurd image has no journal, and the shutdown
# path of the guest leaves the inode and block bitmaps out of sync with the
# inode table, which makes e2fsck complain about the resulting image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMG="${1:?Usage: $0 <base.qcow2> [ssh_port]}"
SSH_PORT="${2:-2222}"
SSH_HOST="127.0.0.1"
ROOT_PASSWORD="${ROOT_PASSWORD:-hurdkit}"
# The CPU count and the memory size are configurable so that the guest
# used for the provisioning runs with the same resources as the guest that
# is booted from the resulting image.
CPU_COUNT="${CPU_COUNT:-4}"
MEMORY="${MEMORY:-2G}"

# The package upgrade is off by default. The sid archive currently ships a
# hurd-dev that cannot be unpacked on Hurd (see the hurd-dev comment in
# scripts/provision_guest.py), and a usable image does not need the
# upgrade. Set RUN_APT_UPGRADE=1 to enable it again.
RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-0}"

# The packages that the guest gets. The list is configurable, so that the
# image can carry other tools.
GUEST_PACKAGES="${GUEST_PACKAGES:-curl python3 gdb}"

if [[ ! -f "$BASE_IMG" ]]; then
    echo "Base image not found: $BASE_IMG" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for provisioning" >&2
    exit 1
fi

if ! python3 -c "import pexpect" >/dev/null 2>&1; then
    echo "The python module pexpect is required for provisioning" >&2
    exit 1
fi

# Resolve to absolute paths so the drive paths work from any cwd
BASE_IMG="$(cd "$(dirname "$BASE_IMG")" && pwd)/$(basename "$BASE_IMG")"
BASE_DIR="$(dirname "$BASE_IMG")"

# The working copy lives next to the base image so that replacing the base
# image is a rename within the same filesystem. It is an overlay directly on
# BASE_IMG: creation is near-instant and the guest writes only to the
# overlay, so a failed or interrupted provisioning never touches BASE_IMG and
# no slow full-image conversion is needed up front.
WORK_IMG="$(mktemp -p "$BASE_DIR" .provision.XXXXXX.qcow2)"
qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$WORK_IMG"
# The SSH keys of the guest accounts live next to the base image. They are
# private keys, so the directory is only readable by the owner.
SSH_KEY_DIR="${SSH_KEY_DIR:-$BASE_DIR/keys}"
mkdir -p "$SSH_KEY_DIR"
chmod 700 "$SSH_KEY_DIR"
QEMU_LOG="$(mktemp)"
QEMU_PID=""
cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$QEMU_LOG" "$WORK_IMG" "$BASE_IMG.tmp"
}
trap cleanup EXIT

# KVM is used when it is available; without it the guest runs under
# emulation, which is much slower but works.
QEMU_ACCEL=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL=(-enable-kvm -cpu host)
else
    QEMU_ACCEL=(-cpu max)
    echo "KVM is not available, running the guest without acceleration" >&2
fi

qemu-system-x86_64 \
    "${QEMU_ACCEL[@]}" \
    -smp "$CPU_COUNT" \
    -m "$MEMORY" \
    -drive file="$WORK_IMG",if=ide,cache=writeback \
    -netdev user,id=net0,hostfwd=tcp:"$SSH_HOST":"$SSH_PORT"-:22 \
    -device e1000,netdev=net0 \
    -nographic > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!

# Wait for the SSH port to accept connections. sshd starts during boot,
# so this usually succeeds within a few seconds.
port_open() {
    (exec 3<>"/dev/tcp/$SSH_HOST/$SSH_PORT") 2>/dev/null
}

for _ in $(seq 1 120); do
    if port_open; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "QEMU exited during boot:" >&2
        cat "$QEMU_LOG" >&2
        exit 1
    fi
    sleep 2
done

if ! port_open; then
    echo "Timed out waiting for SSH on port $SSH_PORT" >&2
    cat "$QEMU_LOG" >&2
    exit 1
fi

# Drive the guest over SSH:
#   1. Log in as root with the password set during offline preparation
#   2. Check the provision marker; if absent, run apt update/upgrade
#   3. Write the marker and power off
#
# Terminal echo is disabled first: otherwise the echoed command line is
# indistinguishable from the command output when matching markers.
#
# The forwarded port accepts connections as soon as QEMU is running, but
# sshd in the guest only listens a little later. The login is therefore
# retried until the guest is ready.
#
# The exit status of the driver tells the two failures apart: 1 means that
# the session could not be established and that a retry may work, 2 means
# that a command failed in the guest and that the same guest cannot fix
# that.
SSH_RC=0
for attempt in $(seq 1 12); do
    if SSH_HOST="$SSH_HOST" SSH_PORT="$SSH_PORT" ROOT_PASSWORD="$ROOT_PASSWORD" \
    RUN_APT_UPGRADE="$RUN_APT_UPGRADE" \
    GUEST_PACKAGES="$GUEST_PACKAGES" \
    SSH_KEY_DIR="$SSH_KEY_DIR" \
    python3 "$SCRIPT_DIR/provision_guest.py"; then
        SSH_RC=0
        break
    else
        # The exit status of the failed attempt has to be read here: after
        # the fi it is the status of the if statement, which is 0 even when
        # the attempt failed.
        SSH_RC=$?
    fi
    if (( SSH_RC == 2 )); then
        # A command failed in the guest. The same guest cannot fix that,
        # so retrying would only repeat the failure.
        echo "The provisioning failed in the guest, not retrying" >&2
        exit 1
    fi
    echo "SSH session failed (attempt $attempt), retrying in 10 seconds..."
    sleep 10
done

if (( SSH_RC != 0 )); then
    echo "Could not establish an SSH session with the guest" >&2
    exit 1
fi

# Wait for QEMU to shut down cleanly after the guest powers off. The wait
# is bounded: a guest that does not power off would otherwise block the
# whole pipeline forever.
POWER_OFF_TIMEOUT=300
for _ in $(seq 1 $((POWER_OFF_TIMEOUT / 5))); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 5
done

if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "The guest did not power off within ${POWER_OFF_TIMEOUT}s, terminating QEMU" >&2
    kill "$QEMU_PID" 2>/dev/null || true
    sleep 5
    kill -9 "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
    echo "QEMU log:" >&2
    cat "$QEMU_LOG" >&2
    exit 1
fi

wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

# Repair the filesystem of the provisioned copy. The guest wrote to the
# filesystem, and without a journal the shutdown leaves stale inode and
# block bitmaps behind. The repair runs on the image itself: qemu-nbd
# serves it, nbdfuse exposes it as a file and e2fsck opens the partition
# inside that file by its offset, so no conversion is needed.
bash "$SCRIPT_DIR/repair_filesystem.sh" "$WORK_IMG"

# Flatten the provisioned overlay into the new base image. The overlay
# contains only the changes the guest made; it is read through the backing
# chain (BASE_IMG) and written as a standalone image, then swapped in with a
# rename so a failed flatten never leaves a half-written base image behind.
qemu-img convert -f qcow2 -O qcow2 "$WORK_IMG" "$BASE_IMG.tmp"
mv -f "$BASE_IMG.tmp" "$BASE_IMG"
rm -f "$WORK_IMG"
trap - EXIT
rm -f "$QEMU_LOG"

echo "Provisioning complete."
