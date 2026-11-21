# Fetch, convert, and boot a Debian GNU/Hurd x86_64 image via QEMU.
#
# The downloaded image is stored in img/ and is never deleted.
# A pristine qcow2 base disk is created from it (after offline
# preparation), and the VM boots from a temporary copy-on-write
# overlay so the base stays unchanged.

# Pinned Hurd image version
VERSION       := 20260314

# Configuration
REPO_ROOT     ?= $(CURDIR)
IMG_DIR       := img
IMG_URL       := https://cdimage.debian.org/cdimage/ports/latest/hurd-amd64/debian-hurd-amd64-$(VERSION).img.tar.xz
MD5_SUM       := 91dc71608fcfc9f237028f1fe87c39c2
IMG_TAR       := $(IMG_DIR)/debian-hurd-amd64-$(VERSION).img.tar.xz
RAW_IMG       := $(IMG_DIR)/debian-hurd-amd64-$(VERSION).img
# Out-of-tree cross build directory (matches toolchain/Makefile).
BUILD         := $(HOME)/work/x86_64-gnu-build
# Stamp for the extraction step: the tarball preserves the member mtime,
# which is older than the tarball itself, so the raw image would otherwise
# be extracted again on every make invocation.
EXTRACT_STAMP := $(IMG_DIR)/.extracted
WORK_IMG      := $(IMG_DIR)/hurd.work.img
# "base" is the raw, offline-prepared OS image: no accounts, no SSH keys,
# no guest packages.  Every provisioning step lands in its own staged image
# on top of it (accounts -> packages -> kernel), so rebuilding the base
# never silently drops the provisioning, and the test harnesses can take
# their CoW snapshots from the stage that matches what they need.
BASE_IMG      := $(IMG_DIR)/hurd.base.qcow2
TMP_DIR       := $(IMG_DIR)/tmp
MEMORY        := 2G
CPU_COUNT     := 4
# ?= so the port can come from the environment or the command line
# (SSH_PORT=2223 make run): everything below (run, run-nokvm, ssh,
# ssh-peon, the provisioning stages) already uses this one variable.
SSH_PORT      ?= 2222
SSH_HOST      ?= 127.0.0.1
REUSE         ?= 0
ROOT_PASSWORD := abcdef
# The in-VM package upgrade is off by default: the sid archive ships a
# hurd-dev that cannot be unpacked on Hurd. Set it to 1 to run
# "apt-get update" and "apt-get upgrade" during the provisioning.
RUN_APT_UPGRADE := 0
# The packages that the guest gets during the provisioning. The list can be
# changed, and the provisioning installs the packages that are missing.
GUEST_PACKAGES := curl python3 gdb
# Staged image builds (make stage): VARIANT is the image that is produced,
# STAGE the stage that is applied on top of STAGE_INPUT, CUSTOM_KERNEL the
# host-built kernel binary that the kernel stage ships in the overlay.
STAGE_INPUT   ?= $(BASE_IMG)
VARIANT       ?= $(IMG_DIR)/hurd.kernel.qcow2
STAGE         ?= kernel
CUSTOM_KERNEL ?=
# The image the test harnesses boot: the staged packages variant carries
# the account SSH keys (accounts stage) and gdb/python3 (packages stage),
# unlike the raw base.  As a make prerequisite it pulls the stage chain
# (base -> accounts -> packages) through the rules below when missing or
# stale, so a test run never boots an image without keys.
TEST_IMG      ?= $(IMG_DIR)/hurd.packages.qcow2
# A host directory copied into the guest filesystem by the kernel stage,
# for out-of-tree drivers, init scripts etc.  CUSTOM_KERNEL travels in
# the same overlay.
CUSTOM_OVERLAY ?=
# The SSH keys of the guest accounts. The private keys stay in this
# directory and are used to log into the guest without a password.
SSH_KEY_DIR   := $(IMG_DIR)/keys
# The host directory shared with the guest through virtio-9p, and the
# standalone repo of the virtio drivers (translator and daemons).
# VIRTIO_DIR is overridable so a workbranch (e.g. ~/src/virtio) can be
# built and tested without touching the checked-out tree.
SHARE_DIR     := $(CURDIR)/$(IMG_DIR)/share
VIRTIO_DIR    ?= $(HOME)/src/virtio
VIRTIO_NET_DIR ?= $(VIRTIO_DIR)
VNET_IMG       ?= $(IMG_DIR)/hurd.vnet.qcow2
VIRTIO_9P_BIN := $(VIRTIO_DIR)/virtio-9p
# The gnumach source checkout used for the kernel build. Override this to
# build a worktree instead of the pinned 3p checkout.
GNUMACH_DIR   ?= 3p/gnumach
# Number of CPUs configured in the gnumach kernel.
GNUMACH_NCPUS ?= 1

