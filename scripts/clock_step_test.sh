#!/usr/bin/env bash
# Step GNU Mach's high precision clock back while the guest idles with its
# clock interrupt stopped, and check that the kernel takes it: it does not
# stop in its debugger, the guest answers after each step, and its
# CLOCK_REALTIME moves forward by no more than the host's clock plus a
# tolerance.
#
# A tickless GNU Mach (configured with --enable-tickless, one processor)
# stops its clock interrupt while it idles.  When it wakes, clock_catchup
# (kern/mach_clock.c) charges the time since last_hpc_read, the reading of
# the high precision clock at the last clock interrupt.  If the clock reads
# behind last_hpc_read, as kvmclock does when the host writes its time info
# with an earlier time, that difference must not be taken as a huge
# unsigned gap.  This script produces that state on purpose: through
# QEMU's gdb stub it moves last_hpc_read STEP_NS ahead of the clock, at a
# moment when tickless_active says that the clock interrupt is stopped, and
# lets the guest go on.  The step changes nothing else.
#
# A kernel without tickless idle refreshes last_hpc_read at the clock
# interrupt that is pending when the guest goes on, before anything reads
# the clock, so the step does not reach clock_catchup there: the script
# skips such a kernel (no tickless_machine_idle in GNUMACH).
#
# Like the other harnesses, it boots a throw-away overlay of CLOCK_IMG with
# virtio_boot_lib.sh, or takes a running guest with REUSE=1.  On failure
# QEMU is left running, so the guest can be inspected by hand.
#
# Environment:
#   GNUMACH       the booted kernel as an ELF file with its symbols
#                 (default build/gnumach-kernel/gnumach)
#   CLOCK_IMG     image to boot (default img/hurd.kernel.up.qcow2)
#   CLOCK_CPUS    vCPUs (default 1; a tickless kernel has one processor)
#   STEPS         how many steps (default 3)
#   STEP_NS       how far last_hpc_read is moved ahead, in nanoseconds
#                 (default 2000000000)
#   TOLERANCE_S   how far CLOCK_REALTIME may move ahead of the host's clock
#                 across a step, in seconds (default 5)
#   SSH_HOST / SSH_PORT
#                 address QEMU forwards the guest SSH port to (default
#                 127.0.0.1 / 2222)
#   REUSE         "1" steps the guest already running on SSH_PORT instead
#                 of booting one
#   QEMU_LOG      the guest's serial log
#                 (default img/tmp/clock-step-test-qemu.log)
#   QEMU_PIDFILE  pidfile of the guest's QEMU
#                 (default img/tmp/clock-step-test-qemu.pid)
#   QEMU_MONITOR  HMP monitor socket of the guest's QEMU (default: the one
#                 virtio_boot_lib.sh creates; required with REUSE=1)
#   GDB_PORT      local port of QEMU's gdb stub while the script uses it
#                 (default SSH_PORT + 1000)
#
# Host tools: gdb, ssh, python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GNUMACH="${GNUMACH:-${REPO_ROOT}/build/gnumach-kernel/gnumach}"
CLOCK_IMG="${CLOCK_IMG:-${REPO_ROOT}/img/hurd.kernel.up.qcow2}"
CLOCK_CPUS="${CLOCK_CPUS:-1}"
STEPS="${STEPS:-3}"
STEP_NS="${STEP_NS:-2000000000}"
TOLERANCE_S="${TOLERANCE_S:-5}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
REUSE="${REUSE:-0}"
SSH_KEY_DIR="${SSH_KEY_DIR:-${REPO_ROOT}/img/keys}"
SSH_KEY="${SSH_KEY_DIR}/root_ed25519"
GDB_PORT="${GDB_PORT:-$((SSH_PORT + 1000))}"
TMP_DIR="${REPO_ROOT}/img/tmp"
mkdir -p "$TMP_DIR"
# Seconds to watch the serial log after a step, to wait for an answer of
# the guest, to let the guest go idle, and to wait for tickless_active.
WATCH_SECONDS=5
ANSWER_TIMEOUT=60
IDLE_SECONDS=2
IDLE_ATTEMPTS=20
# What GNU Mach prints when it stops (kern/debug.c).
STOPPED='Debugger invoked|Assertion `'

for tool in gdb ssh python3; do
    if ! command -v "$tool" > /dev/null; then
        echo "clock-step-test: $tool is required but not in PATH" >&2
        exit 1
    fi
