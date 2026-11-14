#!/usr/bin/env bash
# Prepare the Hurd base image: copy the pristine raw disk image and apply
# offline changes to the copy (the downloaded image stays untouched).
#
# The root filesystem lives on partition 2 (ext2). partitionfs exposes the
# partitions of the disk image as regular files, and debugfs edits that file
# in place. fuse2fs cannot be used for writing because it enforces strict
# ownership, and root-owned files cannot be modified without root privileges.
#
# Changes applied offline (no VM boot required):
#   * /boot/grub/grub.cfg              - serial console + auto-boot
#   * /etc/default/grub                - same settings, for update-grub
#   * /etc/shadow                      - password hash for root
#   * /etc/ssh/sshd_config.d/10-local.conf - permit root password login
#
# The resulting image is expected to be converted to qcow2 by the caller.

set -euo pipefail

SRC_IMG="${1:?Usage: $0 <source.raw> <work.raw> [root_password]}"
WORK_IMG="${2:?Usage: $0 <source.raw> <work.raw> [root_password]}"
ROOT_PASSWORD="${3:-abcdef}"
# Default to the partitionfs built from the pinned 3p checkout
# (make partitionfs-build); override with the PARTFS environment variable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARTFS="${PARTFS:-$REPO_ROOT/3p/partitionfs/build/partitionfs}"

if [[ ! -f "$SRC_IMG" ]]; then
    echo "Source image not found: $SRC_IMG" >&2
    exit 1
fi

if [[ ! -x "$PARTFS" ]]; then
    echo "partitionfs binary not found or not executable: $PARTFS" >&2
    exit 1
fi

if ! command -v debugfs >/dev/null 2>&1; then
    echo "debugfs is required for offline image preparation" >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to generate the password hash" >&2
    exit 1
fi

# The password hash must use a crypt(3) method supported by the Hurd libc.
# $6$ (SHA-512) is supported by glibc; yescrypt ($y$) is not, even though
# /etc/login.defs names it as the preferred method.
#
# The hash uses a random salt, and the password is passed through standard
# input, so that it does not show up in the process list.
password_hash() {
    printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin
}

ROOT_HASH="$(password_hash)"

