/* The clocks across pauses of the whole guest: the guest side of
   scripts/clock_pause_test.sh, which stops the guest's QEMU from the host
   (SIGSTOP, then SIGCONT) while this program runs.

   Usage: clock-pause [BUSY-THREADS]

   One thread reads CLOCK_MONOTONIC and CLOCK_REALTIME with a short sleep
   before each reading, so that a tickless kernel has stopped its clock
   interrupt when a pause comes.  BUSY-THREADS more threads (default 0, at
   most MAX_BUSY_THREADS) read both clocks as fast as they can, so that
   reads also come while the kernel catches up after a pause, and from
   every processor.

   Each line "now" on the standard input prints both clocks, in
   nanoseconds, as the TAP comment "# now MONOTONIC REALTIME"; the host
   script reads them before and after each pause.  At the end of the
   standard input the threads stop and the program prints its result as
   TAP.  It runs on Linux too, which checks the expectations themselves:

     (sleep 2; echo now; sleep 2) | clock-pause 2

   Under KVM, GNU Mach's high precision clock is kvmclock, which follows
   the host's clock also while QEMU is stopped, so after a pause the
   kernel finds it ahead by the length of the pause.  How the kernel then
   brings its clocks up to date differs: with a periodic clock interrupt
   it catches up over several interrupts, while a tickless kernel charges
   the whole pause at once (clock_catchup in kern/mach_clock.c).  So this
   program checks only the direction of the clocks, not the size of their
   steps.  The steps of the sleeping thread that are longer than its sleep
   by more than LONG_STEP_NS go to the standard error, to show what the
   kernel did.  */

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_BUSY_THREADS 8
/* The sleeps of the sleeping thread cycle through these, in ms.  */
static const int sleeps_ms[] = { 1, 3, 10, 30, 100, 300 };
#define SLEEPS (sizeof sleeps_ms / sizeof sleeps_ms[0])
#define LONG_STEP_NS 500000000LL

struct reader
{
  pthread_t thread;
  int number;
  int sleeps;
  long long readings;
  int64_t first_monotonic, last_monotonic;
  int64_t largest_step;
  long long steps_back;
  int64_t largest_step_back;
  int error;
};

static int stop;

static int64_t
nanoseconds (const struct timespec *t)
{
  return (int64_t) t->tv_sec * 1000000000 + t->tv_nsec;
}

static int
read_clock (clockid_t clock, int64_t *value)
{
  struct timespec t;
  if (clock_gettime (clock, &t) < 0)
    {
      *value = 0;
      return errno ? errno : EINVAL;
    }
  *value = nanoseconds (&t);
  return 0;
}

/* Read CLOCK_MONOTONIC and CLOCK_REALTIME in turn until STOP is set, and
   note every step back of CLOCK_MONOTONIC.  */
static void *
read_clocks (void *argument)
{
  struct reader *r = argument;
  int64_t monotonic, wall, previous_monotonic, previous_wall;
  unsigned i = 0;

  if ((r->error = read_clock (CLOCK_MONOTONIC, &previous_monotonic))
      || (r->error = read_clock (CLOCK_REALTIME, &previous_wall)))
    return NULL;
  r->first_monotonic = r->last_monotonic = previous_monotonic;
  while (!__atomic_load_n (&stop, __ATOMIC_RELAXED))
    {
      int64_t sleep_ns = 0;
      if (r->sleeps)
        {
          struct timespec pause = { 0, 0 };
          sleep_ns = sleeps_ms[i++ % SLEEPS] * 1000000LL;
          pause.tv_nsec = sleep_ns;
          nanosleep (&pause, NULL);
        }
      if ((r->error = read_clock (CLOCK_MONOTONIC, &monotonic))
          || (r->error = read_clock (CLOCK_REALTIME, &wall)))
        return NULL;
      r->readings++;
      if (monotonic < previous_monotonic)
        {
          if (r->steps_back++ == 0)
            fprintf (stderr, "# thread %d: CLOCK_MONOTONIC went from %lld "
                     "to %lld ns\n", r->number, (long long) previous_monotonic,
                     (long long) monotonic);
          if (previous_monotonic - monotonic > r->largest_step_back)
            r->largest_step_back = previous_monotonic - monotonic;
        }
      else if (monotonic - previous_monotonic > r->largest_step)
        r->largest_step = monotonic - previous_monotonic;
      if (r->sleeps
          && (monotonic - previous_monotonic > sleep_ns + LONG_STEP_NS
              || wall - previous_wall > sleep_ns + LONG_STEP_NS))
        fprintf (stderr, "# thread %d: after a %lld ms sleep, "
                 "CLOCK_MONOTONIC %+lld ms, CLOCK_REALTIME %+lld ms\n",
                 r->number, (long long) (sleep_ns / 1000000),
                 (long long) ((monotonic - previous_monotonic) / 1000000),
                 (long long) ((wall - previous_wall) / 1000000));
      previous_monotonic = monotonic;
      previous_wall = wall;
    }
  r->last_monotonic = previous_monotonic;
  return NULL;
}

