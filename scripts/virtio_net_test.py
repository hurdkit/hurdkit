#!/usr/bin/env python3
"""Drive the virtio-net test matrix in the guest.

scripts/virtio_net_test.sh boots the guest with QEMU's virtio-net device
attached to a user-mode network backend; this script installs the driver
and runs the network matrix, printing one PASS/FAIL line per assertion.

Configuration comes from the environment:

    VIRTIO_NET_BIN   host path of the virtio-net binary
    VNET_STALL_SOCKET
                     in stall mode, the Unix socket that this script listens
                     on and QEMU connects to as the device's backend
                     (-netdev stream,server=off,reconnect-ms=...)

    (SSH_HOST / SSH_PORT / SSH_KEY / QEMU_LOG / GDB are the shared
    harness configuration documented in scripts/virtio_harness.py.)

Modes (argv[1]):

    main     the full matrix, with the device attached
    nodev    the no-device negative test, without the device attached
    stress   repeated selftest cycles to churn bring-up/teardown
    stall    the stalled-backend phase (phase_stall), with the device's
             backend a stream socket that this script serves

Exit codes: 0 every assertion passed, 1 at least one failed.
"""

import os
import re
import select
import socket
import struct
import sys
import threading
import time

import virtio_harness as vh

VIRTIO_NET_BIN = os.environ.get("VIRTIO_NET_BIN", "")
VIRTIO_NET_CLIENT_BIN = os.environ.get("VIRTIO_NET_CLIENT_BIN", "")

_MODE = sys.argv[1] if len(sys.argv) > 1 else "main"

DAEMON_LOG = "/tmp/virtio-net.log"
SERVE_NODE = "/dev/vnet0"

VNET_STALL_SOCKET = os.environ.get("VNET_STALL_SOCKET", "")
STALL_PFINET = "/tmp/pfinet-stall"
STALL_DRIVER_LOG = "/tmp/virtio-net-stall.log"
STALL_PFINET_LOG = "/tmp/pfinet-stall.log"
STALL_FLOOD_LOG = "/tmp/stall-flood.log"
STALL_GUEST_IP = "10.0.3.15"
STALL_BROADCAST = "10.0.3.255"
STALL_PEER_IP = bytes([10, 0, 3, 2])
STALL_PEER_MAC = bytes([0x52, 0x54, 0x00, 0x00, 0x03, 0x02])
# Every slot of QEMU's TX queue has to time out once (VNET_TX_TIMEOUT
# each), after the frames that the socket buffer takes before QEMU's
# write would block.
STALL_TIMEOUT = 900


def guest_responsive(session, label):
    status, out = session.run("ls / >/dev/null && echo alive", timeout=60)
    vh.record(f"{label}: guest responsive", status == 0 and "alive" in out,
              f"rc={status}, {out.strip()[-200:]}")


def install_binary(session):
    vh.install(VIRTIO_NET_BIN, "/tmp/virtio-net")
    session.run("install -m 755 /tmp/virtio-net /hurd/virtio-net", timeout=60)

def install_client(session):
    vh.install(VIRTIO_NET_CLIENT_BIN, "/tmp/vnet-client")
    session.run("install -m 755 /tmp/vnet-client /hurd/vnet-client", timeout=60)


def phase_status(session):
    status, out = session.run("/hurd/virtio-net --status", timeout=120)
    vh.record("phase1 status: device usable", status == 0,
              f"rc={status}, {out.strip()[-300:]}")
    if status == 0:
        vh.record("phase1 status: MAC reported", "MAC" in out, out.strip()[-200:])
    return status == 0


def phase_selftest(session):
    status, out = session.run("/hurd/virtio-net --selftest", timeout=300)
    gate = "selftest ok" in out
    vh.record("phase2 selftest gate", status == 0 and gate,
              f"rc={status}, {out.strip().splitlines()[-1] if out.strip() else ''}")
    if status == 0:
        vh.record("phase2 selftest: NET_RCV_MSG round trip reported",
                  "NET_RCV_MSG round trip" in out, "")
    return status == 0 and gate