# Number of vCPUs for the SMP test harness (default 2; must equal
# GNUMACH_NCPUS for the SMP kernel build or gnumach's ACPI parse aborts).
SMP_CPU_COUNT ?= 2

# Number of vCPUs for the UP test harness (default 1; must equal
# GNUMACH_NCPUS for the UP kernel build).
UP_CPU_COUNT ?= 1

# Toolchain
QEMU_SYSTEM   := qemu-system-x86_64
QEMU_IMG      := qemu-img
WGET          := wget
TAR           := tar
MKDIR_P       := mkdir -p
RM            := rm -f
# Serialises the image building steps: two concurrent builds would write to
# the same image files and corrupt them.
LOCK          := flock
LOCK_FILE     := $(IMG_DIR)/.build.lock

.PHONY: all download check base accounts packages kernel provision stage
.PHONY: run run-nokvm ssh ssh-peon
.PHONY: clean distclean clean-images rebuild
.PHONY: toolchain toolchain-clean toolchain-docker
.PHONY: verify-vm hurd-build
.PHONY: gnumach-kernel smp-kernel up-kernel 9pfs fetch-3p
.PHONY: virtio-blk virtio-blk-test virtio-net virtio-net-test
.PHONY: virtio-net-image virtio-net-connectivity-test
.PHONY: virtio-bench-image virtio-bench-vnet-image virtio-bench
.PHONY: run-smp-tests run-up-tests smp-image up-image clock-pause-test
.PHONY: virtio-clean gnumach-clean

# The default builds the whole image pipeline, with every intermediate
# exposed as its own qcow2 (see the stage rules below).
all: base accounts packages

# Download the image if missing
$(IMG_TAR):
	$(MKDIR_P) $(IMG_DIR)
	$(WGET) -O $@ $(IMG_URL)

# Verify MD5 checksum
check: $(IMG_TAR)
	@echo "$$(md5sum $(IMG_TAR) | cut -d' ' -f1)  $(IMG_TAR)" | grep -q "^$(MD5_SUM)  " || { echo "Checksum failed"; exit 1; }

# Download the image only
download: check

# Extract the raw image from the tarball if missing
$(EXTRACT_STAMP): $(IMG_TAR)
	$(TAR) -xJf $< -C $(IMG_DIR)
	touch $@

# Prepare the raw image offline (GRUB serial console, passwords, sshd
# configuration), then convert it to a qcow2 base image.
base: $(BASE_IMG)

# The image is built in a temporary file and moved into place, so that an
# interrupted build never leaves a partially written base image behind.
# The preparation scripts are prerequisites, so that changing them rebuilds
# the base image. Every prerequisite is a real file: a phony prerequisite
# would rebuild the base image, and discard its provisioning, on every
# "make run" and "make provision".
$(BASE_IMG): $(EXTRACT_STAMP) scripts/prepare_base.sh scripts/partition.sh
	@$(MKDIR_P) $(IMG_DIR)
	@$(LOCK) $(LOCK_FILE) sh -c 'set -e; \
		ROOT_PASSWORD=$(ROOT_PASSWORD) bash scripts/prepare_base.sh $(RAW_IMG) $(WORK_IMG); \
		$(QEMU_IMG) convert -f raw -O qcow2 $(WORK_IMG) $(WORK_IMG).qcow2; \
		mv -f $(WORK_IMG).qcow2 $@; \
		rm -f $(WORK_IMG)'

# The staged provisioning chain, exposed stage by stage: each stage is its
# own qcow2 layered on the previous one, so "base" always stays the raw
# offline-prepared image and a base rebuild propagates through the chain
# instead of being folded into it.
accounts: $(IMG_DIR)/hurd.accounts.qcow2
packages: $(IMG_DIR)/hurd.packages.qcow2
kernel:   $(IMG_DIR)/hurd.kernel.qcow2

# Provisioning alias for the old provision-the-base workflow: build the
# accounts and packages stage images.  The base image itself is never
# provisioned in place.
provision: accounts packages

