#!/bin/bash
# squashfs end-to-end test in the Hurd guest.  Run it through make, which
# builds the translator and the compression libraries first:
#
#   make squashfs-test SQUASHFS_DIR=DIR    # translator from a checkout
#   SQUASHFS_BIN=FILE bash scripts/squashfs_test.sh
#                                          # any binary as the translator
#                                          # (the harness's own red run)
#
# The goal is parity with the Linux squashfs driver.  The host builds
# source trees (squashfs_images.py) and images from them with mksquashfs,
# without root: owners, devices and xattrs come from pseudo definitions.
# Two oracles check each image before the guest boots: the Linux kernel
# driver (sudo mount -o loop) must show the source tree, and so must
# unsquashfs's extraction of the gzip image.  The guest then mounts every
# image with the translator and its view must equal the Linux view field
# by field (fs_image_test.py manifest --full: type, size, mtime, sha256,
# mode, uid, gid, nlink, rdev, symlink target, inode number, st_blocks).
# Corrupt images must be refused at least as strictly as Linux refuses
# them, and a seeded fuzz run must never crash or hang the translator.
#
# A failed run leaves its guest running for inspection.  REUSE=1 runs the
# checks again against that guest.  Every guest step is bounded by
# GUEST_TIMEOUT seconds (default 300), so a hung translator fails its
# check rather than hanging the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUASHFS_BIN="${SQUASHFS_BIN:-$HOME/src/squashfs/squashfs.static}"
CROSS_CC="${CROSS_CC:-$HOME/opt/x86_64-gnu/bin/x86_64-gnu-gcc}"
REUSE="${REUSE:-0}"
GUEST_TIMEOUT="${GUEST_TIMEOUT:-300}"
FUZZ_SEED="${FUZZ_SEED:-1}"
FUZZ_COUNT="${FUZZ_COUNT:-200}"
BASE_IMG="${BASE_IMG:-$REPO_ROOT/img/hurd.packages.qcow2}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_KEY="${SSH_KEY_DIR:-$REPO_ROOT/img/keys}/root_ed25519"
TMP_DIR="$REPO_ROOT/img/tmp"
WORK="$TMP_DIR/squashfs-test"
TOOL="$SCRIPT_DIR/fs_image_test.py"
IMAGES="$SCRIPT_DIR/squashfs_images.py"
FT_NAME="squashfs-test"
source "$SCRIPT_DIR/fs_test_lib.sh"
ft_prepare_work

[[ -f "$SQUASHFS_BIN" ]] || { echo "squashfs-test: missing $SQUASHFS_BIN (make squashfs)" >&2; exit 1; }
for t in mksquashfs unsquashfs; do
    command -v $t >/dev/null || { echo "squashfs-test: $t not found (squashfs-tools)" >&2; exit 1; }
done

# Host side: trees, images, the Linux and unsquashfs oracles.
echo "squashfs-test: building the probe, the trees and the images"
"$CROSS_CC" -static -O2 -o "$WORK/fs_probe" "$SCRIPT_DIR/fs_probe.c" 2> "$WORK/fs_probe.log" \
    || { cat "$WORK/fs_probe.log" >&2; exit 1; }
mkdir -p "$WORK/img"
for kind in main wide small xattr; do
    python3 "$IMAGES" tree $kind "$WORK/src-$kind" "$WORK/fs_probe"
    python3 "$IMAGES" expect $kind "$WORK/src-$kind" > "$WORK/expect-$kind.txt"
done
python3 "$IMAGES" expect-xattrs xattr > "$WORK/expect-xattrs.txt"
common=$(python3 "$IMAGES" variants | head -1 | cut -f2 | grep -o -- '-noappend.*')
# name, source tree, mksquashfs options; the main tree's images first.
specs=()
while IFS=$'\t' read -r name opts; do specs+=("$name main $opts"); done \
    < <(python3 "$IMAGES" variants)
specs+=("wide wide -comp gzip $common" "xattr xattr -comp xz $common"
        "small small -comp gzip $common" "lzma small -comp lzma $common")
VARIANTS=()
for spec in "${specs[@]}"; do
    read -r name kind opts <<< "$spec"
    # shellcheck disable=SC2086
    mksquashfs "$WORK/src-$kind" "$WORK/img/$name.img" -pf "$WORK/src-$kind.pseudo" $opts
    [[ $kind == main ]] && VARIANTS+=("$name")
