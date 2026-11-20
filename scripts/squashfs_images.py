#!/usr/bin/env python3
"""Build the squashfs test images on the host, without root.

  squashfs_images.py tree KIND DIR PROBE   write source tree KIND (main,
                                           wide, small, xattr) to DIR and
                                           its pseudo definitions to
                                           DIR.pseudo; PROBE is the static
                                           Hurd binary to exec from the image
  squashfs_images.py expect KIND DIR       print the full manifest the image
                                           of DIR must have: DIR's own,
                                           with the pseudo definitions applied
  squashfs_images.py expect-xattrs KIND    print the xattrs the image must
                                           have (fs_image_test.py xattrs form)
  squashfs_images.py variants              print "name<TAB>mksquashfs options"
                                           for every image of the main tree
  squashfs_images.py corrupt IMG OUTDIR    write the corrupt copies of IMG
  squashfs_images.py fuzz IMG OUTDIR SEED N
                                           write N copies of IMG with random
                                           bytes changed, fuzz-NNN.img
  squashfs_images.py set-compressor IMG ID patch the superblock compressor id
  squashfs_images.py craft KIND IMG        write a hand-made image (CRAFTED)

Owners, device nodes and xattrs come from mksquashfs pseudo definitions
(-pf DIR.pseudo), so no step needs root.  The definitions and the
expected manifest are both generated from PSEUDO below, so they cannot
disagree.
"""
import base64
import hashlib
import os
import random
import socket
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fs_image_test as fit  # noqa: E402

MTIME = 1622550896
MTIME_DIR = 1609459200

# Every main-tree image: (name, mksquashfs options).  Each compressor
# Linux supports, with defaults and with non-default options, plus the
# layout options that change how the reader must find data.
VARIANTS = [
    ("gzip", "-comp gzip"),
    ("gzip-opts", "-comp gzip -Xcompression-level 1 -Xwindow-size 8 -Xstrategy huffman_only,run_length_encoded"),
    ("lzo", "-comp lzo"),
    ("lzo-1x1", "-comp lzo -Xalgorithm lzo1x_1"),
    ("xz", "-comp xz"),
    ("xz-bcj", "-comp xz -Xbcj x86,arm -Xdict-size 50%"),
    ("lz4", "-comp lz4"),
    ("lz4-hc", "-comp lz4 -Xhc"),
    ("zstd", "-comp zstd"),
    ("zstd-22", "-comp zstd -Xcompression-level 22"),
    ("uncompressed", "-noI -noD -noF -noX"),
    ("block-4k", "-comp gzip -b 4K"),
    ("block-1m", "-comp xz -b 1M"),
    ("no-fragments", "-comp zstd -no-fragments"),
    ("always-fragments", "-comp lz4 -always-use-fragments -tailends"),
    ("no-duplicates", "-comp gzip -no-duplicates"),
    ("no-exports-no-sparse", "-comp gzip -no-exports -no-sparse"),
]

# Options every image gets: a fixed creation time, so builds repeat.
COMMON = "-noappend -quiet -no-progress -mkfs-time 1622550896"


