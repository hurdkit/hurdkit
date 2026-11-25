#!/usr/bin/env bash
# Apply one provisioning stage to a qcow2 image and write the result as a
# new image, so that stages can be chained:
#
#   raw -> prepared base -> accounts -> packages -> kernel -> ...
#
#   provision_stage.sh <stage> <in.qcow2> <out.qcow2> [ssh_port]
#
# The stage runs in a qcow2 overlay on top of the input image, driven over
# SSH by scripts/provision_guest.py (the same driver that provisions the
# base image, but with STAGES naming the one stage to run). The overlay is
# kept, not flattened: the output image is the overlay, a thin qcow2 that
# holds only the writes of this stage and names the input image as its
# backing file. Flattening it would copy the entire input on every stage,
# while a rebuild of the chain re-creates the downstream images anyway. The
# overlay is written next to the output and moved into place on success, so
# a failed or interrupted stage never leaves a half-written image behind.
#
# The images are layered, not mutated: the stage after this one takes the
# output of this one as its input, so an updated kernel or package set is
# rebuilt on top of the apt-provisioned image, never into the base image.
# A stage also re-runs safely on an image that already carries it.
#
# A backing chain references its backing files by path: an output image is
# only valid while its backing chain is intact, in place. Rebuilding a
# stage replaces its output, which invalidates the images layered on top
# of it. When an upstream stage changes, rebuild the downstream stages
# with the chain targets of the Makefile, which lets make do exactly that.
#
# Stage environment (see scripts/provision_guest.py for the full list):
#   CUSTOM_KERNEL     host kernel binary for the "kernel" stage; shipped
#                     inside the overlay as /boot/gnumach-1.8-amd64-up.gz
#   CUSTOM_OVERLAY    host directory whose contents are copied into the
#                     guest filesystem (kernel stage)
#   RUN_APT_UPGRADE   "1" upgrades the packages (packages stage)
#   GUEST_PACKAGES    packages to install (packages stage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${1:?Usage: $0 <stage> <in.qcow2> <out.qcow2> [ssh_port]}"
IN_IMG="${2:?Usage: $0 <stage> <in.qcow2> <out.qcow2> [ssh_port]}"
OUT_IMG="${3:?Usage: $0 <stage> <in.qcow2> <out.qcow2> [ssh_port]}"
SSH_PORT="${4:-2222}"
SSH_HOST="127.0.0.1"
ROOT_PASSWORD="${ROOT_PASSWORD:-hurdkit}"
# The same resources as the guests booted from the resulting image.
CPU_COUNT="${CPU_COUNT:-4}"
MEMORY="${MEMORY:-2G}"

RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-0}"
GUEST_PACKAGES="${GUEST_PACKAGES:-curl python3 gdb}"
CUSTOM_OVERLAY="${CUSTOM_OVERLAY:-}"

KNOWN_STAGES="accounts packages kernel"

for s in $KNOWN_STAGES; do
    if [[ "$STAGE" == "$s" ]]; then
        KNOWN=1
        break
    fi
done
if [[ "${KNOWN:-}" != 1 ]]; then
    echo "Unknown stage: $STAGE (known stages: $(echo $KNOWN_STAGES | tr ' ' ','))" >&2
    exit 2
fi

# The stage output is an overlay on the input image: the same path would be
# both backing file and overlay, and the next stage's write would corrupt the
# chain it reads from.
if [[ "$IN_IMG" == "$OUT_IMG" ]]; then
    echo "The input and output images must differ: $IN_IMG" >&2
    exit 2
fi

if [[ "$STAGE" == "kernel" ]]; then
    if [[ -z "${CUSTOM_KERNEL:-}" && -z "$CUSTOM_OVERLAY" ]]; then
        echo "The kernel stage needs CUSTOM_KERNEL or CUSTOM_OVERLAY" >&2
        exit 2
    fi
    if [[ -n "${CUSTOM_KERNEL:-}" && ! -f "$CUSTOM_KERNEL" ]]; then
        echo "Kernel binary not found: $CUSTOM_KERNEL" >&2
        exit 2
    fi
    if [[ -n "$CUSTOM_OVERLAY" && ! -d "$CUSTOM_OVERLAY" ]]; then
        echo "Overlay directory not found: $CUSTOM_OVERLAY" >&2
        exit 2
    fi
fi

if [[ ! -f "$IN_IMG" ]]; then
    echo "Input image not found: $IN_IMG" >&2
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

# Resolve to absolute paths so the backing paths work from any cwd
IN_IMG="$(cd "$(dirname "$IN_IMG")" && pwd)/$(basename "$IN_IMG")"
OUT_DIR="$(cd "$(dirname "$OUT_IMG")" && pwd)"
OUT_IMG="$OUT_DIR/$(basename "$OUT_IMG")"

# The working copy lives next to the output image so that promoting it is
# a rename within the same filesystem. The overlay sits directly on the
# input image: creation is near-instant and the guest writes only to the
# overlay, so a failed stage never touches the input image and no
# full-image conversion is needed up front.
WORK_IMG="$(mktemp -p "$OUT_DIR" .stage.XXXXXX.qcow2)"
qemu-img create -f qcow2 -b "$IN_IMG" -F qcow2 "$WORK_IMG"
# The SSH keys of the guest accounts live next to the images. They are
# private keys, so the directory is only readable by the owner.
SSH_KEY_DIR="${SSH_KEY_DIR:-$OUT_DIR/keys}"
mkdir -p "$SSH_KEY_DIR"
chmod 700 "$SSH_KEY_DIR"
QEMU_LOG="$(mktemp)"
QEMU_PID=""
cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$QEMU_LOG" "$WORK_IMG"
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

# Drive the stage in the guest. The exit status of the driver tells the
# two failures apart: 1 means that the session could not be established
# and that a retry may work, 2 means that a command failed in the guest
# and that the same guest cannot fix that.
SSH_RC=0
for attempt in $(seq 1 12); do
    if SSH_HOST="$SSH_HOST" SSH_PORT="$SSH_PORT" ROOT_PASSWORD="$ROOT_PASSWORD" \
    STAGES="$STAGE" \
    RUN_APT_UPGRADE="$RUN_APT_UPGRADE" \
    GUEST_PACKAGES="$GUEST_PACKAGES" \
    CUSTOM_KERNEL="${CUSTOM_KERNEL:-}" \
    CUSTOM_OVERLAY="$CUSTOM_OVERLAY" \
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
        echo "The stage $STAGE failed in the guest, not retrying" >&2
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

# Repair the filesystem of the staged overlay. The guest wrote to the
# filesystem, and without a journal the shutdown leaves stale inode and
# block bitmaps behind. The repair runs on the overlay itself: qemu-nbd
# serves the disk, nbdfuse exposes it as a file and the repair opens the
# partition by its offset (see scripts/repair_filesystem.sh), so nothing
# has to be converted.
bash "$SCRIPT_DIR/repair_filesystem.sh" "$WORK_IMG"

# Promote the staged overlay to the output image. The overlay holds only
# the changes the guest made and reads the rest through the backing chain
# (IN_IMG), so the rename is atomic and the output stays a thin image.
mv -f "$WORK_IMG" "$OUT_IMG"
trap - EXIT
rm -f "$QEMU_LOG"

echo "Stage $STAGE complete: $OUT_IMG"
