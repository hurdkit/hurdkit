# Fetch, convert, and boot a Debian GNU/Turd x86_64 image via QEMU.
#
# The downloaded image is stored in img/ and is never deleted.
# A pristine qcow2 base disk is created from it (after offline
# preparation), and the VM boots from a temporary copy-on-write
# overlay so the base stays unchanged.

# Pinned Hurd image version
VERSION       := 20260314

# Configuration
IMG_DIR       := img
IMG_URL       := https://cdimage.debian.org/cdimage/ports/latest/hurd-amd64/debian-hurd-amd64-$(VERSION).img.tar.xz
MD5_SUM       := 91dc71608fcfc9f237028f1fe87c39c2
IMG_TAR       := $(IMG_DIR)/debian-hurd-amd64-$(VERSION).img.tar.xz
RAW_IMG       := $(IMG_DIR)/debian-hurd-amd64-$(VERSION).img
# Stamp for the extraction step: the tarball preserves the member mtime,
# which is older than the tarball itself, so the raw image would otherwise
# be extracted again on every make invocation.
EXTRACT_STAMP := $(IMG_DIR)/.extracted
WORK_IMG      := $(IMG_DIR)/hurd.work.img
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
# A host directory copied into the guest filesystem by the kernel stage,
# for out-of-tree drivers, init scripts etc.  CUSTOM_KERNEL travels in
# the same overlay.
CUSTOM_OVERLAY ?=
# The SSH keys of the guest accounts. The private keys stay in this
# directory and are used to log into the guest without a password.
SSH_KEY_DIR   := $(IMG_DIR)/keys
# The host directory shared with the guest through virtio-9p, and the
# standalone repo of the virtio-9p device translator.
SHARE_DIR     := $(CURDIR)/$(IMG_DIR)/share
VIRTIO_9P_BIN := $(HOME)/src/virtio/virtio-9p

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

.PHONY: all download check base provision stage run run-nokvm ssh ssh-peon clean distclean toolchain toolchain-clean toolchain-docker verify-vm hurd-build 9pfs fetch-3p

all: base

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

# Provision the base image in-VM (idempotent: skips if already provisioned)
provision: $(BASE_IMG)
	@$(MKDIR_P) $(IMG_DIR)
	@$(LOCK) $(LOCK_FILE) env ROOT_PASSWORD=$(ROOT_PASSWORD) \
		CPU_COUNT=$(CPU_COUNT) MEMORY=$(MEMORY) \
		RUN_APT_UPGRADE=$(RUN_APT_UPGRADE) \
		GUEST_PACKAGES="$(GUEST_PACKAGES)" \
		SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))" \
		bash scripts/provision_base.sh $(BASE_IMG) $(SSH_PORT)

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

$(IMG_DIR)/hurd.accounts.qcow2: $(BASE_IMG) scripts/provision_stage.sh scripts/provision_guest.py
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

# Boot from a temporary overlay so the base image stays pristine
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
9pfs: fetch-3p         ; $(MAKE) -C toolchain 9pfs
virtio-9p: fetch-3p    ; $(MAKE) -C toolchain virtio-9p

# Boot the guest with a host directory shared through QEMU's virtio-9p
# device and run the translator test matrix: the device selftest, the
# 9pfs mount gate and the Phase 3 assertions (see scripts/virtio_test.sh).
virtio-test: 9pfs virtio-9p $(BASE_IMG)
	$(MKDIR_P) $(TMP_DIR) $(SHARE_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		bash scripts/virtio_test.sh
# Shared-IRQ churn: add/exercise/remove the driver in a loop with network
# traffic on the e1000 line shared with virtio-9p.  Targets the
# registration/teardown path the one-shot matrix runs at most twice; see
# scripts/virtio_test.py phase_stress.
virtio-irq-stress: 9pfs virtio-9p $(BASE_IMG)
	$(MKDIR_P) $(TMP_DIR) $(SHARE_DIR)
	SSH_HOST="$(SSH_HOST)" SSH_PORT="$(SSH_PORT)" REUSE="$(REUSE)" \
		MODE=stress bash scripts/virtio_test.sh
verify-vm: fetch-3p    ; $(MAKE) -C toolchain verify-vm

# Remove temporary overlay images
clean:
	$(RM) $(TMP_DIR)/*.qcow2
	$(RM) $(IMG_DIR)/.provision.*.qcow2
	$(RM) $(IMG_DIR)/.repair.*.raw
	$(RM) $(IMG_DIR)/.repaired.*.qcow2
	$(RM) $(IMG_DIR)/hurd.work.img
	$(RM) $(IMG_DIR)/hurd.work.img.qcow2

# Remove all downloaded/generated files
distclean:
	$(RM) -r $(IMG_DIR)
