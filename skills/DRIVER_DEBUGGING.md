# Driver / PCI / IRQ debugging skill (GNU/Turd guests under QEMU)

Debugging device-driver translators in this repo (virtio-9p today, any PCI
device tomorrow), above all interrupt-delivery bugs on shared PCI lines,
including when the normal SSH control channel is already dead.

## Control channels, in order of trust

1. **QEMU serial log** (`img/tmp/virtio-test-qemu.log`, `$QEMU_LOG`): driver
   `fprintf(stderr, ...)` and kernel prints always land here, even when SSH is
   dead. The harness truncates it per boot and keeps it on failure. This is
   the printf of last resort: put diagnostics in stderr, not stdout.
2. **SSH** (`scripts/virtio_test.py` `GuestSession`): first thing to die.
   Distinguish the failure modes: `Timed out after Ns while running: CMD` =
   the session is alive but the guest is starved; `Connection lost while
   running: CMD` = the network (e1000) is dead.
3. **Host `/proc` on the QEMU pid**: names the burning thread.
   `/proc/<qemu-pid>/task/*/stat` fields 14+15 (utime+stime), sampled twice a
   few seconds apart. `CPU 0/KVM` growing = guest vCPU 0 spinning (guest-side
   bug); `qemu-system` main thread or `IOThread` = host-side device model.
   `top -H` thread-name greps are unreliable here; use `/proc/<pid>/task`.

## Reaching the guest when SSH is dead

- For manual debug boots, do not redirect serial to a file: keep `-nographic`
  on your terminal (you can log in on the console) or add
  `-monitor unix:/tmp/mon,server,nowait` for the QEMU monitor.
- Before reproducing, arm a guest-side watchdog that needs no SSH to be read:
  `nohup sh -c 'while :; do date +%s; ps -A -o pid,time,comm; echo ---; done >>
  /dev/console' >/dev/null 2>&1 </dev/null &`. It must be fully detached
  (all fds away from the pty) or the SSH session never exits.
- In-guest gdb (base image already has it):
  `gdb /hurd/<bin> -p <pid> -batch -ex 'thread apply all bt'` — pass the
  binary or the unwinding is garbage. `GDB=1 make virtio-test` makes the
  harness dump stacks of stuck `virtio-9p`/`9pfs` processes automatically
  (needs working networking, so it fails late in a storm).

## Shared-level-IRQ model (the shape of every bug here)

- On the default `pc` machine e1000 and virtio-9p share IRQ 11, level
  triggered. gnumach masks the line on fire (`queue_intr` → `__disable_irq`)
  and unmasks only via `irq_acknowledge` → `__enable_irq`. `irqhelp` acks
  **unconditionally after every handler call**, so a handler must answer
  "is this mine?" by reading its own device ISR and return untouched when it
  is not; the driver must never call `device_intr_ack`/`__enable_irq` itself.
- QEMU legacy virtio-pci: INTA asserts on used-buffer push, deasserts on ISR
  read. ISR bit 0 = queue completion, 0x3 = config change, so check `& 1` and
  let the waiter re-check `used.idx` instead of trusting the signal.
- Kernel serial-log markers: `new delivery port ... for <task>` (registered),
  `release a dead delivery port` + `still N unacked irqs in entry` (a driver
  exited between fire and ack; the kernel compensates with one `__enable_irq`
  per unacked). Benign in isolation; count them during churn.
- The ISR read is read-to-clear: two handlers for the same virtio device (a
  selftest next to a live translator) steal each other's interrupt and one
  waiter times out. One owner per device at a time.
- Storm signature: one vCPU pegged + SSH session alive but stalled + netdde
  CPU climbing + no `v9fs_*` traces in the serial log.

## Repro loops

- End-to-end until it wedges: `for i in $(seq 1 N); do GDB=1 make virtio-test
  || break; done` (a full run is ~80 s; the wedge is intermittent, expect
  ~1-in-3).
- Add/remove churn (registration/teardown path): `make virtio-irq-stress`.
- Manual single shot: boot, install binaries, `settrans -a /dev/virtio-9p0
  /hurd/virtio-9p --mount-tag=hostshare`, watch serial + netdde CPU.

## Live forensics on a wedged run (QEMU side)

The harness passes `-monitor unix:img/tmp/virtio-test-monitor.sock` to
every boot, so a wedge is dissectable without SSH. Work the scene in this
order:

1. `stop` via the monitor (freeze the VM) before any gdb attach; `cont`
   only deliberately. Talk to the socket with python (`socat`/`ncat` are
   not installed); strip readline echo from replies.
2. `info ioapic` — **the signature of the stalled-shared-IRQ wedge**: the
   pin is `masked` in its redir entry AND its number appears on the
   `IRR` line (an interrupt fired but was never delivered). Both devices
   on the line starve from that moment.
