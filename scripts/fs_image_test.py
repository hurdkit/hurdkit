#!/usr/bin/env python3
"""Filesystem image test helpers, used on the host and inside the guest.

  fs_image_test.py tree DIR          write the deterministic test tree
  fs_image_test.py fragment ROOT     leave a fragmented file in a mounted image
  fs_image_test.py mutate ROOT       apply the write test's operations
  fs_image_test.py manifest ROOT     print one line per path under ROOT
  fs_image_test.py compare A B [--content-only]
                                     diff two manifests; exit 1 on mismatch.
                                     --content-only drops paths and compares
                                     the multiset of type/size/sha256 (for a
                                     translator that rewrites names, like
                                     fatfs serving only 8.3 short names)

A manifest line is  type<TAB>size<TAB>mtime<TAB>sha256<TAB>path  with the
path relative to ROOT, sorted, so the host's view of an image (through an
independent implementation) and the guest's (through the translator under
test) compare line by line.  The same file runs on both sides, so the
format cannot drift.
"""
import hashlib
import os
import random
import sys

# Fixed timestamps, even seconds so FAT's 2 s resolution can hold them too.
MTIME_FILE = 1622550896   # 2021-06-01 12:34:56 UTC
MTIME_DIR = 1609459200    # 2021-01-01 00:00:00 UTC


LONG_PLACEHOLDER = "Q" * 100 + ".txt"