def phase_traffic(session):
    status, out = session.run(
        "/hurd/virtio-net --selftest --selftest-traffic", timeout=300)
    gate = "selftest ok" in out
    vh.record("phase3 selftest+traffic gate", status == 0 and gate,
              f"rc={status}, {out.strip().splitlines()[-1] if out.strip() else ''}")
    # Traffic arrival is backend-dependent; report, don't fail.
    if "raw RX observed" in out:
        vh.record("phase3 raw RX observed", True, "")
    else:
        vh.record("phase3 raw RX observed (backend-dependent)",
                  True, "no backend traffic observed (not a failure)")
    return status == 0 and gate


def phase_daemon(session):
    session.run(
        "sh -c 'setsid /hurd/virtio-net >%s 2>&1 </dev/null &'" % DAEMON_LOG,
        timeout=30)
    import time
    deadline = time.time() + 60
    while time.time() < deadline:
        pids = vh.guest_pids(session, r"hurd\/virtio-net")
        _, log = session.run(f"cat {DAEMON_LOG}", timeout=30)
        if pids:
            vh.record("phase4 daemon running", True, f"pids {', '.join(pids)}")
            return
        if log.strip():
            vh.record("phase4 daemon running", False,
                      f"exited; log: {log.strip()[-300:]}")
            return
        time.sleep(2)
    vh.record("phase4 daemon running", False, "did not start within 60s")


def stop_daemon(session):
    pids = vh.guest_pids(session, r"hurd\/virtio-net")
    if not pids:
        return
    # Exclude the --serve translator if any; stop only plain daemon.
    session.run("pkill -f 'hurd/virtio-net$' 2>/dev/null || true", timeout=30)
    import time
    deadline = time.time() + 60
    while time.time() < deadline:
        if not vh.guest_pids(session, r"hurd\/virtio-net$"):
            return
        time.sleep(2)


def phase_serve(session):
    # Clean any stale node first.
    session.run(f"settrans -g {SERVE_NODE} 2>/dev/null || true", timeout=30)
    status, out = session.run(
        f"settrans -c {SERVE_NODE} /hurd/virtio-net --serve", timeout=120)
    vh.record("phase5 serve: translator started", status == 0,
              f"rc={status}, {out.strip()[-300:]}")
    status, out = session.run(f"ls -l {SERVE_NODE}", timeout=60)
    vh.record("phase5 serve: node published", status == 0 and "vnet0" in out,
              f"rc={status}, {out.strip()[-200:]}")
    pids = vh.guest_pids(session, r"virtio-net.*--serve")
    vh.record("phase5 serve: process running", bool(pids),
              "no matching process" if not pids else ", ".join(pids))
    # Leave the translator running for subsequent phases; teardown happens
    # in phase_serve_teardown().


def phase_raw_client(session):
    install_client(session)
    status, out = session.run("/hurd/vnet-client /dev/vnet0 test", timeout=120)
    vh.record("phase6 raw client TX/RX", status == 0 and "PASS" in out,
              f"rc={status}, {out.strip()[-300:]}")

def phase_pfinet_attach(session):
    status, out = session.run(
        "settrans -c /tmp/pfinet-vnet0 /hurd/pfinet -i /dev/vnet0 "
        "-a 10.0.2.20 -m 255.255.255.0", timeout=120)
    vh.record("phase7 pfinet attach", status == 0,
              f"rc={status}, {out.strip()[-200:]}")
    import time
    time.sleep(2)
    pids = vh.guest_pids(session, r"hurd\/pfinet")
    vh.record("phase7 pfinet running", bool(pids),
              "no pfinet process" if not pids else ", ".join(pids))

def phase_serve_teardown(session):
    session.run(f"settrans -g {SERVE_NODE} 2>/dev/null || true", timeout=60)
    pids = vh.guest_pids(session, r"virtio-net.*--serve")
    if pids:
        session.run("kill " + " ".join(pids), timeout=30)

