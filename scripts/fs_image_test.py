#!/usr/bin/env python3
"""Filesystem image test helpers, used on the host and inside the guest.

  fs_image_test.py tree DIR          write the deterministic test tree
  fs_image_test.py fragment ROOT     leave a fragmented file in a mounted image
  fs_image_test.py mutate ROOT       apply the write test's operations
  fs_image_test.py manifest ROOT [--no-mtime] [--full]
                                     print one line per path under ROOT
  fs_image_test.py compare A B [--content-only] [--ignore FIELDS]
                                     diff two manifests; exit 1 on mismatch.
                                     --content-only drops paths and compares
                                     the multiset of type/size/sha256 (for a
                                     translator that rewrites names, like
                                     fatfs serving only 8.3 short names).
                                     --ignore (full manifests) blanks the
                                     comma-separated fields, each FIELD or
                                     TYPE:FIELD (d:size: directories only)
  fs_image_test.py walk ROOT         read every entry, count errors, never
                                     fail (for corrupt images)
  fs_image_test.py xattrs ROOT       print every extended attribute
  fs_image_test.py hurd-dev IN OUT   IN with device numbers as the Hurd's
                                     dev_t holds them; print those that
                                     do not fit
  fs_image_test.py xattrs-from-probe FILE
                                     the same, from fs_probe xattrs output
  fs_image_test.py erofs ROOT FILE DIR
                                     every write on a read-only mount must
                                     fail with EROFS
  fs_image_test.py lookups ROOT      a missing name gives ENOENT; ".." at
                                     ROOT leads to ROOT's parent
  fs_image_test.py mmap FILE...      print sha256 of each FILE read via mmap
  fs_image_test.py stat-names DIR NAME...
                                     print NAME<TAB>found, or the errno
                                     name, for each NAME looked up in DIR
  fs_image_test.py statvfs-flags PATH
                                     print the ST_* flags statvfs gives
  fs_image_test.py stat-storm SECS PROCS PATH...
                                     PROCS processes stat random PATHs for
                                     SECS seconds; print the count of stats
                                     and of each errno
  fs_image_test.py mount-walk TRANSLATOR MNTROOT TIMEOUT IMAGE...
                                     (Hurd guest) mount each IMAGE, walk it,
                                     check the translator is still alive;
                                     one result line per image

A manifest line is  type<TAB>size<TAB>mtime<TAB>sha256<TAB>path  with the
path relative to ROOT, sorted, so the host's view of an image (through an
independent implementation) and the guest's (through the translator under
test) compare line by line.  The same file runs on both sides, so the
format cannot drift.

--full adds the root (".") and every file type, and the columns of
FULL_FIELDS: permission bits including setuid, setgid and sticky, owner,
link count, device numbers, symlink target, inode number and st_blocks.
A regular file larger than SAMPLE_OVER is hashed over fixed sample
regions (sha256 "sampled:..."), so a sparse file of many GiB is checked
without reading all of it.
"""
import errno
import hashlib
import os
import random
import stat
import sys
import time

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


FULL_FIELDS = ("type", "size", "mtime", "sha256", "mode", "uid", "gid",
               "nlink", "rdev", "target", "ino", "blocks", "path")
SAMPLE_OVER = 1 << 30
SAMPLE_LEN = 64 * 1024
SAMPLE_STEP = 256 * 1024 * 1024


def _sha256(path, size):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        if size <= SAMPLE_OVER:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
            return h.hexdigest()
        offsets = list(range(0, size, SAMPLE_STEP)) + [size - SAMPLE_LEN]
        for off in offsets:
            f.seek(off)
            h.update(f.read(SAMPLE_LEN))
    return "sampled:" + h.hexdigest()


def _readlink(path, size):
    """os.readlink, except that Python on the Hurd reads at most 1024
    bytes (its MAXPATHLEN); readlink(1) has no such limit."""
    target = os.readlink(path)
    if len(os.fsencode(target)) < size:
        import subprocess
        out = subprocess.run(["readlink", path], stdout=subprocess.PIPE, check=True).stdout
        target = os.fsdecode(out[:-1] if out.endswith(b"\n") else out)
    return target


