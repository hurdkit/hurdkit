#!/usr/bin/env bash
# Repair the ext2 root filesystem of a disk image without converting the
# image to a raw file.
#
# This is the repair half of scripts/fsck_qcow2.sh: the same nbd/nbdfuse
# machinery, but always repairing instead of only checking.
#
# Usage: repair_filesystem.sh <image> [partition-number]

set -euo pipefail

IMG="${1:?Usage: $0 <image> [partition-number]}"
PART_NUM="${2:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "$SCRIPT_DIR/fsck_qcow2.sh" --repair "$IMG" "$PART_NUM"