# Apply one provisioning stage to an image and write a new image layered on
# top of it: accounts -> packages -> kernel -> ... Each stage boots the input
# image in a throwaway overlay and promotes that overlay (with its writes) to
# VARIANT, a thin CoW image backed by the input, so a failed stage never
# touches the input. The kernel stage needs CUSTOM_KERNEL (for example the
# gnumach built under ~/work/x86_64-gnu-build/gnumach) or CUSTOM_OVERLAY.
#
#   make stage STAGE=kernel VARIANT=img/hurd.kernel.qcow2 \
#       CUSTOM_KERNEL=~/work/x86_64-gnu-build/gnumach/gnumach
#
# The input image is not a make prerequisite: chaining means the input of a
# stage is the output of the previous one (see the chain rules below), and a
# one-off input does not have a rule. The stage script checks that it exists.
stage:
	@if [ ! -f "$(STAGE_INPUT)" ]; then \
		echo "stage: STAGE_INPUT not found: $(STAGE_INPUT)" >&2; exit 1; \
	fi
	@$(MKDIR_P) $(IMG_DIR)
	@$(LOCK) $(LOCK_FILE) env ROOT_PASSWORD=$(ROOT_PASSWORD) \
		CPU_COUNT=$(CPU_COUNT) MEMORY=$(MEMORY) \
		RUN_APT_UPGRADE=$(RUN_APT_UPGRADE) \
		GUEST_PACKAGES="$(GUEST_PACKAGES)" \
		CUSTOM_KERNEL="$(CUSTOM_KERNEL)" \
		CUSTOM_OVERLAY="$(CUSTOM_OVERLAY)" \
		SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))" \
		bash scripts/provision_stage.sh $(STAGE) $(abspath $(STAGE_INPUT)) $(abspath $(VARIANT)) $(SSH_PORT)

# The staged chain as real make targets: each stage image is built from the
# output of the previous stage, so rebuilding the variant rebuilds only the
# stages whose input or script changed. The accounts and packages images are
# the pipeline's intermediates; kernel variants are always built on top of
# the packages image, never into the base. An image backs its predecessor by
# path: if that predecessor is rebuilt, rebuild the dependent image too (make
# does, through these rules).
STAGE_ENV = ROOT_PASSWORD=$(ROOT_PASSWORD) \
		CPU_COUNT=$(CPU_COUNT) MEMORY=$(MEMORY) \
		RUN_APT_UPGRADE=$(RUN_APT_UPGRADE) \
		GUEST_PACKAGES="$(GUEST_PACKAGES)" \
		SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))"

$(SSH_KEY_DIR)/%_ed25519:
	@mkdir -p $(SSH_KEY_DIR)
	ssh-keygen -t ed25519 -N '' -f $@ -C '$*@hurd' >/dev/null

$(SSH_KEY_DIR)/%_ed25519.pub: $(SSH_KEY_DIR)/%_ed25519
	@test -f $@ || ssh-keygen -y -f $< > $@

$(IMG_DIR)/hurd.accounts.qcow2: $(BASE_IMG) scripts/provision_stage.sh scripts/provision_guest.py $(SSH_KEY_DIR)/root_ed25519 $(SSH_KEY_DIR)/root_ed25519.pub $(SSH_KEY_DIR)/peon_ed25519 $(SSH_KEY_DIR)/peon_ed25519.pub
	@$(LOCK) $(LOCK_FILE) env $(STAGE_ENV) \
		bash scripts/provision_stage.sh accounts $(abspath $<) $(abspath $@) $(SSH_PORT)

$(IMG_DIR)/hurd.packages.qcow2: $(IMG_DIR)/hurd.accounts.qcow2 scripts/provision_stage.sh scripts/provision_guest.py
	@$(LOCK) $(LOCK_FILE) env $(STAGE_ENV) \
		bash scripts/provision_stage.sh packages $(abspath $<) $(abspath $@) $(SSH_PORT)

# $(CUSTOM_OVERLAY) is a directory prerequisite: make sees its mtime, which
# changes when entries are added or removed directly in it; an edit deep
# inside does not, and needs a re-run through the prerequisite-free stage
# target (or a touch of the directory).
$(IMG_DIR)/hurd.kernel.qcow2: $(IMG_DIR)/hurd.packages.qcow2 scripts/provision_stage.sh scripts/provision_guest.py $(CUSTOM_KERNEL) $(CUSTOM_OVERLAY)
	@$(LOCK) $(LOCK_FILE) env $(STAGE_ENV) \
		CUSTOM_KERNEL="$(CUSTOM_KERNEL)" \
		CUSTOM_OVERLAY="$(CUSTOM_OVERLAY)" \
		bash scripts/provision_stage.sh kernel $(abspath $<) $(abspath $@) $(SSH_PORT)

# Boot the image in a throwaway overlay for interactive use.  This boots
# the raw base: log in with the root password (the accounts and SSH keys
# live in the staged images).
run: $(BASE_IMG)
	$(MKDIR_P) $(TMP_DIR)
	@OVERLAY=$$(mktemp -u $(TMP_DIR)/XXXXXX.qcow2); \
	trap 'rm -f "$$OVERLAY"' EXIT; \
	$(QEMU_IMG) create -f qcow2 -b $(abspath $(BASE_IMG)) -F qcow2 $$OVERLAY; \
	if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then \
		echo "Booting with KVM acceleration" >&2; \
		$(QEMU_SYSTEM) \
			-enable-kvm \
			-cpu host \
			-smp $(CPU_COUNT) \
			-m $(MEMORY) \
			-drive file=$$OVERLAY,if=ide,cache=writeback \
			-netdev user,id=net0,hostfwd=tcp:$(SSH_HOST):$(SSH_PORT)-:22 \
			-device e1000,netdev=net0 \
			-nographic; \
	else \
		echo "KVM is not available, booting without acceleration" >&2; \
		$(QEMU_SYSTEM) \
			-cpu max \
			-smp $(CPU_COUNT) \
			-m $(MEMORY) \
			-drive file=$$OVERLAY,if=ide,cache=writeback \
			-netdev user,id=net0,hostfwd=tcp:$(SSH_HOST):$(SSH_PORT)-:22 \
			-device e1000,netdev=net0 \
			-nographic; \
	fi