TMP_DIR="$(mktemp -d)"
# A dedicated mount point per run: a leftover FUSE mount from an earlier run
# would make partitionfs fail with "mountpoint is not empty".
WORK_DIR="$(mktemp -d "$(dirname "$WORK_IMG")/partitions.XXXXXX")"
PARTFS_PID=""
cleanup() {
    fusermount -u "$WORK_DIR" 2>/dev/null || true
    if [[ -n "$PARTFS_PID" ]]; then
        kill "$PARTFS_PID" 2>/dev/null || true
        wait "$PARTFS_PID" 2>/dev/null || true
    fi
    rmdir "$WORK_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# --- New /etc/default/grub: persistent serial console ---
cat > "$TMP_DIR/default_grub" <<'GRUBDEF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR=$( . /etc/os-release && echo ${NAME} )
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0"
GRUB_CMDLINE_GNUMACH="console=com0"
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
GRUBDEF

# --- sshd drop-in: allow root to authenticate with a password ---
# OpenSSH refuses password logins for root unless this is set explicitly,
# and refuses empty passwords unless PermitEmptyPasswords is enabled.
cat > "$TMP_DIR/sshd_local.conf" <<'SSHDCONF'
# Permit root to log in with a password so the image can be provisioned
# over SSH without an interactive console.
PermitRootLogin yes
PasswordAuthentication yes
SSHDCONF

# Work on a copy: the downloaded image must stay pristine so that the
# preparation can be repeated from a known state.
#
# --reflink=never is required on filesystems that support clone requests
# (btrfs, XFS): cp defaults to --reflink=auto there, and reading a
# reflinked image right after the clone intermittently returns inconsistent
# data, which made debugfs fail with a bogus "Ext2 inode is not a directory"
# and broke the dumps below nondeterministically. A real copy costs a few
# seconds but is reliable.
cp --reflink=never "$SRC_IMG" "$WORK_IMG"
# libparted probes the image through the block layer, which ignores the
# page cache; without flushing the copy the partition table reads back empty
# and partitionfs exposes no partitions.
sync "$WORK_IMG"

# Expose partitions as numbered files
"$PARTFS" "$WORK_IMG" "$WORK_DIR" &
PARTFS_PID=$!

# Wait for partition file to appear
for _ in $(seq 1 10); do
    if [[ -f "$WORK_DIR/2" ]]; then
        break
    fi
    sleep 1
done

if [[ ! -f "$WORK_DIR/2" ]]; then
    echo "Partition 2 not found after partitionfs mount" >&2
    exit 1
fi

PART_FILE="$WORK_DIR/2"

# Dump a file out of the image. debugfs returns exit status 0 even when the
# dump fails, and its diagnostics go to stderr, so a failed dump used to
# surface much later as a cryptic awk error about the missing output file.
# The dump result is therefore verified right here.
debugfs_dump() {
    local path="$1" out="$2"
    rm -f "$out"
    if ! debugfs -R "dump $path $out" "$PART_FILE" 2>/dev/null || [[ ! -s "$out" ]]; then
        echo "Failed to dump $path from the image (debugfs failed or produced an empty file)" >&2
        return 1
    fi
}

# --- Patch the GRUB configuration of the image ---
# The shipped grub.cfg is patched instead of replaced: it knows the kernel
# file, the translator modules and the filesystem UUID of the image, and
# every symbol that the modules refer to has to be defined by exactly one
# of them. Replacing the file risks dropping one of those definitions,
# which makes the kernel panic with "bootstrap script missing symbol".
#
# Three things are changed:
#   * the menu timeout becomes 0, so that the guest boots unattended,
#   * the GRUB output goes to the console instead of the graphics console,
#   * the Hurd console is put on the serial line.
debugfs_dump /boot/grub/grub.cfg "$TMP_DIR/grub.cfg.orig"

awk '
    /^terminal_output gfxterm$/ { print "terminal_output console"; next }
    /^[[:space:]]*set timeout=[0-9]+[[:space:]]*$/ {
        match($0, /^[[:space:]]*/)
        print substr($0, 1, RLENGTH) "set timeout=0"
        next
    }
    /^[[:space:]]*multiboot/ && !/console=/ {
        sub(/[[:space:]]+$/, "")
        print $0 " console=com0"
        next
    }
    { print }
' "$TMP_DIR/grub.cfg.orig" > "$TMP_DIR/grub.cfg"

# The patched configuration has to contain the settings the unattended
# boot depends on; a configuration without them would boot into a menu or
# into a console that cannot be reached.
for pattern in '^[[:space:]]*set timeout=0$' '^terminal_output console$' 'console=com0'; do
    if ! grep -q "$pattern" "$TMP_DIR/grub.cfg"; then
        echo "Patched grub.cfg does not contain '$pattern'" >&2
        exit 1
    fi
done

# The kernel that the configuration refers to has to be in the image.
KERNEL_PATH="$(awk '/^[[:space:]]*multiboot/ { for (i = 1; i < NF; i++) if ($i ~ /^\/boot\//) { print $i; exit } }' "$TMP_DIR/grub.cfg")"
if [[ -z "$KERNEL_PATH" ]]; then
    echo "No kernel found in the patched grub.cfg" >&2
    exit 1
fi
if ! debugfs -R "stat $KERNEL_PATH" "$PART_FILE" 2>/dev/null | grep -q "Inode:"; then
    echo "The kernel $KERNEL_PATH is not in the image" >&2
    exit 1
fi

echo "Using kernel $KERNEL_PATH"

# --- Patch /etc/shadow in place ---
# The shipped file has one line per account and nine colon-separated
# fields. Rewriting it from scratch drops the accounts and produces
# malformed entries, which breaks logins for every user.
# Dump it, replace only the password field of root, and write it back
# with the original ownership and permissions.
#
# Only the root account gets its password here, because it is the account
# that the provisioning logs in with. The account of the image is renamed
# during the provisioning, and its password is set there, after the
# rename.
debugfs_dump /etc/shadow "$TMP_DIR/shadow.orig"

awk -F: -v OFS=: -v root_hash="$ROOT_HASH" '
    $1 == "root" { $2 = root_hash }
    { print }
' "$TMP_DIR/shadow.orig" > "$TMP_DIR/shadow.new"

# The rewritten file must keep every account and all nine fields. A file
# with fewer accounts or with malformed entries breaks the login of every
# user, so the result is checked before it is written into the image.
ORIG_ACCOUNTS="$(grep -c '' "$TMP_DIR/shadow.orig")"
NEW_ACCOUNTS="$(grep -c '' "$TMP_DIR/shadow.new")"
if [[ "$ORIG_ACCOUNTS" != "$NEW_ACCOUNTS" ]]; then
    echo "Account count changed while patching /etc/shadow ($ORIG_ACCOUNTS -> $NEW_ACCOUNTS)" >&2
    exit 1
fi

BROKEN_LINES="$(awk -F: 'NF != 9 { count++ } END { print count + 0 }' "$TMP_DIR/shadow.new")"
if [[ "$BROKEN_LINES" != "0" ]]; then
    echo "$BROKEN_LINES lines of /etc/shadow do not have nine fields" >&2
    exit 1
fi

if ! awk -F: -v root_hash="$ROOT_HASH" \
    '$1 == "root" && $2 == root_hash { found = 1 } END { exit !found }' "$TMP_DIR/shadow.new"; then
    echo "Password hash for root was not applied" >&2
    exit 1
fi

# Build debugfs command script (no shell syntax, no comments)
CMDS_FILE="$TMP_DIR/debugfs.cmds"

# debugfs cannot overwrite a file, so an existing file has to be removed
# first. The removal is only added for files that are really there, because
# debugfs complains about missing files.
remove_if_present() {
    local path="$1"
    if debugfs -R "stat $path" "$PART_FILE" 2>/dev/null | grep -q "Inode:"; then
        echo "rm $path"
    fi
}

{
    remove_if_present /boot/grub/grub.cfg
    echo "write $TMP_DIR/grub.cfg /boot/grub/grub.cfg"
    remove_if_present /etc/default/grub
    echo "write $TMP_DIR/default_grub /etc/default/grub"
    remove_if_present /etc/shadow
    echo "write $TMP_DIR/shadow.new /etc/shadow"
    echo "sif /etc/shadow mode 0100640"
    echo "sif /etc/shadow uid 0"
    echo "sif /etc/shadow gid 42"
    remove_if_present /etc/ssh/sshd_config.d/10-local.conf
    echo "write $TMP_DIR/sshd_local.conf /etc/ssh/sshd_config.d/10-local.conf"
    echo "sif /etc/ssh/sshd_config.d/10-local.conf mode 0100644"
    echo "sif /etc/ssh/sshd_config.d/10-local.conf uid 0"
    echo "sif /etc/ssh/sshd_config.d/10-local.conf gid 0"
    echo "quit"
} > "$CMDS_FILE"

debugfs -w -f "$CMDS_FILE" "$PART_FILE"

echo "Base image prepared offline: $WORK_IMG"
