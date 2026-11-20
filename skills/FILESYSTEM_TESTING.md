# Skill: Test a Hurd filesystem translator against Linux

## Trigger

Use this skill when you change a disk filesystem translator (`fatfs` in a
Hurd tree, or `exfatfs` or `squashfs` in its own repo) and need to prove
that it reads and writes images the way Linux does. Also use it when you
add a filesystem to the test. `make exfatfs-test` covers fatfs and exfatfs.
`make squashfs-test` covers squashfs and is described in
[The squashfs test](#the-squashfs-test).

## Run the test

`make exfatfs-test` builds the translators, boots a throwaway overlay of
the packages image, and runs `scripts/exfatfs_test.sh`:

```sh
make exfatfs-test EXFATFS_DIR=~/src/exfatfs        # fatfs and exfatfs
make exfatfs-test FS=fat                           # the fatfs control only
make exfatfs-test FS=exfat                         # exfatfs only
make exfatfs-test EXFAT_WRITE=0                    # exFAT read checks only
make exfatfs-test REUSE=1                          # rerun against a failed run's guest
```

fatfs is built from `HURD_TREE`, by default the pinned `3p/hurd`.
exfatfs is built from its own repo,
[exfatfs](https://github.com/hurdkit/exfatfs), checked out at
`EXFATFS_DIR`.

`FS=fat` builds and tests fatfs alone. With the pinned tree it builds,
but `fat: mount` fails until the fatfs fix lands (see Gotchas).

The run ends with `exfatfs-test: N passed, M failed` and exits non-zero on
any failure. Each `PASS` and `FAIL` line names one check.

A check can also end `KNOWN`: it fails because of a gap in an interface
outside the translator, such as glibc's, which the translator cannot
close. `known NAME REASON STATUS` in `scripts/fs_test_lib.sh` records it.
A known check still runs its comparison, and STATUS is the comparison's
exit status. While the comparison fails, the check prints `KNOWN` with
the reason, the summary counts it apart (`N passed, 0 failed, 2 known
gaps`), and the run does not fail. When the comparison passes, the gap
has closed, and the check fails with `known gap closed; promote this
check` until it is made an ordinary `pass`/`fail` check. Use `known` only
for a gap the translator cannot fix, and give the reason with the file
or interface that causes it.

The work files (images, manifests, the written image) stay in
`img/tmp/exfatfs-test/` for inspection, and the QEMU log is
`img/tmp/exfatfs-test-qemu.log`.

The target takes these variables:

| Variable | Default | Meaning |
|---|---|---|
| `HURD_TREE` | `3p/hurd` | Hurd source tree fatfs is built from |
| `EXFATFS_DIR` | `~/src/exfatfs` | Checkout of the exfatfs repo |
| `TEST_IMG` | `img/hurd.packages.qcow2` | Image the guest overlay is based on |
| `SSH_KEY_DIR` | `img/keys` | Directory that holds `root_ed25519` |
| `SSH_PORT` | `2222` | Host port forwarded to the guest's sshd |
| `BUILD` | `~/work/x86_64-gnu-build` | Cross build root; fatfs goes to `$(BUILD)/hurd-translators` |
| `FS` | `fat exfat` | Filesystems to build and test |
| `EXFAT_WRITE` | `1` | `0` skips the exFAT write checks |
| `REUSE` | `0` | `1` runs the checks against the guest a failed run left running |
| `GUEST_TIMEOUT` | `300` | Seconds each guest step may take before its check fails |

If another guest already uses port 2222, pass a free `SSH_PORT`. Two runs
from the same checkout share `img/tmp/exfatfs-test-qemu.pid` and cannot
run at the same time. Give each concurrent run its own checkout and its
own `BUILD`. `make exfatfs` builds in `EXFATFS_DIR` itself, so
concurrent runs also need their own exfatfs checkout.

### After a failed run

A failed run leaves its guest running, so you can inspect the mounts with
the `ssh` command it prints. The next run refuses to start while that
guest is up. Do one of these:

- Run again with `REUSE=1`. The checks run against the same guest. The
  run first clears every mount point the test uses, then copies the
  translators and images again. A successful `REUSE=1` run also leaves
  the guest running.
- Stop the guest with `/bin/kill $(cat img/tmp/exfatfs-test-qemu.pid)`,
  then run without `REUSE`. Do this when a translator in the guest is
  stopped or hung, because clearing its mount point would hang too.

A guest step that fails (an `ssh` or `scp` error, a crashed translator, or
a step that takes longer than `GUEST_TIMEOUT`) fails the check it belongs
to. The run still prints the summary and keeps the guest.

The host loop mounts all use `img/tmp/exfatfs-test/mnt`. The script
unmounts it on exit and before it deletes the work directory, so an
aborted run does not leave a loop mount behind.

## How the translators are built

`make -C toolchain fs-translators` copies `HURD_TREE` to
`$(BUILD)/hurd-translators-src`, configures the copy out of tree for
`x86_64-gnu`, builds the libraries a libdiskfs translator links, and
builds `fatfs/fatfs.static`. The binaries are static, so they run in the
guest whatever Hurd libraries the Debian image ships. The `storeio` target
uses the same `hurd-configure` recipe.

`make -C toolchain exfatfs` runs `make` in `EXFATFS_DIR` with
`HURD_PREFIX` set to the cross prefix, the way the `9pfs` target builds
`3p/9pfs`. The exfatfs repo links libdiskfs, libstore, and libhurdbugaddr
from the prefix. The `hurd` stage does not install them, so the
`libdiskfs` target installs them from `3p/hurd` the first time. The
static binary links the store types that the prefix's libstore has:
`device` and `remap`, plus `gunzip` if zlib was in the prefix when
libstore was built. The target does not clean `EXFATFS_DIR` first, so
`make` there rebuilds only what changed. Run `make exfatfs-clean` to
force a full rebuild, for example after the prefix's libdiskfs changes.

`make -C toolchain squashfs` builds `SQUASHFS_DIR` the same way. It runs
`compress-libs` first (see
[How the compression libraries are built](#how-the-compression-libraries-are-built)),
so a first `libdiskfs` build finds zlib and libstore gets `gunzip`. It
asks the squashfs repo for all five compressors, so a missing library
fails the build instead of leaving its compressor out. It does not clean
first either; `make squashfs-clean` forces a full rebuild.

The top-level target builds only the translators that `FS` names
(`<fs>fs` for each `<fs>`). Before any build step it checks that
`HURD_TREE` has each in-tree one, and stops if not.

The copy and the build directory are recreated on every run, so a run
never depends on an earlier build. A full build takes about 15 seconds of
wall time on a 12-thread host. The copy is taken when the build starts,
so edits to `HURD_TREE` after that point are not in the binaries.

The copy is `cp -a`, so it includes any build products in `HURD_TREE`. A
tree that was configured and built in place (it has a `config.status`)
still works: a test with such a copy of `3p/hurd` built fatfs, because
the out-of-tree build compiles every object again in its own directory.

## What the test checks

The fatfs run is the control. It proves the build, the copy into the
guest, and the file-store mount before exfatfs is judged.

| Check | What must hold |
|---|---|
| `fat: mount` | fatfs mounts a FAT16 image read-only on a file store |
| `fat: manifest` | Every file's type, size, and sha256 match the host's copy (by content, since fatfs serves only 8.3 names) |
| `exfat: mount` | exfatfs mounts the exFAT image read-only |
| `exfat: manifest` | Every path's type, size, mtime, and sha256 match the Linux kernel driver's view |
| `exfat: case-insensitive lookup` | `MixedCase.TXT` and `mixedcase.txt` open the same file |
| `exfat: a name past NAME_MAX is hidden, its sibling still listed` | A 304-byte UTF-8 name is left out of the listing and its directory still lists |
| `exfat: writes refused with EROFS` | `touch` on the read-only mount fails with `Read-only file system` |
| `exfat: refuses bad-name.img` | A wrong file system name gives the translator's own error and a non-zero exit, not a crash |
| `exfat: refuses bad-checksum.img` | Same, for a wrong boot checksum |
| `exfat: refuses truncated.img` | Same, for a volume longer than its file |
| `exfat: original mount still serves after the corrupt-image attempts` | The first mount still answers |
| `exfat-rw: read-write mount` | exfatfs mounts a fresh copy read-write |
| `exfat-rw: operations` | `fs_image_test.py mutate` runs without error in the guest |
| `exfat-rw: guest view matches expected` | The guest's manifest equals the same operations applied to a host directory |
| `exfat-rw: clean unmount` | `settrans -g` succeeds |
| `exfat-rw: guest view after remount` | The manifest is unchanged after a remount |
| `exfat-rw: fsck.exfat clean, VolumeDirty cleared` | `fsck.exfat -n` accepts the written image, and VolumeDirty is clear after the clean unmount |
| `exfat-rw: Linux reads back what Hurd wrote` | The Linux driver's manifest of the written image equals the expected one |
| `exfat-rw: a dirty volume is written with a warning and stays dirty` | A volume with VolumeDirty set mounts writable and says it was not unmounted cleanly and to run `fsck.exfat`, as the Linux driver does; after a write and `settrans -g`, VolumeDirty is still set and `fsck.exfat -n` accepts the image |
| `exfat-rw: Linux reads back what Hurd wrote to the dirty volume` | The Linux driver reads the file written there |
| `exfat-rw: reading a read-write mount leaves the image unchanged` | Reads on a read-write mount write no byte to the image |

`scripts/fs_image_test.py` runs on both the host and the guest, so the
manifest format is the same on both sides. A manifest line is
`type size mtime sha256 path`, tab separated and sorted by path.
`fs_image_test.py compare` refuses an empty manifest as a match.

The test tree (`fs_image_test.py tree`) has one entry per reader path:
an empty file, files of one cluster and one cluster plus one byte, a 5 MiB
file, a 204-character name, BMP and surrogate-pair names, a name of
exactly 255 UTF-8 bytes, 300 entries in one directory, and a file whose
clusters are not contiguous.

## The oracles

The test trusts three programs that do not share code with the Hurd:

- The Linux kernel exfat driver, through `sudo mount -t exfat -o loop`.
  It fills the source image and reads back the image that Hurd wrote.
  The mounts use `time_offset=0`, so mtimes compare as UTC.
- `fsck.exfat -n` from exfatprogs. It checks the source image before the
  guest sees it and the written image after.
- `filefrag`, through sudo. It proves that `frag.bin` has more than one
  extent. If it does not, the run stops before the guest boots.

The expected state after the write operations is the same operations
applied by Python to a plain host copy of the image's contents.

## Host prerequisites

- The cross toolchain in `~/opt/x86_64-gnu` (`make toolchain`) and
  autoconf and automake for the out-of-tree configure.
- The packages image and its keys (`make packages`).
- Passwordless sudo for `mount`, `umount`, and `filefrag`, and the Linux
  `exfat` kernel module.
- `exfatprogs` (`mkfs.exfat`, `fsck.exfat`), `dosfstools` (`mkfs.vfat`),
  `mtools` (`mcopy`), and `e2fsprogs` (`filefrag`).
- Python 3.9 or later on the host. The guest gets `python3` from the
  packages stage.

## Add a filesystem

1. Make sure the translator is the directory `<fs>fs` in the Hurd tree
   and that the directory builds `<fs>fs.static`. The build and the test
   both derive the name from the entry `<fs>` in `FS`. A translator in
   its own repo, like exfatfs or squashfs, needs its own toolchain target and its own
   branch in the `bins` loop of the script instead.
2. Add a `case` branch to the image loop in `scripts/exfatfs_test.sh`. It
   must leave `$WORK/<fs>.img` and the host's manifest in
   `$WORK/host-<fs>.txt`. Build the image with a tool that does not share
   code with the translator, and take the manifest from an independent
   reader of the image.
3. Add `<fs>` to the default `FS` in the top-level `Makefile` and in the
   script, and `<fs>fs` to the default `FS_TRANSLATORS` in
   `toolchain/Makefile`.

The mount and manifest checks then run for the new filesystem. Add checks
for its own behavior after the exFAT blocks, with a `pass` or `fail`
line per check.

## The squashfs test

`make squashfs-test` checks the read-only `squashfs` translator against
the Linux kernel squashfs driver. The goal is parity with Linux: the
guest's view of every image must equal the Linux view, field by field.

### Run it

```sh
make squashfs-test SQUASHFS_DIR=~/src/squashfs    # build, boot, run every check
make squashfs-test REUSE=1                         # rerun against a failed run's guest
make squashfs-test FUZZ_SEED=7 FUZZ_COUNT=500
```

The translator comes from its own repo,
[squashfs](https://github.com/hurdkit/squashfs), checked out at
`SQUASHFS_DIR`. The target builds it with `make squashfs` (see
[How the translators are built](#how-the-translators-are-built)) and
takes `squashfs.static` from that checkout. `make squashfs` builds in
`SQUASHFS_DIR` itself, so concurrent runs need their own squashfs
checkout. The other variables are the ones in the table above
(`TEST_IMG`, `SSH_KEY_DIR`, `SSH_PORT`, `REUSE`, `GUEST_TIMEOUT`), plus:

| Variable | Default | Meaning |
|---|---|---|
| `SQUASHFS_DIR` | `~/src/squashfs` | Checkout of the squashfs repo |
| `FUZZ_SEED` | `1` | Seed of the fuzz images; copy k of seed s is the same on every run |
| `FUZZ_COUNT` | `200` | Number of fuzz images |
| `SQUASHFS_BIN` | `~/src/squashfs/squashfs.static` | Script only: the binary used as the translator; the target sets it to `SQUASHFS_DIR/squashfs.static` |
| `LINK_SECS` | `60` | Script only: how long the hard-link check runs its 16 processes of lookups |
| `CROSS_CC` | `~/opt/x86_64-gnu/bin/x86_64-gnu-gcc` | Script only: compiler for `scripts/fs_probe.c` |

To check the harness itself, or to run it without a build, call the
script with any binary as the translator:

```sh
SQUASHFS_BIN=/path/to/stub SSH_PORT=2241 SSH_KEY_DIR=... BASE_IMG=... \
    bash scripts/squashfs_test.sh
```

The work files stay in `img/tmp/squashfs-test/`: the source trees
(`src-*`), the images (`img/`, `corrupt/`, `fuzz/`), the expected,
Linux and guest manifests (`expect-*.txt`, `linux-*.txt`,
`guest-*.txt`), each comparison's diff (`compare-*.txt`) and the fuzz
results (`fuzz-results.txt`). The QEMU log is
`img/tmp/squashfs-test-qemu.log` and the pidfile
`img/tmp/squashfs-test-qemu.pid`.

### The images

`scripts/squashfs_images.py` writes four source trees and the pseudo
definitions for each. mksquashfs builds the images without root: owners,
device nodes, modes that the user cannot read and xattrs come from
pseudo definitions (`-pf`). One list in the script (`pseudo_defs`)
produces both the definitions and the changes to the expected manifest,
so the two cannot disagree.

| Tree | What it holds | Images |
|---|---|---|
| `main` | Empty and 1-byte files; files one byte under, at and over 4 KiB, 128 KiB and 1 MiB; a 5 MiB random file; an 8 MiB compressible file; two identical files; sparse files with holes inside and at the end; 3500 entries in one directory; 40 nested directories; an empty directory; 255-byte ASCII and UTF-8 names; other UTF-8 names; short, 1500-byte, dangling and directory symlinks; three hard links to one file; a fifo; a socket; char and block devices, some with large major and minor numbers; 300 files with distinct uids and gids; setuid, setgid and sticky bits, mode 0000; mtimes 0, 4000000000 and 4294967295; a static Hurd binary and a shell script | One per entry of `VARIANTS`: gzip, lzo, xz, lz4 and zstd, each with default and non-default options (`-Xcompression-level`, `-Xwindow-size`, `-Xstrategy`, `-Xalgorithm`, `-Xbcj x86,arm`, `-Xdict-size`, `-Xhc`); uncompressed (`-noI -noD -noF -noX`); `-b 4K`; `-b 1M`; `-no-fragments`; `-always-use-fragments -tailends`; `-no-duplicates`; `-no-exports -no-sparse` |
| `wide` | 72173 inodes in 71 directories, 4201 distinct ids (the id table spans three metadata blocks), and a 5 GiB sparse file with data across the 4 GiB boundary | `wide.img` (gzip) |
| `xattr` | `user.*`, `trusted.*` and `security.*` xattrs on files and a directory, a 6148-byte value, 120 xattrs on one file, two files with the same set, an empty value | `xattr.img` (xz) |
| `small` | A few files, a compressible multi-block file, one fragment, three ids | `small.img` (gzip), the source of the corrupt and fuzz images; `lzma.img` (compressor id 2, which Linux does not support); `compressor-99.img` |
| `links` | One file with 2000 names in one directory | `links.img` (gzip) |

`squashfs_images.py craft KIND IMG` writes three images by hand, field by
field, that no tool writes: `dirloop.img`, where directory `a` holds `b`
and `b` holds `a` again; `unsorted.img`, whose directory `d` lists
`a1 b2 b10 b1 c3 b4` in that order, which is not strcmp order; and
`huge.img`, whose file claims 2^62 bytes and lists one block.

### What the squashfs test checks

Every check name starts with `squash:`.

| Check | What must hold |
|---|---|
| `oracle: Linux reads NAME.img as the source tree` | Host only. The Linux manifest equals the source tree's with the pseudo definitions applied (inode numbers, st_blocks, and directory sizes and link counts left out, because the source tree cannot know them) |
| `oracle: Linux reads the xattrs of the pseudo definitions` | Host only. Every xattr, read as root, has the defined length and sha256 |
| `oracle: unsquashfs extracts gzip.img as the source tree` | Host only. `sudo unsquashfs` gives the same manifest |
| `oracle: Linux refuses lzma.img`, `... compressor-99.img` | Host only. Linux does not mount them |
| `NAME: mount` | The translator mounts the image read-only on a file store |
| `Hurd interface: every device number fits the Hurd's dev_t` | Host only, and `KNOWN` while it fails. glibc on the Hurd keeps an 8-bit major number and a minor number without its bits 8 to 15 (`mmmmMMmm`), so a device number outside that cannot reach any Hurd program. This check lists the image's numbers that do not fit, which the test tree has (`dev/big-numbers`, `dev/disk-high`) |
| `NAME: manifest matches Linux` | The guest's full manifest equals the Linux one in every field: type, size, mtime, sha256, mode with setuid, setgid and sticky bits, uid, gid, nlink (directories too), device numbers as the Hurd's `dev_t` holds Linux's (`fs_image_test.py hurd-dev`), symlink target, inode number and st_blocks |
| `lookups: a missing name gives ENOENT, .. at the root leaves the mount` | `lstat` of missing names gives ENOENT; `ROOT/..` is the mount point's parent; `DIR/..` is the root |
| `readdir (readdir1) of X lists each entry once` | `fs_probe readdir1` lists the root and the 3500-entry directory with one `dir_readdir` RPC per entry; the names equal Linux's, `.` and `..` included, each once |
| `readdir (seekdir 7) of X lists each entry once` | Same, reading 7 entries, then `telldir`, `closedir`, `opendir` and `seekdir` back |
| `exec a static binary from the image`, `exec a script from the image` | Both run from the mount and print their marker |
| `mmap reads the same bytes as Linux` | The sha256 of five files read through `mmap` equals Linux's |
| `writes refused with EROFS` | Create, open for write, truncate, unlink, chmod, chown, utime, rename, link, symlink, mkdir, rmdir and mkfifo all fail with EROFS |
| `8 parallel readers get the single reader's manifest` | Eight full manifests taken at once all equal the one taken alone, so a concurrency bug shows apart from a reader bug |
| `statvfs gives the flags Linux gives` | `os.statvfs` of the gzip mount sets the same `ST_*` flags, by name, as on Linux (`ST_RDONLY ST_RELATIME`; Linux and the Hurd number them differently) |
| `xattr: user, trusted and security xattrs match Linux` | `KNOWN` while it fails: glibc's `hurd/xattr.c` passes only `gnu.*` names. `fs_probe xattrs` (glibc `llistxattr` and `lgetxattr`, as any Hurd program sees them) must list the same names, lengths and sha256 of values as Linux, for every entry of the image |
| `hard links: 16 processes of lookups for Ns, and the mount still answers` | 16 processes `lstat` random names of `links.img` for `LINK_SECS` seconds without an error, under a time bound, and a `ls` of the mount then answers. A translator that locks the child and then the directory again, against the order of libdiskfs's name cache, wedges within seconds |
| `a directory loop gives EIO, and 16 processes walking it do not hang the mount` | `a/b/a` of `dirloop.img` gives EIO (Linux gives ELOOP), 16 processes `lstat` paths through the loop and their `..` for 30 s, and the mount then answers; refusing the image passes too |
| `a directory not in strcmp order: the names Linux finds are found` | For each name of `unsorted.img`'s `d`, a lookup finds it or gives the same errno as on Linux, whose lookup stops only at an entry whose first byte sorts after the name's |
| `a file claiming 2^62 bytes gives EIO` | `lstat` of `huge.img`'s file gives EIO within a time bound, and the mount then answers; refusing the image passes too. Linux is not asked: reading that file hangs Linux 7.0's reader |
| `refuses lzma.img, naming the compressor`, `refuses compressor-99.img, ...` | The mount fails with the translator's own message, which names `lzma` or `99` |
| `corrupt NAME.img: at least as strict as Linux` | See below |
| `the gzip mount still serves after the corrupt images` | The first mount still answers |
| `fuzz: N corrupted images, no crash or hang` | See below |
| `clean unmount (settrans -gR) of every mounted image` | Every `settrans -gR` succeeds. `-R` because a lookup of a fifo starts `/hurd/fifo` on it below the mount, and plain `-g` then fails with EBUSY; tmpfs does the same |

The corrupt images are copies of `small.img`: truncated at half of
`bytes_used`, a bad magic, version 3.1, an id table offset past the end,
and one bit flipped in the middle of the first metadata block of the
inode, directory, fragment and id tables and in the first data block.
Before the guest boots, the run records what Linux does with each:
`refused` (no mount), `errors` (mounts, some access fails) or `served`
(every access succeeds). Where Linux refuses or errors, the translator
must refuse the mount with its own message or fail an access. Where
Linux serves, the translator may serve. It must never crash or hang:
after a walk the translator must still answer `fsysopts`. Linux serves
some of these images (it lists an empty root for the directory-table
flip, and the id table of `small.img` is stored uncompressed, so a flip
changes a uid). The recorded levels are printed as `Linux on corrupt
NAME.img: LEVEL`.

The fuzz images are `FUZZ_COUNT` copies of `small.img` with 1 to 4
random bytes replaced. `fs_image_test.py mount-walk` runs in the guest,
mounts each on its own mount point (so a hung translator does not block
the next), walks it, and checks that the translator is still alive. Each
image ends `refused`, `served`, `crash` or `hang`. Any `crash` or `hang`
fails the check, and the message names the seed. The results are in
`fuzz-results.txt`, one line per image.

### Proving the harness

Every guest check must fail, not error out, when the translator is
missing or wrong. To see the red run, use a stub as `SQUASHFS_BIN`, for
example a script that serves an empty directory:

```sh
printf '#!/bin/sh\nexec /hurd/tmpfs 64M\n' > /tmp/stub && chmod 755 /tmp/stub
SQUASHFS_BIN=/tmp/stub ... bash scripts/squashfs_test.sh
```

The `oracle:` checks still pass with a stub. They prove the oracles, not
the translator.

### How the compression libraries are built

The translator links zlib, liblzma, liblzo2, liblz4 and libzstd
statically. `make compress-libs` (`make -C toolchain compress-libs`, stages
`zlib`, `xz`, `zstd`, `lz4`, `lzo`) downloads each pinned release tarball
into `~/work/x86_64-gnu-src`, checks its sha256 against the value in
`toolchain/Makefile`, builds it in a fresh `$(BUILD)/<lib>` with the cross
compiler and installs the headers, the `.a` and the `.pc` file into
`~/opt/x86_64-gnu`. No shared objects are installed. liblzma is built
without the xz tools, and libzstd without threads. A stage skips when its
`.a` is installed, and its gate links a static GNU/Hurd program that
calls the library. To move to a new release, change the `*_VER` and
`*_SHA256` lines together.

### squashfs host prerequisites

- squashfs-tools 4.6 or later (`mksquashfs`, `unsquashfs`).
- A Linux kernel with squashfs and all five decompressors
  (`CONFIG_SQUASHFS_{ZLIB,LZO,XZ,LZ4,ZSTD}`) and `CONFIG_SQUASHFS_XATTR`.
- Passwordless sudo for `mount`, `umount`, `unsquashfs`, `rm` (of the
  extraction) and `python3` (to read files the user cannot read, and
  `trusted.*` xattrs).
- About 1 GB free under `img/tmp`, and a host filesystem with sparse
  files and `user.*` xattrs for the source trees.
- The cross compiler, for `scripts/fs_probe.c`.

### squashfs gotchas

- mksquashfs 4.6.1 corrupts its heap when it decodes a long hex (`0x`)
  xattr value in a pseudo definition, and it rejects an empty value. The
  builder encodes values in base64 (`0s`), and the empty value comes from
  a `user.*` xattr on the source file.
- A pseudo modify (`M`) of a directory conflicts with pseudo definitions
  of entries inside it, and mksquashfs then ignores it.
- mksquashfs cannot read a file the user cannot read. Give the source
  file a readable mode and set the real mode with a pseudo `M`.
- Do not loop-mount `huge.img` on the host and read its file: Linux 7.0
  serves the 2^62-byte size, and a `dd` of its first MiB stays in D state
  (the reader waits on a page that never completes).
- mksquashfs pads the image to 4 KiB, so a truncation must cut
  `bytes_used`, not the file length, or it removes only padding.
- The guest's Python (3.14) reads at most 1024 bytes in `os.readlink`
  (its `MAXPATHLEN`), so the 1539-byte symlink came back truncated.
  `fs_image_test.py` falls back to `readlink(1)` when the target is
  shorter than `st_size`.
- The guest's Python has no `os.listxattr`, so the guest side of the
  xattr check uses `fs_probe xattrs` (glibc's `llistxattr` and
  `lgetxattr`).

## Gotchas

- `ssh guest "settrans -a ..."` never returns when the mount succeeds. The
  active translator inherits settrans's stdout and stderr, and ssh waits
  for every holder of the channel. `mount_fs` in the script sends the
  output to a log file in the guest and prints it afterwards. Do the same
  in any new guest command that starts a translator.
- Do not `pkill -f` a script name from an agent's shell. The shell has
  the same string on its command line and kills itself. Stop QEMU with the
  pid in `img/tmp/exfatfs-test-qemu.pid`.
- Upstream fatfs reads the 32-bit fields `total_sectors_32` and
  `sectors_per_fat_32` with `read_word`, which reads 16 bits, so a FAT32
  volume fails or gets a truncated size. hurdkit/hurd#55 (branch
  `fatfs-32bit-boot-fields`) fixes this. `total_sectors_32` is also used
  by FAT16 volumes of more than 65535 sectors, and the 64 MiB control
  image is one, so with the pinned `3p/hurd` (no fix) `fat: mount` fails
  with `Number of total sectors is zero`. Run the control with a
  `HURD_TREE` that has the fix.
- exfat-fuse always asks for `allow_other`, so it cannot mount without
  root unless `user_allow_other` is set. The test uses the kernel driver.
- The kernel exfat driver does not fill freed gaps first. To get a
  fragmented file, `fs_image_test.py fragment` fills the volume, frees
  every other file, then writes.
- Linux cannot create a name longer than 255 UTF-8 bytes. The test creates
  a 104-character placeholder and `fs_image_test.py patch-long-name`
  rewrites it on the image to 100 CJK characters (304 bytes), fixing the
  name hash and the set checksum. `fsck.exfat` then checks the result.
