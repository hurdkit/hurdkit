#!/usr/bin/env bash
# Pause the whole guest from the host while tests/hurd/clock-pause.c reads
# the clocks in it, and check that GNU Mach takes the pauses: it does not
# stop in its debugger, the guest answers after each pause, both clocks
# have moved forward across each pause, and CLOCK_MONOTONIC never goes back.
#
# A pause is SIGSTOP, then SIGCONT, of the guest's QEMU process.  Under KVM
# the guest's processors stop while kvmclock, GNU Mach's high precision
# clock, follows the host's clock, so the kernel finds that clock ahead by
# the length of the pause.  How far the guest's clocks catch up differs
# between kernels (see tests/hurd/clock-pause.c), so only their direction
# is checked; the log shows the steps.
#
# The pauses of PAUSES come twice: in the first round clock-pause only
# sleeps between its readings, so that a tickless kernel has stopped its
# clock interrupt when a pause comes; in the second, BUSY_THREADS threads
# also read the clocks as fast as they can.
#
# The guest boots from a throw-away overlay of CLOCK_IMG.  On failure the
# guest is left running, resumed and not paused, so it can be inspected by
# hand.
#
# Environment:
#   CLOCK_IMG       image to boot (default img/hurd.kernel.smp.qcow2)
#   CLOCK_CPUS      vCPUs (default 2; must equal the kernel's GNUMACH_NCPUS)
#   PAUSES          pause lengths in seconds (default "0.2 0.2 0.2 1 1 3 3 10 30")
#   BUSY_THREADS    busy reader threads of the second round (default 2)
#   SSH_HOST / SSH_PORT
#                   address QEMU forwards the guest SSH port to (default
#                   127.0.0.1 / 2222)
#   REUSE           "1" pauses the guest already running on SSH_PORT, whose
#                   QEMU pid is in QEMU_PIDFILE, instead of booting one
#   QEMU_PIDFILE    pidfile of the guest's QEMU
#                   (default img/tmp/clock-pause-test-qemu.pid)
#   QEMU_LOG        the guest's serial log
#                   (default img/tmp/clock-pause-test-qemu.log)
#   CLOCK_PAUSE_BIN guest binary of tests/hurd/clock-pause.c (default: build
#                   it with XCC)
#   XCC             path to the x86_64-gnu cross compiler
#                   (default $HOME/opt/x86_64-gnu/bin/x86_64-gnu-gcc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOCK_IMG="${CLOCK_IMG:-${REPO_ROOT}/img/hurd.kernel.smp.qcow2}"
CLOCK_CPUS="${CLOCK_CPUS:-2}"
PAUSES="${PAUSES:-0.2 0.2 0.2 1 1 3 3 10 30}"
BUSY_THREADS="${BUSY_THREADS:-2}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
REUSE="${REUSE:-0}"
SSH_KEY_DIR="${SSH_KEY_DIR:-${REPO_ROOT}/img/keys}"
SSH_KEY="${SSH_KEY_DIR}/root_ed25519"
XCC="${XCC:-$HOME/opt/x86_64-gnu/bin/x86_64-gnu-gcc}"
TMP_DIR="${REPO_ROOT}/img/tmp"
mkdir -p "$TMP_DIR"
# Seconds to watch the serial log after a pause, and to wait for an answer
# of the guest.
WATCH_SECONDS=2
ANSWER_TIMEOUT=60
# What GNU Mach prints when it stops (kern/debug.c).
STOPPED='Debugger invoked|Assertion `'

