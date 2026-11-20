/* libbpf's validator refuses a filter whose jumps can leave the program:
   every jump must land on a later instruction of the same program.
   eth-multiplexer, and the network drivers that link libbpf, hand each
   client's filter to libbpf's net_set_filter, which calls bpf_validate,
   and run it with bpf_do_filter on every frame they receive.

   Usage: bpf-validate

   It calls bpf_validate directly, the way net_set_filter does: with the
   whole filter, including its first word (NETF_IN | NETF_BPF), which the
   validator skips, and with the size of the filter in bytes.  For a
   program without a BPF_RET|BPF_MATCH_IMM instruction it returns 1 when
   it accepts the program and 0 when it refuses it.  Every refused
   program ends in BPF_RET, as a valid program must, so what is refused
   is its jump; the accepted programs make a validator that refuses
   everything fail.

   Build it against the libbpf to check, linked statically, so that the
   binary carries that libbpf:

     cc -O2 -Wall -Wextra -o bpf-validate bpf-validate.c PREFIX/lib/libbpf.a

   The output is TAP.  It needs the Hurd's libbpf and GNU Mach's
   <device/bpf.h>, so it does not build on Linux.

   A libbpf that checks a BPF_JA only with `from + k >= len' lets every
   negative K through, since K is signed, so the backward jump cases fail
   on it.  bpf_do_filter adds K to its program counter: with K = -1 the
   filter never returns, and with a larger negative K it runs the memory
   before the program as instructions.  For the largest K, the sum
   `from + k' overflows.  */

#include <limits.h>
#include <stdio.h>

#include <device/bpf.h>
#include <device/net_status.h>
/* libbpf's own header; it needs the types of <device/net_status.h>.  */
#include <hurd/bpf_impl.h>

/* The first word of a filter, as net_set_filter requires it.  */
#define HEADER { NETF_IN | NETF_BPF, 0, 0, 0 }
#define JA(k) BPF_STMT (BPF_JMP | BPF_JA, k)
#define JEQ(jt, jf) BPF_JUMP (BPF_JMP | BPF_JEQ | BPF_K, 0, jt, jf)
#define RET BPF_STMT (BPF_RET | BPF_K, 0)

/* hurdkit/hurd#47: the jump lands on itself.  */
static struct bpf_insn jump_to_itself[] = { HEADER, JA (-1), RET };
static struct bpf_insn jump_before_start[] = { HEADER, JA (-3), RET };
static struct bpf_insn jump_past_end[] = { HEADER, JA (1), RET };
/* FROM + K would overflow an int.  */
static struct bpf_insn jump_far_past_end[] = { HEADER, JA (INT_MAX), RET };
static struct bpf_insn jump_forward[] = { HEADER, JA (1), RET, RET };
static struct bpf_insn return_only[] = { HEADER, RET };
static struct bpf_insn branch_forward[] = { HEADER, JEQ (1, 0), RET, RET };
static struct bpf_insn branch_past_end[] = { HEADER, JEQ (0, 2), RET, RET };

static int test_number;
static int failures;

static void
check (struct bpf_insn *program, size_t bytes, int accepted,
       const char *description)
{
  bpf_insn_t match = NULL;
  int ret = bpf_validate (program, (int) bytes, &match);
  int ok = accepted ? ret == 1 : ret == 0;

  test_number++;
  if (!ok)
    failures++;
  printf ("%sok %d - %s\n", ok ? "" : "not ", test_number, description);
  if (!ok)
    printf ("# bpf_validate returned %d, expected %d\n", ret,
            accepted ? 1 : 0);
}

#define CHECK(program, accepted, description) \
  check (program, sizeof program, accepted, description)

int
main (void)
{
  printf ("TAP version 13\n1..8\n");
  CHECK (jump_to_itself, 0, "a BPF_JA back to itself is refused");
  CHECK (jump_before_start, 0,
         "a BPF_JA back to before the program is refused");
  CHECK (jump_past_end, 0, "a BPF_JA just past the end is refused");
  CHECK (jump_far_past_end, 0,
         "a BPF_JA with the largest offset is refused");
  CHECK (jump_forward, 1, "a BPF_JA forward within the program is accepted");
  CHECK (return_only, 1, "a lone BPF_RET is accepted");
  CHECK (branch_forward, 1,
         "a conditional jump within the program is accepted");
  CHECK (branch_past_end, 0,
         "a conditional jump past the end is refused");
  return failures != 0;
}