3. gdb on the QEMU pid (host build has DWARF):
   `set $dev=(V9fsVirtioState*)object_resolve_path_type("", "virtio-9p-device", 0)`
   (same pattern for `"e1000"`). `status`/`isr`/`vq[0].last_avail_idx`
   separate "guest never submitted" from "QEMU never replied". Gotchas:
   `E1000State->mac_reg[]` is indexed by register offset >> 2 (ICR =
   `mac_reg[0xc0>>2]`, IMS = `mac_reg[0xd0>>2]`); `vring.avail`/`used`
   are plain `hwaddr` GPAs — read guest RAM with the monitor's
   `xp /Nwx <gpa>` (e.g. `avail+2` is the live avail.idx), not by
   dereferencing them.
4. QEMU IRQ tracing for the mask/unmask story:
   `QTRACE='ioapic_*' make virtio-irq-stress` logs every device assert
   (`ioapic_set_irq`) and every guest mask/unmask write
   (`ioapic_mem_write`) to img/tmp/qtrace.log. **Requires
   `QEMU_EXTRA='-machine kernel_irqchip=split'`**: with the default
   in-kernel irqchip the guest IOAPIC belongs to KVM and the trace log
   stays 0 bytes. Split also slows IRQ delivery: boots may need
   `SSH_PROBE_ATTEMPTS=400`, and one split boot showed a self-healing
   wd0 lost-interrupt (IDE serves its IRQ through the same irqhelp
   path) — treat isolated soft-corrected ATA timeouts as latency
   artifacts, not media failure.
5. Reading files out of the qcow2: qemu-nbd + nbdfuse + debugfs with the
   `file?offset=<partition-2-byte-offset>` syntax (offset 1000341504 for
   this image). The daemons must be backgrounded with polling loops (the
   pattern in scripts/repair_filesystem.sh); nbdfuse never exits in the
   foreground. The image's `/boot/gnumach-1.8-amd64-up.gz` is stripped —
   no kernel symbols — but the kernel prints live kernel VAs of its own
   structures into the serial log, and guest-physical = VA -
   0xffffffff80000000 (`KERNEL_MAP_BASE` in the gnumach x86_64 build).

## The shared-IRQ-line wedge (open issue)

Under add/remove churn with virtio-9p sharing IRQ 11 with the e1000,
gnumach intermittently leaves the IOAPIC pin masked with IRR latched and
never unmasks: the whole line dies (netdde and the translator both
starve, arbitrary victim point — first exchange or teardown). The QEMU
threads stay healthy and the vCPUs idle; the guest freezes blocked. Not a
driver bug: putting virtio-9p on its own line (slot ≡ 1 mod 4 → PIRQ A →
IRQ 10, harness default `VIRTIO_ADDR=0x5`) makes it disappear 4/4, and
`VIRTIO_ADDR=` reproduces it. Kernel-side mechanism identified
2026-11-15: gnumach's nested `nested_irqs[].ndisabled` counters
(`i386/i386/irq.c:43-92`) keep a shared pin masked until **every**
alive entry on the line acks, so one lost/unacked notification (wedged
driver thread, `deliver_intr` `ikm_alloc` failure) starves the whole
line with no recovery sweep for alive entries; the ioapic RMW itself is
lock-protected (`ioapic_lock`), and this QEMU's IOAPIC v0x20 uses the
specific-EOI path (no mask+edge workaround). An `ioapic_*` qtrace of a
wedged run (split irqchip) showing the last `ioapic_set_irq` followed
by mask=1 and no unmask write is the confirmation to capture.

## Landmines learned the hard way

- pexpect output carries ANSI/bracketed-paste escapes; strip before string
  compares (harness `clean()`).
- `pkill`/`pgrep` patterns for QEMU are unreliable; the harness uses a pidfile
  (`img/tmp/virtio-test-qemu.pid`) plus `/proc/$PID/comm` verification.
  `/bin/kill -9` (the shell builtin `kill` is unsupported in this context).
- `settrans -c` is passive-only; `-a` starts actively. Removal form is
  `settrans -c NODE ''` (prints ERANGE, rc=5, but works).
- glibc port I/O is `outb(value, port)`; swapped args SIGILL the driver.
- `vm_allocate_contiguous` fragments under repeated 4 MiB requests; a fresh
  boot fixes it.
- A `/dev/tcp` boot probe races sshd; probe with a real SSH login instead.
- Working notes and evidence captures live in untracked scratch
  directories; do not rely on them being in git.
- The driver's 30 s `ETIMEDOUT` prints `virtio-9p: device did not reply`; if
  a hung run never prints it, the hang is before the condvar wait, not in it.