def _checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return ~total & 0xffff


def _peer_answer(frame):
    """The peer's answer to FRAME: an ARP reply or an ICMP echo reply for
    STALL_PEER_IP, or None."""
    if len(frame) >= 42 and frame[12:14] == b"\x08\x06":
        if frame[20:22] != b"\x00\x01" or frame[38:42] != STALL_PEER_IP:
            return None
        sender_mac, sender_ip = frame[22:28], frame[28:32]
        return (sender_mac + STALL_PEER_MAC + b"\x08\x06"
                + b"\x00\x01\x08\x00\x06\x04\x00\x02"
                + STALL_PEER_MAC + STALL_PEER_IP + sender_mac + sender_ip)
    if len(frame) < 34 or frame[12:14] != b"\x08\x00":
        return None
    ihl = (frame[14] & 0x0f) * 4
    ip = bytearray(frame[14:14 + ihl])
    if len(ip) < 20 or ip[9] != 1 or bytes(ip[16:20]) != STALL_PEER_IP:
        return None
    total = struct.unpack("!H", ip[2:4])[0]
    icmp = bytearray(frame[14 + ihl:14 + total])
    if len(icmp) < 8 or icmp[0] != 8:
        return None
    icmp[0] = 0
    icmp[2:4] = b"\0\0"
    icmp[2:4] = struct.pack("!H", _checksum(bytes(icmp)))
    ip[12:16], ip[16:20] = ip[16:20], ip[12:16]
    ip[8] = 64
    ip[10:12] = b"\0\0"
    ip[10:12] = struct.pack("!H", _checksum(bytes(ip)))
    return frame[6:12] + STALL_PEER_MAC + b"\x08\x00" + bytes(ip) + bytes(icmp)


