/* Minimal libuuid implementation for the cross toolchain.
   See uuid/uuid.h for why this exists.  The generated UUIDs are version 4
   (random) as util-linux does, because libparted uses them for GPT disk
   and partition GUIDs and for filesystem volume identifiers.  */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <uuid/uuid.h>

/* Fill BUF with LEN random bytes.  The kernel random device is the
   preferred source; a time-seeded generator keeps the function usable on
   a system without /dev/urandom.  */
static void
get_random_bytes (void *buf, size_t len)
{
  unsigned char *out = buf;
  size_t got = 0;
  int fd;

  fd = open ("/dev/urandom", O_RDONLY);
  if (fd >= 0)
    {
      while (got < len)
	{
	  ssize_t n = read (fd, out + got, len - got);
	  if (n <= 0)
	    break;
	  got += (size_t) n;
	}
      close (fd);
    }

  if (got < len)
    {
      /* Fallback: a small xorshift generator seeded from the clock.  The
	 result only has to be unique, not cryptographically strong.  */
      static unsigned long long state;
      size_t i;

      if (state == 0)
	state = (unsigned long long) time (NULL) ^ ((unsigned long long) getpid () << 16);
      for (i = got; i < len; i++)
	{
	  state ^= state << 13;
	  state ^= state >> 7;
	  state ^= state << 17;
	  out[i] = (unsigned char) (state >> 24);
	}
    }
}

void
uuid_generate_random (uuid_t out)
{
  get_random_bytes (out, 16);

  /* Version 4 (random) and the RFC 4122 variant bits.  */
  out[6] = (unsigned char) ((out[6] & 0x0f) | 0x40);
  out[8] = (unsigned char) ((out[8] & 0x3f) | 0x80);
}

void
uuid_generate (uuid_t out)
{
  uuid_generate_random (out);
}

void
uuid_clear (uuid_t uu)
{
  memset (uu, 0, 16);
}

int
uuid_is_null (const uuid_t uu)
{
  static const uuid_t null_uuid = { 0 };
  return memcmp (uu, null_uuid, 16) == 0;
}

int
uuid_compare (const uuid_t uu1, const uuid_t uu2)
{
  return memcmp (uu1, uu2, 16);
}

void
uuid_copy (uuid_t dst, const uuid_t src)
{
  memcpy (dst, src, 16);
}

static int
hex_value (int c)
{
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

int
uuid_parse (const char *in, uuid_t uu)
{
  static const int group_len[5] = { 8, 4, 4, 4, 12 };
  unsigned char bytes[16];
  int nbyte = 0;
  int group;

  if (in == NULL || uu == NULL)
    return -1;

  for (group = 0; group < 5; group++)
    {
      int i;

      for (i = 0; i < group_len[group]; i++)
	{
	  int hi = hex_value ((unsigned char) in[0]);
	  int lo;

	  if (hi < 0)
	    return -1;
	  lo = hex_value ((unsigned char) in[1]);
	  if (lo < 0)
	    return -1;
	  bytes[nbyte++] = (unsigned char) ((hi << 4) | lo);
	  in += 2;
	}
      if (group < 4)
	{
	  if (*in != '-')
	    return -1;
	  in++;
	}
    }

  if (*in != '\0')
    return -1;

  memcpy (uu, bytes, 16);
  return 0;
}

static void
uuid_unparse_common (const uuid_t uu, char *out, const char *digits)
{
  static const int dash_after[4] = { 4, 6, 8, 10 };
  int i;
  int pos = 0;
  int group = 0;

  for (i = 0; i < 16; i++)
    {
      if (group < 4 && i == dash_after[group])
	{
	  out[pos++] = '-';
	  group++;
	}
      out[pos++] = digits[uu[i] >> 4];
      out[pos++] = digits[uu[i] & 0x0f];
    }
  out[pos] = '\0';
}

void
uuid_unparse (const uuid_t uu, char *out)
{
  uuid_unparse_common (uu, out, "0123456789ABCDEF");
}

void
uuid_unparse_lower (const uuid_t uu, char *out)
{
  uuid_unparse_common (uu, out, "0123456789abcdef");
}