# Boot without KVM
run-nokvm: $(BASE_IMG)
	$(MKDIR_P) $(TMP_DIR)
	@OVERLAY=$$(mktemp -u $(TMP_DIR)/XXXXXX.qcow2); \
	trap 'rm -f "$$OVERLAY"' EXIT; \
	$(QEMU_IMG) create -f qcow2 -b $(abspath $(BASE_IMG)) -F qcow2 $$OVERLAY; \
	$(QEMU_SYSTEM) \
		-cpu max \
		-smp $(CPU_COUNT) \
		-m $(MEMORY) \
		-drive file=$$OVERLAY,if=ide,cache=writeback \
		-netdev user,id=net0,hostfwd=tcp:$(SSH_HOST):$(SSH_PORT)-:22 \
		-device e1000,netdev=net0 \
		-nographic

# SSH into the running VM (the key of the root account is used when it
# exists, otherwise the password is asked for)
ssh:
	@KEY=""; \
	if [ -f "$(SSH_KEY_DIR)/root_ed25519" ]; then \
		KEY="-i $(SSH_KEY_DIR)/root_ed25519 -o IdentitiesOnly=yes"; \
	fi; \
	ssh $$KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $(SSH_PORT) root@$(SSH_HOST)

# SSH into the running VM as the peon account
ssh-peon:
	@KEY=""; \
	if [ -f "$(SSH_KEY_DIR)/peon_ed25519" ]; then \
		KEY="-i $(SSH_KEY_DIR)/peon_ed25519 -o IdentitiesOnly=yes"; \
	fi; \
	ssh $$KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $(SSH_PORT) peon@$(SSH_HOST)

# --- 3p sources (cloned only if they do not exist) ---
# The toolchain builds against git checkouts under 3p/. They are shared
# between this and other checkouts of the repo (3p may be a symlink to a
# common directory), so fetch-3p never deletes, resets or rewrites an
# existing repo; it only clones missing ones and then pins them to the
# exact commits used for the verified build (via toolchain/Makefile).
# The URLs match the verified checkouts.
3P_DIR   ?= 3p
include toolchain/pins.mk

