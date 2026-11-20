/* Guest-side probe for the filesystem tests, built static for GNU/Hurd.

     fs_probe hello          print "fs-probe-exec-ok" (the binary the
                             tests copy into an image and exec from it)
     fs_probe readdir1 DIR   list DIR with dir_readdir, one entry per RPC
     fs_probe seekdir N DIR  list DIR with readdir, reopening the stream
                             and seekdir()ing back every N entries
     fs_probe xattrs ROOT PATH...
                             print each xattr of ROOT/PATH (not following
                             symlinks) as  PATH<TAB>NAME<TAB>HEX-VALUE,
                             or  PATH<TAB>!<TAB>ERROR  when listing fails

   Each listing prints one name per line, in the order the translator
   returned them, so the caller can check that every entry comes once.  */

#define _GNU_SOURCE
#include <dirent.h>
#include <error.h>
#include <errno.h>
#include <fcntl.h>
#include <hurd.h>
#include <hurd/fs.h>
#include <mach.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>

static int
readdir1 (const char *dir)
{
  file_t port = file_name_lookup (dir, O_READ, 0);
  if (port == MACH_PORT_NULL)
    error (1, errno, "%s", dir);
  int entry = 0;
  for (;;)
    {
      char local[2048];
      data_t data = local;
      mach_msg_type_number_t cnt = sizeof local;
      int amount = 0;
      error_t err = dir_readdir (port, &data, &cnt, entry, 1, 0, &amount);
      if (err)
        error (1, err, "dir_readdir %s entry %d", dir, entry);
      if (amount == 0)
        break;
      if (amount != 1)
        error (1, 0, "dir_readdir %s entry %d: asked for 1 entry, got %d",
               dir, entry, amount);
      struct dirent *d = (struct dirent *) data;
      if (cnt < offsetof (struct dirent, d_name) + 1 || d->d_reclen > cnt
          || d->d_namlen >= d->d_reclen)
        error (1, 0, "dir_readdir %s entry %d: malformed record", dir, entry);
      printf ("%.*s\n", (int) d->d_namlen, d->d_name);
      if (data != local)
        vm_deallocate (mach_task_self (), (vm_address_t) data, cnt);
      entry += amount;
    }
  return 0;
}

static int
seekdir_walk (const char *dir, int every)
{
  long pos = 0;
  for (;;)
    {
      DIR *d = opendir (dir);
      if (!d)
        error (1, errno, "%s", dir);
      seekdir (d, pos);
      struct dirent *e = NULL;
      for (int i = 0; i < every && (errno = 0, e = readdir (d)); i++)
        puts (e->d_name);
      if (!e && errno)
        error (1, errno, "readdir %s", dir);
      pos = telldir (d);
      closedir (d);
      if (!e)
        return 0;
    }
}

static int
xattrs (const char *root, char **paths, int n)
{
  for (int i = 0; i < n; i++)
    {
      char path[4096];
      snprintf (path, sizeof path, "%s/%s", root, paths[i]);
      static char names[65536];
      ssize_t len = llistxattr (path, names, sizeof names);
      if (len < 0)
        {
          printf ("%s\t!\t%s\n", paths[i], strerror (errno));
          continue;
        }
      for (char *name = names; name < names + len; name += strlen (name) + 1)
        {
          static unsigned char value[65536];
          ssize_t vlen = lgetxattr (path, name, value, sizeof value);
          if (vlen < 0)
            {
              printf ("%s\t%s\t!%s\n", paths[i], name, strerror (errno));
              continue;
            }
          printf ("%s\t%s\t", paths[i], name);
          for (ssize_t k = 0; k < vlen; k++)
            printf ("%02x", value[k]);
          putchar ('\n');
        }
    }
  return 0;
}

int
main (int argc, char **argv)
{
  if (argc == 2 && !strcmp (argv[1], "hello"))
    return puts ("fs-probe-exec-ok") < 0;
  if (argc == 3 && !strcmp (argv[1], "readdir1"))
    return readdir1 (argv[2]);
  if (argc == 4 && !strcmp (argv[1], "seekdir"))
    return seekdir_walk (argv[3], atoi (argv[2]));
  if (argc >= 4 && !strcmp (argv[1], "xattrs"))
    return xattrs (argv[2], argv + 3, argc - 3);
  fprintf (stderr, "usage: fs_probe hello | readdir1 DIR | seekdir N DIR"
           " | xattrs ROOT PATH...\n");
  return 2;
}
