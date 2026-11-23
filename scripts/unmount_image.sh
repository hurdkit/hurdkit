#!/usr/bin/env bash
# unmount_image.sh <mntpath>
#
# Unmount an image mount created by scripts/mount_image.sh and stop the
# daemons (qemu-nbd, nbdfuse, fuse2fs) that keep it alive, then remove the
# working and log directories they used.
#
# mount_image.sh leaves a breadcrumb file (daemon PIDs, working directories)
# in $MOUNT_INFO_DIR (default /tmp/.mount_image), keyed by the mount path.
# This script reads it, so only <mntpath> is required.
#
# After this script returns, <mntpath> is a regular empty directory again and
# no image-related daemons are left running.
#
set -euo pipefail

MNTPATH="${1:?Usage: $0 <mntpath>}"
MNTPATH="$(cd "$MNTPATH" && pwd)"

MOUNT_INFO_DIR="${MOUNT_INFO_DIR:-/tmp/.mount_image}"
MNTPATH_SAFE="${MNTPATH//\//_}"
MOUNT_INFO="$MOUNT_INFO_DIR/$MNTPATH_SAFE"

if [[ ! -f "$MOUNT_INFO" ]]; then
    echo "No mount info found for $MNTPATH (looked in $MOUNT_INFO)" >&2
    echo "  (was it mounted with scripts/mount_image.sh?)" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$MOUNT_INFO"

# 1. Unmount the FUSE filesystem. fusermount -u is the clean path; -uz is the
#    lazy fallback when a process still holds the mount busy. Poll briefly
#    afterwards because the kernel can take a moment to release the mount.
if mountpoint -q "$MNTPATH" 2>/dev/null; then
    fusermount -u "$MNTPATH" 2>/dev/null || fusermount -uz "$MNTPATH" 2>/dev/null || true
fi
for _ in $(seq 1 50); do
    mountpoint -q "$MNTPATH" 2>/dev/null || break
    sleep 0.2
done
if mountpoint -q "$MNTPATH" 2>/dev/null; then
    echo "Warning: $MNTPATH is still busy after unmount" >&2
fi

# The writes have to reach the image before the daemons are stopped.
# sync -d (fsync) on the nbdfuse file pushes the kernel's dirty pages of the
# virtual disk down the chain: every FUSE write is forwarded to qemu-nbd
# (nbdfuse/operations.c), so once the fsync returns nothing is pending in
# the kernel and stopping the daemons cannot discard data. A plain "sync"
# is not enough: FUSE sync_fs is a no-op, and fuse2fs (when used) buffers
# writes in its own process until it exits. The nbdfuse file sits in
# MNTPATH in raw mode and in RUN_DIR in fuse2fs mode.
RAW_DISK=""
if [[ -n "${MNTPATH:-}" && -f "$MNTPATH/disk.raw" ]]; then
    RAW_DISK="$MNTPATH/disk.raw"
elif [[ -n "${RUN_DIR:-}" && -f "$RUN_DIR/disk.raw" ]]; then
    RAW_DISK="$RUN_DIR/disk.raw"
fi
if [[ -n "$RAW_DISK" ]]; then
    sync -d "$RAW_DISK" 2>/dev/null || sync --data "$RAW_DISK" 2>/dev/null || sync
fi

# Stop a helper daemon without losing its last writes: SIGTERM first, then
# SIGKILL only when the daemon ignores it (qemu-nbd flushes on graceful
# shutdown; an unconditional SIGKILL discards its cache).
stop_daemon() {
    local pid="$1"

    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Stop the daemons in reverse order. FUSE2FS_PID is best effort: fuse2fs
# daemonizes, so the PID recorded by mount_image.sh may be its short-lived
# parent (the --raw/debugfs path avoids fuse2fs entirely for this reason).
for pid_var in FUSE2FS_PID NBDFUSE_PID QEMU_NBD_PID; do
    stop_daemon "${!pid_var:-}"
done

# 3. Remove the working and log directories. nbdfuse leaves RUN_DIR mode 000,
#    so restore write permission before removing it.
for dir in "$RUN_DIR" "$LOG_DIR"; do
    if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
        chmod -R u+w "$dir" 2>/dev/null || true
        rm -rf "$dir" 2>/dev/null || true
    fi
done

# 4. Remove the breadcrumb itself.
rm -f "$MOUNT_INFO" 2>/dev/null || true

echo "Unmounted $MNTPATH and stopped the image daemons."