class StallPeer(threading.Thread):
    """The far end of the device's backend, QEMU's -netdev stream.

    QEMU sends each frame as a 4-byte big-endian length and the frame, and
    takes the peer's frames the same way.  While the peer reads, it counts
    the frames and answers ARP and ICMP echo requests for STALL_PEER_IP.
    While it is stalled it reads nothing: once the socket buffer is full,
    QEMU's write would block, and QEMU keeps the transmit chain it took
    and takes no more from the queue until the socket is writable again
    (net/stream_data.c, net_stream_data_receive; hw/net/virtio-net.c,
    virtio_net_flush_tx), so the driver gets no completions.

    The peer listens and QEMU connects: QEMU makes the socket of a
    connection it opens non-blocking, but not one it accepts (QEMU's
    net/stream_data.c; io/channel-socket.c, qio_channel_socket_accept),
    and a blocking write would stop QEMU's main loop, and the whole guest
    with it, for as long as the peer does not read.
    """

    def __init__(self, path, timeout=60):
        super().__init__(daemon=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            listener.bind(path)
            listener.listen(1)
            # QEMU tries again every reconnect-ms.
            listener.settimeout(timeout)
            self.sock, _ = listener.accept()
        finally:
            listener.close()
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        self.sock.settimeout(None)
        self.stalled = threading.Event()
        self.done = threading.Event()
        self.frames = 0

    def run(self):
        pending = b""
        while not self.done.is_set():
            if self.stalled.is_set():
                time.sleep(0.1)
                continue
            ready, _, _ = select.select([self.sock], [], [], 0.2)
            if not ready:
                continue
            data = self.sock.recv(1 << 16)
            if not data:
                return
            pending += data
            while len(pending) >= 4:
                (length,) = struct.unpack("!I", pending[:4])
                if len(pending) < 4 + length:
                    break
                frame = pending[4:4 + length]
                pending = pending[4 + length:]
                self.frames += 1
                answer = _peer_answer(frame)
                if answer is not None:
                    self.sock.sendall(struct.pack("!I", len(answer)) + answer)

    def close(self):
        self.done.set()
        self.join(timeout=5)
        self.sock.close()


def stall_ping(session, peer):
    """Ping the peer three times through the card's pfinet; return the
    replies and a detail line."""
    status, out = session.run(
        f"remap /servers/socket/2 {STALL_PFINET} -- "
        f"ping -c 3 {socket.inet_ntoa(STALL_PEER_IP)}")
    m = re.search(r"(\d+) packets received", out)
    received = int(m.group(1)) if m else 0
    return received, (f"{received}/3 replies (rc={status}), the peer has read "
                      f"{peer.frames} frames")


def no_slot_count(session):
    _, out = session.run(
        f"grep -c 'no free TX slot' {STALL_DRIVER_LOG} || true")
    m = re.search(r"(\d+)", out)
    return int(m.group(1)) if m else -1


def stall_pfinet_serves(session):
    # A dead translator leaves the node to the filesystem under it, which
    # then answers the RPC.
    status, out = session.run(f"fsysopts {STALL_PFINET}")
    return status == 0 and "pfinet" in out, out.strip()[-200:]


def phase_stall(session):
    """A backend that stops taking frames while pfinet sends, then resumes.

    The driver serves with --sync, so each write waits for its completion
    and gives up after VNET_TX_TIMEOUT; the slot stays marked until the
    device hands the chain back.  A flood of broadcast pings (no ARP)
    through a pfinet on the card makes every slot time out once.  When the
    peer reads again, QEMU completes the held chains, and the slots must
    come back: before hurdkit/virtio#27 the timed-out waiter kept each
    slot, and every later write failed with "no free TX slot".  pfinet
    must survive the failed writes; that needs a pfinet that drops a frame
    the driver does not take (hurdkit/hurd#54).
    """
    if not VNET_STALL_SOCKET:
        vh.record("stall: backend socket", False,
                  "VNET_STALL_SOCKET is not set (the boot script sets it)")
        return
    try:
        peer = StallPeer(VNET_STALL_SOCKET)
    except OSError as exc:
        vh.record("stall: QEMU connected to the backend socket", False,
                  f"{VNET_STALL_SOCKET}: {exc}")
        return
    peer.start()
    try:
        session.run(f"settrans -fg {STALL_PFINET} 2>/dev/null; "
                    f"settrans -fg {SERVE_NODE} 2>/dev/null; "
                    f"rm -f {STALL_PFINET}", timeout=60)
        status, out = session.run(
            f"settrans -ac {SERVE_NODE} /hurd/virtio-net --serve --sync "
            f"2>{STALL_DRIVER_LOG}", timeout=120)
        vh.record("stall: driver serving with --sync", status == 0,
                  f"rc={status}, {out.strip()[-200:]}")
        status, out = session.run(
            f"settrans -ac {STALL_PFINET} /hurd/pfinet -i {SERVE_NODE} "
            f"-a {STALL_GUEST_IP} -m 255.255.255.0 2>{STALL_PFINET_LOG}",
            timeout=120)
        vh.record("stall: pfinet on the card", status == 0,
                  f"rc={status}, {out.strip()[-200:]}")

        received, detail = stall_ping(session, peer)
        vh.record("stall: traffic flows before the stall", received > 0,
                  detail)
        if not received:
            return

        peer.stalled.set()
        session.run(
            f"sh -c 'setsid remap /servers/socket/2 {STALL_PFINET} -- "
            f"ping -f -q -s 1400 -c 2000 {STALL_BROADCAST} "
            f">{STALL_FLOOD_LOG} 2>&1 </dev/null &'")
        start = time.time()
        exhausted = False
        while time.time() < start + STALL_TIMEOUT:
            time.sleep(10)
            if no_slot_count(session) > 0:
                exhausted = True
                break
            if not vh.guest_pids(session, r"ping -f", timeout=vh.COMMAND_TIMEOUT):
                break
        elapsed = time.time() - start
        pids = vh.guest_pids(session, r"ping -f", timeout=vh.COMMAND_TIMEOUT)
        if pids:
            session.run("kill " + " ".join(pids))
        _, flood = session.run(f"tail -n 3 {STALL_FLOOD_LOG}")
        vh.record("stall: every TX slot timed out while the backend stalled",
                  exhausted,
                  f"'no free TX slot' after {elapsed:.0f}s" if exhausted
                  else f"not within {elapsed:.0f}s; flood: "
                  f"{flood.strip()[-200:]}")
        time.sleep(3)
        ok, detail = stall_pfinet_serves(session)
        vh.record("stall: pfinet survived the stall", ok, detail)

        before = no_slot_count(session)
        peer.stalled.clear()
        # QEMU hands the held frames to the peer and completes their chains.
        time.sleep(5)
        received, detail = stall_ping(session, peer)
        after = no_slot_count(session)
        vh.record("stall: traffic flows again after the backend resumed",
                  received > 0, detail)
        vh.record("stall: the timed-out slots are free again",
                  after == before,
                  f"'no free TX slot' lines: {before} before the resume, "
                  f"{after} after")
        ok, detail = stall_pfinet_serves(session)
        vh.record("stall: pfinet still serves", ok, detail)
    finally:
        try:
            session.run(f"settrans -fg {STALL_PFINET} 2>/dev/null; "
                        f"settrans -fg {SERVE_NODE} 2>/dev/null; true",
                        timeout=60)
        except vh.GuestError:
            pass
        peer.close()


def nodev(session):
    status, out = session.run("/hurd/virtio-net --selftest", timeout=120)
    vh.record("negative: no device, selftest clean exit", status != 0,
              f"rc={status}, "
              f"{out.strip().splitlines()[-1] if out.strip() else ''}")
    status, out = session.run("/hurd/virtio-net --status", timeout=60)
    vh.record("negative: no device, status clean exit", status != 0,
              f"rc={status}, "
              f"{out.strip().splitlines()[-1] if out.strip() else ''}")


def stress(session):
    cycles = int(os.environ.get("CYCLES", "8"))
    for i in range(cycles):
        status, out = session.run("/hurd/virtio-net --selftest", timeout=300)
        ok = status == 0 and "selftest ok" in out
        vh.record(f"stress cycle {i + 1} selftest", ok,
                  f"rc={status}")
    guest_responsive(session, "stress post")


def dump_guest_state(session):
    vh.dump_commands(session, (
        ("driver status", "/hurd/virtio-net --status || true"),
        ("processes", "ps -ef | grep -i virtio-net | grep -v grep || true"),
    ))
    if vh.WANT_GDB:
        vh.gdb_backtraces(
            session, r"hurd\/virtio-net",
            "gdb /hurd/virtio-net -p {pid} -batch "
            "-ex 'thread apply all bt' 2>&1")


def main():
    mode = _MODE

    if mode == "nodev":
        pass
    else:
        if not VIRTIO_NET_BIN:
            sys.exit("VIRTIO_NET_BIN is not set (the boot script exports it)")

    session = None
    failed_early = False
    try:
        session = vh.GuestSession()
        if mode == "nodev":
            nodev(session)
        elif mode == "stress":
            install_binary(session)
            stress(session)
        elif mode == "stall":
            install_binary(session)
            phase_stall(session)
        else:
            install_binary(session)
            if not phase_status(session):
                failed_early = True
            else:
                if phase_selftest(session):
                    phase_traffic(session)
            phase_daemon(session)
            stop_daemon(session)
            phase_serve(session)
            phase_raw_client(session)
            phase_pfinet_attach(session)
            phase_serve_teardown(session)
    except vh.GuestError as exc:
        vh.record("harness", False, str(exc))
        failed_early = True
    if failed_early:
        try:
            dump_guest_state(session)
        except Exception as exc:  # noqa: BLE001
            print(f"--- guest state dump failed: {exc} ---", flush=True)
        print("--- QEMU serial log tail ---", flush=True)
        print(vh.qemu_log_tail(), flush=True)

    return vh.finish(session)


if __name__ == "__main__":
    sys.exit(main())