done
# 2000 names for one file: lookups of hard links hold the directory and
# lock a node that many names share.
mkdir -p "$WORK/src-links/a"
echo "one file, 2000 names" > "$WORK/src-links/a/f0"
for i in $(seq 1 1999); do ln "$WORK/src-links/a/f0" "$WORK/src-links/a/f$i"; done
# shellcheck disable=SC2086
mksquashfs "$WORK/src-links" "$WORK/img/links.img" -comp gzip $common
for k in dirloop unsorted huge; do python3 "$IMAGES" craft $k "$WORK/img/$k.img"; done
cp "$WORK/img/small.img" "$WORK/img/compressor-99.img"
python3 "$IMAGES" set-compressor "$WORK/img/compressor-99.img" 99
python3 "$IMAGES" corrupt "$WORK/img/small.img" "$WORK/corrupt"
python3 "$IMAGES" fuzz "$WORK/img/small.img" "$WORK/fuzz" "$FUZZ_SEED" "$FUZZ_COUNT"
CORRUPT=(truncated bad-magic version-3 table-past-end flip-inode-table flip-dir-table
         flip-frag-table flip-id-table flip-data-block)

kind_of() { case $1 in wide|xattr|small) echo "$1" ;; *) echo main ;; esac; }
# The source tree cannot say what squashfs stores for these, so the
# oracle checks leave them out; the guest is compared with Linux on all.
SOURCE_IGNORE="ino,blocks,d:size,d:nlink"
linux_mount() { sudo mount -t squashfs -o loop,ro "$1" "$WORK/mnt" 2>/dev/null; }
echo "squashfs-test: reading every image through the Linux driver"
for name in "${VARIANTS[@]}" wide xattr small; do
    if linux_mount "$WORK/img/$name.img"; then
        sudo python3 -I "$TOOL" manifest "$WORK/mnt" --full > "$WORK/linux-$name.txt"
        [[ $name == xattr ]] && sudo python3 -I "$TOOL" xattrs "$WORK/mnt" > "$WORK/linux-xattrs.txt"
        [[ $name == gzip ]] && python3 -I "$TOOL" statvfs-flags "$WORK/mnt" > "$WORK/linux-statvfs.txt"
        [[ $name == gzip ]] && for d in . big-dir; do
            { echo .; echo ..; ls -A "$WORK/mnt/$d"; } | LC_ALL=C sort > "$WORK/linux-list-$(basename "$d").txt"
        done
        sudo umount "$WORK/mnt"
        if python3 "$TOOL" compare "$WORK/expect-$(kind_of "$name").txt" "$WORK/linux-$name.txt" \
               --ignore "$SOURCE_IGNORE" > "$WORK/oracle-$name.txt"; then
            pass "squash: oracle: Linux reads $name.img as the source tree"
        else
            cat "$WORK/oracle-$name.txt"
            fail "squash: oracle: Linux reads $name.img as the source tree"
        fi
    else
        : > "$WORK/linux-$name.txt"
        fail "squash: oracle: Linux reads $name.img as the source tree (Linux cannot mount it)"
    fi
done
# The guest is compared with Linux's device numbers as the Hurd's dev_t
# holds them.  Those it cannot hold are a gap of the Hurd's interface,
# which this check keeps in view instead of failing every manifest on it.
unheld=""
for name in "${VARIANTS[@]}" wide xattr small; do
    unheld+=$(python3 "$TOOL" hurd-dev "$WORK/linux-$name.txt" "$WORK/linux-$name.hurd-dev.txt")$'\n'
done
unheld=$(echo "$unheld" | grep . | sort -u | tr '\t\n' '  ' || true)
rc=0; [[ -z "$unheld" ]] || rc=1
known "squash: Hurd interface: every device number fits the Hurd's dev_t" \
    "glibc bits/sysmacros.h gives the Hurd's dev_t an 8-bit major; path, Linux, Hurd: $unheld" $rc
if python3 "$TOOL" compare "$WORK/expect-xattrs.txt" "$WORK/linux-xattrs.txt"; then
    pass "squash: oracle: Linux reads the xattrs of the pseudo definitions"
