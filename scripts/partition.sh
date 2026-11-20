#!/usr/bin/env bash
# Helpers for addressing a partition inside a raw disk image. This file is
# sourced by prepare_base.sh and repair_filesystem.sh.
#
# e2fsprogs (debugfs, e2fsck, dumpe2fs, mke2fs) can open a filesystem that
# starts at a byte offset inside a file: the name "IMAGE?offset=BYTES" is
# split at the question mark by libext2fs, and the unix I/O manager adds
# the offset to every read and write. The partition is therefore edited and
# checked in place, inside the disk image, through ordinary file I/O: no
# loop device, no FUSE mount, no root privileges and no helper daemon.
#
# The start sector is read with partx (util-linux), which works on regular
# files and handles DOS/MBR and GPT tables alike.

# partition_offset <raw-image> <partition-number>
#
# Print the byte offset of the partition. Fails (status 1, nothing printed)
# when the image has no partition table or no partition with that number.
partition_offset() {
    local image="$1" number="$2" start
    # Partition numbers are 1-indexed; 0 (or negative) means "all partitions"
    # to partx and would return multiple start sectors.
    if [[ ! "$number" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid partition number: $number (must be a positive integer)" >&2
        return 1
    fi
    # partx exits 0 with empty output when the partition does not exist,
    # so the empty check is part of the failure test. partx may print a
    # header line on some util-linux versions, so take only the last token
    # (the start sector) and reject anything that is not a single integer.
    if ! start="$(partx -g -n "$number" -o START "$image" 2>/dev/null | tail -n 1)" || [[ -z "$start" ]]; then
        return 1
    fi
    if [[ ! "$start" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    echo $(( start * 512 ))
}

# partition_target <raw-image> <partition-number>
#
# Print the name under which the e2fsprogs tools open the partition:
# "IMAGE?offset=BYTES".
partition_target() {
    local image="$1" number="$2" offset
    if ! offset="$(partition_offset "$image" "$number")"; then
        echo "Partition $number not found in $image" >&2
        return 1
    fi
    printf '%s?offset=%s\n' "$image" "$offset"
}