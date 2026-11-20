#!/usr/bin/env bash
# mount_image.sh <img.qcow2> <mntpath> [partition]
#
# Mount a qcow2 (or raw) disk image's partition to a directory without root
# privileges, using the qemu-nbd + nbdfuse + fuse2fs chain described in
# skills/BOOT.md ("Offline filesystem repair"):
#
#   qemu-nbd serves the image on a Unix socket
#   nbdfuse exposes the served disk as a plain raw file
#   fuse2fs mounts the ext2 partition (at its byte offset) to <mntpath>
#
# No loop device, no libguestfs, no root: only /dev/fuse is required.
# The image stays read-only through the chain unless the guest wrote dirty
# metadata; fuse2fs with fakeroot permits reading root-owned files.
#
# The mount persists after this script exits. Unmount with:
#
#   fusermount -u <mntpath>
#
# and then stop the daemons whose PIDs are printed at mount time (and remove
# the working directories they print).
#
# Note: nbdfuse leaves its working directory non-writable (mode 000), so
# logs and the PID file are kept in a separate directory that stays writable.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/partition.sh
source "$SCRIPT_DIR/partition.sh"

IMG="${1:?Usage: $0 <img.qcow2> <mntpath> [partition]}"
MNTPATH="${2:?Usage: $0 <img.qcow2> <mntpath> [partition]}"
PARTITION="${3:-2}"

if [[ ! -f "$IMG" ]]; then
    echo "Image not found: $IMG" >&2
    exit 1
fi

for tool in qemu-img qemu-nbd nbdfuse fuse2fs fusermount partx; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required to mount the image" >&2
        exit 1
    fi
done

mkdir -p "$MNTPATH"

# Absolute paths so the backing references work from any cwd.
IMG="$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")"
MNTPATH="$(cd "$MNTPATH" && pwd)"

# RUN_DIR holds the nbd socket and the raw disk file nbdfuse exposes. After
# nbdfuse starts this directory becomes non-writable (mode 000), so nothing
# is written to it afterwards.
RUN_DIR="$(mktemp -d)"
# LOG_DIR holds the daemon logs and the PID file; it stays writable so the
# caller can inspect them and stop the daemons after unmounting.
LOG_DIR="$(mktemp -d)"
SOCKET="$RUN_DIR/nbd.sock"
RAW_FILE="$RUN_DIR/disk.raw"
QEMU_NBD_PID=""
NBDFUSE_PID=""
FUSE2FS_PID=""
MOUNTED=0

