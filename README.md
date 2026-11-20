# hurdkit

Build and run customized Debian GNU/Hurd x86_64 VM images, plus an `x86_64-gnu` cross toolchain. AI pull requests ENCOURAGED!

## What it does

The top-level Makefile downloads a pinned Debian GNU/Hurd image, prepares it offline (GRUB serial console, root password, sshd), converts it to a qcow2 base image, provisions it in-VM (packages, users, SSH keys), and boots the guest from a copy-on-write overlay so the base image stays byte-for-byte pristine:

```
download -> offline preparation -> qcow2 base -> in-VM provisioning -> overlay boot
```

It also builds a cross toolchain (binutils, gcc stage 1/2, gnumach, MIG, glibc, Hurd libs, 9pfs) for `x86_64-gnu` on a Linux host (host-local or via Docker).

The Debian GNU/Hurd image is pinned to version `20260314` (see `VERSION` in the Makefile).

## Requirements

Host tools for the image pipeline: `make`, `wget`, `tar`, `xz`, `qemu-system-x86_64`, `qemu-img` and `qemu-nbd` (QEMU), `flock` and `partx` (util-linux), `debugfs` and `e2fsck` (e2fsprogs), `nbdfuse` (libnbd), `openssl`, `ssh` and `ssh-keygen`, and `python3` with the `pexpect` module. Nothing has to be compiled on the host, and no root privileges are needed. KVM (`/dev/kvm`) is used for acceleration when available; the VM boots without it otherwise. FUSE (`/dev/fuse` and a setuid `fusermount3`) is used by `make provision` only, for the offline repair of the qcow2 image.

Toolchain builds download `binutils` and `gcc` source tarballs from ftp.gnu.org and install into `$HOME/opt/x86_64-gnu` (build artifacts under `$HOME/work/x86_64-gnu-*`).

### Nix / NixOS

The flake lives in `nix/` and provides a development shell with every host tool listed above, for the image pipeline and for the host-local toolchain build. It follows `nixos-unstable`:

```sh
nix develop ./nix   # or: direnv allow  (the .envrc points at ./nix)
make base
```

Two things are worth knowing, because each of them fails in a confusing way otherwise:

* `nbdfuse` mounts through the setuid `fusermount3`, which on NixOS lives in `/run/wrappers/bin`. The shell puts that directory first in `PATH`, because the `fusermount3` of the `fuse3` package in the Nix store is not setuid ("Operation not permitted").
* The shell disables the hardening flags of the nixpkgs compiler wrapper (`hardeningDisable = [ "all" ]`); GCC and glibc do not build with them.

The Docker backend (`make toolchain-docker`) is not covered by the shell; it needs a `docker` command on the host.

The 3p source checkouts (`mig`, `gnumach`, `glibc`, `hurd`, `9pfs`, `libpciaccess`) are pinned to verified commits. The image pipeline needs none of them; they are fetched by `make toolchain` via `fetch-3p`. `make -C toolchain ...` assumes `3p/` is already present.

## Main targets

| Target | What it does |
|---|---|
| `make base` | Build the raw OS base image `img/hurd.base.qcow2` (offline preparation only: no accounts, no SSH keys, no guest packages) |
| `make accounts` / `make packages` | Build the staged images on top of it: `hurd.accounts.qcow2` (accounts + SSH keys), then `hurd.packages.qcow2` (+ guest packages such as gdb) |
| `make provision` | Alias for `accounts packages` (kept for the old provision-the-base habit; the base image itself is never provisioned in place) |
| `make run` | Boot from an overlay of the raw base; log in with the root password |
| `make ssh` / `make ssh-peon` | SSH into the running VM (port 2222) |
| `make toolchain` | Build the x86_64-gnu cross toolchain |
| `make toolchain-docker` | Same via Docker |
| `make fetch-3p` | Clone missing 3p source checkouts |
| `make clean` / `make distclean` | Remove temporaries / all generated files |

## The image pipeline

```
img/hurd.base.qcow2   raw, offline-prepared OS image (make base)
  -> img/hurd.accounts.qcow2    + account rename, passwords, SSH keys (make accounts)
  -> img/hurd.packages.qcow2    + GUEST_PACKAGES: curl, python3, gdb (make packages)
  -> img/hurd.kernel.qcow2      + custom kernel overlay, optional (make kernel)
```

