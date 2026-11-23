#!/usr/bin/env bash
# Check or repair the ext2 root filesystem of a disk image in place.
#
# The image may be a raw file or a qcow2 file with a backing chain.  A qcow2
# image is served by qemu-nbd and nbdfuse exposes that server as a plain file
# with the raw content of the disk; e2fsck opens the partition inside that
# file by its byte offset ("FILE?offset=BYTES", see scripts/partition.sh),
# and its writes travel through the chain back into the original image.  A
# raw image needs no chain: e2fsck opens the partition inside the image file
# itself.  Either way no loop device, no root privileges and no conversion
# to a raw file are needed.
#
# The GNU/Hurd root filesystem is ext2 without a journal, so a guest that was
# shut down without a clean unmount leaves the inode and block bitmaps out of
# sync with the inode table.  The metadata is intact and only the bookkeeping
# is stale, so e2fsck repairs such an image completely.
#
# Usage: fsck_qcow2.sh [--check|--repair] <image> [partition-number]
#
#   --check    report the state of the filesystem, change nothing
#              (default; exits 0 when the filesystem is clean)
#   --repair   fix the filesystem, then verify that it is clean
#
# The image must not be in use elsewhere: qemu-nbd takes an exclusive lock
# on it.

set -euo pipefail

MODE="check"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)  MODE="check"; shift ;;
        --repair) MODE="repair"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --) shift; break ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *) break ;;
    esac
done

IMG="${1:?Usage: $0 [--check|--repair] <image> [partition-number]}"
PART_NUM="${2:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/partition.sh
source "$SCRIPT_DIR/partition.sh"

if [[ ! -f "$IMG" ]]; then
    echo "Image not found: $IMG" >&2
    exit 1
fi

for tool in e2fsck qemu-img partx; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required to check the filesystem" >&2
        exit 1
    fi
done

# The image format is needed for qemu-nbd; the file name gives no hint.
# The format is parsed from the plain output instead of the JSON output,
# so that the script does not need jq.
IMAGE_FORMAT="$(qemu-img info "$IMG" | sed -n 's/^file format: \(.*\)$/\1/p')"
if [[ -z "$IMAGE_FORMAT" ]]; then
    echo "Could not determine the format of $IMG" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
MNT_DIR="$TMP_DIR/mnt"
SOCKET="$TMP_DIR/nbd.sock"
QEMU_NBD_PID=""
NBDFUSE_PID=""
# The file with the raw content of the disk: the image itself when it is a
# raw image, the file that nbdfuse exposes otherwise.
DISK_FILE=""

# Stop a helper daemon without letting cleanup hang forever: SIGTERM first,
# then SIGKILL when the daemon ignores it (qemu-nbd can sit in a shutdown
# path as long as a client connection is still open).
stop_daemon() {
    local pid="$1"

    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# The FUSE daemon has to be stopped before its mount point can be removed.
# nbdfuse mounts a file, so the mount point is the file, not its directory.
# A lazy unmount is the fallback when the file is still open.
cleanup() {
    if [[ -n "$NBDFUSE_PID" ]]; then
        fusermount3 -u "$MNT_DIR/disk.raw" 2>/dev/null \
            || fusermount -u "$MNT_DIR/disk.raw" 2>/dev/null \
            || fusermount3 -uz "$MNT_DIR/disk.raw" 2>/dev/null \
            || fusermount -uz "$MNT_DIR/disk.raw" 2>/dev/null \
            || true
        stop_daemon "$NBDFUSE_PID"
    fi

    stop_daemon "$QEMU_NBD_PID"
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ "$IMAGE_FORMAT" == "raw" ]]; then
    # A raw image is the disk content already.
    DISK_FILE="$IMG"
else
    for tool in qemu-nbd nbdfuse; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "$tool is required to check a $IMAGE_FORMAT image" >&2
            exit 1
        fi
    done

    mkdir -p "$MNT_DIR"
    DISK_FILE="$MNT_DIR/disk.raw"

    # Serve the image on a Unix socket.
    qemu-nbd -k "$SOCKET" -f "$IMAGE_FORMAT" "$IMG" > "$TMP_DIR/qemu-nbd.log" 2>&1 &
    QEMU_NBD_PID=$!

    for _ in $(seq 1 50); do
        [[ -S "$SOCKET" ]] && break
        sleep 0.2
    done

    if [[ ! -S "$SOCKET" ]]; then
        echo "qemu-nbd did not create its socket" >&2
        cat "$TMP_DIR/qemu-nbd.log" >&2
        exit 1
    fi

    # Expose the served image as a file.
    nbdfuse "$DISK_FILE" --unix "$SOCKET" > "$TMP_DIR/nbdfuse.log" 2>&1 &
    NBDFUSE_PID=$!

    for _ in $(seq 1 50); do
        [[ -f "$DISK_FILE" ]] && break
        sleep 0.2
    done

    if [[ ! -f "$DISK_FILE" ]]; then
        echo "nbdfuse did not create its file" >&2
        cat "$TMP_DIR/nbdfuse.log" >&2
        exit 1
    fi
fi

# The name under which e2fsck opens the partition inside the disk file:
# "<disk file>?offset=<byte offset of the partition>".
if ! PART_FILE="$(partition_target "$DISK_FILE" "$PART_NUM")"; then
    echo "Partition $PART_NUM not found in $IMG" >&2
    exit 1
fi

if [[ "$MODE" == "check" ]]; then
    # -f: the filesystem is not mounted, but it may carry the "needs
    # recovery" flag; -n: answer no to every question, change nothing.
    set +e
    e2fsck -fn "$PART_FILE"
    FSCK_RC=$?
    set -e
    if (( FSCK_RC & ~1 )); then
        echo "Filesystem of $IMG is not clean (e2fsck status $FSCK_RC)" >&2
        exit 1
    fi
    echo "Filesystem of $IMG is clean"
    exit 0
fi

# -f: the filesystem is not mounted, but it carries the "needs recovery"
# flag; -y: answer every question with yes so that the repair is not
# interactive.
#
# e2fsck exits with 1 when it corrected errors and with 2 when it corrected
# errors and the filesystem should be rebooted; both are success here.
echo "Repairing partition $PART_NUM of $IMG"
set +e
e2fsck -fy "$PART_FILE"
FSCK_RC=$?
set -e
if (( FSCK_RC & ~3 )); then
    echo "e2fsck failed with status $FSCK_RC" >&2
    exit 1
fi

# The writes have to reach the image before the daemons are stopped.
sync

# Verify the repaired filesystem.
e2fsck -fn "$PART_FILE"

echo "Filesystem repaired: $IMG"