if [[ -z "${CLOCK_PAUSE_BIN:-}" ]]; then
    if [[ ! -x "$XCC" ]]; then
        echo "clock-pause-test: cross compiler not found: $XCC" >&2
        echo "  build it: make -C toolchain gcc1 gcc2 glibc" >&2
        exit 1
    fi
    CLOCK_PAUSE_BIN="$TMP_DIR/clock-pause"
    "$XCC" -O2 -Wall -Wextra -pthread -o "$CLOCK_PAUSE_BIN" \
        "$REPO_ROOT/tests/hurd/clock-pause.c"
    file "$CLOCK_PAUSE_BIN" | grep -q 'for GNU/Hurd' || {
        echo "clock-pause-test: $CLOCK_PAUSE_BIN is not a GNU/Hurd ELF" >&2
        exit 1
    }
fi
for f in "$CLOCK_PAUSE_BIN" "$SSH_KEY"; do
    if [[ ! -f "$f" ]]; then
        echo "clock-pause-test: missing $f" >&2
        exit 1
    fi
done
if [[ "$REUSE" != "1" && ! -f "$CLOCK_IMG" ]]; then
    echo "clock-pause-test: missing $CLOCK_IMG (make smp-image)" >&2
    exit 1
fi

FAILED=0
PASSED=0
COUNT=0
PAUSED=""

VT_NAME="clock-pause-test"
VT_TMP_DIR="$TMP_DIR"
VT_QEMU_LOG="${QEMU_LOG:-${TMP_DIR}/clock-pause-test-qemu.log}"
VT_PIDFILE="${QEMU_PIDFILE:-${TMP_DIR}/clock-pause-test-qemu.pid}"
VT_SSH_HOST="$SSH_HOST"
VT_SSH_PORT="$SSH_PORT"
VT_SSH_KEY="$SSH_KEY"
VT_BASE_IMG="$CLOCK_IMG"
VT_RERUN_HINT="rerun against it with: REUSE=1 $0"
source "$SCRIPT_DIR/virtio_boot_lib.sh"

vt_check_pidfile "$REUSE"
# A write to a clock-pause that has gone fails instead of ending the script.
trap '' PIPE
# A guest that a failed run leaves behind must not stay stopped.
trap '[[ -z "$PAUSED" ]] || kill -CONT "$PAUSED" 2>/dev/null; vt_cleanup "$FAILED" "$REUSE"' EXIT

if [[ "$REUSE" == "1" ]]; then
    if ! vt_ssh_alive; then
        echo "clock-pause-test: REUSE=1 but no guest answers on port $VT_SSH_PORT" >&2
        exit 1
    fi
else
    vt_make_overlay
    vt_boot -smp "$CLOCK_CPUS"
fi
SSH_PORT="$VT_SSH_PORT"
qemu_pid="$(cat "$VT_PIDFILE" 2>/dev/null || true)"
if [[ -z "$qemu_pid" ]] || ! grep -q qemu-system "/proc/$qemu_pid/comm" 2>/dev/null; then
    echo "clock-pause-test: no QEMU process in $VT_PIDFILE" >&2
    exit 1
fi
echo "clock-pause-test: QEMU pid $qemu_pid, serial log $VT_QEMU_LOG"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR
    -o ConnectTimeout=10)
scp -P "$SSH_PORT" "${SSH_OPTS[@]}" "$CLOCK_PAUSE_BIN" \
    root@"$SSH_HOST":/tmp/clock-pause

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

