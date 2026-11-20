/* The clocks move forward: CLOCK_MONOTONIC never goes back, and
   CLOCK_REALTIME never steps back by more than WALL_TOLERANCE_NS, while
   two threads read both of them as fast as they can (two, so that on
   several processors the reads come from more than one).

   Usage: clock-forward [SECONDS]

   The output is TAP.  It runs on Linux too, which checks the
   expectations themselves.

   On the Hurd, glibc's clock_gettime asks GNU Mach for both clocks
   (sysdeps/mach/clock_gettime.c): CLOCK_MONOTONIC with host_get_uptime64,
   CLOCK_REALTIME with host_get_time; gettimeofday and time read
   CLOCK_REALTIME.  GNU Mach answers with the time of the last clock tick
   plus what its high precision clock measured since that tick
   (time_value64_add_hpc in kern/mach_clock.c).

   Under KVM, a GNU Mach whose kvmclock keeps only 64 bits of the product
   in kvmclock_scale reads the high precision clock up to 2^32 ns (about
   4.3 seconds) behind the reading of the last tick, again every 2^32 ns
   once the host has stopped rewriting its time struct.  The first clock
   read after such a step stops the kernel in its debugger
   (time_value64_add_hpc: Assertion `0 <= (value)->nanoseconds &&
   (value)->nanoseconds < TIME_NANOS_MAX' failed), so on that kernel this
   test does not report: the guest stops while it runs.  The default
   duration spans many of those 2^32 ns periods, so that the step does
   not have to fall into a short run by luck.  */

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define THREADS 2
#define DEFAULT_SECONDS 60
/* How far CLOCK_REALTIME may step back between two readings, since it
   may be set while the test runs.  This is far below the 2^32 ns of the
   kvmclock step, and well above one tick of GNU Mach's clock, the most
   that its interpolation between two ticks adds.  */
#define WALL_TOLERANCE_NS 100000000LL
/* The run fails when it has not ended this long after its duration.  */
#define GRACE_SECONDS 60

struct reader
{
  pthread_t thread;
  int number;
  long long readings;
  int64_t first_monotonic, last_monotonic, first_wall, last_wall;
  long long monotonic_steps_back;
  int64_t monotonic_largest_step_back;
  long long wall_steps_back;
  int64_t wall_largest_step_back;
  int error;
};

static int64_t end_ns;
static int test_number;
static int failures;

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

/* Read CLOCK_MONOTONIC and CLOCK_REALTIME in turn until CLOCK_MONOTONIC
   reaches end_ns, and note every step back.  */
static void *
read_clocks (void *argument)
{
  struct reader *r = argument;
  int64_t monotonic, wall, previous_monotonic, previous_wall;

  if ((r->error = read_clock (CLOCK_MONOTONIC, &previous_monotonic))
      || (r->error = read_clock (CLOCK_REALTIME, &previous_wall)))
    return NULL;
  r->first_monotonic = r->last_monotonic = previous_monotonic;
  r->first_wall = r->last_wall = previous_wall;
  do
    {
      if ((r->error = read_clock (CLOCK_MONOTONIC, &monotonic))
          || (r->error = read_clock (CLOCK_REALTIME, &wall)))
        return NULL;
      r->readings++;
      if (monotonic < previous_monotonic)
        {
          if (r->monotonic_steps_back++ == 0)
            fprintf (stderr, "# thread %d: CLOCK_MONOTONIC went from %lld "
                     "to %lld ns\n", r->number, (long long) previous_monotonic,
                     (long long) monotonic);
          if (previous_monotonic - monotonic > r->monotonic_largest_step_back)
            r->monotonic_largest_step_back = previous_monotonic - monotonic;
        }
      if (wall < previous_wall - WALL_TOLERANCE_NS)
        {
          if (r->wall_steps_back++ == 0)
            fprintf (stderr, "# thread %d: CLOCK_REALTIME went from %lld "
                     "to %lld ns\n", r->number, (long long) previous_wall,
                     (long long) wall);
          if (previous_wall - wall > r->wall_largest_step_back)
            r->wall_largest_step_back = previous_wall - wall;
        }
      previous_monotonic = monotonic;
      previous_wall = wall;
    }
  while (monotonic < end_ns);
  r->last_monotonic = monotonic;
  r->last_wall = wall;
  return NULL;
}