else
    fail "squash: oracle: Linux reads the xattrs of the pseudo definitions"
fi
sudo unsquashfs -q -n -d "$WORK/unsquashfs" "$WORK/img/gzip.img" > "$WORK/unsquashfs.log" 2>&1 || true
sudo python3 -I "$TOOL" manifest "$WORK/unsquashfs" --full > "$WORK/unsquashfs.txt" || true
sudo rm -rf -- "$WORK/unsquashfs"
if python3 "$TOOL" compare "$WORK/expect-main.txt" "$WORK/unsquashfs.txt" --ignore "$SOURCE_IGNORE"; then
    pass "squash: oracle: unsquashfs extracts gzip.img as the source tree"
else
    fail "squash: oracle: unsquashfs extracts gzip.img as the source tree"
fi
# The names a lookup finds in a directory not in strcmp order.  huge.img
# is not read through Linux: reading its file hangs Linux 7.0's reader in
# D state.
if linux_mount "$WORK/img/unsorted.img"; then
    # shellcheck disable=SC2046
    python3 -I "$TOOL" stat-names "$WORK/mnt/d" $(ls -f "$WORK/mnt/d" | grep -vx '\.\.\?') > "$WORK/linux-unsorted.txt"
    sudo umount "$WORK/mnt"
else
    : > "$WORK/linux-unsorted.txt"
fi
for name in lzma compressor-99; do
    if linux_mount "$WORK/img/$name.img"; then
        sudo umount "$WORK/mnt"
        fail "squash: oracle: Linux refuses $name.img"
    else
        pass "squash: oracle: Linux refuses $name.img"
    fi
done
# How strict Linux is with each corrupt image: refused (no mount), errors
# (mounts, some access fails) or served (every access succeeds).
declare -A LINUX_LEVEL
for name in "${CORRUPT[@]}"; do
    if linux_mount "$WORK/corrupt/$name.img"; then
        walked=$(sudo timeout 120 python3 -I "$TOOL" walk "$WORK/mnt" | tail -1 || true)
        sudo umount "$WORK/mnt"
        if [[ "$walked" == *" errors=0" ]]; then LINUX_LEVEL[$name]=served; else LINUX_LEVEL[$name]=errors; fi
    else
        LINUX_LEVEL[$name]=refused
    fi
    echo "squashfs-test: Linux on corrupt $name.img: ${LINUX_LEVEL[$name]}"
done

ft_boot

GT=/tmp/squashfs.static
gmnt() { echo "/mnt/sq-$1"; }
# A reused guest may still run translators from the failed run.  Clear
# every mount point first, then copy the translator under one fixed name,
# so its error messages start with "$GT: " whatever the host file is.
echo "squashfs-test: copying the translator and the test tools"
mnts=""
for m in "${VARIANTS[@]}" wide xattr lzma compressor-99 links dirloop unsorted huge "${CORRUPT[@]}"; do
    mnts+=" $(gmnt "$m")"
done
cp "$SQUASHFS_BIN" "$WORK/squashfs.static"
if ! { g "for m in$mnts; do settrans -fg \$m 2>/dev/null; done; rm -rf /tmp/sq-fuzz; true" \
       && put "$WORK/squashfs.static" "$TOOL" "$WORK/fs_probe"; }; then
    fail "guest setup: clear the mount points and copy the translator"
    finish
fi