stopped() {
    grep -a -q -E "$STOPPED" "$VT_QEMU_LOG"
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

now_ns() { date +%s%N; }

# Ask the running clock-pause for both clocks; sets NOW_MONOTONIC and
# NOW_WALL.  Fails when no answer comes within ANSWER_TIMEOUT seconds.
guest_now() {
    local before deadline line
    before="$(grep -c '^# now ' "$READER_OUT" || true)"
    echo now >&"$TO_READER" || return 1
    deadline=$(( $(now_ns) + ANSWER_TIMEOUT * 1000000000 ))
    while (( $(grep -c '^# now ' "$READER_OUT" || true) == before )); do
        if (( $(now_ns) > deadline )) || ! kill -0 "$READER_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
    done
    line="$(grep '^# now ' "$READER_OUT" | tail -n 1)"
    read -r _ _ NOW_MONOTONIC NOW_WALL <<< "$line"
    [[ "$NOW_MONOTONIC" =~ ^[0-9]+$ && "$NOW_WALL" =~ ^[0-9]+$ ]]
}

# One round: start clock-pause with BUSY busy threads, take every pause of
# PAUSES, end clock-pause and check its result.  Fails after the first
# pause that stops or loses the guest.
run_round() {
    local round="$1" busy="$2" i=0 p name m0 w0 h0 t0 t1 h1 rc fifo err
    echo "clock-pause-test: round $round, clock-pause with $busy busy threads, pauses (s): $PAUSES"
    READER_OUT="$TMP_DIR/clock-pause-test-$round.tap"
    err="$TMP_DIR/clock-pause-test-$round.err"
    fifo="$TMP_DIR/clock-pause-test.fifo"
    rm -f "$fifo" "$READER_OUT" "$err"
    mkfifo "$fifo"
    ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" root@"$SSH_HOST" /tmp/clock-pause "$busy" \
        < "$fifo" > "$READER_OUT" 2> "$err" &
    READER_PID=$!
    exec {TO_READER}> "$fifo"
    rm -f "$fifo"

    for p in $PAUSES; do
        i=$((i + 1))
        name="round $round, pause $i of $p s"
        if ! guest_now; then
            record "$name: the guest answers before the pause" 0 \
                "no answer within ${ANSWER_TIMEOUT}s"
            break
        fi
        m0="$NOW_MONOTONIC" w0="$NOW_WALL" h0="$(now_ns)"
        # Let the guest go idle again after the answer.
        sleep 1
        t0="$(now_ns)"
        PAUSED="$qemu_pid"
        kill -STOP "$qemu_pid"
        sleep "$p"
        kill -CONT "$qemu_pid"
        PAUSED=""
        t1="$(now_ns)"
        if watch_serial; then
            record "$name: GNU Mach did not stop" 0 \
                "$(grep -a -E -m 1 "$STOPPED" "$VT_QEMU_LOG")"
            break
        fi
        record "$name: GNU Mach did not stop" 1
        if ! guest_now; then
            record "$name: the guest answers after the pause" 0 \
                "no answer within ${ANSWER_TIMEOUT}s"
            break
        fi
        h1="$(now_ns)"
        record "$name: both clocks moved forward across the pause" \
            "$(( NOW_MONOTONIC > m0 && NOW_WALL > w0 ))" \
            "host $(( (h1 - h0) / 1000000 )) ms (stopped $(( (t1 - t0) / 1000000 )) ms), CLOCK_MONOTONIC $(( (NOW_MONOTONIC - m0) / 1000000 )) ms, CLOCK_REALTIME $(( (NOW_WALL - w0) / 1000000 )) ms"
    done

    # The end of its input ends clock-pause.
    exec {TO_READER}>&-
    for (( i = 0; i < ANSWER_TIMEOUT; i++ )); do
        kill -0 "$READER_PID" 2>/dev/null || break
        sleep 1
    done
    kill "$READER_PID" 2>/dev/null || true
    rc=0
    wait "$READER_PID" || rc=$?
    sed 's/^/  /' "$READER_OUT" "$err"
    record "round $round: clock-pause passed (CLOCK_MONOTONIC never went back)" \
        "$(( rc == 0 ))" "exit status $rc"
}

if stopped; then
    record "GNU Mach did not stop before the pauses" 0 \
        "$(grep -a -E -m 1 "$STOPPED" "$VT_QEMU_LOG")"
else
    run_round 1 0
    if [[ "$FAILED" -eq 0 ]]; then
        run_round 2 "$BUSY_THREADS"
    fi
    record "GNU Mach did not stop during the run" "$(stopped && echo 0 || echo 1)"
fi

echo
echo "$PASSED/$COUNT assertions passed"
if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo "clock-pause-test: done."
