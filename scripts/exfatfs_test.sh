#!/bin/bash
# exfatfs end-to-end test in the Hurd guest.  Run it through make, which
# builds the translators first:
#
#   make exfatfs-test                  # control (fatfs) + exfatfs
#   make exfatfs-test FS=fat           # control only
#   make exfatfs-test HURD_TREE=DIR    # fatfs from another Hurd tree
#   make exfatfs-test EXFATFS_DIR=DIR  # exfatfs from another checkout
#
# Takes fatfs.static from TRANSLATOR_DIR (the fs-translators build
# directory) and exfatfs.static from EXFATFS_STATIC (default:
# TRANSLATOR_DIR/exfatfs/exfatfs.static), makes a FAT image (mtools) and an exFAT
# image (mkfs.exfat, filled through the Linux kernel exfat driver, which
# needs sudo for the loop mount), boots a throwaway overlay of the packages
# image, mounts each image in the guest with its translator on a file
# store, and compares a manifest of every path (type, size, mtime, sha256)
# with the host's view of the same image.  fatfs is the control: it proves
# the build, the copy and the store plumbing before exfatfs is judged.
# Hurd's fatfs serves only 8.3 short names, so its manifest is compared by
# content (type, size, sha256), not by path.  The exFAT run also checks
# case-insensitive lookup, EROFS on writes, and that corrupt images are
# refused without killing the translator.
#
# Unless EXFAT_WRITE=0, the exFAT run then tests writes.  The same
# deterministic operations (fs_image_test.py mutate) are applied to a plain
# host copy of the image's contents, which gives the expected manifest,
# and to a read-write exfatfs mount in the guest.  Then the guest's view,
# the guest's view after a remount, fsck.exfat on the image, and the Linux
# kernel driver's readback of the image must all agree with it.
#
# A failed run leaves its guest running for inspection.  REUSE=1 runs the
# checks again against that guest instead of booting a new one.  Every
# guest step is bounded by GUEST_TIMEOUT seconds (default 300), so a hung
# translator fails its check rather than hanging the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRANSLATOR_DIR="${TRANSLATOR_DIR:-$HOME/work/x86_64-gnu-build/hurd-translators}"
FS="${FS:-fat exfat}"
EXFAT_WRITE="${EXFAT_WRITE:-1}"
REUSE="${REUSE:-0}"
GUEST_TIMEOUT="${GUEST_TIMEOUT:-300}"
BASE_IMG="${BASE_IMG:-$REPO_ROOT/img/hurd.packages.qcow2}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_KEY="${SSH_KEY_DIR:-$REPO_ROOT/img/keys}/root_ed25519"
TMP_DIR="$REPO_ROOT/img/tmp"
WORK="$TMP_DIR/exfatfs-test"
TOOL="$SCRIPT_DIR/fs_image_test.py"
FT_NAME="exfatfs-test"
source "$SCRIPT_DIR/fs_test_lib.sh"
ft_prepare_work

bins=()
for fs in $FS; do
    if [[ $fs == exfat ]]; then
        bins+=("${EXFATFS_STATIC:-$TRANSLATOR_DIR/exfatfs/exfatfs.static}")
    else
        bins+=("$TRANSLATOR_DIR/${fs}fs/${fs}fs.static")
    fi
done
for f in "${bins[@]}"; do
    [[ -f "$f" ]] || { echo "exfatfs-test: missing $f (make fs-translators exfatfs)" >&2; exit 1; }
done

