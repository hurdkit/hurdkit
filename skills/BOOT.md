# Skill: Boot and Provision the Debian GNU/Hurd Image

## Trigger

Use this skill whenever work touches the Hurd disk image or its boot path:

- building or refreshing `img/hurd.base.qcow2` (`make base`) or the staged
  images on top of it (`make accounts`, `make packages`, `make kernel`),
- changing what the guest does at first boot (GRUB, serial console, sshd, passwords),
- changing what the in-VM provisioning step installs or configures,
- debugging a guest that does not boot, does not answer on SSH, or whose
  base image turns out to be dirty or corrupt,
- changing the image version, the root password, the SSH port, or the disk layout.

## Inputs

- `Makefile` - pipeline definition and all tunables (version, URL, MD5, ports, password).
- `scripts/prepare_base.sh` - offline changes applied to a copy of the raw image.
- `scripts/partition.sh` - finds a partition inside a disk image by its byte offset
  (sourced by the preparation and the repair script).
- `scripts/provision_base.sh` - boots the guest and runs the provisioning.
- `scripts/provision_guest.py` - drives the guest over SSH (login, commands, poweroff).
- `scripts/provision_stage.sh` - applies one provisioning stage to an image
  and writes a new image layered on top of it (staged variants).
- `scripts/repair_filesystem.sh` - offline ext2 repair of the provisioned image.
- `img/keys/` - the SSH keys of the guest accounts (private keys, not in git).
- `img/debian-hurd-amd64-<VERSION>.img.tar.xz` - the downloaded Debian GNU/Hurd image
  (pinned to `VERSION=20260314`, MD5 `91dc71608fcfc9f237028f1fe87c39c2`).

## Goal

A reproducible pipeline that produces a clean, provisioned, bootable Hurd image
without root privileges, and that boots the guest from a throw-away overlay so
the base image stays byte-for-byte pristine:

```
download -> offline preparation -> qcow2 base -> staged images -> overlay boot
```

"Base" is the raw, offline-prepared OS image: no accounts, no SSH keys, no
guest packages. Every provisioning step lands in its own staged image
(`accounts` -> `packages` -> `kernel`), so the intermediates stay visible and
rebuilding the base propagates through the chain instead of being folded into
one image. The test harnesses snapshot the `packages` stage.

The acceptance criteria for a finished image are:

1. `make base` produces `img/hurd.base.qcow2` whose root filesystem passes
   `e2fsck -fn` (exit status 0).
2. `make accounts` and `make packages` complete and leave the same property
   (see "Known issue: ext2 without a journal" for why a repair step is needed).
3. `make run` boots the guest, SSH login as `root` with the configured password
   works, and the MD5 of `img/hurd.base.qcow2` is unchanged after the run.
4. The stage targets are idempotent: a second `make packages` is a no-op while
   the stage image is newer than its input and the scripts.

## Environment (this sandbox)

- Tools available: `qemu-img` / `qemu-system-x86_64` 10.2.3, `wget`, `tar`, `xz`,
  `python3` 3.14 with the module `pexpect` 4.9, `ssh`, `md5sum`, `debugfs` 1.47.4,
  `dumpe2fs`, `e2fsck`, `partx`, `parted`, `fuse2fs`, `fusermount`, `openssl`,
  `flock`, `qemu-nbd`, `nbdfuse`.
- Tool **not** available: `sudo`, `nbd`, `guestfish`, `virt-customize`, `socat`,
  `sshpass`, `jq` (the repair script therefore parses the plain `qemu-img info`
  output instead of its JSON output). There is no root access, so loop mounts
  and libguestfs are out; the offline write path is `debugfs` on the
  partition inside the image.
- A partition inside a disk image is addressed by its byte offset: e2fsprogs
  opens the name `IMAGE?offset=BYTES` as a filesystem, so `debugfs`, `e2fsck`
  and `dumpe2fs` work on the partition in place, through ordinary file I/O.
  `scripts/partition.sh` reads the offset from the partition table with
  `partx` (`partition_target IMAGE 2` prints the complete name). Nothing
  is compiled on the host, and the offline preparation mounts nothing.
- The Hurd sources are checked out next to the project in `hurd/`; read them
  (`hurd/ext2fs`, `hurd/libdiskfs`) when the behaviour of the translator matters.
- KVM is available at `/dev/kvm`.
- Disk layout of the image (partition table is a DOS/MBR table):
  - partition 1: swap, starts at sector 2048, 1951744 sectors,
  - partition 2: ext2 root filesystem, starts at sector 1953792, 6236160 sectors
    (byte offset 1000341504, about 3.0 GB with roughly 1.5 GB free).
  - The root filesystem has **no journal**; this matters for the shutdown path.

## Procedure

### Stage 1 - download (`make download`)

`$(IMG_TAR)` is downloaded from
`https://cdimage.debian.org/cdimage/ports/latest/hurd-amd64/debian-hurd-amd64-$(VERSION).img.tar.xz`
and checked against `MD5_SUM` before it is used.

The tarball is unpacked into `img/` by the rule for `img/.extracted`. The stamp
file exists because `tar` restores the *member* mtime of the image, which is
older than the tarball itself; without the stamp, make would consider the raw
image out of date and re-extract it on every invocation.

### Stage 2 - offline preparation (`scripts/prepare_base.sh`)

`prepare_base.sh <source.raw> <work.raw> [root_password]` never touches the
downloaded image. It copies it to `img/hurd.work.img` and edits the copy:

1. `cp --reflink=never` the raw image: a real copy, not a reflink (see
   pitfall 41).
2. Find the root filesystem inside the copy. `partition_target <work.raw> 2`
   (from `scripts/partition.sh`) prints `<work.raw>?offset=1000341504`, the
   name under which e2fsprogs opens partition 2. The script checks with
   `debugfs -R stats` that an ext2 filesystem really starts at that offset.
