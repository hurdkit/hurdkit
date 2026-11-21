# Performance debugging skill for virtio drivers under GNU/Hurd (PERF_DEBUG)

How to investigate performance of a virtio device translator on this stack,
today virtio-9p, tomorrow any device. The method is measurement first, layer
isolation second, suspects third, fixes last, each proven with numbers.

## Ground rules

1. Never optimise without a baseline. Run the benchmark matrix before
   touching code and keep the JSON output of every run, before and after,
   in the same directory with the commit hash in the name.
2. One change per measurement. A fix proven together with three others
   proves nothing about any of them.
3. The benchmark measures file operations through the whole stack. A slow
   number is a hypothesis about a layer, not a verdict on one.
4. Degrade gracefully when investigating: if a leg fails, record it and
   keep the legs that ran. Partial matrices still compare.

## The layers, from slowest to fastest to change

Every filesystem operation through virtio-9p crosses all of these:

1. The client filesystem translator, 9pfs, which builds protocol messages.
2. Two Mach IPC round trips per protocol message into the device
   translator, io_write to send, io_read to collect.
3. The stream adapter that reassembles short writes into whole messages.
4. The exchange engine that copies the message into a DMA buffer, posts it,
   kicks the device, waits for the interrupt, copies the reply out.
5. The virtqueue and the device itself, QEMU today.

Virtio-blk rides layers 4 and 5 with bigger payloads and a caching
filesystem above, so a fair comparison pins the same layer, blk against 9p
at the device level, ext2fs on blk against 9pfs on 9p at the filesystem
level. The benchmark harness does exactly this, use its legs.

## Measurement

- `scripts/virtio_bench.sh` boots the guest and runs the matrix. Legs:
  B1 raw block dd, B2 tar of a 1000 file corpus, B3 filesystem dd at 4K
  and 1M, N1 network. MODE selects a subset, BENCH_RUNS sets iterations,
  BENCH_JSON=1 emits one JSON object per case and run.
- For B3, the two filesystems ride the same virtio-blk driver on separate
  disks, so the comparison isolates the 9pfs plus virtio-9p stack against
  ext2fs with its page cache. Read the harness source before trusting any
  leg, the isolation is only as good as the setup code.
- Wall time over SSH is the outer truth. When a case is slow, drill in
  from the guest: time the same dd against the raw translator node, then
  a single protocol exchange with a small C client, then the device read
  alone. The first layer whose numbers collapse carries the problem.
- Sample the host QEMU process threads, `/proc/<pid>/task/*/stat` fields
  14 and 15, twice a few seconds apart. A burning vCPU thread means the
  guest spins, a burning device thread means the host model works.

## The suspect checklist, ranked by how often it is guilty here

1. One request in flight. A lock held across submit, wait and reply makes
   the whole pipeline serial. Look for a mutex taken before the exchange
   and released after, and count how many payloads each round trip moves.
   Virtio-blk moves up to 256 KiB per round trip, a 9p exchange moves one
   message. The ratio of round trips to bytes is the first thing to
   compute.
2. Copies per payload. Count them end to end, IPC included. The 9p path
   copies payload data four times inside the translator on top of two IPC
   copies. A read that lands in a mapped reply region instead of a
   memcpy saves one whole hop.
3. Per-request device kicks. Every notify is a port write and a VM exit.
   The deferred post plus single notify API exists, use it when requests
   can batch.
4. Per-completion interrupts and thread handoffs. Each completion wakes a
   waiter through the irqhelp thread and a condition variable, a two
   thread ping pong per message. Negotiate EVENT_IDX where the device
   supports it, and prefer a short poll of the used ring before sleeping,
   QEMU completes in microseconds.
5. IPC hop count per operation. Two round trips per message is the design
   of the stream adapter, but any chance to answer from a buffered reply
   without crossing the boundary again is free time.
6. Allocation on the hot path. Per call mmap and fresh buffers show up at
   small sizes, where tar lives.

## Proving a fix

1. Reproduce the baseline on the same boot mode and image as the fix run.
2. Apply one change, rebuild only what changed, install into the guest
   image the same way the harness does.
3. Run the same leg, same BENCH_RUNS, collect JSON.
4. Report per case: baseline median and spread, fixed median and spread,
   and the pass or fail of the size check. A fix that helps 1M dd and
   hurts 4K dd is a real result, not a success.
5. Keep the before and after serial logs. A latency fix that adds
   spinning shows up as host CPU time even when throughput is flat.

## What lives where

- `scripts/virtio_bench.sh` and `scripts/virtio_bench.py`: the harness.
- `scripts/virtio_test.py`: the guest session and boot plumbing.
- The device translator under test: the sibling virtio checkout.
- The client translator: 3p/9pfs in this repo.
- Skills for correctness debugging, hangs and IRQ problems:
  `skills/DRIVER_DEBUGGING.md`.