fetch-3p:
	@set -e; \
	if [ -L $(3P_DIR) ] && [ ! -d $(3P_DIR) ]; then \
		echo "fetch-3p: $(3P_DIR) is a dangling symlink; point it at the 3p checkout"; \
		exit 1; \
	fi; \
	if [ ! -e $(3P_DIR) ]; then mkdir $(3P_DIR); fi; \
	if [ ! -d $(3P_DIR) ]; then echo "fetch-3p: $(3P_DIR) exists and is not a directory"; exit 1; fi; \
	for spec in $(3P_REPOS); do \
		repo=$${spec%%:*}; url=$${spec#*:}; \
		if [ -d $(3P_DIR)/$$repo/.git ]; then \
			echo "fetch-3p: $$repo already present, skipping"; \
		elif [ -e $(3P_DIR)/$$repo ]; then \
			echo "fetch-3p: $$repo exists but is not a git repo; refusing to overwrite"; \
			exit 1; \
		else \
			echo "fetch-3p: cloning $$url into $(3P_DIR)/$$repo"; \
			git clone $$url $(3P_DIR)/$$repo; \
		fi; \
	done
	@if [ '$(3P_DIR)' = '3p' ]; then \
		$(MAKE) -C toolchain 3p-pin; \
	else \
		echo "fetch-3p: non-default 3P_DIR; pin the tree manually with 'make -C toolchain 3p-pin' after pointing 3p at it"; \
	fi

# --- cross toolchain (delegates to toolchain/Makefile) ---
toolchain: fetch-3p    ; $(MAKE) -C toolchain toolchain
toolchain-clean:       ; $(MAKE) -C toolchain clean
toolchain-docker: fetch-3p ; $(MAKE) -C toolchain toolchain BACKEND=docker
hurd-build: fetch-3p   ; $(MAKE) -C toolchain hurd
gnumach-kernel: fetch-3p ; $(MAKE) -C toolchain gnumach-kernel \
	GNUMACH_DIR=$(abspath $(GNUMACH_DIR)) GNUMACH_NCPUS=$(GNUMACH_NCPUS)
gnumach-clean: ; $(RM) -r $(BUILD)/gnumach-kernel $(BUILD)/gnumach-kernel-src
smp-kernel: fetch-3p ; $(MAKE) -C toolchain gnumach-kernel \
	GNUMACH_DIR=$(abspath $(GNUMACH_DIR)) GNUMACH_NCPUS=2
up-kernel: fetch-3p ; $(MAKE) -C toolchain gnumach-kernel \
	GNUMACH_DIR=$(abspath $(GNUMACH_DIR)) GNUMACH_NCPUS=1
9pfs: fetch-3p         ; $(MAKE) -C toolchain 9pfs
virtio-9p: fetch-3p    ; $(MAKE) -C toolchain virtio-9p VIRTIO_DIR=$(VIRTIO_DIR)
virtio-balloon: fetch-3p    ; $(MAKE) -C toolchain virtio-balloon VIRTIO_DIR=$(VIRTIO_DIR)
virtio-blk: fetch-3p    ; $(MAKE) -C toolchain virtio-blk VIRTIO_DIR=$(VIRTIO_DIR)
virtio-net: fetch-3p    ; $(MAKE) -C toolchain virtio-net VIRTIO_DIR=$(VIRTIO_NET_DIR)
virtio-clean: fetch-3p ; $(MAKE) -C toolchain virtio-clean VIRTIO_DIR=$(VIRTIO_DIR)
storeio: fetch-3p       ; $(MAKE) -C toolchain storeio

# Boot the guest with a host directory shared through QEMU's virtio-9p
# device and run the translator test matrix: the device selftest, the
# 9pfs mount gate and the Phase 3 assertions (see scripts/virtio_test.sh).
virtio-test: 9pfs virtio-9p $(TEST_IMG)
	$(MKDIR_P) $(TMP_DIR) $(SHARE_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		VIRTIO_DIR="$(VIRTIO_DIR)" BASE_IMG="$(abspath $(TEST_IMG))" \
		bash scripts/virtio_test.sh
# Shared-IRQ churn: add/exercise/remove the driver in a loop with network
# traffic on the e1000 line shared with virtio-9p.  Targets the
# registration/teardown path the one-shot matrix runs at most twice; see
# scripts/virtio_test.py phase_stress.
virtio-irq-stress: 9pfs virtio-9p $(TEST_IMG)
	$(MKDIR_P) $(TMP_DIR) $(SHARE_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		VIRTIO_DIR="$(VIRTIO_DIR)" BASE_IMG="$(abspath $(TEST_IMG))" \
		MODE=stress bash scripts/virtio_test.sh
# Boot the guest with QEMU's virtio-balloon device and run the balloon
# matrix: driver selftest, a host-driven inflate/deflate round trip
# through the QEMU monitor (two-sided: guest status, device-model traces),
# churn and the teardown path (see scripts/virtio_balloon_test.sh).
virtio-balloon-test: virtio-balloon $(TEST_IMG)
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		VIRTIO_DIR="$(VIRTIO_DIR)" MODE="$(MODE)" RAM_MB="$(RAM_MB)" \
		BASE_IMG="$(abspath $(TEST_IMG))" \
		bash scripts/virtio_balloon_test.sh
# Boot the guest with QEMU's virtio-blk device backed by a disposable raw
# disk image and run the disk matrix: the driver selftest (raw read/write/
# flush plus the Mach semantics layer), two-sided data checks (guest reads
# vs the host-seeded image, guest writes vs the image content afterwards),
# trace-backed device-model evidence, and the no-device negative boot
# (see scripts/virtio_blk_test.sh; plan stuff/virtio_disk_plan.md §7.3).
virtio-blk-test: virtio-blk $(TEST_IMG)
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		VIRTIO_DIR="$(VIRTIO_DIR)" MODE="$(MODE)" \
		BASE_IMG="$(abspath $(TEST_IMG))" \
		bash scripts/virtio_blk_test.sh

# Boot the guest with QEMU's virtio-net device and run the network matrix:
# --status, the Phase 1/2 selftest (handshake, status flavors, write
# policy, NET_RCV_MSG delivery), the raw TX/RX traffic probe, a daemon
# smoke test and a Mach-device translator smoke test, plus the no-device
# negative boot (see scripts/virtio_net_test.sh).
virtio-net-test: virtio-net $(TEST_IMG)
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		VIRTIO_DIR="$(VIRTIO_NET_DIR)" MODE="$(MODE)" \
		BASE_IMG="$(abspath $(TEST_IMG))" \
		bash scripts/virtio_net_test.sh

# Build a guest image whose primary network interface is virtio-net (replacing
# e1000): stages the virtio-net binary and a matching /etc/network/interfaces
# into the packages image via CUSTOM_OVERLAY.
virtio-net-image: virtio-net $(TEST_IMG)
	$(MKDIR_P) $(TMP_DIR)/vnet-overlay/hurd $(TMP_DIR)/vnet-overlay/etc/network
	cp $(VIRTIO_NET_DIR)/virtio-net $(TMP_DIR)/vnet-overlay/hurd/virtio-net
	chmod 755 $(TMP_DIR)/vnet-overlay/hurd/virtio-net
	printf '%s\n' \
	  '# This file describes the network interfaces available on your system' \
	  '# and how to activate them. For more information, see interfaces(5).' \
	  '' \
	  '# The loopback network interface' \
	  'auto lo' \
	  'iface lo inet loopback' \
	  '' \
	  '# The primary network interface (virtio-net)' \
	  'auto /dev/vnet0' \
	  'iface /dev/vnet0 inet dhcp' \
	  > $(TMP_DIR)/vnet-overlay/etc/network/interfaces
	@printf '%s\n' '#!/bin/sh' 'pkill -f netdde 2>/dev/null || true' > $(TMP_DIR)/vnet-overlay/etc/rc.local
	@chmod 755 $(TMP_DIR)/vnet-overlay/etc/rc.local
	@printf '%s\n' '#!/bin/sh' 'exit 0' > $(TMP_DIR)/vnet-overlay/hurd/netdde
	@chmod 755 $(TMP_DIR)/vnet-overlay/hurd/netdde
	SSH_PORT="$(SSH_PORT)" $(MAKE) stage STAGE=kernel \
		VARIANT="$(abspath $(VNET_IMG))" \
		STAGE_INPUT="$(abspath $(TEST_IMG))" \
		CUSTOM_OVERLAY="$(abspath $(TMP_DIR)/vnet-overlay)"

# Boot the virtio-net-only image and verify end-to-end connectivity.
virtio-net-connectivity-test: virtio-net-image
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		BASE_IMG="$(abspath $(VNET_IMG))" \
		bash scripts/virtio_net_connectivity_test.sh

# Build a guest image carrying the hurdkit-branch gnumach (CUSTOM_KERNEL)
# and the fixed storeio from commit e07e9590 (CUSTOM_OVERLAY).  The fixed
# storeio is staged as /hurd/storeio-FIXED, never over /hurd/storeio: the
# cross build runs --without-parted, so its libstore has no `part` class
# and it cannot serve the `part:2:device:...` typed stores behind the
# partition nodes (/dev/wd0s2) that fsck opens at boot.  The benchmark's
# ensure_store_node uses /hurd/storeio-fixed; the Debian storeio keeps
# serving every system node.
virtio-bench-image: $(IMG_DIR)/hurd.bench.qcow2

$(IMG_DIR)/hurd.bench.qcow2: $(TEST_IMG) scripts/provision_stage.sh scripts/provision_guest.py $(BUILD)/hurd/storeio/storeio.static $(VIRTIO_DIR)/virtio-9p 3p/9pfs/9pfs $(BUILD)/gnumach-kernel/gnumach
	rm -rf $(TMP_DIR)/bench-overlay
	$(MKDIR_P) $(TMP_DIR)/bench-overlay/hurd
	cp $(BUILD)/hurd/storeio/storeio.static $(TMP_DIR)/bench-overlay/hurd/storeio-fixed
	chmod 755 $(TMP_DIR)/bench-overlay/hurd/storeio-fixed
	cp $(VIRTIO_DIR)/virtio-9p $(TMP_DIR)/bench-overlay/hurd/virtio-9p
	chmod 755 $(TMP_DIR)/bench-overlay/hurd/virtio-9p
	cp 3p/9pfs/9pfs $(TMP_DIR)/bench-overlay/hurd/9pfs
	chmod 755 $(TMP_DIR)/bench-overlay/hurd/9pfs
	SSH_PORT="$(SSH_PORT)" $(MAKE) stage STAGE=kernel \
		VARIANT="$(abspath $@)" \
		STAGE_INPUT="$(abspath $(TEST_IMG))" \
		CUSTOM_KERNEL="$(abspath $(BUILD)/gnumach-kernel/gnumach)" \
		CUSTOM_OVERLAY="$(abspath $(TMP_DIR)/bench-overlay)"

# Build a guest image whose only NIC is virtio-net (stages the driver and an
# `auto /dev/vnet0` interfaces entry via CUSTOM_OVERLAY), so SSH rides on the
# driver under test.  Used by the net-vnet leg of `make virtio-bench MODE=net`.
virtio-bench-vnet-image: $(IMG_DIR)/hurd.bench-vnet.qcow2

$(IMG_DIR)/hurd.bench-vnet.qcow2: $(TEST_IMG) scripts/provision_stage.sh scripts/provision_guest.py $(VIRTIO_NET_DIR)/virtio-net $(BUILD)/gnumach-kernel/gnumach
	rm -rf $(TMP_DIR)/bench-vnet-overlay
	$(MKDIR_P) $(TMP_DIR)/bench-vnet-overlay/hurd $(TMP_DIR)/bench-vnet-overlay/etc/network
	cp $(VIRTIO_NET_DIR)/virtio-net $(TMP_DIR)/bench-vnet-overlay/hurd/virtio-net
	chmod 755 $(TMP_DIR)/bench-vnet-overlay/hurd/virtio-net
	printf '%s\n' \
	  '# This file describes the network interfaces available on your system' \
	  '# and how to activate them. For more information, see interfaces(5).' \
	  '' \
	  '# The loopback network interface' \
	  'auto lo' \
	  'iface lo inet loopback' \
	  '' \
	  '# The primary network interface (virtio-net)' \
	  'auto /dev/vnet0' \
	  'iface /dev/vnet0 inet dhcp' \
	  > $(TMP_DIR)/bench-vnet-overlay/etc/network/interfaces
	@printf '%s\n' '#!/bin/sh' 'pkill -f netdde 2>/dev/null || true' > $(TMP_DIR)/bench-vnet-overlay/etc/rc.local
	@chmod 755 $(TMP_DIR)/bench-vnet-overlay/etc/rc.local
	@printf '%s\n' '#!/bin/sh' 'exit 0' > $(TMP_DIR)/bench-vnet-overlay/hurd/netdde
	@chmod 755 $(TMP_DIR)/bench-vnet-overlay/hurd/netdde
	SSH_PORT="$(SSH_PORT)" $(MAKE) stage STAGE=kernel \
		VARIANT="$(abspath $@)" \
		STAGE_INPUT="$(abspath $(TEST_IMG))" \
		CUSTOM_KERNEL="$(abspath $(BUILD)/gnumach-kernel/gnumach)" \
		CUSTOM_OVERLAY="$(abspath $(TMP_DIR)/bench-vnet-overlay)"

# Build the cross-compiled artifacts on demand (only if missing) without
# forcing a full rebuild of the phony toolchain targets on every make run.
$(BUILD)/hurd/storeio/storeio.static:
	$(MAKE) -C toolchain storeio

$(VIRTIO_DIR)/virtio-9p:
	$(MAKE) -C toolchain virtio-9p VIRTIO_DIR=$(VIRTIO_DIR)

3p/9pfs/9pfs:
	$(MAKE) -C toolchain 9pfs

# Track the gnumach source tree so edits trigger a rebuild (the build copies
# the tree, so a plain directory mtime is not enough).
GNUMACH_SOURCES := $(shell find $(GNUMACH_DIR) -type f 2>/dev/null)
$(BUILD)/gnumach-kernel/gnumach: $(GNUMACH_SOURCES)
	$(MAKE) -C toolchain gnumach-kernel GNUMACH_NCPUS=$(GNUMACH_NCPUS)

$(VIRTIO_NET_DIR)/virtio-net:
	$(MAKE) -C toolchain virtio-net VIRTIO_DIR=$(VIRTIO_NET_DIR)

$(VIRTIO_DIR)/virtio-blk:
	$(MAKE) -C toolchain virtio-blk VIRTIO_DIR=$(VIRTIO_DIR)

# Build the SMP kernel image (-smp 2): gnumach with GNUMACH_NCPUS=2 staged
# into hurd.kernel.smp.qcow2 on top of the packages image.  Run this before
# `make run-smp-tests`.
smp-image: smp-kernel
	$(MKDIR_P) $(TMP_DIR)
	SSH_PORT="$(SSH_PORT)" $(MAKE) stage STAGE=kernel \
		VARIANT="$(abspath $(IMG_DIR)/hurd.kernel.smp.qcow2)" \
		STAGE_INPUT="$(abspath $(TEST_IMG))" \
		CUSTOM_KERNEL="$(abspath $(BUILD)/gnumach-kernel/gnumach)"

# Build the UP kernel image (-smp 1): gnumach with GNUMACH_NCPUS=1 staged
# into hurd.kernel.up.qcow2 on top of the packages image.  Run this before
# `make run-up-tests`.
up-image: up-kernel
	$(MKDIR_P) $(TMP_DIR)
	SSH_PORT="$(SSH_PORT)" $(MAKE) stage STAGE=kernel \
		VARIANT="$(abspath $(IMG_DIR)/hurd.kernel.up.qcow2)" \
		STAGE_INPUT="$(abspath $(TEST_IMG))" \
		CUSTOM_KERNEL="$(abspath $(BUILD)/gnumach-kernel/gnumach)"

# Boot the staged SMP kernel image (-smp 2) and run the SMP test matrix:
# the `smp` userland command plus the in-guest pset stress binary.  The
# SMP image is expected to already exist (built via `make smp-kernel
# GNUMACH_NCPUS=2` + `make stage STAGE=kernel VARIANT=... CUSTOM_KERNEL=...`).
# Pass SMP_IMG=... to boot a different image.
run-smp-tests:
	@if [ ! -f "$(IMG_DIR)/hurd.kernel.smp.qcow2" ]; then \
		echo "run-smp-tests: missing $(IMG_DIR)/hurd.kernel.smp.qcow2" >&2; \
		echo "  build it with: make smp-image" >&2; exit 1; \
	fi
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		GDB="$(GDB)" SMP_IMG="$(abspath $(IMG_DIR)/hurd.kernel.smp.qcow2)" \
		SMP_CPU_COUNT="$(SMP_CPU_COUNT)" \
		bash scripts/run_smp_tests.sh

# Boot the guest and run the virtio benchmark matrix (block, filesystem, 9pfs,
# network).  See scripts/virtio_bench.sh and stuff/benchmark_plan.md.
# Boots hurd.bench.qcow2 (hurdkit gnumach + fixed storeio via CUSTOM_OVERLAY).
virtio-bench: $(IMG_DIR)/hurd.bench.qcow2 $(IMG_DIR)/hurd.bench-vnet.qcow2 $(VIRTIO_DIR)/virtio-blk $(VIRTIO_NET_DIR)/virtio-net
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		GDB="$(GDB)" MODE="$(MODE)" BENCH_RUNS="$(BENCH_RUNS)" \
		BENCH_JSON="$(BENCH_JSON)" RAM_MB="2048" \
		BASE_IMG="$(abspath $(IMG_DIR)/hurd.bench.qcow2)" \
		VIRTIO_DIR="$(VIRTIO_DIR)" VIRTIO_NET_DIR="$(VIRTIO_NET_DIR)" \
		VIRTIO_9P_BIN="$(VIRTIO_DIR)/virtio-9p" \
		VIRTIO_BLK_BIN="$(VIRTIO_DIR)/virtio-blk" \
		VBLK_CLIENT_BIN="$(VIRTIO_DIR)/vblk-client" \
		VIRTIO_NET_BIN="$(VIRTIO_NET_DIR)/virtio-net" \
		VIRTIO_NET_CLIENT_BIN="$(VIRTIO_NET_DIR)/vnet-client" \
		NINEPFS_BIN="$(REPO_ROOT)/3p/9pfs/9pfs" \
		bash scripts/virtio_bench.sh

run-up-tests:
	@if [ ! -f "$(IMG_DIR)/hurd.kernel.up.qcow2" ]; then \
		echo "run-up-tests: missing $(IMG_DIR)/hurd.kernel.up.qcow2" >&2; \
		echo "  build it with: make up-image" >&2; exit 1; \
	fi
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		GDB="$(GDB)" SMP_IMG="$(abspath $(IMG_DIR)/hurd.kernel.up.qcow2)" \
		SMP_CPU_COUNT="$(UP_CPU_COUNT)" \
		SMP_UP=1 \
		bash scripts/run_smp_tests.sh

# Boot the staged SMP kernel image and pause the whole guest from the host
# (SIGSTOP/SIGCONT of its QEMU) while tests/hurd/clock-pause.c reads the
# clocks in it (see scripts/clock_pause_test.sh).  CLOCK_IMG and CLOCK_CPUS
# boot another kernel image, e.g. the UP one with 1 vCPU.
clock-pause-test:
	$(MKDIR_P) $(TMP_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		bash scripts/clock_pause_test.sh
verify-vm: fetch-3p    ; $(MAKE) -C toolchain verify-vm

# Print resolved configuration values useful for debugging.
print-config:
	@echo "BUILD=$(BUILD)"
	@echo "VIRTIO_DIR=$(VIRTIO_DIR)"
	@echo "VIRTIO_NET_DIR=$(VIRTIO_NET_DIR)"
	@echo "IMG_DIR=$(IMG_DIR)"
	@echo "TEST_IMG=$(TEST_IMG)"
	@echo "SSH_PORT=$(SSH_PORT)"

# Remove temporary overlay images
clean:
	$(RM) $(TMP_DIR)/*.qcow2
	$(RM) $(IMG_DIR)/.provision.*.qcow2
	$(RM) $(IMG_DIR)/.repair.*.raw
	$(RM) $(IMG_DIR)/.repaired.*.qcow2
	$(RM) $(IMG_DIR)/hurd.work.img
	$(RM) $(IMG_DIR)/hurd.work.img.qcow2

# Remove all generated images but keep the downloaded tarball
clean-images:
	$(RM) $(IMG_DIR)/*.qcow2 $(IMG_DIR)/*.img $(IMG_DIR)/.extracted
	$(RM) -r $(TMP_DIR)

# Rebuild the default image pipeline from scratch
rebuild: clean-images all

# Remove all downloaded/generated files
distclean:
	$(RM) -r $(IMG_DIR)