3. Apply the offline edits with `debugfs -w` on that name:
   - `/boot/grub/grub.cfg` - serial console and auto-boot (see below),
   - `/etc/default/grub` - the same settings, so `update-grub` keeps them,
   - `/etc/shadow` - password hash for `root`,
   - `/etc/ssh/sshd_config.d/10-local.conf` - permit root password login.

The GRUB configuration of the image is **patched, not replaced**: it knows
the kernel file, the translator modules and the filesystem UUID of the image,
and every task symbol that the modules refer to (`acpi-task`, `disk-task`,
`fs-task`, `exec-task`) has to be defined by exactly one module line. A
hand-written configuration that misses one of them makes the kernel panic
with "bootstrap script missing symbol 'acpi-task'" before the guest is up.
Three settings are changed: the menu timeout becomes 0, the GRUB output goes
to the console instead of the graphics console, and the Hurd console is put
on the serial line (`console=com0`).

The patched configuration and the kernel it refers to are checked before the
file is written into the image, and the patched `/etc/shadow` is checked as
well: the number of accounts, the number of fields per line and the new
hashes are verified, because a malformed shadow file breaks the login of
every user without any obvious error. The dumps that these checks are based
on are verified as well: `debugfs` exits 0 even when a dump fails, so a
helper checks the exit status and that the dumped file exists and is not
empty, and fails with an error that names the file (see pitfall 42).

The GRUB configuration that makes the image boot unattended is the
configuration of the image with three changes:

```
terminal_output console      # instead of gfxterm, which is invisible in a serial terminal
set timeout=0                # instead of 5 or 30, so that no key press is needed
multiboot /boot/gnumach-1.8-amd64-up.gz root=part:2:device:wd0 console=com0
```

`console=com0` hands the console to the Hurd kernel. Without these changes
the guest waits at the GRUB menu and never boots unattended.

The password hash is generated with `openssl passwd -6` (`$6$`, SHA-512).
`/etc/login.defs` of the image names `YESCRYPT` as the preferred method, but the
Hurd libc `crypt` does not support `$y$` hashes, so `$6$` is the only safe
choice. The hash uses a random salt, and the password is passed to `openssl`
through standard input so that it does not show up in the process list.

Only the `root` account gets its password here, because it is the account that
the provisioning logs in with. The account of the image is renamed during the
provisioning, and its password is set there, after the rename.

### Stage 3 - base image (`make base`)

`make base` runs the preparation under `flock img/.build.lock`, converts the work
image to qcow2 (`qemu-img convert -f raw -O qcow2`) and moves the result into
place with `mv -f`. The build therefore never leaves a half-written base image
behind, and two concurrent builds cannot interleave.

### Stage 4 - staged provisioning (`make accounts`, `make packages`)

The pipeline provisions through stages, each of which is its own qcow2
layered on the previous one. `scripts/provision_stage.sh <stage> <input>
<variant> [ssh_port]` boots the input image in a throwaway overlay, applies
the stage with `scripts/provision_guest.py`, repairs the filesystem offline
and promotes the overlay to the variant image:

```
img/hurd.base.qcow2 -> img/hurd.accounts.qcow2 -> img/hurd.packages.qcow2
                    -> img/hurd.kernel.qcow2   (kernel stage)
```

The `accounts` stage renames the account of the image, sets the passwords
and installs the SSH keys; the `packages` stage installs `GUEST_PACKAGES`
(`curl python3 gdb` by default). `make provision` is an alias for
`accounts packages`. The base image itself is never provisioned in place,
so it always means the same thing: the raw offline-prepared OS image.

### Stage 5 - legacy single-image provisioning (`scripts/provision_base.sh`)

`provision_base.sh <base.qcow2> [ssh_port]` provisions a **private copy** of the
base image and only replaces the base when everything succeeded. It is the
pre-stage flow, kept for manual single-image provisioning; the Makefile
drives the stage chain above instead.

1. `qemu-img convert` the base into `img/.provision.XXXXXX.qcow2`.
2. Boot that copy with QEMU (`if=ide`, `-device e1000`, user networking with
   `hostfwd` of the SSH port to port 22 of the guest).
3. Wait until the forwarded port accepts connections (sshd starts during boot).
4. Drive the guest over SSH with `scripts/provision_guest.py` (the login is
   retried, see pitfall 19):
   - log in as `root` with the password that was set offline,
   - `stty -echo` so that the echoed command line cannot be mistaken for
     command output,
   - `run_command <cmd> <tag>` sends a command, captures its exit status through
     a `__RC__<n>__` marker and leaves the output in the guest's
     `/tmp/provision_<tag>.log`,
   - remove the "unreleased" suite from the apt sources and hold `hurd-dev`
     (see pitfalls 29 and 30),
   - install the packages of `GUEST_PACKAGES` (`curl python3 gdb` by default) when
     one of them is missing, and verify that every one of them is there
     afterwards,
   - rename the account `demo` to `peon`, together with its group and its
     home directory (see pitfalls 36 and 37), and give the renamed account
     the configured password,
   - generate the SSH key of `root` and of `peon` on the host, if the pair does
     not exist yet, install the public key of each account in the guest, and
     verify that the key really landed in the `authorized_keys` of the account,
   - check that the login with the key of every account works; the check
     offers only the key of the account (`IdentitiesOnly=yes`), because ssh
     otherwise offers the keys of a loaded agent first (see pitfall 43),
   - if `/root/.provisioned` exists, stop here ("Image is already provisioned."),
   - otherwise run `apt-get update` and `apt-get upgrade` **only** when
     `RUN_APT_UPGRADE=1` is set, and create the marker,
   - `poweroff` the guest and wait for the SSH connection to end. The SSH
     connection dies together with the guest, so the script does not wait for
     the exit status or the shell prompt of the poweroff command.
