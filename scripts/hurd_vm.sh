#!/usr/bin/env bash
# Boot the Hurd VM from a throwaway qcow2 overlay of img/hurd.vm.qcow2.
#
# Two boot modes:
#   MODE=virtio    (default)  root disk on virtio-blk, network on
#                  virtio-net.  Boots the 'Debian GNU/Hurd virtio' grub
#                  entry (the image's default), exercising the
#                  virtio-blk bootstrap chain.
#   MODE=rumpdisk  root disk on IDE, network on e1000.  The stock
#                  Debian RumpDisk chain, used as the control boot.
#                  Select 'Debian GNU/Hurd RumpDisk' in the GRUB menu
#                  during the 5s timeout (the menu is on stdio).
#
# The overlay keeps the base image pristine.  SSH is forwarded through
# the guest's network device on a user-net backend in both modes.
#
# PCI slots (virtio mode) are pinned so the INTx lines stay stable:
# slots ≡ 1 (mod 4) route through PIRQ A, which gnumach assigns to
# IRQ 10 -- boot logs show virtio-blk at 0x5 landing on IRQ 10.
# virtio-net sits at 0x6, the balloon at 0x7.
#
# Environment:
#   SSH_PORT      forwarded guest SSH port (default 3333)
#   SSH_HOST      ssh bind host (default 127.0.0.1)
#   BASE_IMG      base image for the overlay (default img/hurd.vm.qcow2)
#   TMPIMG        overlay path (default img/tmp/hurd.vm.snapshot.qcow2)
#   RAM_MB        guest memory in MiB (default 2048)
#   MODE          boot mode: virtio or rumpdisk (default virtio);
#                 may also be given as the first argument
#   REUSE         "1" boot against an existing overlay instead of recreating it
#   QEMU_EXTRA    extra QEMU arguments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

SSH_PORT="${SSH_PORT:-3333}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
BASE_IMG="${BASE_IMG:-${REPO_ROOT}/img/hurd.vm.qcow2}"
TMPIMG="${TMPIMG:-${REPO_ROOT}/img/tmp/hurd.vm.snapshot.qcow2}"
RAM_MB="${RAM_MB:-2048}"
MODE="${1:-${MODE:-virtio}}"
REUSE="${REUSE:-0}"
QEMU_EXTRA="${QEMU_EXTRA:-}"
CPU_NUM=1

SSH_KEY_DIR="${SSH_KEY_DIR:-${REPO_ROOT}/img/keys}"
SSH_KEY="${SSH_KEY_DIR}/root_ed25519"

TMP_DIR="${REPO_ROOT}/img/tmp"
mkdir -p "$TMP_DIR"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
for f in "$BASE_IMG" "$SSH_KEY"; do
    if [[ ! -f "$f" ]]; then
        echo "hurd_vm: missing $f" >&2
        echo "  (build the image with: make img/hurd.vm.qcow2)" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Overlay: throwaway qcow2 backing on the base image
# ---------------------------------------------------------------------------
if [[ "$REUSE" != "1" ]]; then
    rm -f "$TMPIMG"
    qemu-img create -f qcow2 -b "$(readlink -f "$BASE_IMG")" -F qcow2 \
        "$TMPIMG" >/dev/null
    echo "hurd_vm: created temp image $TMPIMG -> $BASE_IMG"
    # The snapshot is throwaway, so repair it before boot instead of
    # letting the guest trip over the stale bitmaps of a previous run.
    bash "$SCRIPT_DIR/scripts/fsck_qcow2.sh" --repair "$TMPIMG"
fi

# ---------------------------------------------------------------------------
# Inject the correct /etc/network/interfaces for the boot mode.
# The overlay image is shared between virtio and rumpdisk modes, but each
# mode needs a different primary network interface:
#   - virtio: /dev/vnet0 (served by /hurd/virtio-net --serve)
#   - rumpdisk: /dev/eth0 (served by devnode via gnumach device master)
# Configuring both causes ifup to bring up the first one successfully, then
# crash pfinet when trying to add the second one via fsysopts
# ("(ipc/mig) server died"), breaking SSH.
# ---------------------------------------------------------------------------
inject_interfaces() {
    local mnt
    case "$MODE" in
        virtio)
            # cfg/network/interfaces already ships only /dev/vnet0; nothing to do.
            return 0
            ;;
        rumpdisk)
            mnt="$(mktemp -d)"
            echo "hurd_vm: injecting /etc/network/interfaces for rumpdisk mode (/dev/eth0)..."
            bash "$SCRIPT_DIR/scripts/mount_image.sh" "$TMPIMG" "$mnt" 2 >/dev/null
            cat > "$mnt/etc/network/interfaces" <<'EOF'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

# The loopback network interface
auto lo
iface lo inet loopback

# Primary interface for e1000/rumpdisk (MODE=rumpdisk).  /dev/eth0 is served
# by devnode -M /dev/net eth0 backed by gnumach's device master via netdde
# or a kernel e1000 driver.  QEMU exposes e1000 in scripts/hurd_vm.sh:boot_rumpdisk.
auto /dev/eth0
iface /dev/eth0 inet dhcp
EOF
            bash "$SCRIPT_DIR/scripts/unmount_image.sh" "$mnt"
            rmdir "$mnt" 2>/dev/null || true
            ;;
    esac
}

inject_interfaces

boot_virtio() {
    echo "hurd_vm: virtio mode: virtio-blk root + virtio-net (SSH on $SSH_HOST:$SSH_PORT)..."
    qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -smp $CPU_NUM -m "${RAM_MB}M" \
        -netdev "user,id=net0,hostfwd=tcp:${SSH_HOST}:${SSH_PORT}-:22" \
        -device "virtio-net-pci,netdev=net0,disable-legacy=off,addr=0x6" \
        -drive "if=none,id=vd0,file=$TMPIMG,format=qcow2,cache=writeback" \
        -device "virtio-blk-pci,drive=vd0,disable-legacy=off,addr=0x5" \
        -device "virtio-balloon-pci,disable-legacy=off,addr=0x7" \
        -monitor unix:"${TMP_DIR}/hurd-vm-monitor.sock",server,nowait \
        ${QEMU_EXTRA:+$QEMU_EXTRA} \
        -nographic
}

boot_rumpdisk() {
    echo "hurd_vm: rumpdisk mode: IDE root + e1000 (SSH on $SSH_HOST:$SSH_PORT)..."
    echo "hurd_vm: pick 'Debian GNU/Hurd RumpDisk' in the GRUB menu"
    qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -smp $CPU_NUM -m "${RAM_MB}M" \
        -drive "file=$TMPIMG,if=ide,cache=writeback" \
        -netdev "user,id=net0,hostfwd=tcp:${SSH_HOST}:${SSH_PORT}-:22" \
        -device "e1000,netdev=net0" \
        -monitor unix:"${TMP_DIR}/hurd-vm-monitor.sock",server,nowait \
        ${QEMU_EXTRA:+$QEMU_EXTRA} \
        -nographic
}

case "$MODE" in
    virtio)   boot_virtio ;;
    rumpdisk) boot_rumpdisk ;;
    *)
        echo "hurd_vm: unknown mode '$MODE' (use virtio or rumpdisk)" >&2
        exit 2
        ;;
esac
