# x86_64-gnu cross toolchain for GNU/Hurd

Builds a cross toolchain (binutils, gcc, glibc, MIG, Hurd libs) for
`x86_64-gnu` on a Linux host, plus the `9pfs` translator used to verify the
toolchain under the Hurd VM. Full recipe: `stuff/crosscompile_plan.md`.

## Committed files

| File | Purpose |
|---|---|
| `Dockerfile.hurd-x86_64-gnu` | Single-stage Docker builder (debian:trixie) |
| `Makefile` | Orchestrates both backends behind one UX |
| `cross-gnu.ini.in` | Meson cross-file template for the GNU/Hurd target (`@PREFIX@` substituted at build time) |
| `9p-server.py` | Optional python 9P2000.L server for the V5 mount test |
| `.dockerignore` | Keeps the Docker build context to this directory only |

## Backends

Host-local (default):

```sh
make -C toolchain toolchain          # stages 0–8: fetch … 9pfs
make -C toolchain 9pfs               # build just the verification ELF
make -C toolchain libpciaccess       # cross-build libpciaccess (GNU/Hurd target)
make -C toolchain compress-libs      # static zlib, liblzma, libzstd, liblz4, liblzo2
make -C toolchain verify-vm          # V2–V4 against the Hurd VM
```

Fresh checkout: the top-level `make toolchain` first runs `fetch-3p`,
which clones any missing 3p repos into `3p/` (never rewrites an existing
repo; a non-git directory at a target path is an error) and then pins
them to the verified commits. `make -C toolchain ...` (this directory)
assumes `3p/` is present.

`compress-libs` (stages `zlib`, `xz`, `zstd`, `lz4`, `lzo`) installs
static compression libraries, with headers and `.pc` files, for
translators that decompress (squashfs). Each stage downloads a pinned
release tarball into `~/work/x86_64-gnu-src`, checks its sha256 against
the value in the Makefile, and gates on a static GNU/Hurd program that
links the library. It is not part of `make toolchain`. The `squashfs`
target runs it first.

The 3p sources the toolchain builds against (`mig`, `glibc`, `gnumach`,
`hurd`, `9pfs`, `libpciaccess`) are pinned to the exact commits that were
verified for this build; `3p/9pfs` is pristine upstream master (the extra link
libraries it needs are passed from the wrapper, not patched in).
`make -C toolchain 3p-pin` checks them out — it runs automatically
before any build, refuses to proceed when a repo has uncommitted changes,
and mounts the pinned tree read-only for Docker.

End-to-end mount test (V5), with the Hurd VM running and SSH on 2222:

```sh
python3 toolchain/9p-server.py ~/work/9p-root 127.0.0.1:1564 &
scp -P 2222 -i img/keys/root_ed25519 3p/9pfs/9pfs root@127.0.0.1:/tmp/9pfs
ssh -i img/keys/root_ed25519 -p 2222 root@127.0.0.1 \
    'settrans -c /host /tmp/9pfs 10.0.2.2:1564'
ssh -i img/keys/root_ed25519 -p 2222 root@127.0.0.1 'ls /host; cat /host/canary.txt'
```

`ssh -p 2222` needs `-i img/keys/root_ed25519` (the provisioned key). The
server uses unprivileged port 1564 (564 requires root). Verified outputs:
`stuff/crosscompile_verification.md`.

Docker (secondary; verified working; the container runs as the host user,
so artifacts land at host paths, not root-owned):

```sh
make -C toolchain toolchain BACKEND=docker
```

All artifacts land at host paths (`$HOME/opt/x86_64-gnu`, `$HOME/work/…`);
nothing is copied into or out of containers. See the plan §4 for the layout.