5. Repair the ext2 filesystem offline (`scripts/repair_filesystem.sh`), see below.
6. `mv -f` the provisioned copy over `img/hurd.base.qcow2`.

The marker file `/root/.provisioned` is what makes the step idempotent. It
lives in the guest, so it survives in the base image and is visible in every
overlay booted from it.

The package upgrade is **off by default** (`RUN_APT_UPGRADE=0` in the
`Makefile`). The sid archive currently ships a `hurd-dev` that cannot be
unpacked on Hurd, and the image is perfectly usable without the upgrade, so
the default provisioning only prepares the sources and writes the marker.
Set `RUN_APT_UPGRADE=1` to run `apt-get update` and `apt-get upgrade` again;
the guest then holds `hurd-dev` and the upgrade is attempted with the old
configuration files (`--force-confold`).

The installation of the packages is **not** part of the upgrade and runs on
every provisioning. The list comes from `GUEST_PACKAGES` in the `Makefile`
(`curl python3 gdb` by default) and is passed through
`scripts/provision_base.sh` to the driver. The check is by command
(`command -v`), so the installation is skipped when every package is already
there: a provisioning of an already provisioned image stays a no-op, and a
package that is added to the list reaches the images that were provisioned
before it was added. The image ships no package lists, so `apt-get update`
runs before the installation. Installing `curl` brings the current libc and
python3 of the archive into the image (2.43 and 3.14 at the time of writing);
the pin of `hurd-dev` keeps the broken package of sid out of it.

### Stage 5 - runtime (`make run`, `make run-nokvm`)

Both targets create a temporary overlay and boot it:

```
qemu-img create -f qcow2 -b $(abspath img/hurd.base.qcow2) -F qcow2 img/tmp/XXXXXX.qcow2
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 2G \
    -drive file=<overlay>,if=ide,cache=writeback \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device e1000,netdev=net0 -nographic
```

`make run` uses KVM when `/dev/kvm` is readable and writable, and falls back
to `-cpu max` otherwise; `make run-nokvm` always runs without KVM. The overlay
is removed when QEMU exits, so an aborted run does not leave it behind.

The backing file must be an **absolute** path: `qemu-img` resolves a relative
backing path against the directory of the overlay, so `-b img/hurd.base.qcow2`
from `img/tmp/` looks for `img/tmp/img/hurd.base.qcow2`.

The base image is only ever used as a read-only backing file, so it stays
pristine; all writes land in the overlay in `img/tmp/`.

### Staged image variants (`make stage`, `scripts/provision_stage.sh`)

Provisioning stages can be applied one at a time, each producing its own
image layered on top of the previous one:

```
raw -> prepared base -> accounts -> packages -> kernel -> (drivers) -> ...
```

`provision_stage.sh <stage> <in.qcow2> <out.qcow2> [ssh_port]` boots the
input image in a throwaway overlay (the same skeleton as
`provision_base.sh`: KVM detection, port-open wait, bounded poweroff wait,
bounded SSH login retries), runs `provision_guest.py` with `STAGES=<stage>`,
repairs the filesystem offline and promotes the overlay to the output image.
A failed or interrupted stage never touches the input image: only a
successful run replaces the output, through renaming the finished overlay
into place.

The output is not flattened: it stays a thin qcow2 image that holds only the
writes of its stage and names the input image as backing file, so a stage
costs its own changes, not a copy of the whole disk. The price is that a
backing chain references its backing files by path: rebuild an upstream stage
and the images layered on it are stale. The chain targets below rebuild the
downstream stages for that reason; a variant that is only ever handed out on
its own must be flattened first (`qemu-img convert`). The input and the output
of a stage must differ.

The stages and their environment (full list in `scripts/provision_guest.py`):

- `accounts` - rename the account of the image, set passwords, install the
  SSH keys. The keys live in `SSH_KEY_DIR` (default: `keys/` next to the
  output image) and are shared across images.
- `packages` - prune the apt sources, install `GUEST_PACKAGES`, optionally
  upgrade (`RUN_APT_UPGRADE=1`; the marker gates the upgrade only).
- `kernel` - copy an overlay into the guest filesystem: the
  `CUSTOM_OVERLAY` directory (out-of-tree drivers, init scripts and
  similar extra content) and, when `CUSTOM_KERNEL` names a kernel
  binary, that kernel gzipped at the boot path
  `/boot/gnumach-1.8-amd64-up.gz`. Needs at least one of the two. The
  overlay is applied to an image created after the packages stage, never
  into the base image: the packages image keeps the stock kernel, so a
  broken variant is discarded and rebuilt from the chain rather than
  repaired in place.

The Makefile wraps this in the `stage` target (serialized with the same
image lock as the other image steps):

```
make stage STAGE=kernel VARIANT=img/hurd.kernel.qcow2 \
    CUSTOM_KERNEL=$HOME/work/x86_64-gnu-build/gnumach/gnumach
```

`STAGE_INPUT` (default: `img/hurd.base.qcow2`) names the image the stage is
applied to, `VARIANT` (default: `img/hurd.kernel.qcow2`) the image that is
produced. A stage also re-runs safely on an image that already carries it,
which makes variant rebuilds reproducible: rebuild the chain from the base
when a stage changes, or re-apply only the later stages when an early stage
changes.

Each image is thin, so `ls -la img/` shows what each stage actually wrote:
the accounts image holds the account changes, the packages image the
package installation, the kernel image the kernel stage: the base and the
earlier stages are read through the backing chain, not copied.

The standard chain is also encoded as real make targets, so make rebuilds
only the stages whose input or scripts changed:

```
img/hurd.base.qcow2 -> img/hurd.accounts.qcow2 -> img/hurd.packages.qcow2
                    -> img/hurd.kernel.qcow2   (kernel stage)
```