def _write(path, data, mtime=MTIME, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    if mode is not None:
        os.chmod(path, mode)
    os.utime(path, (mtime, mtime))


def _blob(seed, size):
    return random.Random(seed).randbytes(size)


def _sparse(path, size, chunks):
    """A file of SIZE bytes that holds CHUNKS ((offset, bytes)) and holes."""
    with open(path, "wb") as f:
        f.truncate(size)
        for off, data in chunks:
            f.seek(off)
            f.write(data)
    os.utime(path, (MTIME, MTIME))


def pseudo_defs(kind):
    """The pseudo definitions of tree KIND, as structured records.

    ("M", path, mtime, mode, uid, gid)          modify an existing entry
    ("C"/"B", path, mtime, mode, uid, gid, major, minor)  device node
    ("x", path, name, value)                     extended attribute
    """
    defs = []
    if kind == "main":
        defs.append(("C", "dev/null-like", MTIME, 0o666, 0, 0, 1, 3))
        defs.append(("C", "dev/big-numbers", MTIME, 0o600, 0, 5, 4095, 1048575))
        defs.append(("B", "dev/disk", MTIME, 0o660, 0, 6, 8, 1))
        defs.append(("B", "dev/disk-high", MTIME, 0o640, 0, 6, 259, 70000))
        for i in range(300):
            defs.append(("M", f"owners/o{i:03d}", MTIME, 0o644, 10000 + i, 20000 + i))
        defs.append(("M", "modes/setuid-root", MTIME, 0o4755, 0, 0))
        defs.append(("M", "modes/none", MTIME, 0o000, 0, 0))
        defs.append(("M", "modes/owned-dir", MTIME_DIR, 0o755, 4294967294, 4294967294))
    elif kind == "wide":
        for i in range(2100):
            defs.append(("M", f"ids/i{i:04d}", MTIME, 0o644, 100000 + i, 200000 + i))
    elif kind == "small":
        defs.append(("M", "owned", MTIME, 0o640, 1234, 5678))
    elif kind == "xattr":
        big = bytes(range(256)) * 24 + b"tail"        # 6148 bytes
        defs += [("x", "file", "user.small", b"hello"),
                 ("x", "file", "user.big", big),
                 ("x", "file", "trusted.t", b"trusted value"),
                 ("x", "file", "security.selinux", b"system_u:object_r:etc_t:s0\0"),
                 ("x", "dir", "user.on-a-dir", b"d"),
                 ("x", "dir", "trusted.t", b"on a directory"),
                 ("x", "same-as-file", "user.small", b"hello"),
                 ("x", "same-as-file", "user.big", big)]
        for i in range(120):
            defs.append(("x", "many", f"user.attr{i:03d}", f"value {i}".encode() * (i % 7 + 1)))
    return defs


def _pseudo_line(d):
    if d[0] == "M":
        _, path, mtime, mode, uid, gid = d
        return f"{path} M {mtime} {mode:o} {uid} {gid}"
    if d[0] in "CB":
        _, path, mtime, mode, uid, gid, major, minor = d
        return f"{path} {d[0]} {mtime} {mode:o} {uid} {gid} {major} {minor}"
    _, path, name, value = d
    # Base64: mksquashfs 4.6.1 corrupts its heap decoding a long 0x value.
    return f"{path} x {name}=0s{base64.b64encode(value).decode()}"


def tree(kind, root, probe):
    """Write the source tree KIND to ROOT and its pseudo file to ROOT.pseudo."""
    os.makedirs(root)
    j = lambda *p: os.path.join(root, *p)
    if kind == "main":
        files = {
            "hello.txt": b"hello from squashfs\n",
            "empty.bin": b"",
            "one-byte.bin": b"x",
            "dup-a.bin": _blob(7, 300000),
            "dup-b.bin": _blob(7, 300000),
            "big-random.bin": _blob(3, 5 * 1024 * 1024 + 123),
            "compressible.txt": b"squashfs compresses this line well\n" * 240000,
            ("n" * 251) + ".txt": b"a 255-byte ASCII name\n",
            "漢" * 85: "a 255-byte UTF-8 name\n".encode(),
            "Grüße 日本語 ✓.txt": "utf-8 name\n".encode(),
            "rocket-\U0001F680.txt": "astral plane name\n".encode(),
            "times/epoch.txt": b"mtime 0\n",
            "times/after-2038.txt": b"mtime 4000000000\n",
            "times/max-u32.txt": b"mtime 4294967295\n",
        }
        for b in (4096, 131072, 1048576):
            for delta, tag in ((-1, "under"), (0, "at"), (1, "over")):
                files[f"blocks/{b}-{tag}.bin"] = _blob(b + delta, b + delta)
        for rel, data in files.items():
            _write(j(rel), data)
        os.utime(j("times/epoch.txt"), (0, 0))
        os.utime(j("times/after-2038.txt"), (4000000000, 4000000000))
        os.utime(j("times/max-u32.txt"), (4294967295, 4294967295))
        _sparse(j("sparse-holes.bin"), 9 * 1024 * 1024 + 17,
                [(0, _blob(30, 70000)), (4 * 1024 * 1024, _blob(31, 200000)),
                 (9 * 1024 * 1024, _blob(32, 17))])
        _sparse(j("sparse-tail-hole.bin"), 3 * 1024 * 1024, [(0, _blob(33, 5000))])
        for i in range(3500):
            _write(j("big-dir", f"entry-{i:05d}-" + "p" * 40), b"" if i % 2 else f"{i}\n".encode())
        deep = j(*[f"d{i:02d}" for i in range(40)])
        _write(os.path.join(deep, "leaf.txt"), b"forty levels down\n")
        os.makedirs(j("empty-dir"))
        os.symlink("hello.txt", j("link-short"))
        os.symlink("/".join(["long-target-component"] * 70), j("link-long"))
        os.symlink("does/not/exist", j("link-dangling"))
        os.symlink("blocks", j("link-to-dir"))
        _write(j("hardlinks/one"), b"three names, one inode\n")
        os.link(j("hardlinks/one"), j("hardlinks/two"))
        os.link(j("hardlinks/one"), j("hardlinks/three"))
        os.makedirs(j("special"))
        os.mkfifo(j("special/fifo"), 0o640)
        cwd = os.getcwd()
        os.chdir(j("special"))
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind("socket")
        s.close()
        os.chdir(cwd)
        os.makedirs(j("dev"))
        os.makedirs(j("owners"))
        for i in range(300):
            _write(j("owners", f"o{i:03d}"), f"owner {i}\n".encode())
        for name, mode in (("setuid-root", 0o4755), ("setuid", 0o4711), ("setgid", 0o2755),
                           ("both", 0o6750), ("none", 0o644), ("rw-only", 0o600)):
            _write(j("modes", name), name.encode() + b"\n", mode=mode)
        for name, mode in (("sticky-dir", 0o1777), ("setgid-dir", 0o2775), ("closed-dir", 0o700),
                           ("owned-dir", 0o755)):
            os.makedirs(j("modes", name))
            os.chmod(j("modes", name), mode)
        with open(probe, "rb") as f:
            _write(j("bin", "fs_probe.static"), f.read(), mode=0o755)
        _write(j("bin", "hello.sh"), b"#!/bin/sh\necho squashfs-script-ok\n", mode=0o755)
    elif kind == "wide":
        for d in range(70):
            for i in range(1000):
                _write(j(f"w{d:02d}", f"f{i:03d}"), b"")
        for i in range(2100):
            _write(j("ids", f"i{i:04d}"), b"")
        _sparse(j("sparse-huge.bin"), 5 * 1024 ** 3 + 4097,
                [(0, _blob(40, 4096)), (4 * 1024 ** 3 - 100, _blob(41, 300)),
                 (5 * 1024 ** 3, _blob(42, 4097))])
    elif kind == "small":
        _write(j("hello.txt"), b"hello from the small image\n")
        _write(j("data.bin"), b"compressible block data\n" * 13000)
        _write(j("owned"), b"owned by 1234\n")
        for i in range(40):
            _write(j("dir", f"f{i:02d}"), f"{i}\n".encode() * (i + 1))
        os.symlink("hello.txt", j("link"))
    elif kind == "xattr":
        _write(j("file"), b"file with xattrs\n")
        _write(j("same-as-file"), b"another file, same xattr set\n")
        _write(j("many"), b"120 xattrs\n")
        _write(j("plain"), b"no xattrs\n")
        os.makedirs(j("dir"))
        # A pseudo xattr cannot be empty, so this one comes from the source.
        os.setxattr(j("plain"), "user.empty", b"")
    else:
        raise SystemExit(f"tree: unknown kind {kind}")
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        for name in filenames + dirnames:
            p = os.path.join(dirpath, name)
            if name in ("epoch.txt", "after-2038.txt", "max-u32.txt"):
                continue
            os.utime(p, (MTIME, MTIME), follow_symlinks=False)
        os.utime(dirpath, (MTIME_DIR, MTIME_DIR))
    with open(root + ".pseudo", "w") as f:
        for d in pseudo_defs(kind):
            f.write(_pseudo_line(d) + "\n")


def expect(kind, root):
    """The source tree's full manifest with the pseudo definitions applied."""
    entries = {}
    for line in fit.full_manifest(root):
        e = fit.parse_full(line)
        entries[e["path"]] = e
    for d in pseudo_defs(kind):
        if d[0] == "M":
            _, path, mtime, mode, uid, gid = d
            entries[path].update(mtime=str(mtime), mode="%04o" % mode, uid=str(uid), gid=str(gid))
        elif d[0] in "CB":
            _, path, mtime, mode, uid, gid, major, minor = d
            entries[path] = {"type": d[0].lower(), "size": "0", "mtime": str(mtime),
                             "sha256": "-", "mode": "%04o" % mode, "uid": str(uid),
                             "gid": str(gid), "nlink": "1", "rdev": f"{major},{minor}",
                             "target": "-", "ino": "-", "blocks": "-", "path": path}
    return [fit.format_full(entries[p]) for p in sorted(entries)]


SOURCE_XATTRS = {"xattr": [("plain", "user.empty", b"")]}


def expect_xattrs(kind):
    defs = [d[1:] for d in pseudo_defs(kind) if d[0] == "x"] + SOURCE_XATTRS.get(kind, [])
    return sorted(f"{path}\t{name}\t{len(value)}\t{hashlib.sha256(value).hexdigest()}"
                  for path, name, value in defs)


SB = struct.Struct("<IIIIIHHHHHHQQQQQQQQ")
SB_FIELDS = ("magic", "inode_count", "mod_time", "block_size", "frag_count",
             "compressor", "block_log", "flags", "id_count", "major", "minor",
             "root_inode", "bytes_used", "id_table", "xattr_table", "inode_table",
             "dir_table", "frag_table", "export_table")


def superblock(data):
    return dict(zip(SB_FIELDS, SB.unpack_from(data, 0)))


def _metadata_payload(data, start):
    """Offset of a byte in the middle of the metadata block at START."""
    header = struct.unpack_from("<H", data, start)[0]
    length = header & 0x7FFF
    return start + 2 + length // 2


def _lookup_block(data, table):
    """The first metadata block a lookup table (u64 pointers) names."""
    return struct.unpack_from("<Q", data, table)[0]


def corrupt(image, outdir):
    """Write each corrupt copy of IMAGE: NAME.img in OUTDIR."""
    with open(image, "rb") as f:
        data = f.read()
    sb = superblock(data)
    os.makedirs(outdir, exist_ok=True)

    def out(name, blob):
        with open(os.path.join(outdir, name + ".img"), "wb") as f:
            f.write(blob)

    def flip(name, offset, bit=0x10):
        b = bytearray(data)
        b[offset] ^= bit
        out(name, bytes(b))

    # The file is padded to 4 KiB; cut the filesystem, not the padding.
    out("truncated", data[:sb["bytes_used"] // 2])
    b = bytearray(data)
    b[0:4] = b"hsqT"
    out("bad-magic", bytes(b))
    b = bytearray(data)
    struct.pack_into("<HH", b, 28, 3, 1)
    out("version-3", bytes(b))
    b = bytearray(data)
    struct.pack_into("<Q", b, 48, len(data) + (1 << 20))
    out("table-past-end", bytes(b))
    flip("flip-inode-table", _metadata_payload(data, sb["inode_table"]))
    flip("flip-dir-table", _metadata_payload(data, sb["dir_table"]))
    flip("flip-frag-table", _metadata_payload(data, _lookup_block(data, sb["frag_table"])))
    flip("flip-id-table", _metadata_payload(data, _lookup_block(data, sb["id_table"])))
    flip("flip-data-block", SB.size + 100)


CORRUPT_NAMES = ("truncated", "bad-magic", "version-3", "table-past-end",
                 "flip-inode-table", "flip-dir-table", "flip-frag-table",
                 "flip-id-table", "flip-data-block")


def fuzz(image, outdir, seed, count):
    """COUNT copies of IMAGE, each with 1 to 4 random bytes replaced.
    Copy k of seed s is the same on every run."""
    with open(image, "rb") as f:
        data = f.read()
    os.makedirs(outdir, exist_ok=True)
    for k in range(count):
        rng = random.Random(f"{seed}:{k}")
        b = bytearray(data)
        for _ in range(rng.randint(1, 4)):
            b[rng.randrange(len(b))] = rng.randrange(256)
        with open(os.path.join(outdir, f"fuzz-{k:03d}.img"), "wb") as f:
            f.write(b)


def set_compressor(image, cid):
    with open(image, "r+b") as f:
        f.seek(20)
        f.write(struct.pack("<H", cid))


class _Crafted:
    """A small image written field by field: every inode in one stored
    (uncompressed) metadata block, every listing in another, so that an
    image no tool would write can be described in a few lines."""

    def __init__(self):
        self.inodes = bytearray()
        self.listings = bytearray()
        self.count = 0

    def _inode(self, itype, ino, body, mode):
        ref = len(self.inodes)
        self.inodes += struct.pack("<HHHHII", itype, mode, 0, 0, MTIME, ino) + body
        self.count += 1
        return ref

    def file(self, ino, size=6, blocks=(6 | 1 << 24,)):
        """A file whose data is uncompressed blocks at the start of the
        data area; a size past 4 GiB makes it an extended inode."""
        if size >> 32:
            body = struct.pack("<QQQIIII", SB.size, size, 0, 1, 0xFFFFFFFF, 0, 0xFFFFFFFF)
            itype = 9
        else:
            body = struct.pack("<IIII", SB.size, 0xFFFFFFFF, 0, size)
            itype = 2
        return self._inode(itype, ino, body + struct.pack(f"<{len(blocks)}I", *blocks), 0o644)

    def dir(self, ino, parent):
        """A directory with an empty listing until list() gives it one."""
        return self._inode(1, ino, struct.pack("<IIHHI", 0, 2, 3, 0, parent), 0o755)

    def list(self, dref, entries):
        """Give directory DREF the listing ENTRIES, (name, ino, type, ref),
        in the order given, as one run."""
        start = len(self.listings)
        base = entries[0][1]
        self.listings += struct.pack("<III", len(entries) - 1, 0, base)
        for name, ino, itype, ref in entries:
            self.listings += struct.pack("<HhHH", ref, ino - base, itype, len(name) - 1) + name.encode()
        nlink = 2 + sum(itype == 1 for _, _, itype, _ in entries)
        struct.pack_into("<IIHHI", self.inodes, 16 + dref, 0, nlink,
                         len(self.listings) - start + 3, start,
                         struct.unpack_from("<I", self.inodes, dref + 28)[0])

    def write(self, path, root, data=b"hello\n"):
        stored = lambda b: struct.pack("<H", len(b) | 0x8000) + bytes(b)
        out = bytearray(SB.size) + data
        itab = len(out)
        out += stored(self.inodes)
        dtab = len(out)
        out += stored(self.listings)
        idblock = len(out)
        out += stored(struct.pack("<I", 0))
        idtab = len(out)
        out += struct.pack("<Q", idblock)
        none = 0xFFFFFFFFFFFFFFFF
        out[:SB.size] = SB.pack(0x73717368, self.count, MTIME, 4096, 0, 1, 12, 0, 1, 4, 0,
                                root, len(out), idtab, none, itab, dtab, none, none)
        out += bytes(-len(out) % 4096)
        with open(path, "wb") as f:
            f.write(out)


def craft(kind, path):
    """Write the hand-made image KIND to PATH (see CRAFTED)."""
    c = _Crafted()
    if kind == "dirloop":
        f = c.file(4)
        a = c.dir(2, 1)
        b = c.dir(3, 2)
        root = c.dir(1, 5)
        c.list(root, [("a", 2, 1, a), ("f", 4, 2, f)])
        c.list(a, [("b", 3, 1, b)])
        c.list(b, [("a", 2, 1, a)])
    elif kind == "unsorted":
        n = len(UNSORTED)
        files = [c.file(ino) for ino in range(1, n + 1)]
        d = c.dir(n + 1, n + 2)
        root = c.dir(n + 2, n + 3)
        c.list(d, [(name, i + 1, 2, files[i]) for i, name in enumerate(UNSORTED)])
        c.list(root, [("d", n + 1, 1, d)])
    elif kind == "huge":
        f = c.file(2, size=1 << 62, blocks=(0,))
        root = c.dir(1, 3)
        c.list(root, [("huge", 2, 2, f)])
    else:
        raise SystemExit(f"craft: unknown kind {kind}")
    c.write(path, root)


# The hand-made images: dirloop, where directory a holds b and b holds a
# again; unsorted, whose directory d lists UNSORTED in that order, which
# is not strcmp order; huge, whose file claims 2^62 bytes and lists one
# block.
CRAFTED = ("dirloop", "unsorted", "huge")
UNSORTED = ("a1", "b2", "b10", "b1", "c3", "b4")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "tree" and len(argv) == 5:
        tree(argv[2], argv[3], argv[4])
    elif cmd == "expect" and len(argv) == 4:
        print("\n".join(expect(argv[2], argv[3])))
    elif cmd == "expect-xattrs" and len(argv) == 3:
        print("\n".join(expect_xattrs(argv[2])))
    elif cmd == "variants" and len(argv) == 2:
        for name, opts in VARIANTS:
            print(f"{name}\t{opts} {COMMON}")
    elif cmd == "corrupt" and len(argv) == 4:
        corrupt(argv[2], argv[3])
    elif cmd == "fuzz" and len(argv) == 6:
        fuzz(argv[2], argv[3], argv[4], int(argv[5]))
    elif cmd == "set-compressor" and len(argv) == 4:
        set_compressor(argv[2], int(argv[3]))
    elif cmd == "craft" and len(argv) == 4:
        craft(argv[2], argv[3])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