static int test_number;

static void
report (int ok, const char *description)
{
  printf ("%sok %d - %s\n", ok ? "" : "not ", ++test_number, description);
}

int
main (int argc, char **argv)
{
  int busy = 0;
  char *end;

  if (argc > 2)
    busy = -1;
  else if (argc == 2)
    {
      long n = strtol (argv[1], &end, 10);
      busy = *argv[1] && !*end && n >= 0 && n <= MAX_BUSY_THREADS ? n : -1;
    }
  if (busy < 0)
    {
      fprintf (stderr, "usage: clock-pause [BUSY-THREADS (0 to %d)]\n",
               MAX_BUSY_THREADS);
      return 2;
    }

  struct reader readers[1 + MAX_BUSY_THREADS];
  int threads = 1 + busy;
  memset (readers, 0, sizeof readers);
  printf ("TAP version 13\n");
  fflush (stdout);
  for (int i = 0; i < threads; i++)
    {
      readers[i].number = i + 1;
      readers[i].sleeps = i == 0;
      int err = pthread_create (&readers[i].thread, NULL, read_clocks,
                                &readers[i]);
      if (err)
        {
          fprintf (stderr, "clock-pause: pthread_create: %s\n",
                   strerror (err));
          return 2;
        }
    }

  char line[64];
  while (fgets (line, sizeof line, stdin))
    if (strcmp (line, "now\n") == 0)
      {
        int64_t monotonic, wall;
        int err = read_clock (CLOCK_MONOTONIC, &monotonic);
        if (!err)
          err = read_clock (CLOCK_REALTIME, &wall);
        if (err)
          printf ("# now: clock_gettime: %s\n", strerror (err));
        else
          printf ("# now %lld %lld\n", (long long) monotonic,
                  (long long) wall);
        fflush (stdout);
      }
  __atomic_store_n (&stop, 1, __ATOMIC_RELAXED);
  for (int i = 0; i < threads; i++)
    pthread_join (readers[i].thread, NULL);

  int ran_ok = 1, back_ok = 1;
  for (int i = 0; i < threads; i++)
    {
      struct reader *r = &readers[i];
      fprintf (stderr, "# thread %d (%s): %lld readings of each clock over "
               "%lld ms of CLOCK_MONOTONIC, largest step %lld ms\n",
               r->number, r->sleeps ? "sleeping" : "busy", r->readings,
               (long long) ((r->last_monotonic - r->first_monotonic)
                            / 1000000),
               (long long) (r->largest_step / 1000000));
      if (r->error)
        fprintf (stderr, "# thread %d: clock_gettime: %s\n", r->number,
                 strerror (r->error));
      if (r->steps_back)
        fprintf (stderr, "# thread %d: CLOCK_MONOTONIC went back %lld times, "
                 "at most %lld ns\n", r->number, r->steps_back,
                 (long long) r->largest_step_back);
      if (r->error || r->readings == 0
          || r->last_monotonic <= r->first_monotonic)
        ran_ok = 0;
      if (r->error || r->steps_back)
        back_ok = 0;
    }
  printf ("1..2\n");
  report (ran_ok, "every thread read both clocks until the end, and "
          "CLOCK_MONOTONIC advanced in each");
  report (back_ok, "CLOCK_MONOTONIC never went back in a thread");
  return !(ran_ok && back_ok);
}