static void
report (int ok, const char *description)
{
  test_number++;
  if (!ok)
    failures++;
  printf ("%sok %d - %s\n", ok ? "" : "not ", test_number, description);
  fflush (stdout);
}

static void
timed_out (int signal_number)
{
  static const char message[] = "Bail out! the run did not end in time\n";
  (void) signal_number;
  if (write (STDOUT_FILENO, message, sizeof message - 1) < 0)
    _exit (2);
  _exit (1);
}

int
main (int argc, char **argv)
{
  int seconds = DEFAULT_SECONDS;
  if (argc > 2 || (argc == 2 && (seconds = atoi (argv[1])) < 1))
    {
      fprintf (stderr, "usage: clock-forward [SECONDS]\n");
      return 2;
    }

  int64_t start;
  int err = read_clock (CLOCK_MONOTONIC, &start);
  if (err)
    {
      fprintf (stderr, "clock-forward: CLOCK_MONOTONIC: %s\n",
               strerror (err));
      return 2;
    }
  end_ns = start + (int64_t) seconds * 1000000000;
  printf ("TAP version 13\n1..3\n");
  fflush (stdout);
  signal (SIGALRM, timed_out);
  alarm ((unsigned) seconds + GRACE_SECONDS);

  struct reader readers[THREADS];
  memset (readers, 0, sizeof readers);
  for (int i = 0; i < THREADS; i++)
    {
      readers[i].number = i + 1;
      err = pthread_create (&readers[i].thread, NULL, read_clocks,
                            &readers[i]);
      if (err)
        {
          fprintf (stderr, "clock-forward: pthread_create: %s\n",
                   strerror (err));
          return 2;
        }
    }
  for (int i = 0; i < THREADS; i++)
    pthread_join (readers[i].thread, NULL);
  alarm (0);

  int monotonic_ok = 1, wall_ok = 1, advanced_ok = 1;
  for (int i = 0; i < THREADS; i++)
    {
      struct reader *r = &readers[i];
      int64_t monotonic_span = r->last_monotonic - r->first_monotonic;
      int64_t wall_span = r->last_wall - r->first_wall;
      fprintf (stderr, "# thread %d: %lld readings of each clock over "
               "%lld ms of CLOCK_MONOTONIC and %lld ms of CLOCK_REALTIME\n",
               r->number, r->readings, (long long) (monotonic_span / 1000000),
               (long long) (wall_span / 1000000));
      if (r->error)
        fprintf (stderr, "# thread %d: clock_gettime: %s\n", r->number,
                 strerror (r->error));
      if (r->monotonic_steps_back)
        fprintf (stderr, "# thread %d: CLOCK_MONOTONIC went back %lld "
                 "times, at most %lld ns\n", r->number,
                 r->monotonic_steps_back,
                 (long long) r->monotonic_largest_step_back);
      if (r->wall_steps_back)
        fprintf (stderr, "# thread %d: CLOCK_REALTIME stepped back %lld "
                 "times, at most %lld ns\n", r->number, r->wall_steps_back,
                 (long long) r->wall_largest_step_back);
      if (r->error || r->monotonic_steps_back)
        monotonic_ok = 0;
      if (r->error || r->wall_steps_back)
        wall_ok = 0;
      /* Both clocks advanced, and by about the same: a clock that stood
         still or jumped would show here.  */
      if (r->error || r->readings == 0
          || monotonic_span < (int64_t) seconds * 1000000000 - 1000000000
          || llabs ((long long) (wall_span - monotonic_span))
             > WALL_TOLERANCE_NS)
        advanced_ok = 0;
    }
  report (monotonic_ok, "CLOCK_MONOTONIC never went back in a thread");
  report (wall_ok, "CLOCK_REALTIME never stepped back by more than the "
          "tolerance");
  report (advanced_ok, "each thread read both clocks, and they advanced "
          "alike over the run");
  return failures != 0;
}