Each stage boots its input image in a throwaway CoW overlay, applies its
provisioning step, and promotes the overlay to the stage image — so a
failed stage never touches its input, and `base` always means the same
thing: the raw prepared image with no accounts or keys. Every stage is its
own qcow2 file, so the intermediates stay visible and a rebuilt base
propagates through the chain instead of being folded into one image.

The provisioning steps (identical for the stage chain and the legacy
single-image flow in `scripts/provision_base.sh`):

* renames the `demo` account to `peon` (group, home directory, and password moved too),
* installs the guest packages listed by `GUEST_PACKAGES` in the Makefile (e.g. `curl python3`) when any are missing,
* generates host-side SSH key pairs for `root` and `peon` if they don't exist, and installs each public key into the guest so passwordless SSH login works,
* verifies that key-based login works for every account,
* optionally runs `apt-get update` and `apt-get upgrade` when `RUN_APT_UPGRADE=1` (off by default),
* repairs the ext2 filesystem offline afterward (ext2 has no journal).

The test harnesses (`make virtio-test`, `make virtio-balloon-test`, `make exfatfs-test`, `make squashfs-test`) boot
from a CoW snapshot of the packages image (`qemu-img create`, not
`convert`), which is the stage that carries both the SSH keys and gdb.

Tunables (image version, URL, MD5, memory, CPU count, SSH port, root password, guest packages) live at the top of the [Makefile](./Makefile).

## Project layout

```
Makefile              # image pipeline + toolchain entry points
nix/                  # flake.nix + flake.lock (development shell)
toolchain/            # cross toolchain orchestration (host-local and docker backends)
scripts/              # prepare_base.sh, provision_base.sh, provision_guest.py, repair_filesystem.sh, partition.sh
skills/BOOT.md        # detailed boot/provisioning skill
skills/CROSS_TESTING.md  # test cross-compiled drivers inside the Hurd VM
skills/CROSSCOMPILING.md  # cross-compiling with the toolchain (gnumach example, cross nm/objdump/readelf)
skills/FILESYSTEM_TESTING.md  # test disk filesystem translators (fatfs, exfatfs, squashfs) against Linux
img/                  # downloaded image, base image, keys (git ignored)
3p/                   # pinned 3p source checkouts (git ignored)
```

See `toolchain/README.md` for toolchain build details, `skills/BOOT.md` for the boot/provisioning procedure, `skills/CROSSCOMPILING.md` for cross-compiling (including the gnumach kernel and the cross `nm`/`objdump`/`readelf` workflow), `skills/CROSS_TESTING.md` for testing cross-compiled drivers in the guest, and `skills/FILESYSTEM_TESTING.md` for `make exfatfs-test`, which checks the fatfs and exfatfs translators against the Linux kernel driver and `fsck.exfat`, and `make squashfs-test`, which checks the squashfs translator against the Linux kernel driver and `unsquashfs` for all five compressors.

## Benchmarks

Run the virtio benchmark matrix (raw block I/O, filesystem dd, tar create/extract, network):

```sh
make virtio-bench            # all legs
MODE=block make virtio-bench # block only; also fs-tar, fs-dd, net, net-e1000, net-vnet
```

Results are written as JSON to `img/tmp/virtio-bench-summary*.json`. Use `REUSE=1` to rerun against an already-booted guest.

Override source locations for a workbranch (use absolute paths; `~` is not expanded):

```sh
make virtio-bench GNUMACH_DIR=/path/to/gnumach \
  VIRTIO_DIR=/path/to/virtio VIRTIO_NET_DIR=/path/to/virtio
```
Defaults: `GNUMACH_DIR=3p/gnumach`, `VIRTIO_DIR=$(HOME)/src/virtio` (and `VIRTIO_NET_DIR` defaults to `VIRTIO_DIR`).

SMP stress tests (build an SMP kernel first with `make smp-kernel GNUMACH_NCPUS=2`):

```sh
make smp-image        # build hurd.kernel.smp.qcow2
make run-smp-tests    # SMP kernel, 2 vCPUs
make up-image         # build hurd.kernel.up.qcow2
make run-up-tests     # UP kernel, 1 vCPU

Use a custom gnumach checkout/branch with `GNUMACH_DIR=/path/to/gnumach`
(e.g. `make smp-kernel smp-image run-smp-tests GNUMACH_DIR=/path/to/gnumach`).
```


SMP results are written to `img/tmp/results/smp-*.log`.


## Quick start

```sh
make base          # builds img/hurd.base.qcow2
make provision     # provisions it in the VM
make run           # boots from an overlay, SSH on 127.0.0.1:2222
```