Building `img/hurd.kernel.qcow2` (or running `make stage` with its default
`VARIANT`) walks that chain. The accounts and packages images are pipeline
intermediates and are kept; a kernel variant is always rebuilt on top of the
packages image, never into the base.

The overlay is packed with tar on the host and extracted over `/` in the
guest, so the files land at exactly the paths they have relative to the
overlay directory and keep their modes and symlinks; ownership is
rewritten to root, since the tar would otherwise carry the host
account's uid and gid. `CUSTOM_KERNEL` travels in the same tar, gzipped
at the boot path, and is checked with `gzip -t` after the extraction, so
a corrupt kernel fails the stage instead of the next boot. The overlay
directory may not itself carry `boot/gnumach-1.8-amd64-up.gz` when
`CUSTOM_KERNEL` is set. Example layout that drops a translator, an init
script and a canary for the smoke check into the image:

```
img/overlay/
├── hurd/virtio-9p          (executable translator binary)
├── etc/init.d/virtio-9p    (mode 755)
└── root/overlay-marker     (shows up as /root/overlay-marker)
```

```
make stage STAGE=kernel VARIANT=img/hurd.kernel.qcow2 \
    CUSTOM_KERNEL=.../gnumach CUSTOM_OVERLAY=img/overlay
```

As a make prerequisite of the chain rule, `$(CUSTOM_OVERLAY)` is tracked
through the directory mtime: entries added to or removed directly from
the overlay directory trigger a rebuild, an edit deep inside does not
(re-run through the prerequisite-free `stage` target or touch the
directory).

## SSH keys

The provisioning gives `root` and `peon` an SSH key, so that the guest can be
logged into without a password:

```
img/keys/root_ed25519      private key of the root account
img/keys/root_ed25519.pub  public key of the root account
img/keys/peon_ed25519      private key of the peon account
img/keys/peon_ed25519.pub  public key of the peon account
```

The pairs are generated on the host with `ssh-keygen -t ed25519` and are never
replaced: the public key of a pair is installed in the guest, and a new pair
would lock the guest out of the key login until it is installed again. The
private keys stay in `img/`, which is not in git, so they never end up in the
repository.

The public key of an account is appended to `~/.ssh/authorized_keys` of the
account in the guest. The directory has the mode 700, the file the mode 600,
and both belong to the account, because sshd refuses the key otherwise
(`StrictModes`).

Login with a key (`IdentitiesOnly=yes` matters: ssh otherwise offers the keys
of a loaded agent first, and sshd drops the connection after six rejected
attempts - see pitfall 43):

```
ssh -o IdentitiesOnly=yes -i img/keys/root_ed25519 -p 2222 root@127.0.0.1
ssh -o IdentitiesOnly=yes -i img/keys/peon_ed25519 -p 2222 peon@127.0.0.1
```

`make ssh` and `make ssh-peon` do the same (they pass `IdentitiesOnly=yes`
when the key exists) and fall back to the password when the key does not
exist. The password of the accounts keeps working; the keys are an addition,
not a replacement.

### Offline filesystem repair (`scripts/repair_filesystem.sh`)

`repair_filesystem.sh <image> [partition]` repairs the root filesystem of a
disk image **without converting the image to a raw file**. The image is served
by `qemu-nbd`, `nbdfuse` exposes that server as a plain file with the raw
content of the disk, and `e2fsck` opens the partition inside that file by its
byte offset. Its writes travel back through the chain into the original
image:

```
qemu-nbd -k <socket> -f <format> <image>      # serve the image
nbdfuse <mnt>/disk.raw --unix <socket>        # expose it as a file
e2fsck -fy '<mnt>/disk.raw?offset=<bytes>'    # repair through the chain
```

The offset comes from `partition_target <mnt>/disk.raw <partition>` in
`scripts/partition.sh`. A raw image needs no chain: the script then runs
`e2fsck` on `<image>?offset=<bytes>` directly.

`nbdfuse` is the FUSE client of libnbd; it speaks the NBD protocol in
userspace and needs neither the kernel NBD module nor root privileges. Only
`/dev/fuse` is required. The image format is parsed from the plain output of
`qemu-img info` with `sed`, so the script needs no `jq` and the same script
works for raw and qcow2 images.

The repair needs the image not to be in use elsewhere, because `qemu-nbd`
takes an exclusive lock on it. The provisioning works on a private copy of
the base image, so this is never a problem.

Measured on the Hurd image: the repair through the chain takes about 7
seconds, while converting the 4 GB image to raw, extracting the partition,
repairing it and converting everything back takes several minutes.

## Pitfalls

Every one of these was hit while building this pipeline.

1. **Root SSH login is rejected.** The shipped `/etc/ssh/sshd_config` has
   `#PermitRootLogin prohibit-password` commented out, so the default
   `prohibit-password` applies and password authentication for root is refused.
   Fix: drop-in `/etc/ssh/sshd_config.d/10-local.conf` with `PermitRootLogin yes`
   and `PasswordAuthentication yes`. The main config contains
   `Include /etc/ssh/sshd_config.d/*.conf`, and sshd uses the first value it
   obtains, so the drop-in wins.

2. **An empty root password is not enough.** Even with `PermitRootLogin yes`,
   `PermitEmptyPasswords` defaults to `no`. The image ships `root` and its user
   account with empty password fields, so a non-empty password has to be set.

3. **Rewriting `/etc/shadow` from scratch breaks everything.** The file has one
   line per account and **nine** colon-separated fields. A rewrite that emits
   eight fields and only the root line deletes 20 accounts and makes the
   malformed entry crash the console `login` with SIGSEGV. Fix: dump the file
   with `debugfs`, replace **only field 2** of the `root` line with
   `awk -F: -v OFS=: ...`, and write it back with mode `0100640`, uid 0, gid 42
   (the `shadow` group). Note the `=` in `-v OFS=:`; `-v OFS:` is an awk usage
   error.