UNMOUNT_FAILS=()
# mount_image NAME: copy NAME.img and mount it on $(gmnt NAME).
mount_image() {
    put "$WORK/img/$1.img" && g "mkdir -p $(gmnt "$1")" \
        && mount_fs "$(gmnt "$1")" "$GT" "/tmp/$1.img"
}
# -R: looking up a fifo starts /hurd/fifo on it as an active translator
# below the mount (libdiskfs does this for tmpfs too), and plain -g then
# fails with EBUSY.  -R shuts those children down first.  The no-senders
# notifications for the ports a finished reader held arrive later, so
# right after a walk the translator can still count them and answer
# EBUSY; a few retries a second apart let them drain.  A leak still fails.
unmount_image() {
    g "for i in 1 2 3 4 5; do settrans -gR $(gmnt "$1") 2>/dev/null && rm -f /tmp/$1.img && exit 0; sleep 1; done; settrans -gR $(gmnt "$1")" \
        || UNMOUNT_FAILS+=("$1")
}
# check_manifest NAME: the guest's full manifest of NAME equals Linux's.
check_manifest() {
    local name=$1 limit=$GUEST_TIMEOUT
    # 72173 inodes: the walk alone takes minutes in the guest.
    [[ $name == wide ]] && limit=$((GUEST_TIMEOUT * 4))
    if GUEST_TIMEOUT=$limit g "python3 /tmp/fs_image_test.py manifest $(gmnt "$name") --full > /tmp/guest-$name.txt" \
        && get "/tmp/guest-$name.txt" "$WORK/guest-$name.txt" \
        && python3 "$TOOL" compare "$WORK/linux-$name.hurd-dev.txt" "$WORK/guest-$name.txt" > "$WORK/compare-$name.txt"; then
        pass "squash: $name: manifest matches Linux"
    else
        head -40 "$WORK/compare-$name.txt" 2>/dev/null || true
        fail "squash: $name: manifest matches Linux"
    fi
}

for name in "${VARIANTS[@]}" wide; do
    echo "squashfs-test: $name: mounting"
    if mount_image "$name"; then
        pass "squash: $name: mount"
        check_manifest "$name"
        [[ $name == gzip ]] || unmount_image "$name"
    else
        fail "squash: $name: mount"
        fail "squash: $name: manifest matches Linux (not mounted)"
    fi
done

M=$(gmnt gzip)
GZIP_CHECKS=("lookups: a missing name gives ENOENT, .. at the root leaves the mount"
             "readdir (readdir1) of . lists each entry once" "readdir (seekdir 7) of . lists each entry once"
             "readdir (readdir1) of big-dir lists each entry once" "readdir (seekdir 7) of big-dir lists each entry once"
             "exec a static binary from the image" "exec a script from the image"
             "mmap reads the same bytes as Linux" "writes refused with EROFS"
             "8 parallel readers get the single reader's manifest"
             "statvfs gives the flags Linux gives")
if [[ " ${PASSES[*]} " != *"squash: gzip: mount"* ]]; then
    for c in "${GZIP_CHECKS[@]}"; do fail "squash: $c (gzip.img not mounted)"; done
else
    if out=$(g "python3 /tmp/fs_image_test.py lookups $M" 2>&1); then
        pass "squash: lookups: a missing name gives ENOENT, .. at the root leaves the mount"
    else
        fail "squash: lookups: a missing name gives ENOENT, .. at the root leaves the mount ($out)"
    fi
    for d in . big-dir; do
        list=$(basename "$d")
        for how in "readdir1" "seekdir 7"; do
            if g "/tmp/fs_probe $how $M/$d" > "$WORK/guest-list-$list.raw" \
                && LC_ALL=C sort "$WORK/guest-list-$list.raw" | cmp -s - "$WORK/linux-list-$list.txt"; then
                pass "squash: readdir ($how) of $list lists each entry once"
            else
                fail "squash: readdir ($how) of $list lists each entry once ($(wc -l < "$WORK/guest-list-$list.raw") names, Linux $(wc -l < "$WORK/linux-list-$list.txt"))"
            fi
        done
    done
    out=$(g "$M/bin/fs_probe.static hello" 2>&1 || true)
    if [[ "$out" == "fs-probe-exec-ok" ]]; then
        pass "squash: exec a static binary from the image"
    else
        fail "squash: exec a static binary from the image (got: $out)"
    fi
    out=$(g "$M/bin/hello.sh" 2>&1 || true)
    if [[ "$out" == "squashfs-script-ok" ]]; then
        pass "squash: exec a script from the image"
    else
        fail "squash: exec a script from the image (got: $out)"
    fi
    mapped="big-random.bin blocks/131072-over.bin blocks/4096-under.bin sparse-holes.bin compressible.txt"
    expected=$(for f in $mapped; do awk -F'\t' -v p="$f" '$13 == p { print $4 }' "$WORK/linux-gzip.txt"; done)
    got=$(g "cd $M && python3 /tmp/fs_image_test.py mmap $mapped" 2>&1 | cut -f1 || true)
    if [[ -n "$expected" && "$got" == "$expected" ]]; then
        pass "squash: mmap reads the same bytes as Linux"
    else
        fail "squash: mmap reads the same bytes as Linux (got: $(echo "$got" | head -3 | tr '\n' ' '))"
    fi
    if out=$(g "python3 /tmp/fs_image_test.py erofs $M hello.txt empty-dir" 2>&1); then
        pass "squash: writes refused with EROFS"
    else
        fail "squash: writes refused with EROFS ($(echo "$out" | tr '\n' ' '))"
    fi
    got=$(g "python3 /tmp/fs_image_test.py statvfs-flags $M" 2>&1 || true)
    if [[ -s "$WORK/linux-statvfs.txt" && "$got" == "$(cat "$WORK/linux-statvfs.txt")" ]]; then
        pass "squash: statvfs gives the flags Linux gives"
    else
        fail "squash: statvfs gives the flags Linux gives (Linux: $(cat "$WORK/linux-statvfs.txt"), translator: $got)"
    fi
    echo "squashfs-test: 8 parallel readers"
    if g "for i in 1 2 3 4 5 6 7 8; do python3 /tmp/fs_image_test.py manifest $M --full > /tmp/par-\$i.txt & done; wait" \
        && get "/tmp/par-*.txt" "$WORK/"; then
        same=0
        for i in 1 2 3 4 5 6 7 8; do
            [[ -s "$WORK/guest-gzip.txt" ]] && cmp -s "$WORK/par-$i.txt" "$WORK/guest-gzip.txt" \
                && same=$((same + 1))
        done
        if [[ $same == 8 ]]; then
            pass "squash: 8 parallel readers get the single reader's manifest"
        else
            fail "squash: 8 parallel readers get the single reader's manifest ($same of 8 did)"
        fi
    else
        fail "squash: 8 parallel readers get the single reader's manifest (the readers failed)"
    fi
