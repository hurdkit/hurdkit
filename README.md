# hurdkit

Build and run customized Debian GNU/Hurd x86_64 VM images, plus an `x86_64-gnu` cross toolchain. AI pull requests ENCOURAGED!

## What it does

The top-level Makefile downloads a pinned Debian GNU/Hurd image, prepares it offline (GRUB serial console, root password, sshd), converts it to a qcow2 base image, provisions it in-VM (packages, users, SSH keys), and boots the guest from a copy-on-write overlay so the base image stays byte-for-byte pristine:

```
download -> offline preparation -> qcow2 base -> in-VM provisioning -> overlay boot
```

It also builds a cross toolchain (binutils, gcc stage 1/2, gnumach, MIG, glibc, Hurd libs, 9pfs) for `x86_64-gnu` on a Linux host (host-local or via Docker), and builds the `partitionfs` FUSE tool used by the image pipeline.

The Debian GNU/Hurd image is pinned to version `20260314` (see `VERSION` in the Makefile).

## Requirements

Host tools: `make`, `wget`, `tar`, `xz`, `qemu-img`, `qemu-system-x86_64`, `flock`, `openssl`, `cmake`, `pkg-config`, plus FUSE and libparted development files (for `partitionfs-build`). KVM (`/dev/kvm`) is used for acceleration when available; the VM boots without it otherwise.

Toolchain builds download `binutils` and `gcc` source tarballs from ftp.gnu.org and install into `$HOME/opt/x86_64-gnu` (build artifacts under `$HOME/work/x86_64-gnu-*`).

The 3p source checkouts (`mig`, `gnumach`, `glibc`, `hurd`, `9pfs`, `partitionfs`, `libpciaccess`) are pinned to verified commits. Only `partitionfs` is needed for the image pipeline (`make base` fetches and builds just that checkout); the remaining checkouts are fetched by `make toolchain` via `fetch-3p`. `make -C toolchain ...` assumes `3p/` is already present.

## Main targets

| Target | What it does |
|---|---|
| `make base` | Build `img/hurd.base.qcow2` |
| `make provision` | Provision the base image in-VM (idempotent) |
| `make run` | Boot from an overlay; base stays unchanged |
| `make ssh` / `make ssh-peon` | SSH into the running VM (port 2222) |
| `make toolchain` | Build the x86_64-gnu cross toolchain |
| `make toolchain-docker` | Same via Docker |
| `make partitionfs-build` | Build the partitionfs FUSE tool (fetches only the partitionfs 3p checkout) |
| `make fetch-3p` | Clone missing 3p source checkouts |
| `make clean` / `make distclean` | Remove temporaries / all generated files |

## What `make provision` buys you

`make provision` turns the raw qcow2 base into a ready-to-use image on top of an immutable OS base. It provisions in a throwaway VM copy, then atomically swaps the result into `img/hurd.base.qcow2` — so the base image itself never changes in place. Combined with `make run` (which boots from a copy-on-write overlay), you get reproducible, idempotent image builds on an immutable base without root privileges.

The provisioning step:

* renames the `demo` account to `peon` (group, home directory, and password moved too),
* installs the guest packages listed by `GUEST_PACKAGES` in the Makefile (e.g. `curl python3`) when any are missing,
* generates host-side SSH key pairs for `root` and `peon` if they don't exist, and installs each public key into the guest so passwordless SSH login works,
* verifies that key-based login works for every account,
* optionally runs `apt-get update` and `apt-get upgrade` when `RUN_APT_UPGRADE=1` (off by default),
* writes a `/root/.provisioned` marker so a second run is a no-op.

The image is repaired offline afterward (ext2 has no journal) before being swapped into place.

Tunables (image version, URL, MD5, memory, CPU count, SSH port, root password, guest packages) live at the top of the [Makefile](./Makefile).

## Project layout

```
Makefile              # image pipeline + toolchain entry points
toolchain/            # cross toolchain orchestration (host-local and docker backends)
scripts/              # prepare_base.sh, provision_base.sh, provision_guest.py, repair_filesystem.sh
skills/BOOT.md        # detailed boot/provisioning skill
img/                  # downloaded image, base image, keys (git ignored)
3p/                   # pinned 3p source checkouts (git ignored)
```

See `toolchain/README.md` for toolchain build details and `skills/BOOT.md` for the boot/provisioning procedure.

## Quick start

```sh
make base          # builds img/hurd.base.qcow2
make provision     # provisions it in the VM
make run           # boots from an overlay, SSH on 127.0.0.1:2222
```

# Contributors

Main contributors: chzchzchz, venatiodecorus.
