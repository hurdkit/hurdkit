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

# 2. Stop the daemons in reverse order, then force-kill anything that lingers.
for pid_var in FUSE2FS_PID NBDFUSE_PID QEMU_NBD_PID; do
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
done

sleep 0.5
for pid_var in FUSE2FS_PID NBDFUSE_PID QEMU_NBD_PID; do
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
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