fi

echo "squashfs-test: xattr image"
if mount_image xattr; then
    pass "squash: xattr: mount"
    check_manifest xattr
    # Through glibc's llistxattr and lgetxattr, as any Hurd program sees them.
    paths=$(cut -f13 "$WORK/linux-xattr.txt" | tr '\n' ' ')
    g "/tmp/fs_probe xattrs $(gmnt xattr) $paths" > "$WORK/guest-xattrs.raw" 2>&1 || true
    python3 "$TOOL" xattrs-from-probe "$WORK/guest-xattrs.raw" > "$WORK/guest-xattrs.txt" || true
    rc=0
    python3 "$TOOL" compare "$WORK/linux-xattrs.txt" "$WORK/guest-xattrs.txt" > "$WORK/compare-xattrs.txt" || rc=$?
    known "squash: xattr: user, trusted and security xattrs match Linux" \
        "glibc hurd/xattr.c passes only gnu.* names" $rc
    unmount_image xattr
else
    fail "squash: xattr: mount"
    fail "squash: xattr: manifest matches Linux (not mounted)"
    fail "squash: xattr: user, trusted and security xattrs match Linux (not mounted)"
fi

# A refusal is the translator's own message and a non-zero exit; a crash
# (an assertion or a signal) or a hang is a failure.
refused_cleanly() {
    [[ "$1" != *"rc=0"* && "$1" == *"$GT: "* && "$1" != *"Assertion"* && "$1" != *"signal"* ]]
}
# Images where a lookup must not hang the translator: each is checked
# under its own time bound, and the mount must answer afterwards.
# alive NAME: the mount of NAME still answers a readdir.
alive() { GUEST_TIMEOUT=30 g "timeout 20 ls $(gmnt "$1") >/dev/null"; }
# 16 processes stat the 2000 names of one file: on a translator that
# locks a child, then its directory again, two of them soon wait on each
# other (within seconds, LINK_SECS 60 leaves a margin).
LINK_SECS=${LINK_SECS:-60}
echo "squashfs-test: hard links: $LINK_SECS s of parallel lookups"
if mount_image links; then
    out=$(GUEST_TIMEOUT=$((LINK_SECS + 60)) g "python3 /tmp/fs_image_test.py stat-storm $LINK_SECS 16 $(gmnt links)/a/f{0..1999}" 2>&1 || true)
    if [[ "$out" == "stats="*" errors={}" ]] && alive links; then
        pass "squash: hard links: 16 processes of lookups for ${LINK_SECS}s, and the mount still answers ($out)"
        unmount_image links
    else
        fail "squash: hard links: 16 processes of lookups for ${LINK_SECS}s, and the mount still answers (got: $(echo "$out" | tail -1))"
    fi
