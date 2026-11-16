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

BINUTILS_VER := 2.46.1
GCC_VER      := 15.3.0

.PHONY: all toolchain toolchain-clean fetch binutils gcc1 gnumach glibc gcc2 mig hurd hurd-headers libpciaccess libtrivfs libirqhelp virtio-9p 9pfs verify-vm clean tooldir 3p-pin glibc-rebuild

# The verified 3p checkouts, pinned to exact SHAs (see
# stuff/crosscompile_plan.md, "3p source pins"). The shared 3p checkout is
# mounted read-only by the docker backend, so the pin is applied on the host
# before either backend builds. The 9pfs pin is pristine upstream master.
# The 3p source URLs and verified pins live in toolchain/pins.mk, shared
# with the top-level Makefile, whose fetch-3p target clones the checkouts.
include pins.mk

# Pin the 3p repos to the verified SHAs. No-op when already pinned. Refuses
# to proceed if a repo has uncommitted changes (it may be shared with other
# work) or if the pinned commit is unavailable (network or wrong checkout;
# restore the pinned 3p tree).
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
# prefix install and are created here as symlinks. Idempotent; existing
# real directories are left alone.
tooldir:
	@mkdir -p $(PREFIX)/x86_64-gnu
	@if [ -d $(PREFIX)/x86_64-gnu/include ] && [ ! -L $(PREFIX)/x86_64-gnu/include ]; then \
	    echo "tooldir: leaving existing include directory"; \
	else ln -sfnT $(PREFIX)/include $(PREFIX)/x86_64-gnu/include; fi
	@if [ -d $(PREFIX)/x86_64-gnu/lib ] && [ ! -L $(PREFIX)/x86_64-gnu/lib ]; then \
	    echo "tooldir: leaving existing lib directory"; \
	else ln -sfnT $(PREFIX)/lib $(PREFIX)/x86_64-gnu/lib; fi


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

# libpciaccess is built with meson, not autotools. The GNU/Turd backend is
# selected by the cross file's system = 'gnu'; the pinned upstream commit
# (e33aa5fd) adds the machuser/hurduser libraries that backend needs.
# zlib is disabled: the translator does not read compressed pci.ids, and the
# host's zlib is a Linux build that must not end up in a Hurd binary.
libpciaccess: hurd
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
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc \
	    CPATH=$(PREFIX)/include \
	    LIBS="shouldbeinlibc ihash ports iohelp fshelp pager hurduser machuser" \
	    MIG=$(PREFIX)/bin/mig
	@echo "=== gate: 9pfs ==="
	file $(REPO_ROOT)/3p/9pfs/9pfs

# The virtio-9p translator lives in its own repo (the standalone pattern of
# 3p/9pfs, per the virtio plan: standalone repo first, subtree-merge into
# 3p/hurd later); it links the cross prefix like 9pfs, plus libtrivfs and
# libpciaccess, and stays uncommitted to the 3p trees.
virtio-9p: hurd libpciaccess libtrivfs libirqhelp
	$(MAKE) -C $(HOME)/src/virtio clean
	$(MAKE) -C $(HOME)/src/virtio \
	    PATH=$(PREFIX)/bin:$$PATH \
	    CC=$(PREFIX)/bin/x86_64-gnu-gcc \
	    CPATH=$(PREFIX)/include \
	    LIBS="shouldbeinlibc ihash ports iohelp fshelp trivfs pciaccess hurduser machuser irqhelp"
	@echo "=== gate: virtio-9p ==="
	file $(HOME)/src/virtio/virtio-9p

verify-vm: 9pfs
	@echo "=== V2: ELF check ==="
	file $(REPO_ROOT)/3p/9pfs/9pfs
	$(PREFIX)/bin/x86_64-gnu-readelf -h $(REPO_ROOT)/3p/9pfs/9pfs | sed -n '1,12p'
	@echo "=== V3: install into VM ==="
	scp -P 2222 -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    $(REPO_ROOT)/3p/9pfs/9pfs root@127.0.0.1:/tmp/9pfs
	ssh -p 2222 -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    root@127.0.0.1 'file /tmp/9pfs && chmod 755 /tmp/9pfs'
	@echo "=== V4: smoke test ==="
	ssh -p 2222 -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
	    root@127.0.0.1 '/tmp/9pfs --version'
	ssh -p 2222 -i $(REPO_ROOT)/img/keys/root_ed25519 -o StrictHostKeyChecking=accept-new \
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
