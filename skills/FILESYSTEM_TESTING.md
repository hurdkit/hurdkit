# Skill: Test a Hurd filesystem translator against Linux

## Trigger

Use this skill when you change a disk filesystem translator (`fatfs` in a
Hurd tree, or `exfatfs` in its own repo) and need to prove that it reads and writes images the
way Linux does. Also use it when you add a filesystem to the test.

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

The run ends with `exfatfs-test: N passed, M failed` and exits non-zero on
any failure. Each `PASS` and `FAIL` line names one check. The work files
(images, manifests, the written image) stay in `img/tmp/exfatfs-test/`
for inspection, and the QEMU log is `img/tmp/exfatfs-test-qemu.log`.

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
   its own repo, like exfatfs, needs its own toolchain target and its own
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