def _type(mode):
    for test, t in ((stat.S_ISDIR, "d"), (stat.S_ISREG, "f"), (stat.S_ISLNK, "l"),
                    (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"), (stat.S_ISFIFO, "p"),
                    (stat.S_ISSOCK, "s")):
        if test(mode):
            return t
    return "?"


def full_entry(path, rel):
    """One FULL_FIELDS record (a dict) for PATH, from lstat."""
    st = os.lstat(path)
    t = _type(st.st_mode)
    return {
        "type": t,
        "size": str(st.st_size),
        "mtime": str(int(st.st_mtime)),
        "sha256": _sha256(path, st.st_size) if t == "f" else "-",
        "mode": "%04o" % stat.S_IMODE(st.st_mode),
        "uid": str(st.st_uid),
        "gid": str(st.st_gid),
        "nlink": str(st.st_nlink),
        "rdev": "%d,%d" % (os.major(st.st_rdev), os.minor(st.st_rdev)) if t in "cb" else "-",
        "target": _readlink(path, st.st_size).replace("\t", "\\t") if t == "l" else "-",
        "ino": str(st.st_ino),
        "blocks": str(st.st_blocks),
        "path": rel,
    }


def format_full(entry):
    return "\t".join(entry[k] for k in FULL_FIELDS)


def parse_full(line):
    return dict(zip(FULL_FIELDS, line.split("\t")))


def full_manifest(root):
    lines = [format_full(full_entry(root, "."))]
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(n for n in dirnames if len(os.fsencode(n)) <= NAME_MAX)
        filenames = [n for n in filenames if len(os.fsencode(n)) <= NAME_MAX]
        for name in dirnames + sorted(filenames):
            path = os.path.join(dirpath, name)
            lines.append(format_full(full_entry(path, os.path.relpath(path, root))))
    return sorted(lines, key=lambda l: l.rsplit("\t", 1)[1])


def walk(root):
    """Visit every entry the way a reader would and count what fails.
    For corrupt images: the result is the counts, never an exception."""
    entries = errors = 0
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            names = os.listdir(d)
        except OSError as e:
            errors += 1
            print(f"walk: listdir {d}: {e}")
            continue
        for name in names:
            path = os.path.join(d, name)
            entries += 1
            try:
                st = os.lstat(path)
                if stat.S_ISDIR(st.st_mode):
                    stack.append(path)
                elif stat.S_ISREG(st.st_mode):
                    with open(path, "rb") as f:
                        while f.read(1 << 20):
                            pass
                elif stat.S_ISLNK(st.st_mode):
                    os.readlink(path)
            except OSError as e:
                errors += 1
                if errors <= 20:
                    print(f"walk: {path}: {e}")
    print(f"walk: entries={entries} errors={errors}")
    return 0


def xattrs_from_probe(probe_out):
    """fs_probe xattrs output, in the form xattrs() prints."""
    lines = []
    with open(probe_out, errors="surrogateescape") as f:
        for line in f.read().splitlines():
            path, name, value = line.split("\t", 2)
            if name == "!" or value.startswith("!"):
                lines.append(line)
                continue
            v = bytes.fromhex(value)
            lines.append(f"{path}\t{name}\t{len(v)}\t{hashlib.sha256(v).hexdigest()}")
    print("\n".join(sorted(lines)))
    return 0


def xattrs(root):
    """Lines of path, name, length and sha256 of the value, sorted."""
    if not hasattr(os, "listxattr"):
        print("xattrs: this Python has no os.listxattr")
        return 1
    lines = []
    paths = [root]
    for dirpath, dirnames, filenames in os.walk(root):
        paths += [os.path.join(dirpath, n) for n in dirnames + filenames]
    for path in paths:
        rel = os.path.relpath(path, root)
        for name in os.listxattr(path, follow_symlinks=False):
            value = os.getxattr(path, name, follow_symlinks=False)
            lines.append(f"{rel}\t{name}\t{len(value)}\t{hashlib.sha256(value).hexdigest()}")
    print("\n".join(sorted(lines)))
    return 0


def erofs(root, file, dir):
    """FILE and DIR are an existing file and directory under ROOT."""
    import errno
    j = lambda p: os.path.join(root, p)
    ops = {
        "create": lambda: os.close(os.open(j("new-file"), os.O_CREAT | os.O_WRONLY, 0o644)),
        "open for write": lambda: os.close(os.open(j(file), os.O_WRONLY)),
        "truncate": lambda: os.truncate(j(file), 0),
        "unlink": lambda: os.unlink(j(file)),
        "chmod": lambda: os.chmod(j(file), 0o600),
        "chown": lambda: os.chown(j(file), 1, 1),
        "utime": lambda: os.utime(j(file), (0, 0)),
        "rename": lambda: os.rename(j(file), j("renamed")),
        "link": lambda: os.link(j(file), j("new-link")),
        "symlink": lambda: os.symlink("x", j("new-symlink")),
        "mkdir": lambda: os.mkdir(j("new-dir")),
        "rmdir": lambda: os.rmdir(j(dir)),
        "mkfifo": lambda: os.mkfifo(j("new-fifo")),
    }
    bad = 0
    for name, op in ops.items():
        try:
            op()
            print(f"erofs: {name}: succeeded")
            bad += 1
        except OSError as e:
            if e.errno != errno.EROFS:
                print(f"erofs: {name}: {errno.errorcode.get(e.errno, e.errno)}, not EROFS")
                bad += 1
    print(f"erofs: {len(ops) - bad} of {len(ops)} writes refused with EROFS")
    return 1 if bad else 0


def lookups(root):
    import errno
    bad = 0
    for missing in ("no-such-name", "blocks/no-such-name", "no-such-dir/x"):
        try:
            os.lstat(os.path.join(root, missing))
            print(f"lookups: {missing}: exists")
            bad += 1
        except OSError as e:
            if e.errno != errno.ENOENT:
                print(f"lookups: {missing}: {errno.errorcode.get(e.errno)}, not ENOENT")
                bad += 1
    def same(a, b):
        try:
            sa, sb = os.stat(a), os.stat(b)
        except OSError as e:
            print(f"lookups: {e}")
            return False
        return (sa.st_ino, sa.st_dev) == (sb.st_ino, sb.st_dev)
    parent = os.path.dirname(os.path.abspath(root))
    if not same(os.path.join(root, ".."), parent):
        print(f"lookups: {root}/.. is not {parent}")
        bad += 1
    subdirs = [n for n in sorted(os.listdir(root))
               if os.path.isdir(os.path.join(root, n)) and not os.path.islink(os.path.join(root, n))]
    if not subdirs:
        print("lookups: the root has no subdirectory to check .. from")
        bad += 1
    for sub in subdirs:
        if not same(os.path.join(root, sub, ".."), root):
            print(f"lookups: {sub}/.. is not the root")
            bad += 1
    print("lookups: ok" if not bad else f"lookups: {bad} wrong")
    return 1 if bad else 0


def mmap_hashes(files):
    import mmap
    for path in files:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size == 0:
                digest = hashlib.sha256(b"").hexdigest()
            else:
                with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
                    digest = hashlib.sha256(m).hexdigest()
        print(f"{digest}\t{path}")
    return 0


def stat_names(d, names):
    for name in names:
        try:
            os.lstat(os.path.join(d, name))
            print(f"{name}\tfound")
        except OSError as e:
            print(f"{name}\t{errno.errorcode.get(e.errno, e.errno)}")
    return 0


# By name, as each system numbers them its own way.
STATVFS_FLAGS = ("ST_RDONLY", "ST_NOSUID", "ST_NODEV", "ST_NOEXEC", "ST_SYNCHRONOUS",
                 "ST_MANDLOCK", "ST_WRITE", "ST_APPEND", "ST_IMMUTABLE",
                 "ST_NOATIME", "ST_NODIRATIME", "ST_RELATIME")


def statvfs_flags(path):
    flags = os.statvfs(path).f_flag
    print(" ".join(n for n in STATVFS_FLAGS if flags & getattr(os, n, 0)) or "none")
    return 0


def _storm(args):
    seed, secs, paths = args
    rng = random.Random(seed)
    end = time.time() + secs
    count, errors = 0, {}
    while time.time() < end:
        try:
            os.lstat(rng.choice(paths))
        except OSError as e:
            name = errno.errorcode.get(e.errno, str(e.errno))
            errors[name] = errors.get(name, 0) + 1
        count += 1
    return count, errors


def stat_storm(secs, procs, paths):
    import multiprocessing
    with multiprocessing.Pool(procs) as pool:
        results = pool.map(_storm, [(i, secs, paths) for i in range(procs)])
    errors = {}
    for _, e in results:
        for k, v in e.items():
            errors[k] = errors.get(k, 0) + v
    print(f"stats={sum(c for c, _ in results)} errors={errors}")
    return 0


def mount_walk(translator, mntroot, timeout, images):
    """Guest side of the fuzz check.  Each image gets its own mount point,
    so a translator that hangs does not block the next image.  A result
    line is  image<TAB>outcome<TAB>detail  with outcome one of: refused
    (the translator's own message, non-zero exit), served (mounted, walked,
    still alive), crash (no own message, or dead after the walk), hang (a
    step timed out)."""
    import subprocess
    timeout = int(timeout)
    prefix = translator + ": "
    def run(cmd):
        try:
            p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=timeout)
            return p.returncode, p.stdout.decode(errors="replace")
        except subprocess.TimeoutExpired:
            return None, "timed out"
    for image in images:
        name = os.path.basename(image)
        mnt = os.path.join(mntroot, name)
        os.makedirs(mnt, exist_ok=True)
        # The active translator inherits settrans's output, so a pipe
        # would never close on a successful mount; use a file.
        log = mnt + ".log"
        with open(log, "w") as f:
            try:
                rc = subprocess.run(["settrans", "-ac", mnt, translator, "--readonly",
                                     "-T", "file", image], stdin=subprocess.DEVNULL,
                                    stdout=f, stderr=subprocess.STDOUT, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                rc = None
        with open(log, errors="replace") as f:
            out = f.read()
        one = " ".join(out.split())[:200]
        if rc is None:
            print(f"{name}\thang\tsettrans: {one}", flush=True)
            continue
        if rc != 0:
            ok = prefix in out and "Assertion" not in out and "signal" not in out
            print(f"{name}\t{'refused' if ok else 'crash'}\t{one}", flush=True)
            continue
        rc, out = run([sys.executable, os.path.abspath(__file__), "walk", mnt])
        if rc is None:
            print(f"{name}\thang\twalk", flush=True)
            continue
        walked = out.strip().splitlines()[-1] if out.strip() else "no output"
        rc, out = run(["fsysopts", mnt])
        if rc != 0:
            print(f"{name}\tcrash\tdead after the walk ({walked}); fsysopts: {' '.join(out.split())[:100]}", flush=True)
            continue
        run(["settrans", "-g", mnt])
        print(f"{name}\tserved\t{walked}", flush=True)
    return 0


def copy(src, dst):
    """cp -a, minus names past NAME_MAX, which a Linux directory can't hold."""
    import shutil
    def ignore(_, names):
        return [n for n in names if len(os.fsencode(n)) > NAME_MAX]
    shutil.copytree(src, dst, symlinks=True, ignore=ignore, dirs_exist_ok=True)


def _blank(lines, ignore):
    """Replace the ignored fields of full manifest lines by "*"."""
    out = []
    for line in lines:
        e = parse_full(line)
        for item in ignore:
            t, _, field = item.rpartition(":")
            if field not in FULL_FIELDS:
                raise SystemExit(f"compare: unknown field {field}")
            if not t or e["type"] == t:
                e[field] = "*"
        out.append(format_full(e))
    return out


def hurd_dev(in_path, out_path):
    """Copy the full manifest IN_PATH to OUT_PATH with each device number
    as the Hurd's dev_t holds it: glibc on the Hurd keeps an 8-bit major
    number and a minor number without its bits 8 to 15 (mmmmMMmm).  Print
    the entries whose number does not fit, which no translator can show
    as Linux does."""
    out = []
    with open(in_path) as f:
        for line in f.read().splitlines():
            e = parse_full(line)
            if e["rdev"] != "-":
                major, minor = (int(x) for x in e["rdev"].split(","))
                held = f"{major & 0xff},{minor & 0xffff00ff}"
                if held != e["rdev"]:
                    print(f"{e['path']}\t{e['rdev']}\t{held}")
                    e["rdev"] = held
            out.append(format_full(e))
    with open(out_path, "w") as f:
        f.write("".join(l + "\n" for l in out))
    return 0


def compare(a_path, b_path, content_only=False, ignore=()):
    with open(a_path) as f:
        a = f.read().splitlines()
    with open(b_path) as f:
        b = f.read().splitlines()
    if ignore:
        a, b = _blank(a, ignore), _blank(b, ignore)
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
        if "--full" in argv:
            print("\n".join(full_manifest(argv[2])))
        else:
            print("\n".join(manifest(argv[2], mtimes="--no-mtime" not in argv)))
        return 0
    if len(argv) == 3 and argv[1] == "walk":
        return walk(argv[2])
    if len(argv) == 3 and argv[1] == "xattrs":
        return xattrs(argv[2])
    if len(argv) == 4 and argv[1] == "hurd-dev":
        return hurd_dev(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "xattrs-from-probe":
        return xattrs_from_probe(argv[2])
    if len(argv) == 5 and argv[1] == "erofs":
        return erofs(argv[2], argv[3], argv[4])
    if len(argv) == 3 and argv[1] == "lookups":
        return lookups(argv[2])
    if len(argv) >= 3 and argv[1] == "mmap":
        return mmap_hashes(argv[2:])
    if len(argv) >= 4 and argv[1] == "stat-names":
        return stat_names(argv[2], argv[3:])
    if len(argv) == 3 and argv[1] == "statvfs-flags":
        return statvfs_flags(argv[2])
    if len(argv) >= 5 and argv[1] == "stat-storm":
        return stat_storm(float(argv[2]), int(argv[3]), argv[4:])
    if len(argv) >= 6 and argv[1] == "mount-walk":
        return mount_walk(argv[2], argv[3], argv[4], argv[5:])
    if len(argv) >= 4 and argv[1] == "compare":
        ignore = ()
        if "--ignore" in argv:
            ignore = argv[argv.index("--ignore") + 1].split(",")
        return compare(argv[2], argv[3], content_only="--content-only" in argv,
                       ignore=ignore)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