cleanup() {
    # Tear down only when the mount did not succeed: on success the daemons
    # (and RUN_DIR holding the socket/raw file they need) must keep running
    # so the fuse mount stays alive. LOG_DIR is left in place either way so
    # the caller has the logs and PIDs.
    if (( MOUNTED )); then
        return
    fi
    if [[ -n "$FUSE2FS_PID" ]] && kill -0 "$FUSE2FS_PID" 2>/dev/null; then
        kill "$FUSE2FS_PID" 2>/dev/null || true
        fusermount -u "$MNTPATH" 2>/dev/null || true
    fi
    if [[ -n "$NBDFUSE_PID" ]] && kill -0 "$NBDFUSE_PID" 2>/dev/null; then
        kill "$NBDFUSE_PID" 2>/dev/null || true
    fi
    if [[ -n "$QEMU_NBD_PID" ]] && kill -0 "$QEMU_NBD_PID" 2>/dev/null; then
        kill "$QEMU_NBD_PID" 2>/dev/null || true
    fi
    # nbdfuse leaves RUN_DIR mode 000; restore write permission before removing.
    for dir in "$RUN_DIR" "$LOG_DIR"; do
        if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
            chmod -R u+w "$dir" 2>/dev/null || true
            rm -rf "$dir" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

IMAGE_FORMAT="$(qemu-img info "$IMG" | sed -n 's/^file format: \(.*\)$/\1/p')"
if [[ -z "$IMAGE_FORMAT" ]]; then
    echo "Could not determine the format of $IMG" >&2
    exit 1
fi

# Serve the image on a Unix socket. -k takes an exclusive lock so the image
# is not used elsewhere while mounted.
qemu-nbd -k "$SOCKET" -f "$IMAGE_FORMAT" "$IMG" > "$LOG_DIR/qemu-nbd.log" 2>&1 &
QEMU_NBD_PID=$!
for _ in $(seq 1 50); do
    [[ -S "$SOCKET" ]] && break
    sleep 0.2
done
if [[ ! -S "$SOCKET" ]]; then
    echo "qemu-nbd did not create its socket" >&2
    cat "$LOG_DIR/qemu-nbd.log" >&2
    exit 1
fi

# Expose the served disk as a plain raw file (userspace NBD over FUSE, no root).
nbdfuse "$RAW_FILE" --unix "$SOCKET" > "$LOG_DIR/nbdfuse.log" 2>&1 &
NBDFUSE_PID=$!
for _ in $(seq 1 50); do
    [[ -f "$RAW_FILE" ]] && break
    sleep 0.2
done
if [[ ! -f "$RAW_FILE" ]]; then
    echo "nbdfuse did not create its file" >&2
    cat "$LOG_DIR/nbdfuse.log" >&2
    exit 1
fi

# Byte offset of the partition inside the raw disk file.
OFFSET="$(partition_offset "$RAW_FILE" "$PARTITION")"

# Mount the partition to <mntpath>. fakeroot lets a non-root reader see
# root-owned files; offset seeks into the partition inside the raw file.
fuse2fs -o offset="$OFFSET" -o fakeroot "$RAW_FILE" "$MNTPATH" > "$LOG_DIR/fuse2fs.log" 2>&1 &
FUSE2FS_PID=$!

for _ in $(seq 1 50); do
    if mountpoint -q "$MNTPATH" 2>/dev/null; then
        MOUNTED=1
        break
    fi
    if ! kill -0 "$FUSE2FS_PID" 2>/dev/null; then
        echo "fuse2fs exited during mount:" >&2
        cat "$LOG_DIR/fuse2fs.log" >&2
        exit 1
    fi
    sleep 0.2
done

if (( ! MOUNTED )); then
    echo "fuse2fs did not mount $MNTPATH" >&2
    cat "$LOG_DIR/fuse2fs.log" >&2
    exit 1
fi

# Keep RUN_DIR alive (it holds the socket and raw file the mount needs).
# Record the daemons so the caller can stop them after unmounting.
cat > "$LOG_DIR/pids" <<EOF
qemu-nbd=$QEMU_NBD_PID
nbdfuse=$NBDFUSE_PID
fuse2fs=$FUSE2FS_PID
EOF

# Leave a breadcrumb so scripts/unmount_image.sh can find the daemon PIDs and
# working directories from just the mount path. LOG_DIR stays writable, so the
# breadcrumb lives there too.
MOUNT_INFO_DIR="${MOUNT_INFO_DIR:-/tmp/.mount_image}"
mkdir -p "$MOUNT_INFO_DIR"
MNTPATH_SAFE="${MNTPATH//\//_}"
cat > "$MOUNT_INFO_DIR/$MNTPATH_SAFE" <<EOF
MNTPATH=$MNTPATH
IMG=$IMG
PARTITION=$PARTITION
LOG_DIR=$LOG_DIR
RUN_DIR=$RUN_DIR
QEMU_NBD_PID=$QEMU_NBD_PID
NBDFUSE_PID=$NBDFUSE_PID
FUSE2FS_PID=$FUSE2FS_PID
EOF

echo "Mounted $IMG (partition $PARTITION, offset $OFFSET) on $MNTPATH"
echo "  qemu-nbd PID: $QEMU_NBD_PID"
echo "  nbdfuse PID:  $NBDFUSE_PID"
echo "  fuse2fs PID:  $FUSE2FS_PID"
echo "Working dir (socket, raw file):   $RUN_DIR"
echo "Log dir (logs, pids):             $LOG_DIR"
echo "Unmount with: fusermount -u $MNTPATH"
echo "Then stop the daemons (PIDs above) and remove $RUN_DIR and $LOG_DIR."
