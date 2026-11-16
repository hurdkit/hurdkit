{
  description = "hurdkit: Debian GNU/Turd x86_64 VM images and an x86_64-gnu cross toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The toolchain is configured with --build=x86_64-pc-linux-gnu and the
      # guest is an x86_64 VM, so this is the only supported host.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system} = {
        default = pkgs.mkShell {
          name = "hurdkit";

          # Host tools.
          packages = with pkgs; [
            # --- image pipeline (make base / provision / run / ssh) ---
            gnumake
            wget
            gnutar
            xz
            qemu # qemu-system-x86_64, qemu-img, qemu-nbd
            util-linux # flock, partx
            openssl # password hash for the offline preparation
            e2fsprogs # debugfs, e2fsck, dumpe2fs
            libnbd # nbdfuse, for the offline repair of a qcow2 image
            openssh # ssh, scp, ssh-keygen
            (python3.withPackages (ps: [ ps.pexpect ])) # scripts/provision_guest.py
            git
            gawk
            gnused
            gnugrep
            coreutils
            file
            which

            # --- cross toolchain (make toolchain) ---
            bison
            flex
            gperf
            texinfo
            autoconf
            automake
            libtool
            m4
            perl
            pkg-config
            meson
            ninja
          ];

          # Libraries the host compiler links against. They are listed here,
          # not in `packages`, so that the compiler wrapper adds their include
          # and library directories.
          buildInputs = with pkgs; [
            gmp # gcc
            mpfr # gcc
            libmpc # gcc
          ];

          # The compiler wrapper of nixpkgs adds hardening flags
          # (-Werror=format-security, _FORTIFY_SOURCE, ...) to every compile.
          # GCC and glibc do not build with them, and they must not leak into
          # a cross toolchain.
          hardeningDisable = [ "all" ];

          shellHook = ''
            # nbdfuse (used by the offline repair of a qcow2 image) mounts
            # through the setuid fusermount3. On NixOS that is the wrapper in
            # /run/wrappers/bin; the fusermount3 of the fuse3 package in the
            # store is not setuid and fails with "Operation not permitted".
            # libfuse of nixpkgs already calls the wrapper for mounting; the
            # repair script calls "fusermount3 -u" by name, so the wrapper
            # directory has to come first in PATH.
            if [ -d /run/wrappers/bin ]; then
              export PATH="/run/wrappers/bin:$PATH"
            fi

            if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
              echo "hurdkit: /dev/kvm is not usable, the guest will run without acceleration (slow)" >&2
            fi
            if [ ! -w /dev/fuse ]; then
              echo "hurdkit: /dev/fuse is not usable, 'make provision' needs FUSE for the offline repair" >&2
            fi
          '';
        };
      };
    };
}