done
for f in "$GNUMACH" "$SSH_KEY"; do
    if [[ ! -f "$f" ]]; then
        echo "clock-step-test: missing $f" >&2
        exit 1
    fi
done
# tickless_active exists in every build; tickless_machine_idle only in one
# with tickless idle (MACH_TICKLESS, kern/mach_clock.h).
if ! gdb -q -batch -nx -ex 'info address tickless_machine_idle' "$GNUMACH" 2>&1 |
        grep -q 'is a function'; then
    echo "clock-step-test: SKIP: $GNUMACH has no tickless idle (no tickless_machine_idle)"
    exit 0
fi
if [[ "$REUSE" != "1" && ! -f "$CLOCK_IMG" ]]; then
    echo "clock-step-test: missing $CLOCK_IMG (make up-image, with a GNU Mach" >&2
    echo "  configured with --enable-tickless)" >&2
    exit 1
fi

FAILED=0
PASSED=0
COUNT=0

VT_NAME="clock-step-test"
VT_TMP_DIR="$TMP_DIR"
VT_QEMU_LOG="${QEMU_LOG:-${TMP_DIR}/clock-step-test-qemu.log}"
VT_PIDFILE="${QEMU_PIDFILE:-${TMP_DIR}/clock-step-test-qemu.pid}"
VT_SSH_HOST="$SSH_HOST"
VT_SSH_PORT="$SSH_PORT"
VT_SSH_KEY="$SSH_KEY"
VT_BASE_IMG="$CLOCK_IMG"
VT_RERUN_HINT="rerun against it with: REUSE=1 $0"
source "$SCRIPT_DIR/virtio_boot_lib.sh"

vt_check_pidfile "$REUSE"
trap 'vt_cleanup "$FAILED" "$REUSE"' EXIT

if [[ "$REUSE" == "1" ]]; then
    if [[ -z "${QEMU_MONITOR:-}" ]]; then
        echo "clock-step-test: REUSE=1 needs QEMU_MONITOR" >&2
        exit 1
    fi
    if ! vt_ssh_alive; then
        echo "clock-step-test: REUSE=1 but no guest answers on port $VT_SSH_PORT" >&2
        exit 1
    fi
else
    vt_make_overlay
    vt_boot -smp "$CLOCK_CPUS"
    QEMU_MONITOR="${QEMU_MONITOR:-$VT_MONITOR_SOCK}"
fi
SSH_PORT="$VT_SSH_PORT"
if [[ ! -S "$QEMU_MONITOR" ]]; then
    echo "clock-step-test: no monitor socket: $QEMU_MONITOR" >&2
    exit 1
fi
echo "clock-step-test: serial log $VT_QEMU_LOG, monitor $QEMU_MONITOR, kernel $GNUMACH"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR
    -o ConnectTimeout=10)
guest() {
    timeout "$ANSWER_TIMEOUT" ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" root@"$SSH_HOST" "$@"
}

record() {
    local name="$1" ok="$2" detail="${3:-}"
    COUNT=$((COUNT + 1))
    if [[ "$ok" == 1 ]]; then
        PASSED=$((PASSED + 1))
        echo "PASS: $name${detail:+ -- $detail}"
    else
        FAILED=1
        echo "FAIL: $name${detail:+ -- $detail}"
    fi
}

serial_start="$(wc -c < "$VT_QEMU_LOG")"
stopped() {
    tail -c +"$((serial_start + 1))" "$VT_QEMU_LOG" | grep -a -q -E "$STOPPED"
}

# Whether GNU Mach stops in the next WATCH_SECONDS.
watch_serial() {
    local n
    for (( n = 0; n < WATCH_SECONDS * 5; n++ )); do
        stopped && return 0
        sleep 0.2
    done
    return 1
}

