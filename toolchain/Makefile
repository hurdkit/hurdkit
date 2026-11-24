# Toolchain orchestration for x86_64-gnu cross build.
# Backends: hostlocal (default, runs on this host) | docker (bind-mounts host dirs).
#
# Stages: fetch -> binutils -> gcc1 -> gnumach -> mig -> glibc -> gcc2 -> hurd -> 9pfs
# Each stage skips when its artifact is already installed in the prefix, so an
# interrupted build is resumed by re-running the same target.
# MIG is a host tool built from the 3P/mig checkout (MIG 1.8+): the released
# 1.3.1 tarball does not register the basic C types the Hurd .defs files use.

REPO_ROOT := $(abspath ..)
PREFIX    := $(HOME)/opt/x86_64-gnu
BUILD     := $(HOME)/work/x86_64-gnu-build
SRC       := $(HOME)/work/x86_64-gnu-src
NPROC     := $(shell nproc)
BACKEND   ?= hostlocal
# Build the kernel from a separate worktree when GNUMACH_DIR is overridden.
GNUMACH_DIR ?= $(REPO_ROOT)/3p/gnumach
# Keep the stable uniprocessor build as the default until SMP is verified.
GNUMACH_NCPUS ?= 1
GNUMACH_NCPUS_IS_SMP := $(shell test "$(GNUMACH_NCPUS)" -gt 1 2>/dev/null && echo yes)
GNUMACH_NCPUS_OPTION := $(if $(GNUMACH_NCPUS_IS_SMP),--enable-ncpus=$(GNUMACH_NCPUS))
GNUMACH_TICKLESS ?= no
GNUMACH_TICKLESS_OPTION := $(if $(filter yes,$(GNUMACH_TICKLESS)),--enable-tickless)
GNUMACH_DEVICE_DRIVERS ?=
GNUMACH_DEVICE_DRIVERS_OPTION := $(if $(GNUMACH_DEVICE_DRIVERS),--enable-device-drivers=$(GNUMACH_DEVICE_DRIVERS))
CFLAGS ?= -O2 -g -Wall

SSH_PORT ?= 2222

BINUTILS_VER := 2.46.1
GCC_VER      := 15.3.0

.PHONY: all toolchain toolchain-clean fetch \
	binutils gcc1 gnumach gnumach-kernel glibc gcc2 \
	mig hurd hurd-headers libpciaccess libtrivfs libmachdev libirqhelp libuuid \
	hurd-libstore parted storeio hurd-servers \
	virtio-9p virtio-balloon virtio-blk virtio-net 9pfs verify-vm \
	clean tooldir 3p-pin glibc-rebuild \
	virtio-clean

# The verified 3p checkouts, pinned to exact SHAs (see
# stuff/crosscompile_plan.md, "3p source pins"). The shared 3p checkout is
# mounted read-only by the docker backend, so the pin is applied on the host
# before either backend builds. The 9pfs pin is pristine upstream master.
# The 3p source URLs and verified pins live in toolchain/pins.mk, shared
# with the top-level Makefile, whose fetch-3p target clones the checkouts.
include pins.mk