4. **A tool that reads the image with direct I/O does not see an unflushed
   copy.** The pipeline used to expose the partitions through the FUSE tool
   `partitionfs`, whose libparted backend bypasses the page cache: right
   after `cp` it found no partition table, so every copy had to be followed
   by `sync "$WORK_IMG"`, which blocks for minutes when the disk is busy.
   Fix: no direct I/O. `debugfs` and `e2fsck` open the partition by its
   offset (`IMAGE?offset=BYTES`) through the page cache, and the copy needs
   no `sync`.

5. **`debugfs write` cannot overwrite an existing file.** The command fails
   with "Could not create file". Fix: `rm <file>` first, then `write`.
   The debugfs command file has no shell syntax and no `#` comments.

6. **`fuse2fs` refuses to write root-owned files.** It enforces strict
   ownership, and without root privileges nothing can be written. Fix:
   `debugfs -w`, which edits the filesystem structures directly and does not
   care who owns a file, on the partition inside the image
   (`IMAGE?offset=BYTES`).

7. **The driver matches the wrong branch.** `NOT_PROVISIONED` contains the
   substring `PROVISIONED`, and the guest echoes the command line, which
   contains the marker text. Fix: never match on marker text; use the exit
   status of the command and disable the terminal echo with `stty -echo`.

8. **Concurrent builds corrupt the base image.** Running `make run` and
   `make provision` at the same time made `qemu-img convert` rewrite
   `img/hurd.base.qcow2` while QEMU had it open for writing; the result was a
   filesystem with inode and bitmap damage and an "Exec format error" for every
   binary in the guest. Fix: `flock img/.build.lock` around `base` and
   `provision`, build into a temporary file and `mv -f` it into place, and
   provision on a private copy.

9. **`apt-get` fails with "/dev/nullpartial is missing" (exit status 100).**
   Caused by `-o Dir::Cache::archives=/dev/null`, which makes apt look for the
   partial directory of the cache. Fix: keep the default cache location; the
   image has enough free space for the roughly 180 MB of downloaded packages,
   and `apt-get clean` reclaims it afterwards.

10. **`qemu-img create -b img/hurd.base.qcow2` fails** with
    "Could not open 'img/tmp/img/hurd.base.qcow2'". Fix: use
    `$(abspath $(BASE_IMG))`.

11. **make re-extracts the image on every run.** `tar` restores the older
    mtime of the image inside the tarball, so the raw image always looks older
    than the tarball. Fix: the `img/.extracted` stamp file.

12. **Stale FUSE mounts block the next run.** A FUSE tool refuses a mount
    point that still holds content ("mountpoint is not empty"), and removing
    a directory with a stale mount in it fails with "Function not
    implemented". Fix: unmount before cleanup, and use a fresh `mktemp -d`
    mount point per run. The offline preparation mounts nothing any more;
    only the repair of a qcow2 image does (`nbdfuse`).

13. **The guest has no virtio drivers.** With `if=virtio` the disk is never
    found. Fix: `if=ide` and `-device e1000` for the network.

14. **The guest does not boot unattended** without the GRUB changes of stage 2.

15. **Yescrypt hashes do not work on Hurd.** `/etc/login.defs` says
    `ENCRYPT_METHOD YESCRYPT`, but the Hurd libc `crypt` cannot verify `$y$`
    hashes, so logins fail. Fix: `openssl passwd -6` (`$6$`).

16. **The provisioned image is not clean.** See "Known issue" below.

17. **The guest prints "mount: cannot remount /: Device or resource busy"**
    during shutdown. This is harmless: the root filesystem cannot be remounted
    read-only, the guest halts anyway, and the metadata is repaired offline.

18. **The guest filesystem is small.** The root partition is about 3.0 GB with
    roughly 1.5 GB free, so package installations must not use a huge cache
    and should clean up afterwards.