monitor() {
    python3 -I - "$QEMU_MONITOR" "$1" <<'PY'
import socket, sys
path, command = sys.argv[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(path)
try:
    s.recv(65536)
except TimeoutError:
    pass
s.sendall((command + "\n").encode())
try:
    s.recv(65536)
except TimeoutError:
    pass
s.close()
PY
}

# One attempt to step: attaching gdb stops the guest; if its clock
# interrupt is stopped (tickless_active), move last_hpc_read STEP_NS ahead.
# Detaching lets the guest go on.  Prints gdb's lines.
GDB_SCRIPT="$TMP_DIR/clock-step-test.gdb"
cat > "$GDB_SCRIPT" <<EOF
target remote 127.0.0.1:$GDB_PORT
printf "tickless_active %d\\n", tickless_active
printf "last_hpc_read %lu\\n", last_hpc_read
if tickless_active
  set var last_hpc_read = last_hpc_read + $STEP_NS
  printf "stepped last_hpc_read to %lu\\n", last_hpc_read
end
detach
EOF
step_once() {
    local out rc
    monitor "gdbserver tcp:127.0.0.1:$GDB_PORT" || return 1
    out="$(timeout 60 gdb -q -batch -nx -x "$GDB_SCRIPT" "$GNUMACH" 2>&1)"
    rc=$?
    monitor "gdbserver none" || true
    printf '%s\n' "$out" | grep -E '^(tickless_active|last_hpc_read|stepped) ' || true
    return "$rc"
}

# For the log of a failure: where the kernel is and what it holds as its
# uptime.  Attaching stops the guest; detaching lets it go on.
SHOW_SCRIPT="$TMP_DIR/clock-step-test-show.gdb"
cat > "$SHOW_SCRIPT" <<EOF
target remote 127.0.0.1:$GDB_PORT
printf "uptime.seconds %lu\\n", uptime.seconds
printf "last_hpc_read %lu\\n", last_hpc_read
frame
detach
EOF
show_kernel() {
    local line
    monitor "gdbserver tcp:127.0.0.1:$GDB_PORT" || return 0
    timeout 60 gdb -q -batch -nx -x "$SHOW_SCRIPT" "$GNUMACH" 2>&1 |
        grep -E '^(uptime\.seconds|last_hpc_read|#0) ' | while IFS= read -r line; do echo "  gdb: $line"; done || true
    monitor "gdbserver none" || true
}

# Step until the guest is idle with its clock interrupt stopped.
step() {
    local i out line
    for (( i = 1; i <= IDLE_ATTEMPTS; i++ )); do
        sleep "$IDLE_SECONDS"
        out="$(step_once)" || { echo "$out"; return 1; }
        while IFS= read -r line; do echo "  gdb: $line"; done <<< "$out"
        grep -q '^stepped ' <<< "$out" && return 0
    done
    return 1
}

if stopped; then
    record "GNU Mach did not stop before the steps" 0 \
        "$(grep -a -E -m 1 "$STOPPED" "$VT_QEMU_LOG")"
else
    for (( s = 1; s <= STEPS; s++ )); do
        name="step $s of $STEPS (last_hpc_read + $STEP_NS ns)"
        if ! g0="$(guest date +%s.%N)"; then
            record "$name: the guest answers before the step" 0 \
                "no answer within ${ANSWER_TIMEOUT}s"
            break
        fi
        h0="$(date +%s.%N)"
        if ! step; then
            record "$name: stepped while the clock interrupt was stopped" 0 \
                "tickless_active stayed 0 in $IDLE_ATTEMPTS attempts"
            break
        fi
        record "$name: stepped while the clock interrupt was stopped" 1
        if watch_serial; then
            record "$name: GNU Mach did not stop" 0 \
                "$(grep -a -E -m 1 "$STOPPED" "$VT_QEMU_LOG")"
            break
        fi
        record "$name: GNU Mach did not stop" 1
        if ! g1="$(guest date +%s.%N)"; then
            record "$name: the guest answers after the step" 0 \
                "no answer within ${ANSWER_TIMEOUT}s"
            show_kernel
            break
        fi
        h1="$(date +%s.%N)"
        record "$name: the guest answers after the step" 1
        # In milliseconds, with awk: a wrapped clock is past what shell
        # arithmetic holds in nanoseconds.
        read -r dg dh ok < <(awk -v g0="$g0" -v g1="$g1" -v h0="$h0" -v h1="$h1" \
            -v tol="$TOLERANCE_S" 'BEGIN {
                dg = (g1 - g0) * 1000; dh = (h1 - h0) * 1000
                printf "%.0f %.0f %d\n", dg, dh, (dg > 0 && dg <= dh + tol * 1000) }')
        record "$name: CLOCK_REALTIME moved forward, by at most the host's time plus ${TOLERANCE_S}s" \
            "$ok" "host $dh ms, guest $dg ms"
    done
    record "GNU Mach did not stop during the run" "$(stopped && echo 0 || echo 1)"
fi

echo
echo "$PASSED/$COUNT assertions passed"
if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo "clock-step-test: done."