def patch_long_name(image):
    """Rewrite LONG_PLACEHOLDER's name on an exFAT image to 100 x U+6F22 +
    ".txt", in place: same entry count, so only NameHash (Stream Extension)
    and SetChecksum (File entry) change.  Run fsck.exfat afterwards."""
    with open(image, "r+b") as f:
        data = bytearray(f.read())
    first = bytes([0xC1, 0]) + "Q".encode("utf-16-le") * 15
    at = data.find(first)
    if at < 0 or at % 32:
        raise SystemExit("patch_long_name: placeholder name not found")
    fileent, stream = at - 64, at - 32
    if data[fileent] != 0x85 or data[stream] != 0xC0:
        raise SystemExit("patch_long_name: unexpected entry layout")
    secondary = data[fileent + 1]
    length = data[stream + 3]
    if length != len(LONG_PLACEHOLDER):
        raise SystemExit("patch_long_name: unexpected name length")
    new = ("\u6f22" * 100 + ".txt").encode("utf-16-le")
    for i in range(0, len(new), 2):
        unit = i // 2
        off = at + (unit // 15) * 32 + 2 + (unit % 15) * 2
        data[off:off + 2] = new[i:i + 2]
    h = 0
    for b in ("\u6f22" * 100 + ".txt").upper().encode("utf-16-le"):
        h = (((h << 15) | (h >> 1)) & 0xFFFF) + b & 0xFFFF
    data[stream + 4:stream + 6] = h.to_bytes(2, "little")
    c = 0
    for i in range((secondary + 1) * 32):
        if i in (2, 3):
            continue
        c = (((c << 15) | (c >> 1)) & 0xFFFF) + data[fileent + i] & 0xFFFF
    data[fileent + 2:fileent + 4] = c.to_bytes(2, "little")
    with open(image, "r+b") as f:
        f.write(data)


def _write(path, data, mtime=MTIME_FILE):
    with open(path, "wb") as f:
        f.write(data)
    os.utime(path, (mtime, mtime))


def _blob(seed, size):
    return random.Random(seed).randbytes(size)


def tree(root, unicode_names=True):
    """The test tree.  Every entry exists to exercise one reader path."""
    os.makedirs(root, exist_ok=True)
    files = {
        "hello.txt": b"hello from the image\n",
        "empty.bin": b"",
        "one-cluster.bin": _blob(1, 4096),
        "cluster-plus-one.bin": _blob(2, 4097),
        "big.bin": _blob(3, 5 * 1024 * 1024 + 123),
        "MixedCase.TXT": b"case-insensitive lookup target\n",
        "a/b/c/d/deep.txt": b"four levels down\n",
        ("n" * 200) + ".txt": b"a 204-character name\n",
    }
    if unicode_names:
        files["Grüße 日本語 ✓.txt"] = "bmp characters\n".encode()
        files["rocket-\U0001F680.txt"] = "a surrogate pair\n".encode()
        # Names around NAME_MAX in UTF-8.  85 CJK characters are exactly 255
        # bytes and must be listed.  LONG_PLACEHOLDER is renamed on the image
        # by patch_long_name() to 100 CJK characters plus ".txt": legal on
        # exFAT (104 UTF-16 units) but 304 bytes in UTF-8, which neither Linux
        # nor a Hurd dirent can carry, so it can't be created normally.  The
        # translator must hide it and keep serving its siblings.
        files["long-utf8/" + "\u6f22" * 85] = "exactly 255 bytes\n".encode()
        files["long-utf8/" + LONG_PLACEHOLDER] = "hidden on Hurd\n".encode()
        files["long-utf8/sibling.txt"] = "next to a 304-byte name\n".encode()
    for i in range(300):
        files[f"many/entry-{i:03d}.txt"] = f"entry {i}\n".encode()
    for rel, data in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        _write(path, data)
    for dirpath, _, _ in sorted(os.walk(root), reverse=True):
        os.utime(dirpath, (MTIME_DIR, MTIME_DIR))


def fragment(root):
    """Leave frag.bin with clusters that are not contiguous.

    Run against a mounted image.  Fill the free space with 64 KiB files,
    free every other one, and write a file larger than any single gap, so
    the allocator has to chain it through several gaps.  The survivors
    keep the gaps apart and are part of the tree the reader must get right.
    """
    filler = os.path.join(root, "filler")
    os.makedirs(filler)
    chunk = 64 * 1024
    names = []
    while True:
        st = os.statvfs(root)
        if st.f_bavail * st.f_frsize < 4 * chunk:
            break
        name = os.path.join(filler, f"f{len(names):04d}.bin")
        _write(name, _blob(1000 + len(names), chunk))
        names.append(name)
    for name in names[::2]:
        os.unlink(name)
    _write(os.path.join(root, "frag.bin"), _blob(12, 16 * chunk + 7))
    os.utime(filler, (MTIME_DIR, MTIME_DIR))
    os.utime(root, (MTIME_DIR, MTIME_DIR))


MTIME_WRITTEN = 1700000000  # 2023-11-14 22:13:20 UTC


def mutate(root):
    """Apply the write test's operations to a tree that holds the image
    contents (tree() plus fragment()).  Each step targets one write path.
    Ends by setting every mtime, so the result is deterministic and the
    utimes path is checked for every entry."""
    j = lambda *p: os.path.join(root, *p)
    os.makedirs(j("made", "sub", "deeper"))
    _write(j("new-small.txt"), b"created by the write test\n")
    _write(j("made", "three-clusters.bin"), _blob(20, 3 * 4096 + 5))
    with open(j("hello.txt"), "ab") as f:
        f.write(b"appended\n")
    with open(j("big.bin"), "r+b") as f:
        f.seek(1024 * 1024 + 3)
        f.write(_blob(21, 100))
    os.truncate(j("big.bin"), 2 * 1024 * 1024 + 11)
    with open(j("sparse.bin"), "wb") as f:
        f.truncate(300000)
    with open(j("frag.bin"), "ab") as f:
        f.write(_blob(22, 70000))
    with open(j("one-cluster.bin"), "ab") as f:
        f.write(b"!")
    os.rename(j("hello.txt"), j("renamed.txt"))
    os.rename(j("a", "b", "c", "d", "deep.txt"), j("made", "moved-deep.txt"))
    os.rename(j("MixedCase.TXT"), j("tmp-case"))
    os.rename(j("tmp-case"), j("mixedcase.txt"))
    os.unlink(j("empty.bin"))
    for i in range(50):
        os.unlink(j("many", f"entry-{i:03d}.txt"))
    os.mkdir(j("made", "gone"))
    os.rmdir(j("made", "gone"))
    os.rmdir(j("a", "b", "c", "d"))
    _write(j("nouveau-élève-\U0001F680.txt"), "new unicode name\n".encode())
    _write(j(("L" * 240) + ".txt"), b"a 244-character name\n")
    os.makedirs(j("made", "grow"))
    for i in range(200):
        _write(j("made", "grow", f"g{i:03d}.txt"), f"grow {i}\n".encode())
    for name in os.listdir(j("filler")):
        os.unlink(j("filler", name))
    os.rmdir(j("filler"))
    _write(j("made", "after-free.bin"), _blob(23, 2 * 1024 * 1024 + 9))
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        for name in filenames:
            p = os.path.join(dirpath, name)
            os.utime(p, (MTIME_WRITTEN, MTIME_WRITTEN))
        os.utime(dirpath, (MTIME_DIR, MTIME_DIR))


NAME_MAX = 255


def manifest(root, mtimes=True):
    """Names longer than NAME_MAX bytes are left out: Hurd can't represent
    them, so a host-side view keeps them and the guest must not show them
    at all.  A translator that showed one truncated would add a line the
    host side lacks, so the comparison still catches that."""
    lines = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(n for n in dirnames if len(os.fsencode(n)) <= NAME_MAX)
        filenames = [n for n in filenames if len(os.fsencode(n)) <= NAME_MAX]
        for name in sorted(dirnames) + sorted(filenames):
            path = os.path.join(dirpath, name)
            st = os.lstat(path)
            rel = os.path.relpath(path, root)
            mtime = str(int(st.st_mtime)) if mtimes else "-"
            if os.path.isdir(path):
                lines.append(f"d\t-\t{mtime}\t-\t{rel}")
            else:
                h = hashlib.sha256()
                with open(path, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                lines.append(f"f\t{st.st_size}\t{mtime}\t{h.hexdigest()}\t{rel}")
    return sorted(lines, key=lambda l: l.split("\t", 4)[4])


def copy(src, dst):
    """cp -a, minus names past NAME_MAX, which a Linux directory can't hold."""
    import shutil
    def ignore(_, names):
        return [n for n in names if len(os.fsencode(n)) > NAME_MAX]
    shutil.copytree(src, dst, symlinks=True, ignore=ignore, dirs_exist_ok=True)


def compare(a_path, b_path, content_only=False):
    with open(a_path) as f:
        a = f.read().splitlines()
    with open(b_path) as f:
        b = f.read().splitlines()
    if content_only:
        a = sorted(l.rsplit("\t", 1)[0] for l in a)
        b = sorted(l.rsplit("\t", 1)[0] for l in b)
    if not a:
        print(f"compare: {a_path} is empty; refusing to call that a match")
        return 1
    if a == b:
        print(f"compare: {len(a)} entries identical")
        return 0
    sa, sb = set(a), set(b)
    for line in sorted(sa - sb):
        print(f"  only in {os.path.basename(a_path)}: {line}")
    for line in sorted(sb - sa):
        print(f"  only in {os.path.basename(b_path)}: {line}")
    print(f"compare: MISMATCH ({len(sa - sb)} vs {len(sb - sa)} differing lines)")
    return 1


def main(argv):
    if len(argv) >= 3 and argv[1] == "tree":
        tree(argv[2], unicode_names="--ascii" not in argv)
        return 0
    if len(argv) == 4 and argv[1] == "copy":
        copy(argv[2], argv[3])
        return 0
    if len(argv) == 3 and argv[1] == "patch-long-name":
        patch_long_name(argv[2])
        return 0
    if len(argv) == 3 and argv[1] == "fragment":
        fragment(argv[2])
        return 0
    if len(argv) == 3 and argv[1] == "mutate":
        mutate(argv[2])
        return 0
    if len(argv) >= 3 and argv[1] == "manifest":
        print("\n".join(manifest(argv[2], mtimes="--no-mtime" not in argv)))
        return 0
    if len(argv) in (4, 5) and argv[1] == "compare":
        return compare(argv[2], argv[3], content_only="--content-only" in argv)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