else
    fail "squash: hard links: 16 processes of lookups (links.img not mounted)"
fi

# dirloop.img: a holds b, which holds a again.  Linux gives ELOOP for
# a/b/a; the translator must refuse the image or give EIO for it, and
# keep answering while processes walk the loop.
echo "squashfs-test: a directory loop"
loop=$(gmnt dirloop)
out=$(mount_image dirloop 2>&1; echo "rc=$?")
if [[ "$out" == *"rc=0"* ]]; then
    out=$(GUEST_TIMEOUT=120 g "python3 /tmp/fs_image_test.py stat-names $loop/a/b a; python3 /tmp/fs_image_test.py stat-storm 30 16 $loop/a $loop/a/b $loop/a/b/a $loop/a/b/a/b $loop/a/b/.. $loop/a/b/a/.. $loop/f" 2>&1 || true)
    if [[ "$out" == $'a\tEIO'* && "$out" == *"stats="* ]] && alive dirloop; then
        pass "squash: a directory loop gives EIO, and 16 processes walking it do not hang the mount"
        unmount_image dirloop
    else
        fail "squash: a directory loop gives EIO, and 16 processes walking it do not hang the mount (got: $(echo "$out" | tr '\n\t' '  '))"
    fi
elif refused_cleanly "$out"; then
    pass "squash: a directory loop: the image is refused"
else
    fail "squash: a directory loop gives EIO or is refused (got: $(echo "$out" | tr '\n' ' '))"
fi

# unsorted.img: a listing not in strcmp order.  Linux's lookup stops only
# at an entry whose first byte sorts after the name's: the translator must
# find the same names.
echo "squashfs-test: a directory not in strcmp order"
if mount_image unsorted; then
    # shellcheck disable=SC2046
    got=$(g "python3 /tmp/fs_image_test.py stat-names $(gmnt unsorted)/d $(cut -f1 "$WORK/linux-unsorted.txt" | tr '\n' ' ')" 2>&1 || true)
    if [[ -s "$WORK/linux-unsorted.txt" && "$got" == "$(cat "$WORK/linux-unsorted.txt")" ]]; then
        pass "squash: a directory not in strcmp order: the names Linux finds are found"
    else
        fail "squash: a directory not in strcmp order: the names Linux finds are found (Linux: $(tr '\n\t' ' =' < "$WORK/linux-unsorted.txt"); translator: $(echo "$got" | tr '\n\t' ' ='))"
    fi
    unmount_image unsorted
else
    fail "squash: a directory not in strcmp order (unsorted.img not mounted)"
fi

# huge.img: a file claiming 2^62 bytes with a block list of one entry.
# The image has no room for the list that size needs, so the file must
# give EIO (or the image be refused), within a time bound.
echo "squashfs-test: a file claiming 2^62 bytes"
out=$(mount_image huge 2>&1; echo "rc=$?")
if [[ "$out" == *"rc=0"* ]]; then
    out=$(GUEST_TIMEOUT=90 g "python3 /tmp/fs_image_test.py stat-names $(gmnt huge) huge; timeout 60 dd if=$(gmnt huge)/huge of=/dev/null bs=1M count=64 2>&1 | tail -1" 2>&1 || true)
    if [[ "$out" == $'huge\tEIO'* ]] && alive huge; then
        pass "squash: a file claiming 2^62 bytes gives EIO"
        unmount_image huge
    else
        fail "squash: a file claiming 2^62 bytes gives EIO (got: $(echo "$out" | tr '\n\t' '  '))"
    fi
elif refused_cleanly "$out"; then
    pass "squash: a file claiming 2^62 bytes: the image is refused"
else
    fail "squash: a file claiming 2^62 bytes gives EIO or is refused (got: $(echo "$out" | tr '\n' ' '))"
fi

