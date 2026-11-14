#!/usr/bin/env bash
# Repair the ext2 root filesystem of a disk image without converting the
# image to a raw file.
#
# The image is served by qemu-nbd, nbdfuse exposes that server as a plain
# file, and partitionfs exposes the partitions of that file. e2fsck then
# works directly on the partition file, and its writes travel through the
# chain back into the original image.
#
# The GNU/Hurd root filesystem is ext2 without a journal. After the guest
# has been running (package installation creates and removes a large number
# of files) its shutdown path leaves the inode and block bitmaps out of
# sync with the inode table, and e2fsck reports:
#
#   Deleted inode <n> has zero dtime.
#   Block bitmap differences: ...
#   Inode bitmap differences: ...
#
# The metadata is intact, only the bookkeeping is stale, so e2fsck can
# repair the image while it is not mounted.
#
# Usage: repair_filesystem.sh <image> [partition-number]

set -euo pipefail

IMG="${1:?Usage: $0 <image> [partition-number]}"
PART_NUM="${2:-2}"
# Default to the partitionfs built from the pinned 3p checkout
# (make partitionfs-build); override with the PARTFS environment variable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARTFS="${PARTFS:-$REPO_ROOT/3p/partitionfs/build/partitionfs}"

if [[ ! -f "$IMG" ]]; then
    echo "Image not found: $IMG" >&2
    exit 1
fi

for tool in qemu-nbd nbdfuse e2fsck qemu-img; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required to repair the filesystem" >&2
        exit 1
    fi
done

if [[ ! -x "$PARTFS" ]]; then
    echo "partitionfs binary not found or not executable: $PARTFS" >&2
    exit 1
fi

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
PART_DIR="$TMP_DIR/part"
SOCKET="$TMP_DIR/nbd.sock"
DISK_FILE="$MNT_DIR/disk.raw"
PART_FILE="$PART_DIR/$PART_NUM"
QEMU_NBD_PID=""
NBDFUSE_PID=""
PARTFS_PID=""

# The FUSE daemons have to be stopped before their mount points can be
# removed. A lazy unmount is the fallback when a file is still open.
cleanup() {
    if [[ -n "$PARTFS_PID" ]]; then
        kill "$PARTFS_PID" 2>/dev/null || true
        wait "$PARTFS_PID" 2>/dev/null || true
    fi
    fusermount3 -u "$PART_DIR" 2>/dev/null \
        || fusermount -u "$PART_DIR" 2>/dev/null \
        || fusermount3 -uz "$PART_DIR" 2>/dev/null \
        || fusermount -uz "$PART_DIR" 2>/dev/null \
        || true

    if [[ -n "$NBDFUSE_PID" ]]; then
        kill "$NBDFUSE_PID" 2>/dev/null || true
        wait "$NBDFUSE_PID" 2>/dev/null || true
    fi
    fusermount3 -u "$DISK_FILE" 2>/dev/null \
        || fusermount -u "$DISK_FILE" 2>/dev/null \
        || fusermount3 -uz "$DISK_FILE" 2>/dev/null \
        || fusermount -uz "$DISK_FILE" 2>/dev/null \
        || true

    if [[ -n "$QEMU_NBD_PID" ]]; then
        kill "$QEMU_NBD_PID" 2>/dev/null || true
        wait "$QEMU_NBD_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$MNT_DIR" "$PART_DIR"

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

# Expose the partitions of that file.
"$PARTFS" "$DISK_FILE" "$PART_DIR" > "$TMP_DIR/partitionfs.log" 2>&1 &
PARTFS_PID=$!

for _ in $(seq 1 50); do
    [[ -f "$PART_FILE" ]] && break
    if ! kill -0 "$PARTFS_PID" 2>/dev/null; then
        echo "partitionfs exited during setup:" >&2
        cat "$TMP_DIR/partitionfs.log" >&2
        exit 1
    fi
    sleep 0.2
done

if [[ ! -f "$PART_FILE" ]]; then
    echo "Partition $PART_NUM not found in $IMG" >&2
    cat "$TMP_DIR/partitionfs.log" >&2
    exit 1
fi

echo "Repairing partition $PART_NUM of $IMG"

# -f: the filesystem is not mounted, but it carries the "needs recovery"
# flag; -y: answer every question with yes so that the repair is not
# interactive.
#
# e2fsck exits with 1 when it corrected errors and with 2 when it corrected
# errors and the filesystem should be rebooted; both are success here.
set +e
e2fsck -fy "$PART_FILE"
FSCK_RC=$?
set -e
if (( FSCK_RC & ~3 )); then
    echo "e2fsck failed with status $FSCK_RC" >&2
    exit 1
fi

# Verify the repaired filesystem.
e2fsck -fn "$PART_FILE"

# The writes have to reach the image before the daemons are stopped.
sync

echo "Filesystem repaired: $IMG"