19. **An open forwarded port does not mean that sshd is ready.** QEMU's
    `hostfwd` accepts the connection as soon as QEMU runs, and resets it when
    the guest has no sshd yet ("kex_exchange_identification: read: Connection
    reset by peer"). A check with `/dev/tcp` is therefore useless as a
    readiness test. Fix: retry the SSH login until it succeeds, which matters
    most without KVM, where the boot takes minutes.

20. **Converting the image to raw is the slow part of the repair.** A
    qcow2 -> raw conversion, a `dd` of the partition, the repair and the
    conversion back move more than 20 GB through the disk. Fix: serve the
    image with `qemu-nbd`, expose it with `nbdfuse`, and let `e2fsck` open
    the partition inside that file by its offset and write through the chain
    (seconds instead of minutes). The image format has to be passed to `qemu-nbd`
    explicitly, and `nbdfuse` must be told which socket to use
    (`--unix <socket>`); `qemu-nbd` has no socket activation mode, so the
    socket is created with `-k <path>` and the server is stopped explicitly
    when the repair is done.

21. **A FUSE mount has to be unmounted before its directory can be removed.**
    `fusermount3 -u` fails with "Device or resource busy" while the daemon
    is still running. Fix: stop the daemon first, unmount the mount point
    (`fusermount3 -uz` as a last resort), and only then remove the
    directory. `nbdfuse` mounts a *file*, so the mount point to unmount is
    the file, not its directory.

22. **The kernel file name must not be hardcoded.** The image ships
    `/boot/gnumach-<version>-amd64-up.gz`, and the version changes with the
    image. A hardcoded name produces an image that does not boot at all, with
    an error that does not point at the cause. Fix: read the name from the
    image and fail the preparation when no kernel is found.

23. **A script that changes does not trigger a rebuild.** make only knows
    about the files that are listed as prerequisites. Fix: the preparation
    script is a prerequisite of the base image rule, so that changing it
    rebuilds the base image.

24. **The GRUB configuration of the image must not be written by hand.** The
    module lines of the boot script define the task symbols that the other
    lines refer to (`acpi-task`, `disk-task`, `fs-task`, `exec-task`). Leave
    one of them out and the kernel panics with "bootstrap script missing
    symbol" before the guest is up - the boot then hangs with the QEMU
    process busy, and no login is possible. Fix: patch the configuration of
    the image instead of replacing it.

25. **The SSH connection dies together with the guest.** After `poweroff` the
    connection is closed, so the driver cannot wait for the exit status or for
    the end of the file a second time; the provisioning is aborted even though
    the guest did all the work. Fix: wait for the end of the file once and
    ignore the error when the connection is already closed.

26. **`$?` after `fi` is the status of the `if` statement, not of the failed
    command.** The retry loop of the provisioning used

    ```bash
    if python3 scripts/provision_guest.py; then SSH_RC=0; break; fi
    SSH_RC=$?
    ```

    The status of the `if` statement is 0 even when the condition failed, so
    every failed login attempt looked like a success. After the last attempt
    the script continued as if the guest had been provisioned and blocked
    forever in `wait "$QEMU_PID"`, because the guest was still running. This
    is what made a failed provisioning look like a dead, hanging QEMU job.
    Fix: read the status inside the `else` branch, where it is still the
    status of the condition. The driver uses the exit status 2 for a
    command that failed in the guest; that case is not retried, because the
    same guest cannot fix it.

27. **A long timeout hides a failed login.** The whole session had one
    timeout of 3600 seconds, so a connection that was reset because sshd was
    not up yet blocked for an hour instead of being retried. Fix: a short
    timeout (120 s) for the login phase, a long one for the commands, and an
    `eof` branch everywhere so that a closed connection ends the attempt
    instead of waiting for the timeout.

28. **Waiting for the guest to power off can block forever.** `wait "$QEMU_PID"`
    returns only when QEMU exits, which never happens if the guest does not
    shut down. Fix: wait in steps with a timeout, terminate QEMU when the
    timeout is exceeded, and print the QEMU log.

29. **The `hurd-dev` package of the sid archive cannot be unpacked.** The
    upgrade of the image fails with dpkg error 100:

    ```
    dpkg: error processing archive .../hurd-dev_1%3a0.9.git20261028-4_hurd-amd64.deb (--unpack):
     unable to install new version of './usr/share/libdde_linux26/build/include/linux-headers/linux/hdlc': No such file or directory
    ```

    The new version wants to replace the directory
    `.../linux-headers/linux/hdlc` with a file, which dpkg cannot do on the
    ext2 filesystem of the guest. It is not a timeout (`apt-get update`
    takes 23 s and the upgrade downloads 185 MB before it fails), not caused
    by the "unreleased" suite (the package comes from `sid/main`) and not
    caused by the number of CPUs. `dpkg --force-overwrite` and
    `apt-get -f -y install` fail in the same way. Fix: hold the package
    (`apt-mark hold hurd-dev`), pin it below zero (`Pin-Priority: -1` in
    `/etc/apt/preferences.d/99-hurd-dev`) and leave the upgrade disabled by
    default (`RUN_APT_UPGRADE=0`).

30. **The image enables an "unreleased" suite.** The
    `/etc/apt/sources.list` of the shipped image contains

    ```
    deb http://deb.debian.org/debian-ports/ sid main
    deb http://deb.debian.org/debian-ports/ unreleased main
    ```

    The packages of the "unreleased" suite are not stable. Fix: remove the
    suite from the sources of the guest before `apt-get update` and verify
    that no source mentions "unreleased" any more.

31. **A guest that is still booting can miss the poweroff.** The first
    provisioning attempt after a fresh boot sent the poweroff while the
    guest was still starting up; the connection then stayed open for an
    hour. Fix: wait a bounded time (60 s) for the connection to end, send
    the request again, and fail with a clear error after the second try.
    The provisioning script waits for QEMU to exit anyway and terminates it
    when the guest does not shut down.

32. **The redirection of the log file swallows the output of the last command
    of a chain.** `run_command` sends the command with
    `>logfile 2>&1` appended. In `cmd1 && cmd2 >file`, the redirection of
    `cmd2` wins over the one of the log file, so `cmd2` writes into `file`
    and nothing lands in the log. The pin of `hurd-dev` was written that way
    and lost its last line, which made every apt command in the guest fail
    with "E: No priority (or zero) specified for pin". Fix: run the command
    in a group (`{ cmd ; } >logfile 2>&1`), so that the redirection of the log
    covers the whole command, and write files with a single `printf` instead
    of a chain of `echo` commands.

33. **A pin without a priority breaks every apt command.** A pin block in
    `/etc/apt/preferences.d/` that has no `Pin-Priority` makes apt stop with
    "E: No priority (or zero) specified for pin", so neither `apt-get
    install` nor `apt-cache policy` works any more. Fix: write the pin with
    all three lines (`Package`, `Pin`, `Pin-Priority`) and verify it with a
    `grep` before any apt command runs.

34. **The image ships no package lists.** `/var/lib/apt/lists` of the image is
    empty, so `apt-get install` fails with "Unable to locate package" until
    `apt-get update` has fetched the lists of the archive (15 MB, about 12
    seconds). Fix: the provisioning runs `apt-get update` before the
    installation.

35. **The archive of the Hurd port is sid.** The packages come from
    `deb.debian.org/debian-ports sid main`, so the guest gets the versions of
    the unstable archive: `curl` is currently a release candidate
    (`8.23.0~rc2`), and the installation of a package can pull a new libc
    (2.43) into the image. That is the same source that ships the broken
    `hurd-dev`, which is why that one package is held and pinned.

36. **Renaming the user alone leaves the old name behind.** `usermod -l peon
    demo` renames the account in `/etc/passwd` and `/etc/shadow`, but the
    primary group keeps the name "demo" (the account then belongs to the
    group "demo"), and the comment field of the account (the fifth field of
    `/etc/passwd`) still says "demo". Fix: rename the group first
    (`groupmod -n peon demo`), rename the user with the new home directory
    (`usermod -l peon -d /home/peon -m demo`) and set the comment
    (`usermod -c 'peon,,,' peon`). The provisioning checks afterwards that
    the old name is gone from `/etc/passwd`, `/etc/shadow` and `/etc/group`.

37. **A key is only accepted with the right modes and ownership.** sshd
    checks the home directory, the `.ssh` directory and the
    `authorized_keys` file: the `.ssh` directory has to have the mode 700,
    the file the mode 600, and both have to belong to the account. Otherwise
    the login is refused with "Authentication refused: bad ownership or
    modes".

38. **A new key pair locks the guest out of the key login.** The public key
    in the guest belongs to the pair in `img/keys`. A new pair has a new
    public key, so the key login fails until the new public key is installed
    in the guest, which the provisioning does. Fix: never replace the key
    pairs; when they are lost, remove `img/keys` and rebuild the accounts
    stage (`rm -f img/hurd.accounts.qcow2 img/hurd.packages.qcow2 &&
    make packages`), or log in with the password.

39. **The commands of the provisioning end up in the history of the guest.**
    The driver logs into an interactive shell, and every command that it
    sends is recorded in `/root/.bash_history`. That file then holds the
    password hash of the accounts, which is enough to log in as root or as
    the user account. Fix: the driver disables the history of the session
    (`export HISTFILE=/dev/null` and `set +o history`) right after the
    login, next to `stty -echo`.

40. **The name of the account of the image is only known in one place.** The
    image calls its user account "demo", and the provisioning renames it.
    The name therefore belongs to a single constant (`OLD_ACCOUNT` in
    `scripts/provision_guest.py`); the offline preparation must not mention
    it, because the password of the account is set after the rename, in the
    guest.

41. **A reflinked copy of the image reads back corrupt.** On filesystems with
    clone support (btrfs, XFS), `cp` defaults to `--reflink=auto`: the 4 GB
    "copy" of the raw image takes a millisecond and shares its data extents
    with the source. Reading a freshly cloned image through `partitionfs`
    (the FUSE tool the pipeline used then, which reads with direct I/O)
    intermittently returned inconsistent data, and `debugfs` failed with
    a bogus "Ext2 inode is not a directory" (three failures out of five in a
    retry test), which broke the preparation nondeterministically. The
    `sync` afterwards does not help: a reflink has no dirty data to flush.
    Fix: `cp --reflink=never`; a real copy costs a few seconds and is
    reliable. The partition is read through the page cache now, where the
    problem is not expected, but that has not been tested again on btrfs or
    XFS, so the real copy stays.

42. **A failed `debugfs dump` fails silently.** `debugfs` exits 0 even when
    the dump fails, and its diagnostics go to stderr. The preparation
    discarded stderr, so a failed dump of `/boot/grub/grub.cfg` surfaced
    much later as a cryptic awk error about the missing `grub.cfg.orig`
    file. Fix: the dumps run through a helper that checks the exit status
    and that the dumped file exists and is not empty, and that fails with an
    error that names the file.

43. **`ssh -i` still offers the keys of the agent.** ssh tries the keys of a
    loaded agent before the identity given with `-i`; with six keys in the
    agent, the authentication attempt limit of sshd (default 6) is exhausted
    before the right key is offered, and the connection is dropped with
    "Too many authentication failures" even though the key itself is
    installed in the guest. Fix: `-o IdentitiesOnly=yes` next to `-i`, in
    the key login check of the provisioning and in `make ssh` /
    `make ssh-peon`.

44. **A phony prerequisite rebuilds its target on every run.** The rule of
    the base image listed the phony target `partitionfs-build` as a
    prerequisite. make treats a phony prerequisite as always newer than the
    target, so `make run` and the stage targets rebuilt the base image from
    the downloaded image every time and silently threw the provisioning
    away; a second `make packages` was never a no-op. Fix: the base image
    depends on real files only (the extraction stamp and the scripts). The
    check: with an up-to-date base image, `make -n run` must not print
    `prepare_base.sh`.

45. **A helper that needs libfuse 2 is a dead end.** `partitionfs` is
    written against the FUSE 2 API, which distributions are removing
    (nixpkgs has no libfuse 2 after 26.05), and it had to be compiled on the
    host with CMake and the libparted headers. Fix: none of it is needed.
    e2fsprogs opens a filesystem at an offset inside a file
    (`debugfs -w 'IMAGE?offset=BYTES'`, the same for `e2fsck`, `dumpe2fs`
    and `mke2fs -E offset=BYTES`), and `partx -s IMAGE` prints the partition
    table of a regular file. Quote the name in the shell: it contains a
    question mark.

## Known issue: ext2 without a journal

The root filesystem of the Hurd image is ext2 **without a journal**. The guest
creates and removes tens of thousands of files during `apt-get upgrade`, and
its shutdown path does not flush the inode and block bitmaps to disk. The
resulting image passes the boot test, but `e2fsck -fn` reports:

```
Deleted inode <n> has zero dtime.
Block bitmap differences: -(33875--34388) ...
Inode bitmap differences: -1691 -8193 ...
Free blocks count wrong ...
```

Facts established while investigating this:

- The pristine image is clean (`e2fsck -fn` exits 0), so the inconsistency is
  created by the guest, not by the download or by the offline preparation.
- Running `sync` (twice) in the guest before `poweroff` does **not** fix it.
- The metadata itself is intact; only the bookkeeping is stale, so
  `e2fsck -fy` repairs the image completely (a second `e2fsck -fn` then exits 0).

That is why `scripts/provision_base.sh` repairs the filesystem offline after the
guest has powered off. The repair works on the image itself, through
`qemu-nbd` -> `nbdfuse`, with `e2fsck` opening the partition by its offset,
so no conversion to a raw file is needed.

## How to update it

### Change the Hurd release

1. Set `VERSION` and `MD5_SUM` in `Makefile` (the MD5 of the new tarball).
2. `make download` to fetch and verify it.
3. Remove the old base image (`rm -f img/hurd.base.qcow2`) and run
   `make base && make packages`.
4. Check whether the new image still ships `/etc/ssh/sshd_config.d/`, whether
   the `root` account is still in `/etc/shadow`, and whether the GRUB layout in
   `prepare_base.sh` still matches the shipped `/boot/grub/grub.cfg`. The
   kernel name is taken from the image, so a new kernel version needs no
   change.

### Change the root password

Set `ROOT_PASSWORD` in the `Makefile`. It is passed to `prepare_base.sh`
(offline hash) and to `provision_base.sh` (SSH login). Changing it requires a
fresh base image: `rm -f img/hurd.base.qcow2 && make base && make provision`.

### Add or change offline file edits

Edit the `debugfs` command list in `scripts/prepare_base.sh`. Remember that
`debugfs write` cannot overwrite, so every file needs `rm` before `write`, and
that ownership has to be restored with `sif <file> uid/gid/mode` for files
outside `/etc` (the defaults are taken from the file being replaced).

### Add or change in-VM provisioning steps

Edit `scripts/provision_guest.py` and add a `run_command` call with a
**unique** tag; the tag names the log file in the guest
(`/tmp/provision_<tag>.log`). `run_command` returns the exit status of the
command, so check it and fail the provisioning when it fails.

Steps that must run before the marker is written belong above
`session.run_command("touch /root/.provisioned", "marker_write")`; steps that
must run on every boot belong below it.

### Change the packages of the guest

Set `GUEST_PACKAGES` in the `Makefile`, for example
`GUEST_PACKAGES := curl python3 wget`. The list is passed to the driver,
which installs the packages that are missing and verifies that every one of
them is there afterwards. The installation needs the package lists of the
archive, so `apt-get update` runs first. A package that is added to the list
reaches the images that were provisioned before it was added, because the
installation does not depend on the provision marker.

### Change the name of the user account

The names are `OLD_ACCOUNT` and `NEW_ACCOUNT` in `scripts/provision_guest.py`,
and `NEW_ACCOUNT_HOME` holds the home directory of the renamed account. The
rename covers the account in `/etc/passwd` and `/etc/shadow`, its group and
its home directory, and the provisioning checks that the old name is gone
everywhere. The renamed account gets the configured password
(`ROOT_PASSWORD` of the `Makefile`) in the same run, so that the offline
preparation does not have to know the name of the account of the image. A
fresh base image (`rm -f img/hurd.base.qcow2 && make base && make packages`)
starts again with the account of the image.

The accounts that get an SSH key are in `KEY_ACCOUNTS` in the same file,
together with their home directory.

### Replace the SSH keys

Remove `img/keys` and rebuild the accounts stage (`rm -f
img/hurd.accounts.qcow2 img/hurd.packages.qcow2 && make packages`): the
pairs are generated again and the new public keys are installed in the
guest. The private keys of
the old pairs stop working, and the password of the accounts keeps working in
the meantime.

### Change the SSH port or the network device

`SSH_PORT` in the `Makefile` is the port on the host that is forwarded to port
22 in the guest; the guest's sshd always listens on 22. The network device is
`-device e1000` in `Makefile` and in `scripts/provision_base.sh`; the Hurd image
has no virtio driver, so keep the emulated e1000 or add another driver to the
guest.

### Change the disk layout

The root filesystem is partition 2. It is referenced in three places:
`root=part:2:device:wd0` in the GRUB config of `scripts/prepare_base.sh`,
`ROOT_PARTITION=2` in the same script, and the partition number argument
of `scripts/repair_filesystem.sh` (default 2).

### Rebuild from scratch

```
make distclean     # removes img/ entirely, including the download
make base          # offline preparation, result: img/hurd.base.qcow2
make packages      # accounts + packages stages (alias: make provision)
```

## Verification

Check that the root filesystem of the base image is clean:

```
qemu-img convert -f qcow2 -O raw img/hurd.base.qcow2 /tmp/base.raw
e2fsck -fn '/tmp/base.raw?offset=1000341504'      # expect exit status 0
```

The same check through the NBD chain, without the conversion (a few seconds
instead of a minute):

```
bash scripts/repair_filesystem.sh img/hurd.base.qcow2   # also repairs
```

Check that the base image survives a run unchanged:

```
md5sum img/hurd.base.qcow2
make run                           # boot the overlay, log in with SSH
md5sum img/hurd.base.qcow2        # must be identical
```

Check the SSH login from the host (no `sshpass` on this machine, so use
`pexpect`):

```
python3 -c 'import pexpect; c = pexpect.spawn("ssh", ["-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null", "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no", "-p", "2222", "root@127.0.0.1", "id"], encoding="utf-8");
    c.expect("password:"); c.sendline("hurdkit"); c.expect(pexpect.EOF); print(c.before)'
```

Check the login with the keys (the guest has to be running):

```
ssh -o IdentitiesOnly=yes -i img/keys/root_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1 id
ssh -o IdentitiesOnly=yes -i img/keys/peon_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -p 2222 peon@127.0.0.1 id
```

## Constraints

- No root privileges: no loop mounts, no `guestfish`, no `virt-customize`.
- The downloaded image is immutable; every change is applied to a copy.
- The base image is only used as a read-only backing file for overlays.
- The root password is shared and weakly chosen; the image is for local
  experiments only, never expose the forwarded port to an untrusted network.