# Pin the 3p repos to their pins.mk refs: an exact SHA (detached HEAD) or,
# with an "@branch" pin, the named branch checked out with tracking, so an
# upstream push moves the pin forward on the next 3p-pin run. No-op when
# already pinned. Refuses to proceed if a repo has uncommitted changes (it
# may be shared with other work) or if the pinned commit is unavailable
# (network or wrong checkout; restore the pinned 3p tree).
3p-pin:
	@set -e; \
	for spec in $(3P_PINS); do \
	    repo=$${spec%%:*}; sha=$${spec#*:}; dir=$(REPO_ROOT)/3p/$$repo; \
	    remote=origin; \
	    for rs in $(3P_PIN_REMOTES); do \
	        if [ "$${rs%%:*}" = "$$repo" ]; then remote=$${rs#*:}; fi; \
	    done; \
	    git -C $$dir rev-parse --git-dir >/dev/null 2>&1 || { \
	        echo "3p-pin: $$dir is not a git repo"; exit 1; \
	    }; \
	    if [ "$${sha#@}" != "$$sha" ]; then \
	        branch=$${sha#@}; \
	        if ! git -C $$dir rev-parse -q --verify "refs/heads/$$branch" >/dev/null; then \
	            echo "3p-pin: $$repo: branch $$branch not present locally; fetching from $$remote"; \
	            git -C $$dir fetch $$remote "$$branch:$$branch" || { \
	                echo "3p-pin: fetch failed for $$repo; restore the pinned 3p checkout"; \
	                exit 1; \
	            }; \
	        fi; \
	        if ! git -C $$dir diff --quiet || ! git -C $$dir diff --cached --quiet; then \
	            echo "3p-pin: $$repo has uncommitted changes; commit or stash them before pinning"; \
	            exit 1; \
	        fi; \
	        cur=$$(git -C $$dir rev-parse --abbrev-ref HEAD); \
	        if [ "$$cur" = "$$branch" ]; then \
	            echo "3p-pin: $$repo already on branch $$branch"; \
	            git -C $$dir fetch $$remote "$$branch" || true; \
	            git -C $$dir merge --ff-only "$$remote/$$branch" >/dev/null 2>&1 || true; \
	        else \
	            echo "3p-pin: $$repo $$cur -> branch $$branch"; \
	            git -C $$dir checkout "$$branch" --; \
	        fi; \
	        git -C $$dir fetch $$remote >/dev/null 2>&1 || true; \
	        git -C $$dir branch --set-upstream-to=$$remote/$$branch "$$branch" >/dev/null 2>&1 || true; \
	    else \
	        if ! git -C $$dir cat-file -e $$sha^{commit} 2>/dev/null; then \
	            echo "3p-pin: $$repo: pinned commit $$sha not present locally; fetching from $$remote"; \
	            git -C $$dir fetch $$remote $$sha || { \
	                echo "3p-pin: fetch failed for $$repo; restore the pinned 3p checkout"; \
	                exit 1; \
	            }; \
	        fi; \
	        if ! git -C $$dir diff --quiet || ! git -C $$dir diff --cached --quiet; then \
	            echo "3p-pin: $$repo has uncommitted changes; commit or stash them before pinning"; \
	            exit 1; \
	        fi; \
	        cur=$$(git -C $$dir rev-parse HEAD); \
	        if [ "$$cur" = "$$sha" ]; then \
	            echo "3p-pin: $$repo already at pinned commit $$sha"; \
	        else \
	            echo "3p-pin: $$repo $$cur -> $$sha (detached HEAD)"; \
	            echo "3p-pin: ('git -C 3p/$$repo checkout <branch>' to move back)"; \
	            git -C $$dir checkout --detach $$sha; \
	        fi; \
	    fi; \
	done

all: toolchain

# --- host-local backend ------------------------------------------------------

ifeq ($(BACKEND),hostlocal)

toolchain: 3p-pin fetch binutils gcc1 gnumach mig glibc gcc2 hurd libpciaccess libtrivfs libirqhelp 9pfs virtio-9p

fetch: 3p-pin | $(SRC) $(BUILD)
	cd $(SRC) && \
	    test -f binutils-$(BINUTILS_VER).tar.xz || wget -q https://ftp.gnu.org/gnu/binutils/binutils-$(BINUTILS_VER).tar.xz && \
	    test -f gcc-$(GCC_VER).tar.xz || wget -q https://ftp.gnu.org/gnu/gcc/gcc-$(GCC_VER)/gcc-$(GCC_VER).tar.xz && \
	    test -d binutils-$(BINUTILS_VER) || tar xf binutils-$(BINUTILS_VER).tar.xz && \
	    test -d gcc-$(GCC_VER) || tar xf gcc-$(GCC_VER).tar.xz

$(SRC) $(BUILD):
	mkdir -p $@

binutils: fetch
	@if [ -x "$(PREFIX)/bin/x86_64-gnu-as" ]; then \
	    echo "(skipping: x86_64-gnu-as already installed)"; \
	else \
	    rm -rf $(BUILD)/binutils && mkdir -p $(BUILD)/binutils && cd $(BUILD)/binutils && \
	    $(SRC)/binutils-$(BINUTILS_VER)/configure --target=x86_64-gnu \
	        --prefix=$(PREFIX) --disable-werror --disable-nls && \
	    make -j$(NPROC) && \
	    make install && \
	    rm -rf $(BUILD)/binutils; \
	fi
	@echo "=== gate: binutils ==="
	$(PREFIX)/bin/x86_64-gnu-as --version | head -1

gcc1: binutils
	@if [ -x "$(PREFIX)/bin/x86_64-gnu-gcc" ] && ls $(PREFIX)/lib/gcc/x86_64-gnu/*/libgcc.a >/dev/null 2>&1; then \
	    echo "(skipping: x86_64-gnu-gcc already installed)"; \
	else \
	    rm -rf $(BUILD)/gcc-1 && mkdir -p $(BUILD)/gcc-1 && cd $(BUILD)/gcc-1 && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    $(SRC)/gcc-$(GCC_VER)/configure --target=x86_64-gnu \
	        --prefix=$(PREFIX) --enable-languages=c --without-headers \
	        --disable-shared --disable-multilib --disable-nls --disable-threads && \
	    PATH=$(PREFIX)/bin:$$PATH make all-gcc -j$(NPROC) && \
	    make install-gcc && \
	    PATH=$(PREFIX)/bin:$$PATH make all-target-libgcc -j$(NPROC) && \
	    make install-target-libgcc && \
	    rm -rf $(BUILD)/gcc-1; \
	fi
	@echo "=== gate: gcc stage 1 ==="
	printf 'int x;\n' > $(BUILD)/t.c
	$(PREFIX)/bin/x86_64-gnu-gcc -c $(BUILD)/t.c -o $(BUILD)/t.o && file $(BUILD)/t.o
	ls $(PREFIX)/lib/gcc/x86_64-gnu/*/libgcc.a

gnumach: gcc1
	@if [ -f "$(PREFIX)/include/mach/message.h" ]; then \
	    echo "(skipping: gnumach headers already installed)"; \
	else \
	    rm -rf $(BUILD)/gnumach-src $(BUILD)/gnumach && \
	    cp -a $(REPO_ROOT)/3p/gnumach $(BUILD)/gnumach-src && \
	    cd $(BUILD)/gnumach-src && autoreconf -i && \
	    mkdir -p $(BUILD)/gnumach && cd $(BUILD)/gnumach && \
	    $(BUILD)/gnumach-src/configure --prefix=$(PREFIX) --host=x86_64-gnu && \
	    make install-data && \
	    rm -rf $(BUILD)/gnumach-src $(BUILD)/gnumach; \
	fi
	@echo "=== gate: gnumach headers ==="
	ls -l $(PREFIX)/include/mach/machine
	ls $(PREFIX)/include/mach/machine/vm_types.h >/dev/null
	ls $(PREFIX)/include/mach/message.h >/dev/null
	ls $(PREFIX)/include/mach/exc.defs >/dev/null

# Build the gnumach kernel binary itself (the gnumach target above only
# installs its headers), from the pinned 3p/gnumach checkout, for use as
# CUSTOM_KERNEL in a kernel-stage image (see the top-level Makefile).  The
# kernel needs -mcmodel=kernel, which only the cross gcc accepts; configure
# run without the cross tools in PATH silently records the host "CC = gcc"
# and only the build fails later (with broken objects, e.g. an empty symbol
# table).  So CC and MIG are passed to configure -- AC_ARG_VAR(MIG) and the
# standard CC override put them into the generated Makefile -- and the
# plain make afterwards needs no overrides.  A build dir configured
# without them must be reconfigured, never built in place by hand.
gnumach-kernel: gnumach mig
	@case "$(GNUMACH_NCPUS)" in \
	    ''|*[!0-9]*) echo "gnumach-kernel: GNUMACH_NCPUS must be a positive integer" >&2; exit 1 ;; \
	esac; \
	test "$(GNUMACH_NCPUS)" -ge 1 || { echo "gnumach-kernel: GNUMACH_NCPUS must be at least 1" >&2; exit 1; }
	test "$(GNUMACH_TICKLESS)" != yes || test "$(GNUMACH_NCPUS)" -eq 1 || { \
	    echo "gnumach-kernel: GNUMACH_TICKLESS=yes requires GNUMACH_NCPUS=1" >&2; \
	    exit 1; \
	}
	rm -rf $(BUILD)/gnumach-kernel-src $(BUILD)/gnumach-kernel
	cp -a $(GNUMACH_DIR) $(BUILD)/gnumach-kernel-src
	cd $(BUILD)/gnumach-kernel-src && autoreconf -i
	mkdir -p $(BUILD)/gnumach-kernel && cd $(BUILD)/gnumach-kernel && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    $(BUILD)/gnumach-kernel-src/configure --prefix=$(PREFIX) \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu \
	        $(GNUMACH_NCPUS_OPTION) $(GNUMACH_TICKLESS_OPTION) $(GNUMACH_DEVICE_DRIVERS_OPTION) && \
	    PATH=$(PREFIX)/bin:$$PATH make -j$(NPROC)
	@echo "=== gate: gnumach kernel ==="
	grep -q '^CC = $(PREFIX)/bin/x86_64-gnu-gcc$$' $(BUILD)/gnumach-kernel/Makefile || { echo "gnumach-kernel: Makefile did not record the cross compiler" >&2; exit 1; }
	file $(BUILD)/gnumach-kernel/gnumach
	file $(BUILD)/gnumach-kernel/gnumach | grep -q 'ELF 64-bit.*statically linked' || { echo "gnumach-kernel: kernel binary is not a static x86-64 ELF" >&2; exit 1; }
	$(PREFIX)/bin/x86_64-gnu-nm $(BUILD)/gnumach-kernel/gnumach | \
	    grep -q irq_disable_count_held && \
	    echo "gate: kernel carries the shared-IRQ fixes (irq_disable_count_held)"
ifeq ($(GNUMACH_NCPUS_IS_SMP),yes)
	grep -q '^#define NCPUS $(GNUMACH_NCPUS)$$' $(BUILD)/gnumach-kernel/config.h || { echo "gnumach-kernel: config.h has the wrong NCPUS" >&2; exit 1; }
	grep -q '^#define MULTIPROCESSOR 1$$' $(BUILD)/gnumach-kernel/config.h || { echo "gnumach-kernel: config.h does not enable MULTIPROCESSOR" >&2; exit 1; }
	$(PREFIX)/bin/x86_64-gnu-nm $(BUILD)/gnumach-kernel/gnumach | grep -q ' smp_init$$' || { echo "gnumach-kernel: smp_init is missing" >&2; exit 1; }
	$(PREFIX)/bin/x86_64-gnu-nm $(BUILD)/gnumach-kernel/gnumach | grep -q ' smp_startup_cpus$$' || { echo "gnumach-kernel: smp_startup_cpus is missing" >&2; exit 1; }
endif

# Hurd's interface definitions (.defs) are compiled by glibc's MIG rules
# before the Hurd libraries themselves are built, so install the public
# headers and .defs into the prefix first.
hurd-headers: gcc1
	@if [ -f "$(PREFIX)/include/hurd/io.defs" ]; then \
	    echo "(skipping: hurd headers already installed)"; \
	else \
	    mkdir -p $(PREFIX)/include/hurd && \
	    cp -f $(REPO_ROOT)/3p/hurd/hurd/*.defs $(REPO_ROOT)/3p/hurd/hurd/*.h $(PREFIX)/include/hurd/; \
	fi
	@echo "=== gate: hurd headers ==="
	ls $(PREFIX)/include/hurd/io.defs $(PREFIX)/include/hurd/hurd_types.h >/dev/null

glibc: gnumach mig hurd-headers
	@if ls $(PREFIX)/lib/libc.so.* >/dev/null 2>&1; then \
	    echo "(skipping: libc already installed)"; \
	else \
	    rm -rf $(BUILD)/glibc && mkdir -p $(BUILD)/glibc && cd $(BUILD)/glibc && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc \
	    CXX=false \
	    CPPFLAGS="-idirafter $(REPO_ROOT)/3p/hurd -idirafter $(PREFIX)/include -DUNIXOID_TRAPS=0" \
	    CPATH=$(PREFIX)/include \
	    $(REPO_ROOT)/3p/glibc/configure --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --enable-obsolete-rpc --disable-multilib && \
	    PATH=$(PREFIX)/bin:$$PATH make -j$(NPROC) MIG="$(PREFIX)/bin/mig -I$(PREFIX)/include" && \
	    PATH=$(PREFIX)/bin:$$PATH make install MIG="$(PREFIX)/bin/mig -I$(PREFIX)/include" && \
	    rm -rf $(BUILD)/glibc; \
	fi
	@echo "=== gate: glibc ==="
	ls $(PREFIX)/lib/libc.so.* >/dev/null

# Stage 2 builds without --with-sysroot (see the stage 6 note in
# stuff/crosscompile_plan.md), so the target tools, libraries and headers
# resolve through the $(PREFIX)/x86_64-gnu tooldir. binutils populates
# tooldir/bin itself; include and lib have no flat equivalent after the
# prefix install and are created here as symlinks. The binutils install
# already creates a real tooldir/lib (for lib/ldscripts), so a real
# directory is merged into the prefix directory before it is replaced by
# the symlink; leaving it in place hides glibc from gcc stage 2
# ("cannot find crti.o", "cannot find -lc"). Idempotent.
tooldir:
	@mkdir -p $(PREFIX)/x86_64-gnu
	@for d in include lib; do \
	    t=$(PREFIX)/x86_64-gnu/$$d; \
	    if [ -d $$t ] && [ ! -L $$t ]; then \
	        echo "tooldir: merging $$t into $(PREFIX)/$$d"; \
	        mkdir -p $(PREFIX)/$$d && cp -a $$t/. $(PREFIX)/$$d/ && rm -rf $$t || exit 1; \
	    fi; \
	    ln -sfnT $(PREFIX)/$$d $$t || exit 1; \
	done


# Canonical cross-gnu step: rebuild and reinstall glibc once the full
# compiler (C and C++) exists, so glibc configures against it instead of
# falling back to the C variant for its C++ support bits. Mirrors the
# manual rebuild done on 2026-11-13 (see stuff/crosscompile_plan.md,
# Stage 6). Not part of the default `toolchain` chain: the C-fallback
# initial glibc is what the verification matrix ran against first, and
# re-running it from scratch is occasionally desirable but never required.
glibc-rebuild: gcc2
	rm -rf $(BUILD)/glibc && mkdir -p $(BUILD)/glibc && cd $(BUILD)/glibc && \
	PATH=$(PREFIX)/bin:$$PATH \
	CXX=$(PREFIX)/bin/x86_64-gnu-g++ \
	CPPFLAGS="-idirafter $(REPO_ROOT)/3p/hurd -idirafter $(PREFIX)/include -DUNIXOID_TRAPS=0" \
	CPATH=$(PREFIX)/include \
	$(REPO_ROOT)/3p/glibc/configure --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	    --enable-obsolete-rpc --disable-multilib && \
	PATH=$(PREFIX)/bin:$$PATH make -j$(NPROC) MIG="$(PREFIX)/bin/mig -I$(PREFIX)/include" && \
	PATH=$(PREFIX)/bin:$$PATH make install MIG="$(PREFIX)/bin/mig -I$(PREFIX)/include" && \
	rm -rf $(BUILD)/glibc
	@echo "=== gate: glibc rebuilt against x86_64-gnu-g++ ==="
	ls $(PREFIX)/lib/libc.so.* >/dev/null

gcc2: glibc tooldir
	@if [ -x "$(PREFIX)/bin/x86_64-gnu-g++" ]; then \
	    echo "(skipping: gcc stage 2 already installed)"; \
	else \
	    rm -rf $(BUILD)/gcc-2 && mkdir -p $(BUILD)/gcc-2 && cd $(BUILD)/gcc-2 && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    $(SRC)/gcc-$(GCC_VER)/configure --target=x86_64-gnu \
	        --prefix=$(PREFIX) --enable-languages=c,c++ \
	        --enable-threads=posix --disable-multilib && \
	    PATH=$(PREFIX)/bin:$$PATH make -j$(NPROC) && \
	    make install && \
	    rm -rf $(BUILD)/gcc-2; \
	fi
	@echo "=== gate: gcc stage 2 ==="
	$(PREFIX)/bin/x86_64-gnu-g++ --version | head -1
	ls $(PREFIX)/lib/gcc/x86_64-gnu/*/libgcc.a

# MIG is a host tool: it runs on the build machine and emits target-independent
# C. The 3P checkout is newer than the released 1.3.1 tarball and registers the
# basic C types (int, char, short) that the Hurd .defs files refer to, which
# the released tarball rejects. The checkout ships no generated configure
# script and autoreconf writes into the source tree, so build from a copy.
mig: gnumach
	@if [ -x "$(PREFIX)/bin/mig" ]; then \
	    echo "(skipping: mig already installed)"; \
	else \
	    rm -rf $(BUILD)/mig-src $(BUILD)/mig && \
	    cp -a $(REPO_ROOT)/3p/mig $(BUILD)/mig-src && \
	    cd $(BUILD)/mig-src && autoreconf -i && \
	    mkdir -p $(BUILD)/mig && cd $(BUILD)/mig && \
	    PATH=$(PREFIX)/bin:$$PATH $(BUILD)/mig-src/configure --prefix=$(PREFIX) \
	        --target=x86_64-gnu --host=x86_64-pc-linux-gnu --build=x86_64-pc-linux-gnu \
	        --program-prefix= TARGET_CPPFLAGS="-I$(PREFIX)/include" && \
	    PATH=$(PREFIX)/bin:$$PATH make -j$(NPROC) && \
	    make install && \
	    rm -rf $(BUILD)/mig-src $(BUILD)/mig; \
	fi
	@echo "=== gate: mig ==="
	$(PREFIX)/bin/mig --help | head -1

hurd: mig glibc
	@if ls $(PREFIX)/lib/libshouldbeinlibc.so >/dev/null 2>&1; then \
	    echo "(skipping: hurd libraries already installed)"; \
	else \
	    rm -rf $(BUILD)/hurd-src $(BUILD)/hurd && \
	    cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/hurd-src && \
	    cd $(BUILD)/hurd-src && \
	    sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	    autoreconf -i && \
	    export PATH=$(PREFIX)/bin:$$PATH && \
	    mkdir -p $(BUILD)/hurd && cd $(BUILD)/hurd && \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	    $(BUILD)/hurd-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --without-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    for d in libshouldbeinlibc libihash libiohelp libports libpager libfshelp; do \
	        make -C $$d; \
	    done && \
	    for d in libshouldbeinlibc libihash libiohelp libports libpager libfshelp; do \
	        make -C $$d install; \
	    done && \
	    make -C hurd install-headers && \
	    rm -rf $(BUILD)/hurd-src $(BUILD)/hurd; \
	fi
	@echo "=== gate: hurd libraries ==="
	ls $(PREFIX)/lib/libshouldbeinlibc.so $(PREFIX)/include/hurd/io.h >/dev/null

# libpciaccess is built with meson, not autotools. The GNU/Hurd backend is
# selected by the cross file's system = 'gnu'; the pinned upstream commit
# (e33aa5fd) adds the machuser/hurduser libraries that backend needs.
# zlib is disabled: the translator does not read compressed pci.ids, and the
# host's zlib is a Linux build that must not end up in a Hurd binary.
libpciaccess:
	@command -v meson >/dev/null 2>&1 || { \
	    echo "libpciaccess: meson is required on the host"; exit 1; \
	}
	@command -v ninja >/dev/null 2>&1 || { \
	    echo "libpciaccess: ninja is required on the host"; exit 1; \
	}
	@if ls $(PREFIX)/lib/libpciaccess.so >/dev/null 2>&1; then \
	    echo "(skipping: libpciaccess already installed)"; \
	else \
	    test -f $(PREFIX)/include/hurd/pci.h || \
	        cp -f $(REPO_ROOT)/3p/hurd/hurd/pci.h $(PREFIX)/include/hurd/; \
	    rm -rf $(BUILD)/libpciaccess && mkdir -p $(BUILD)/libpciaccess/build && \
	    sed -e "s|@PREFIX@|$(PREFIX)|g" $(REPO_ROOT)/toolchain/cross-gnu.ini.in \
	        > $(BUILD)/libpciaccess/cross.ini && \
	    meson setup $(BUILD)/libpciaccess/build $(REPO_ROOT)/3p/libpciaccess \
	        --cross-file $(BUILD)/libpciaccess/cross.ini \
	        -Dzlib=disabled -Dprefix=$(PREFIX) -Dlibdir=lib && \
	    meson compile -C $(BUILD)/libpciaccess/build && \
	    meson install -C $(BUILD)/libpciaccess/build && \
	    rm -rf $(BUILD)/libpciaccess; \
	fi
	# Also install a static libpciaccess.a so virtio-blk can link fully static.
	@if ! ls $(PREFIX)/lib/libpciaccess.a >/dev/null 2>&1; then \
	    rm -rf $(BUILD)/libpciaccess-static && \
	    mkdir -p $(BUILD)/libpciaccess-static/build && \
	    sed -e "s|@PREFIX@|$(PREFIX)|g" $(REPO_ROOT)/toolchain/cross-gnu.ini.in \
	        > $(BUILD)/libpciaccess-static/cross.ini && \
	    meson setup $(BUILD)/libpciaccess-static/build $(REPO_ROOT)/3p/libpciaccess \
	        --cross-file $(BUILD)/libpciaccess-static/cross.ini \
	        -Dzlib=disabled -Dprefix=$(PREFIX) -Dlibdir=lib \
	        -Ddefault_library=static && \
	    meson compile -C $(BUILD)/libpciaccess-static/build && \
	    cp $(BUILD)/libpciaccess-static/build/src/libpciaccess.a \
	        $(PREFIX)/lib/libpciaccess.a && \
	    rm -rf $(BUILD)/libpciaccess-static; \
	fi
	@echo "=== gate: libpciaccess ==="
	ls $(PREFIX)/lib/libpciaccess.so $(PREFIX)/include/pciaccess.h \
	    $(PREFIX)/lib/pkgconfig/pciaccess.pc >/dev/null
	$(PREFIX)/bin/x86_64-gnu-readelf -d $(PREFIX)/lib/libpciaccess.so.0 \
	    | grep -E "NEEDED.*(machuser|hurduser)"

libtrivfs: hurd mig
	@if ls $(PREFIX)/lib/libtrivfs.so >/dev/null 2>&1; then \
	    echo "(skipping: libtrivfs already installed)"; \
	else \
	    rm -rf $(BUILD)/hurd-src $(BUILD)/hurd && \
	    cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/hurd-src && \
	    cd $(BUILD)/hurd-src && \
	    sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	    autoreconf -i && \
	    export PATH=$(PREFIX)/bin:$$PATH && \
	    mkdir -p $(BUILD)/hurd && cd $(BUILD)/hurd && \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	    $(BUILD)/hurd-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --without-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    for d in libshouldbeinlibc libihash libiohelp libports libpager libfshelp; do \
	        make -C $$d; \
	    done && \
	    make -C libtrivfs && \
	    make -C libtrivfs install && \
	    make -C hurd install-headers; \
	fi
	@echo "=== gate: libtrivfs ==="
	ls $(PREFIX)/lib/libtrivfs.so $(PREFIX)/include/hurd/trivfs.h >/dev/null

libirqhelp: hurd mig
	@if ls $(PREFIX)/lib/libirqhelp.so >/dev/null 2>&1; then \
	    echo "(skipping: libirqhelp already installed)"; \
	else \
	    rm -rf $(BUILD)/hurd-src $(BUILD)/hurd && \
	    cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/hurd-src && \
	    cd $(BUILD)/hurd-src && \
	    sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	    autoreconf -i && \
	    export PATH=$(PREFIX)/bin:$$PATH && \
	    mkdir -p $(BUILD)/hurd && cd $(BUILD)/hurd && \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	    $(BUILD)/hurd-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --without-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    make -C libirqhelp && \
	    make -C libirqhelp install; \
	fi
	@echo "=== gate: libirqhelp ==="
	ls $(PREFIX)/lib/libirqhelp.so $(PREFIX)/include/hurd/irqhelp.h >/dev/null

# libmachdev is the Mach device emulation library behind the bootstrap
# servers (rumpdisk, pci-arbiter, acpi) and now virtio-blk.static: it
# implements the bootstrap protocol (machdev_trivfs_init resumes the
# next task, fsys_getpriv fetches the privileged ports, the translator
# devnode install) and the device_open demux over emulation ops.  The
# virtio repo's static link needs libmachdev.a plus its headers
# (libmachdev/machdev.h et al) installed in the prefix, so this follows
# the libtrivfs recipe: configure the 3p/hurd copy out-of-tree, build
# the dependency libs, then build and install libmachdev.
libmachdev: hurd libtrivfs
	@if ls $(PREFIX)/lib/libmachdev.a >/dev/null 2>&1; then \
	    echo "(skipping: libmachdev already installed)"; \
	else \
	    rm -rf $(BUILD)/machdev-src $(BUILD)/machdev && \
	    cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/machdev-src && \
	    cd $(BUILD)/machdev-src && \
	    sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	    autoreconf -i && \
	    export PATH=$(PREFIX)/bin:$$PATH && \
	    mkdir -p $(BUILD)/machdev && cd $(BUILD)/machdev && \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	    $(BUILD)/machdev-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --without-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    for d in libshouldbeinlibc libihash libiohelp libports libpager libfshelp libtrivfs; do \
	        make -C $$d; \
	    done && \
	    make -C libmachdev && \
	    make -C libmachdev install; \
	fi
	@echo "=== gate: libmachdev ==="
	ls $(PREFIX)/lib/libmachdev.a $(PREFIX)/include/hurd/machdev.h >/dev/null

# libstore in the prefix: the Hurd patched parted needs libstore at its
# configure and link time, and libstore's "part" store class needs parted.
# The dependency is circular, so it is broken in two passes: this target
# builds the Hurd tree without parted and installs libnetfs and libstore,
# which is what the parted configure check looks for; the storeio target
# then rebuilds the tree with --with-parted.
hurd-libstore: hurd mig
	@if [ -f "$(PREFIX)/lib/libstore.a" ]; then \
	    echo "(skipping: libstore already installed)"; \
	else \
	    rm -rf $(BUILD)/hurd-libstore-src $(BUILD)/hurd-libstore && \
	    cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/hurd-libstore-src && \
	    cd $(BUILD)/hurd-libstore-src && \
	    sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	    autoreconf -i && \
	    mkdir -p $(BUILD)/hurd-libstore && cd $(BUILD)/hurd-libstore && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	    $(BUILD)/hurd-libstore-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --without-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    hurd_version=$$(sed -n 's/^package-version := //p' config.make); \
	    sed -e "s/MASTER_HURD_VERSION/\"$$hurd_version\"/" \
	        < $(BUILD)/hurd-libstore-src/version.h.in > $(BUILD)/hurd-libstore/version.h && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libshouldbeinlibc -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libihash -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libiohelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libports -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libpager -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libfshelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libnetfs -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libstore -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libnetfs install && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libstore install && \
	    rm -rf $(BUILD)/hurd-libstore-src $(BUILD)/hurd-libstore; \
	fi
	@echo "=== gate: libstore ==="
	ls $(PREFIX)/lib/libstore.a $(PREFIX)/lib/libstore.so.0.3 >/dev/null

# libuuid is required by libparted, which the Hurd's libstore needs for its
# "part" store class (the partition device nodes /dev/wd0sN).  The cross
# prefix has no util-linux, so the minimal implementation in
# toolchain/libuuid (the subset libparted uses) is built here.  The shared
# library carries the libuuid.so.1 soname, so a dynamically linked storeio
# picks up the system's libuuid at run time.
libuuid:
	@if [ -f "$(PREFIX)/lib/libuuid.a" ]; then \
	    echo "(skipping: libuuid already installed)"; \
	else \
	    rm -rf $(BUILD)/libuuid && mkdir -p $(BUILD)/libuuid && \
	    $(PREFIX)/bin/x86_64-gnu-gcc -O2 -g -Wall -fPIC \
	        -I$(REPO_ROOT)/toolchain/libuuid \
	        -c $(REPO_ROOT)/toolchain/libuuid/uuid.c \
	        -o $(BUILD)/libuuid/uuid.o && \
	    $(PREFIX)/bin/x86_64-gnu-ar rcs $(BUILD)/libuuid/libuuid.a $(BUILD)/libuuid/uuid.o && \
	    $(PREFIX)/bin/x86_64-gnu-gcc -shared -Wl,-soname,libuuid.so.1 \
	        -o $(BUILD)/libuuid/libuuid.so.1.0.0 $(BUILD)/libuuid/uuid.o && \
	    mkdir -p $(PREFIX)/lib $(PREFIX)/include/uuid && \
	    cp $(BUILD)/libuuid/libuuid.a $(BUILD)/libuuid/libuuid.so.1.0.0 $(PREFIX)/lib/ && \
	    ln -sf libuuid.so.1.0.0 $(PREFIX)/lib/libuuid.so.1 && \
	    ln -sf libuuid.so.1 $(PREFIX)/lib/libuuid.so && \
	    cp $(REPO_ROOT)/toolchain/libuuid/uuid/uuid.h $(PREFIX)/include/uuid/ && \
	    rm -rf $(BUILD)/libuuid; \
	fi
	@echo "=== gate: libuuid ==="
	ls $(PREFIX)/lib/libuuid.a $(PREFIX)/include/uuid/uuid.h >/dev/null

# libparted comes from 3p/parted, the Hurd patched parted: it provides
# ped_device_new_from_store, which libstore/part.c needs to build a
# partition store on top of a device store.  Only the library is built;
# the parted program is not needed.  device-mapper support is off (the
# cross prefix has no libdevmapper) and readline support is off (it would
# pull in a cross termcap).  parted 3.8 predates gcc 14, so the build
# uses gnu17 and turns the diagnostics that became errors into warnings.
# nilfs2.c uses offsetof without including stddef.h, so add that standard
# header to the copied source instead of relying on a transitive include.
# The tree is copied out first: it ships no configure script, so it has to
# be bootstrapped, and the checkout stays untouched.  A plain clone leaves
# the gnulib submodule uninitialized; use its HTTPS mirror because the
# recorded git:// URL is not usable in every build environment.
parted: libuuid hurd-libstore
	@if [ -f "$(PREFIX)/lib/libparted.a" ]; then \
	    echo "(skipping: libparted already installed)"; \
	else \
	    rm -rf $(BUILD)/parted-src $(BUILD)/parted && \
	    cp -a $(REPO_ROOT)/3p/parted $(BUILD)/parted-src && \
	    sed -i '/#include <config.h>/a #include <stddef.h>' \
	        $(BUILD)/parted-src/libparted/fs/nilfs2/nilfs2.c && \
	    git -C $(BUILD)/parted-src config submodule.gnulib.url \
	        https://github.com/coreutils/gnulib.git && \
	    git -C $(BUILD)/parted-src submodule update --init --recursive && \
	    cd $(BUILD)/parted-src && \
	    ./bootstrap && \
	    mkdir -p $(BUILD)/parted && cd $(BUILD)/parted && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc \
	    CFLAGS="-O2 -g -std=gnu17 -fcommon -Wno-implicit-function-declaration \
	        -Wno-int-conversion -Wno-incompatible-pointer-types" \
	    LDFLAGS="-L$(PREFIX)/lib" \
	    $(BUILD)/parted-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --disable-device-mapper --without-readline --disable-nls \
	        --disable-gcc-warnings --enable-shared --enable-static && \
	    PATH=$(PREFIX)/bin:$$PATH make -C include/parted -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH make -C lib -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH make -C libparted -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH make -C include/parted install && \
	    PATH=$(PREFIX)/bin:$$PATH make -C libparted install && \
	    rm -rf $(BUILD)/parted-src $(BUILD)/parted; \
	fi
	@echo "=== gate: libparted ==="
	ls $(PREFIX)/lib/libparted.a $(PREFIX)/include/parted/parted.h >/dev/null
	$(PREFIX)/bin/x86_64-gnu-nm $(PREFIX)/lib/libparted.a | \
	    grep -q ped_device_new_from_store && \
	    echo "gate: libparted carries the Hurd store extension"

# storeio is not installed to the prefix by the `hurd` stage, so it has its
# own target. It builds inside a configured out-of-tree Hurd tree (a
# standalone `make -C 3p/hurd/storeio` fails: generated headers such as
# libstore/store.h, libnetfs/fs_S.h, version.h and libhurdbugaddr.a are
# missing).  Libs are built in dependency order:
#   libshouldbeinlibc -> libihash -> libiohelp -> libports -> libpager ->
#   libfshelp -> libnetfs -> libstore -> libhurdbugaddr -> storeio.
# The hurdkit-branch fix (commit e07e9590) fixes the --no-cache byte-to-block
# conversion (<< instead of >>) in storeio/dev.c.
# The tree is configured --with-parted, so libstore has the "part" store
# class and storeio can serve the partition device nodes (/dev/wd0sN) that
# the boot-time fsck opens.  Both a dynamic and a static storeio are built:
# the static one is self-contained (its libstore carries the local device
# class fix) and is what the vm image ships.
#
# The store classes that the static storeio carries.  A statically linked
# storeio only contains the classes whose objects the link pulls in, and the
# Hurd build's default set ("boot-store-types") is the minimal subset a boot
# filesystem needs: device, remap and part.  The vm image installs this
# binary as the system /hurd/storeio, which serves every device node, so it
# needs the full set of selectable classes: without "zero" the image's
# /dev/zero (storeio -Tzero) fails with "Invalid argument to --store-type"
# and the translator dies.  gunzip and bunzip2 stay out: the cross prefix
# has no libz/libbz2, and no device node uses them.
STOREIO_STORE_TYPES := device remap part file zero task copy nbd
storeio: hurd mig parted
	rm -rf $(BUILD)/hurd-src $(BUILD)/hurd && \
	cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/hurd-src && \
	find $(BUILD)/hurd-src \( -name '*.a' -o -name '*.o' \) -delete && \
	cd $(BUILD)/hurd-src && \
	sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	autoreconf -i && \
	mkdir -p $(BUILD)/hurd && cd $(BUILD)/hurd && \
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	    CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	    $(BUILD)/hurd-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --with-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    hurd_version=$$(sed -n 's/^package-version := //p' config.make); \
	    sed -e "s/MASTER_HURD_VERSION/\"$$hurd_version\"/" \
	        < $(BUILD)/hurd-src/version.h.in > $(BUILD)/hurd/version.h && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libshouldbeinlibc -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libihash -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libiohelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libports -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libpager -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libfshelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libnetfs -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libstore -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libhurdbugaddr -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C storeio storeio storeio.static \
	        LDLIBS="-lpthread -lhurduser -lmachuser -lparted -luuid -ldl" \
	        boot-store-types="$(STOREIO_STORE_TYPES)"
	@echo "=== gate: storeio ==="
	file $(BUILD)/hurd/storeio/storeio.static
	file $(BUILD)/hurd/storeio/storeio.static | grep -q 'for GNU/Hurd' || { echo "storeio: binary is not a GNU/Hurd ELF" >&2; exit 1; }
	$(PREFIX)/bin/x86_64-gnu-nm $(BUILD)/hurd/storeio/storeio.static | \
	    grep -q ped_device_probe_all && \
	    echo "gate: storeio carries the parted partition store"
	$(PREFIX)/bin/x86_64-gnu-nm $(BUILD)/hurd/storeio/storeio.static | \
	    grep -q ' store_zero_class$$' && \
	    echo "gate: storeio carries the zero store class"

# hurd-servers builds the Hurd servers and translators out of a copy of
# 3p/hurd, without installing to the prefix (installationdir is absolute,
# so DESTDIR prepends to an absolute path and produces a wrong nested
# path).  Binaries are read straight out of the out-of-tree build tree at
# $(BUILD)/hurd-servers/<subdir>/ (prefer <target>.static where it
# exists, falling back to <target>).
# Depends on hurd and mig for installed libraries and the MIG stub
# compiler.  Libs are built in dependency order (as storeio does):
#   libshouldbeinlibc -> libihash -> libiohelp -> libports -> libpager ->
#   libfshelp -> libnetfs -> libstore -> libhurdbugaddr,
#   plus libtrivfs libirqhelp for translators.
# The tree is configured --with-parted (like the storeio target): GRUB
# starts the static ext2fs with "-T typed part:2:device:wd0", and libstore
# only registers the "part" store class when built with parted.  Without
# it store_typed_open fails with EINVAL ("ext2fs: part:2:device:wd0:
# Invalid argument") and the guest never mounts its root.  With
# PARTED_LIBS set, boot_store_types gains "part", ext2fs.static links
# libstore_part.a, and Makeconf's .static rule appends $(PARTED_LIBS).
hurd-servers: hurd mig parted
	rm -rf $(BUILD)/hurd-servers-src $(BUILD)/hurd-servers && \
	cp -a $(REPO_ROOT)/3p/hurd $(BUILD)/hurd-servers-src && \
	find $(BUILD)/hurd-servers-src \( -name '*.a' -o -name '*.o' \) -delete && \
	mkdir -p $(BUILD)/hurd-servers-src/include/hurd && \
	shopt -s nullglob && \
	for d in $(BUILD)/hurd-servers-src/*/; do \
	    [ "$$d" = "$(BUILD)/hurd-servers-src/include/" ] && continue; \
	    d_base=$$(basename $$d); \
	    for h in $$d*.h; do \
	        b=$$(basename $$h); \
	        # Expose headers the prefix does not already provide, so the \
	        # in-place build never shadows consistent prefix headers.  Flat \
	        # (installhdrsubdir=., e.g. libps/ps.h) and <hurd/foo.h> \
	        # locations are both covered.  Never clobber a real header already \
	        # copied into the source tree (e.g. include/pids.h). \
	        if [ ! -f $(BUILD)/hurd-servers-src/include/$$b ] \
	            && [ ! -f $(PREFIX)/include/$$b ]; then \
	            ln -sf ../$$d_base/$$b $(BUILD)/hurd-servers-src/include/$$b; \
	        fi; \
	        if [ ! -f $(PREFIX)/include/hurd/$$b ]; then \
	            ln -sf ../../$$d_base/$$b $(BUILD)/hurd-servers-src/include/hurd/$$b; \
	        fi; \
	    done; \
	done && \
	cd $(BUILD)/hurd-servers-src && \
	sed -i -e '/^if test "x$$cross_compiling" = "xyes"; then$$/,/^fi$$/d' configure.ac && \
	autoreconf -i && \
	mkdir -p $(BUILD)/hurd-servers && cd $(BUILD)/hurd-servers && \
	PATH=$(PREFIX)/bin:$$PATH \
	CC=$(PREFIX)/bin/x86_64-gnu-gcc MIG=$(PREFIX)/bin/mig \
	CPPFLAGS="-I$(PREFIX)/include" LDFLAGS="-L$(PREFIX)/lib" CPATH=$(PREFIX)/include \
	CFLAGS="$(CFLAGS)" \
	$(BUILD)/hurd-servers-src/configure \
	        --host=x86_64-gnu --build=x86_64-pc-linux-gnu --prefix=$(PREFIX) \
	        --with-parted --without-libtirpc --without-libdaemon \
	        --without-rump --without-acpica --without-libcrypt --disable-profile && \
	    sed -e 's/MASTER_HURD_VERSION/"$(shell sed -n "s/^package-version := //p" $(BUILD)/hurd-servers/config.make)"/' \
	        < $(BUILD)/hurd-servers-src/version.h.in > $(BUILD)/hurd-servers/version.h && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libshouldbeinlibc -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libihash -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libps -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libiohelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libports -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libcons -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libpipe -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libpager -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libfshelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libnetfs -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libstore -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libdiskfs -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libhurdbugaddr -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libtrivfs -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libirqhelp -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libbpf -j$(NPROC) && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C libftpconn -j$(NPROC) && \
	    for d in $(HURD_SERVERS_SUBDIRS); do \
	        if [ "$$d" = storeio ]; then \
	            # The tree is --with-parted, so storeio compiles its own \
	            # part.c and its dynamic link needs -lparted (Makeconf only \
	            # appends PARTED_LIBS to .static links, and the command-line \
	            # LDLIBS below would drop storeio's Makefile default). \
	            PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C $$d \
	                LDLIBS="-lpthread -lhurduser -lmachuser -lparted -luuid -ldl" -j$(NPROC) || exit 1; \
	        else \
	            PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C $$d LDLIBS="-lpthread -lhurduser -lmachuser" -j$(NPROC) || exit 1; \
	        fi; \
	    done && \
	    PATH=$(PREFIX)/bin:$$PATH CFLAGS="$(CFLAGS)" make -C ext2fs ext2fs.static \
	        LDLIBS="-lpthread -lhurduser -lmachuser" -j$(NPROC) || exit 1;
	@echo "=== gate: hurd-servers ==="
	file $(BUILD)/hurd-servers/ext2fs/ext2fs
	file $(BUILD)/hurd-servers/ext2fs/ext2fs.static
	$(PREFIX)/bin/x86_64-gnu-nm $(BUILD)/hurd-servers/ext2fs/ext2fs.static | \
	    grep -q store_part_open && \
	    echo "gate: ext2fs.static carries the parted partition store"

# 9pfs calls two RPC stubs directly: exec_exec_paths (file-exec-paths.c,
# from libhurduser) and mach_port_move_member (io-reauthenticate.c, from
# libmachuser). libc NEEDs both DSOs, so the loader finds them at run time;
# but GNU ld does not use a DSO that is only a *transitive* dependency of
# libc to resolve undefined references coming from regular objects, and
# refuses the link with "DSO missing from command line". 9pfs's Makefile
# does not honor LDFLAGS (it links with $(CFLAGS) and $(LIBS) only), so the
# extra libraries are passed by overriding LIBS on the make command line;
# 3p/9pfs stays pristine upstream.
9pfs: hurd
	$(MAKE) -C $(REPO_ROOT)/3p/9pfs clean
	$(MAKE) -C $(REPO_ROOT)/3p/9pfs \
	    $(VIRTIO_COMMON_FLAGS) \
	    LIBS="shouldbeinlibc ihash ports iohelp fshelp pager hurduser machuser" \
	    MIG=$(PREFIX)/bin/mig
	@echo "=== gate: 9pfs ==="
	file $(REPO_ROOT)/3p/9pfs/9pfs

# The virtio drivers live in their own repo (the standalone pattern of
# 3p/9pfs, per the virtio plan: standalone repo first, subtree-merge into
# 3p/hurd later); they link the cross prefix like 9pfs, plus libtrivfs and
# libpciaccess, and stay uncommitted to the 3p trees.  VIRTIO_DIR selects
# which checkout is built, so a workbranch can be tested in place.
# The driver build also needs the pinned Hurd source tree (for the
# libports MIG headers and libbpf) and the install prefix; both are
# passed explicitly so the virtio Makefile's defaults never apply here.
VIRTIO_DIR ?= $(HOME)/src/virtio
# Cross-compile flags shared by the virtio drivers and 9pfs (both link the
# cross prefix the same way). VIRTIO_MAKEFLAGS adds HURD_SRC/HURD_PREFIX on
# top; 9pfs inlines these directly with its own LIBS and MIG overrides.
VIRTIO_COMMON_FLAGS = \
    PATH=$(PREFIX)/bin:$$PATH \
    CC=$(PREFIX)/bin/x86_64-gnu-gcc \
    CPATH=$(PREFIX)/include

VIRTIO_MAKEFLAGS = \
    $(VIRTIO_COMMON_FLAGS) \
    HURD_PREFIX=$(PREFIX) \
    HURD_SRC=$(REPO_ROOT)/3p/hurd \
    CFLAGS="$(CFLAGS)" \
    LIBS="shouldbeinlibc ihash ports iohelp fshelp trivfs pciaccess hurduser machuser irqhelp"

# Hurd servers/translators to ship in a vm image (subdirs of 3p/hurd).
# Must mirror the top-level Makefile's HURD_SERVERS_SUBDIRS default.
# Excludes daemons and trans, which use makemode := servers (multiple
# binaries per dir) and don't fit the single-binary-per-dir loop.
HURD_SERVERS_SUBDIRS ?= auth proc exec term ext2fs tmpfs fatfs \
	storeio pfinet console init devnode pflocal boot \
	hostmux usermux ftpfs shutdown rtc \
	eth-multiplexer

virtio-9p: hurd libpciaccess libtrivfs libirqhelp
	$(MAKE) -C $(VIRTIO_DIR) clean
	$(MAKE) -C $(VIRTIO_DIR) $(VIRTIO_MAKEFLAGS)
	@echo "=== gate: virtio-9p ==="
	file $(VIRTIO_DIR)/virtio-9p

# The repo Makefile's default target builds the translator and both
# daemons in one pass, so this reuses the same invocation and gates on the
# balloon binary.
virtio-balloon: hurd libpciaccess libirqhelp
	$(MAKE) -C $(VIRTIO_DIR) clean
	$(MAKE) -C $(VIRTIO_DIR) $(VIRTIO_MAKEFLAGS)
	@echo "=== gate: virtio-balloon ==="
	file $(VIRTIO_DIR)/virtio-balloon

# Same build and gate shape as virtio-balloon: the repo Makefile's
# default target already builds the blk driver, so this only names the
# binaries the disk harness installs: virtio-blk (raw datapath +
# Mach device translator) and vblk-client (the direct-RPC harness
# client).
virtio-blk: hurd libpciaccess libirqhelp
	$(MAKE) -C $(VIRTIO_DIR) clean
	$(MAKE) -C $(VIRTIO_DIR) $(VIRTIO_MAKEFLAGS)
	@echo "=== gate: virtio-blk ==="
	file $(VIRTIO_DIR)/virtio-blk
	file $(VIRTIO_DIR)/vblk-client

# Static build of virtio-blk: links all Hurd libs (including libpciaccess.a)
# into a single self-contained binary named virtio-blk.static, suitable for
# the vm image where dynamic library paths may not be set up.
# Compiles objects via the repo Makefile, then links manually with -static and
# --start-group/--end-group to break circular static-archive references
# between libmachdev, libtrivfs, libports, libiohelp, libfshelp and
# libshouldbeinlibc.
# The static binary serves the bootstrap chain (--next-task) and --serve
# through libmachdev (the rumpdisk pattern); its virtio-blk-machdev.o
# replaces the libports translator objects (virtio-blk-serve.o,
# virtio-serve.o, deviceServer.o, notifyServer.o), which define the same
# trivfs hooks and ds_device_* symbols as libmachdev and cannot be linked
# beside it.  The dynamic virtio-blk keeps that libports path.
# The static libraries for shouldbeinlibc, ihash, ports, iohelp, fshelp,
# trivfs, machdev, pciaccess, hurduser, machuser and irqhelp must be
# pre-installed in $(PREFIX)/lib (built by the hurd/libtrivfs/libmachdev/
# libirqhelp/libpciaccess targets). The pin in 3p/hurd blocks those targets
# here, so we check explicitly instead of declaring a make dependency.
virtio-blk-static: libmachdev libpciaccess
	$(MAKE) -C $(VIRTIO_DIR) clean
	$(MAKE) -C $(VIRTIO_DIR) virtio-blk $(VIRTIO_MAKEFLAGS)
	$(MAKE) -C $(VIRTIO_DIR) virtio-blk-machdev.o $(VIRTIO_MAKEFLAGS)
	@missing=; \
	for lib in shouldbeinlibc ihash ports iohelp fshelp trivfs machdev pciaccess hurduser machuser irqhelp; do \
	    if [ ! -f "$(PREFIX)/lib/lib$${lib}.a" ]; then \
	        missing="$$missing lib$${lib}.a"; \
	    fi; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "virtio-blk-static: missing static libraries:$$missing" >&2; \
	    echo "  Build them first (e.g. make -C toolchain hurd libtrivfs libmachdev libirqhelp libpciaccess)" >&2; \
	    exit 1; \
	fi
	$(PREFIX)/bin/x86_64-gnu-gcc -static \
	    $(VIRTIO_DIR)/virtio-blk.o \
	    $(VIRTIO_DIR)/virtio-blk-dev.o \
	    $(VIRTIO_DIR)/virtio-blk-req.o \
	    $(VIRTIO_DIR)/virtio-blk-hurd.o \
	    $(VIRTIO_DIR)/virtio-blk-machdev.o \
	    $(VIRTIO_DIR)/virtio-pool.o \
	    $(VIRTIO_DIR)/virtio-pci.o \
	    $(VIRTIO_DIR)/virtio-queue.o \
	    -o $(VIRTIO_DIR)/virtio-blk.static -pthread \
	    -Wl,--start-group \
	    -lmachdev -lshouldbeinlibc -lihash -lports -liohelp -lfshelp \
	    -ltrivfs -lpciaccess -lhurduser -lmachuser -lirqhelp \
	    -Wl,--end-group
	@echo "=== gate: virtio-blk-static ==="
	file $(VIRTIO_DIR)/virtio-blk.static

# Same build and gate shape as virtio-blk: the repo Makefile's default
# target already builds the net driver, so this names the binary the
# network harness installs: virtio-net (raw datapath + Mach device
# translator).
virtio-net: hurd libpciaccess libirqhelp
	$(MAKE) -C $(VIRTIO_DIR) clean
	$(MAKE) -C $(VIRTIO_DIR) $(VIRTIO_MAKEFLAGS)
	@echo "=== gate: virtio-net ==="
	file $(VIRTIO_DIR)/virtio-net
	file $(VIRTIO_DIR)/vnet-client

# Clean the virtio driver build artifacts in VIRTIO_DIR.
virtio-clean:
	$(MAKE) -C $(VIRTIO_DIR) clean

verify-vm: 9pfs
	@echo "=== V2: ELF check ==="
	file $(REPO_ROOT)/3p/9pfs/9pfs
	$(PREFIX)/bin/x86_64-gnu-readelf -h $(REPO_ROOT)/3p/9pfs/9pfs | sed -n '1,12p'
	@echo "=== V3: install into VM ==="
	scp -P $(SSH_PORT) -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    $(REPO_ROOT)/3p/9pfs/9pfs root@127.0.0.1:/tmp/9pfs
	ssh -p $(SSH_PORT) -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    root@127.0.0.1 'file /tmp/9pfs && chmod 755 /tmp/9pfs'
	@echo "=== V4: smoke test ==="
	ssh -p $(SSH_PORT) -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    root@127.0.0.1 '/tmp/9pfs --version'
	ssh -p $(SSH_PORT) -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    root@127.0.0.1 '/tmp/9pfs --help; echo EXIT=$$?'

clean:
	rm -rf $(BUILD)/*

# --- docker backend ----------------------------------------------------------

else ifeq ($(BACKEND),docker)

# Stages 1–6 run inside the container with /src/3p (Hurd sources, ro) and
# /opt/x86_64-gnu (install prefix, rw) bind-mounted. Stages 7–8 (Hurd
# libs, 9pfs) additionally need MIG (already installed by the container run
# above) and are intentionally stubbed here.
toolchain: 3p-pin Dockerfile.hurd-x86_64-gnu docker-stages.sh
	docker build -t hurd-x86_64-gnu -f Dockerfile.hurd-x86_64-gnu .
	@echo "=== running build stages 1-6 in container ==="
	mkdir -p $(HOME)/opt/x86_64-gnu
	docker run --rm \
	    --user "$$(id -u):$$(id -g)" \
	    -e HOME=/tmp/home \
	    -v $$(readlink -f $(REPO_ROOT)/3p):/src/3p:ro \
	    -v $(HOME)/opt/x86_64-gnu:/opt/x86_64-gnu:rw \
	    hurd-x86_64-gnu

binutils gcc1 gcc2 gnumach mig glibc: toolchain
	@echo "stages $@ are run by the container above (binutils -> gcc2, incl. MIG)"

hurd libpciaccess 9pfs verify-vm: toolchain
	@echo "stage $@ is not implemented in the docker backend yet;"
	@echo "run it host-local: make -C toolchain $@ BACKEND=hostlocal"
	@echo "(MIG, the Hurd headers and glibc are installed in the prefix;"
	@echo "the Hurd libraries build against the freshly built glibc)"

fetch: toolchain
	@echo "sources are fetched inside the Docker image during docker build"

toolchain-clean:
	docker rmi -f hurd-x86_64-gnu 2>/dev/null || true

clean: toolchain-clean

endif