for spec in "lzma lzma" "compressor-99 99"; do
    read -r name word <<< "$spec"
    out=$(mount_image "$name" 2>&1; echo "rc=$?")
    if refused_cleanly "$out" && [[ "${out,,}" == *"$word"* ]]; then
        pass "squash: refuses $name.img, naming the compressor"
    else
        g "settrans -fg $(gmnt "$name")" >/dev/null 2>&1 || true
        fail "squash: refuses $name.img, naming the compressor (got: $(echo "$out" | tr '\n' ' '))"
    fi
done

# Strictness: refused > errors > served.  Where Linux refuses or errors,
# the translator must refuse the mount or fail an access.
for name in "${CORRUPT[@]}"; do
    m=$(gmnt "$name")
    if ! { put "$WORK/corrupt/$name.img" && g "mkdir -p $m"; }; then
        fail "squash: corrupt $name.img: at least as strict as Linux (could not copy it)"
        continue
    fi
    out=$(mount_fs "$m" "$GT" "/tmp/$name.img" 2>&1; echo "rc=$?")
    if [[ "$out" == *"rc=0"* ]]; then
        walked=$(g "timeout 120 python3 /tmp/fs_image_test.py walk $m | tail -1; fsysopts $m >/dev/null && echo alive" 2>&1 || true)
        g "settrans -fg $m" >/dev/null 2>&1 || true
        if [[ "$walked" != *alive* ]]; then
            level=crash
        elif [[ "$walked" == *" errors=0"* ]]; then
            level=served
        else
            level=errors
        fi
    elif refused_cleanly "$out"; then
        level=refused
    else
        level=crash
    fi
    want=${LINUX_LEVEL[$name]}
    if [[ $level != crash && ( $want == served || $level != served ) ]]; then
        pass "squash: corrupt $name.img: at least as strict as Linux (Linux $want, translator $level)"
    else
        fail "squash: corrupt $name.img: at least as strict as Linux (Linux $want, translator $level: $(echo "$out $walked" | tr '\n' ' ' | cut -c1-300))"
    fi
    g "rm -f /tmp/$name.img" || true
done
if g "grep -qx 'hello from squashfs' $M/hello.txt"; then
    pass "squash: the gzip mount still serves after the corrupt images"
else
    fail "squash: the gzip mount still serves after the corrupt images"
fi

echo "squashfs-test: fuzz: $FUZZ_COUNT images, seed $FUZZ_SEED"
tar -C "$WORK/fuzz" -cf "$WORK/fuzz.tar" .
if put "$WORK/fuzz.tar" \
    && g "mkdir -p /tmp/sq-fuzz/img && tar -C /tmp/sq-fuzz/img -xf /tmp/fuzz.tar" \
    && GUEST_TIMEOUT=$((FUZZ_COUNT * 100)) g "python3 /tmp/fs_image_test.py mount-walk $GT /tmp/sq-fuzz/mnt 30 /tmp/sq-fuzz/img/*.img" \
        > "$WORK/fuzz-results.txt"; then
    bad=$(grep -cP '\t(crash|hang)\t' "$WORK/fuzz-results.txt" || true)
    total=$(wc -l < "$WORK/fuzz-results.txt")
    summary=$(cut -f2 "$WORK/fuzz-results.txt" | sort | uniq -c | tr -s ' \n' ' ')
    if [[ $bad == 0 && $total == "$FUZZ_COUNT" ]]; then
        pass "squash: fuzz: $FUZZ_COUNT corrupted images, no crash or hang (seed $FUZZ_SEED;$summary)"
    else
        grep -P '\t(crash|hang)\t' "$WORK/fuzz-results.txt" | head -10 || true
        fail "squash: fuzz: $FUZZ_COUNT corrupted images, no crash or hang (seed $FUZZ_SEED; $total results;$summary; rerun with FUZZ_SEED=$FUZZ_SEED)"
    fi
else
    fail "squash: fuzz: $FUZZ_COUNT corrupted images, no crash or hang (seed $FUZZ_SEED; the run failed)"
fi

[[ " ${PASSES[*]} " == *"squash: gzip: mount"* ]] && unmount_image gzip
if [[ ${#UNMOUNT_FAILS[@]} == 0 && " ${PASSES[*]} " == *": mount"* ]]; then
    pass "squash: clean unmount (settrans -gR) of every mounted image"
else
    fail "squash: clean unmount (settrans -gR) of every mounted image (failed: ${UNMOUNT_FAILS[*]:-none mounted})"
fi
finish