for fs in $FS; do
    case $fs in
    fat)
        python3 "$TOOL" tree "$WORK/src-fat" --ascii
        truncate -s 64M "$WORK/fat.img"
        mkfs.vfat -F 16 -n HURDTEST "$WORK/fat.img" >/dev/null
        MTOOLS_SKIP_CHECK=1 mcopy -s -m -i "$WORK/fat.img" "$WORK/src-fat"/* ::/
        python3 "$TOOL" manifest "$WORK/src-fat" --no-mtime > "$WORK/host-fat.txt"
        ;;
    exfat)
        python3 "$TOOL" tree "$WORK/src-exfat"
        truncate -s 64M "$WORK/exfat.img"
        mkfs.exfat -q -c 4K -L HURDTEST "$WORK/exfat.img" >/dev/null
        sudo mount -t exfat -o loop,uid="$(id -u)",gid="$(id -g)",time_offset=0 \
            "$WORK/exfat.img" "$WORK/mnt"
        mountpoint -q "$WORK/mnt" || { echo "exfatfs-test: loop mount failed" >&2; exit 1; }
        cp -a "$WORK/src-exfat/." "$WORK/mnt/"
        python3 "$TOOL" fragment "$WORK/mnt"
        extents=$(sudo filefrag "$WORK/mnt/frag.bin" | grep -oE '[0-9]+ extents?' | cut -d' ' -f1)
        sudo umount "$WORK/mnt"
        python3 "$TOOL" patch-long-name "$WORK/exfat.img"
        fsck.exfat -n "$WORK/exfat.img" >/dev/null
        sudo mount -t exfat -o loop,ro,uid="$(id -u)",gid="$(id -g)",time_offset=0 \
            "$WORK/exfat.img" "$WORK/mnt"
        python3 "$TOOL" manifest "$WORK/mnt" > "$WORK/host-exfat.txt"
        sudo umount "$WORK/mnt"
        [[ "${extents:-1}" -gt 1 ]] || { echo "exfatfs-test: frag.bin is not fragmented" >&2; exit 1; }
        echo "exfatfs-test: exFAT image clean; frag.bin in $extents extents"
        # Corrupt copies the translator must refuse: a wrong file system
        # name, a wrong boot checksum, and a volume longer than the file.
        cp "$WORK/exfat.img" "$WORK/bad-name.img"
        printf 'NOTEXFAT' | dd of="$WORK/bad-name.img" bs=1 seek=3 conv=notrunc status=none
        cp "$WORK/exfat.img" "$WORK/bad-checksum.img"
        printf '\x01' | dd of="$WORK/bad-checksum.img" bs=1 seek=200 conv=notrunc status=none
        head -c 4M "$WORK/exfat.img" > "$WORK/truncated.img"
        if [[ "$EXFAT_WRITE" == 1 ]]; then
            sudo mount -t exfat -o loop,ro,uid="$(id -u)",gid="$(id -g)",time_offset=0 \
                "$WORK/exfat.img" "$WORK/mnt"
            python3 "$TOOL" copy "$WORK/mnt" "$WORK/expected-rw"
            sudo umount "$WORK/mnt"
            python3 "$TOOL" mutate "$WORK/expected-rw"
            python3 "$TOOL" manifest "$WORK/expected-rw" > "$WORK/expected-rw.txt"
            cp "$WORK/exfat.img" "$WORK/rw.img"
            cp "$WORK/exfat.img" "$WORK/readonly-load.img"
            # VolumeDirty is bit 1 of VolumeFlags (byte 106), which the boot
            # checksum skips, so this is a valid volume a crash left dirty.
            cp "$WORK/exfat.img" "$WORK/dirty.img"
            printf '\x02' | dd of="$WORK/dirty.img" bs=1 seek=106 conv=notrunc status=none
        fi
        ;;
    esac
done

ft_boot

# A reused guest may still run translators from the failed run, some on
# the binaries about to be overwritten.  Clear every mount point first.
echo "exfatfs-test: copying the translators and the test tool"
mnts=""
for m in $FS bad-name bad-checksum truncated rw dirty load; do mnts+=" /mnt/$m"; done
if ! { g "for m in$mnts; do settrans -fg \$m 2>/dev/null; done; true" \
       && put "$TOOL" "${bins[@]}"; }; then
    fail "guest setup: clear the mount points and copy the translators"
    finish
fi
for fs in $FS; do
    echo "exfatfs-test: $fs: copying the image"
    if ! { put "$WORK/$fs.img" && g "mkdir -p /mnt/$fs"; }; then
        fail "$fs: mount (could not copy the image)"
        continue
    fi
    echo "exfatfs-test: $fs: mounting"
    if ! mount_fs "/mnt/$fs" "/tmp/${fs}fs.static" "/tmp/$fs.img"; then
        fail "$fs: mount"
        continue
    fi
    pass "$fs: mount"
    echo "exfatfs-test: $fs: walking the mount"
    flags=$([[ $fs == fat ]] && echo --no-mtime || true)
    cmp_flags=$([[ $fs == fat ]] && echo --content-only || true)
    if g "python3 /tmp/fs_image_test.py manifest /mnt/$fs $flags > /tmp/guest-$fs.txt" \
        && get "/tmp/guest-$fs.txt" "$WORK/guest-$fs.txt" \
        && python3 "$TOOL" compare "$WORK/host-$fs.txt" "$WORK/guest-$fs.txt" $cmp_flags; then
        pass "$fs: manifest"
    else
        fail "$fs: manifest"
    fi
done

if [[ " $FS " == *" exfat "* ]] && [[ " ${PASSES[*]} " == *"exfat: mount"* ]]; then
    if g "cmp -s /mnt/exfat/MixedCase.TXT /mnt/exfat/mixedcase.txt && cmp -s /mnt/exfat/hello.txt /mnt/exfat/HELLO.TXT"; then
        pass "exfat: case-insensitive lookup"
    else
        fail "exfat: case-insensitive lookup"
    fi
    if [[ "$(g "ls /mnt/exfat/long-utf8 | wc -l; ls /mnt/exfat/long-utf8 | grep -c sibling.txt")" == $'2\n1' ]]; then
        pass "exfat: a name past NAME_MAX is hidden, its sibling still listed"
    else
        fail "exfat: a name past NAME_MAX is hidden, its sibling still listed"
    fi
    out=$(g "touch /mnt/exfat/new.txt 2>&1; echo rc=\$?" || true)
    if [[ "$out" == *"Read-only file system"* && "$out" == *"rc=1"* ]]; then
        pass "exfat: writes refused with EROFS"
    else
        fail "exfat: writes refused with EROFS (got: $out)"
    fi
    for bad in bad-name bad-checksum truncated; do
        if ! { put "$WORK/$bad.img" && g "mkdir -p /mnt/$bad"; }; then
            fail "exfat: refuses $bad.img (could not copy the image)"
            continue
        fi
        out=$(mount_fs "/mnt/$bad" /tmp/exfatfs.static "/tmp/$bad.img" 2>&1; echo "rc=$?")
        # A refusal is the translator's own error message and a non-zero
        # exit; a crash (an assertion or a signal) is a failure too.
        if [[ "$out" != *"rc=0"* && "$out" == *"/tmp/exfatfs.static: "* \
              && "$out" != *"Assertion"* && "$out" != *"signal"* ]]; then
            pass "exfat: refuses $bad.img"
        else
            g "settrans -fg /mnt/$bad" || true
            fail "exfat: refuses $bad.img (got: $(echo "$out" | tr '\n' ' '))"
        fi
    done
    if g "test -f /mnt/exfat/hello.txt"; then
        pass "exfat: original mount still serves after the corrupt-image attempts"
    else
        fail "exfat: original mount still serves after the corrupt-image attempts"
    fi
fi

if [[ " $FS " == *" exfat "* && "$EXFAT_WRITE" == 1 ]]; then
    echo "exfatfs-test: exfat-rw: copying a fresh image and mounting it read-write"
    if put "$WORK/rw.img" && g "mkdir -p /mnt/rw" \
        && mount_fs /mnt/rw /tmp/exfatfs.static /tmp/rw.img ""; then
        pass "exfat-rw: read-write mount"
        echo "exfatfs-test: exfat-rw: running the write operations"
        if g "python3 /tmp/fs_image_test.py mutate /mnt/rw"; then
            pass "exfat-rw: operations"
        else
            fail "exfat-rw: operations"
        fi
        if g "python3 /tmp/fs_image_test.py manifest /mnt/rw > /tmp/guest-rw.txt" \
            && get /tmp/guest-rw.txt "$WORK/guest-rw.txt" \
            && python3 "$TOOL" compare "$WORK/expected-rw.txt" "$WORK/guest-rw.txt"; then
            pass "exfat-rw: guest view matches expected"
        else
            fail "exfat-rw: guest view matches expected"
        fi
        if g "settrans -g /mnt/rw"; then
            pass "exfat-rw: clean unmount"
        else
            fail "exfat-rw: clean unmount"
        fi
        if mount_fs /mnt/rw /tmp/exfatfs.static /tmp/rw.img; then
            if g "python3 /tmp/fs_image_test.py manifest /mnt/rw > /tmp/guest-rw-again.txt; settrans -g /mnt/rw" \
                && get /tmp/guest-rw-again.txt "$WORK/guest-rw-again.txt" \
                && python3 "$TOOL" compare "$WORK/expected-rw.txt" "$WORK/guest-rw-again.txt"; then
                pass "exfat-rw: guest view after remount"
            else
                fail "exfat-rw: guest view after remount"
            fi
        else
            fail "exfat-rw: remount"
        fi
        if get /tmp/rw.img "$WORK/rw-written.img"; then
            # A clean volume must come back clean: VolumeDirty is bit 1 of
            # VolumeFlags (byte 106).
            if fsck.exfat -n "$WORK/rw-written.img" > "$WORK/fsck-rw.txt" 2>&1 \
                && ! (( $(od -An -tu1 -j106 -N1 "$WORK/rw-written.img") & 2 )); then
                pass "exfat-rw: fsck.exfat clean, VolumeDirty cleared"
            else
                fail "exfat-rw: fsck.exfat clean, VolumeDirty cleared (flags byte $(od -An -tu1 -j106 -N1 "$WORK/rw-written.img"); $(tail -1 "$WORK/fsck-rw.txt"))"
            fi
            if sudo mount -t exfat -o loop,ro,uid="$(id -u)",gid="$(id -g)",time_offset=0 \
                    "$WORK/rw-written.img" "$WORK/mnt"; then
                python3 "$TOOL" manifest "$WORK/mnt" > "$WORK/linux-rw.txt"
                sudo umount "$WORK/mnt"
                if python3 "$TOOL" compare "$WORK/expected-rw.txt" "$WORK/linux-rw.txt"; then
                    pass "exfat-rw: Linux reads back what Hurd wrote"
                else
                    fail "exfat-rw: Linux reads back what Hurd wrote"
                fi
            else
                fail "exfat-rw: Linux mounts the written image"
            fi
        else
            fail "exfat-rw: fsck.exfat clean, VolumeDirty cleared (could not copy the written image back)"
            fail "exfat-rw: Linux reads back what Hurd wrote (could not copy the written image back)"
        fi
    else
        fail "exfat-rw: read-write mount"
    fi
fi

if [[ " $FS " == *" exfat "* && "$EXFAT_WRITE" == 1 ]]; then
    echo "exfatfs-test: exfat-rw: dirty volume and read-only workload"
    if put "$WORK/dirty.img" "$WORK/readonly-load.img" && g "mkdir -p /mnt/dirty /mnt/load"; then
        # As on Linux: the volume is written, with a warning, and
        # VolumeDirty stays set after a clean unmount so that fsck runs.
        dirty_text="written to a volume that was not unmounted cleanly"
        if out=$(mount_fs /mnt/dirty /tmp/exfatfs.static /tmp/dirty.img ""); then
            wrote=$(g "printf '%s\\n' '$dirty_text' > /mnt/dirty/new.txt && settrans -g /mnt/dirty && echo rc=0" 2>&1 || true)
            [[ "$wrote" == *"rc=0"* ]] || g "settrans -fg /mnt/dirty" || true
            if [[ "$out" == *"not unmounted cleanly"*"fsck.exfat"* && "$wrote" == *"rc=0"* ]] \
                && get /tmp/dirty.img "$WORK/dirty-written.img" \
                && (( $(od -An -tu1 -j106 -N1 "$WORK/dirty-written.img") & 2 )) \
                && fsck.exfat -n "$WORK/dirty-written.img" > "$WORK/fsck-dirty.txt" 2>&1; then
                pass "exfat-rw: a dirty volume is written with a warning and stays dirty"
            else
                fail "exfat-rw: a dirty volume is written with a warning and stays dirty (mount said: $out; write: $wrote; $(tail -1 "$WORK/fsck-dirty.txt" 2>/dev/null))"
            fi
            if sudo mount -t exfat -o loop,ro "$WORK/dirty-written.img" "$WORK/mnt" 2>/dev/null; then
                got=$(cat "$WORK/mnt/new.txt" 2>&1 || true)
                sudo umount "$WORK/mnt"
                if [[ "$got" == "$dirty_text" ]]; then
                    pass "exfat-rw: Linux reads back what Hurd wrote to the dirty volume"
                else
                    fail "exfat-rw: Linux reads back what Hurd wrote to the dirty volume (got: $got)"
                fi
            else
                fail "exfat-rw: Linux reads back what Hurd wrote to the dirty volume (Linux could not mount it)"
            fi
        else
            g "settrans -fg /mnt/dirty" || true
            fail "exfat-rw: a dirty volume is written with a warning and stays dirty (mount failed: $out)"
            fail "exfat-rw: Linux reads back what Hurd wrote to the dirty volume (mount failed)"
        fi
        if mount_fs /mnt/load /tmp/exfatfs.static /tmp/readonly-load.img ""; then
            if ! { g "python3 /tmp/fs_image_test.py manifest /mnt/load >/dev/null; cat /mnt/load/hello.txt >/dev/null; python3 /tmp/fs_image_test.py manifest /mnt/load >/dev/null; settrans -g /mnt/load" \
                   && get /tmp/readonly-load.img "$WORK/readonly-load-after.img"; }; then
                fail "exfat-rw: reading a read-write mount leaves the image unchanged (the read workload or the copy back failed)"
            elif cmp -s "$WORK/readonly-load.img" "$WORK/readonly-load-after.img"; then
                pass "exfat-rw: reading a read-write mount leaves the image unchanged"
            else
                fail "exfat-rw: reading a read-write mount leaves the image unchanged ($(cmp -l "$WORK/readonly-load.img" "$WORK/readonly-load-after.img" | wc -l) bytes differ)"
            fi
        else
            fail "exfat-rw: reading a read-write mount leaves the image unchanged (mount failed)"
        fi
    else
        fail "exfat-rw: a dirty volume is written with a warning and stays dirty (could not copy the images)"
        fail "exfat-rw: Linux reads back what Hurd wrote to the dirty volume (could not copy the images)"
        fail "exfat-rw: reading a read-write mount leaves the image unchanged (could not copy the images)"
    fi
fi

for fs in $FS; do g "settrans -fg /mnt/$fs" >/dev/null 2>&1 || true; done
finish
