/* Minimal subset of the util-linux uuid API.
   libparted (3p/parted) requires libuuid at configure and link time, but
   the cross toolchain has no util-linux.  Only the functions libparted
   actually uses are provided here; the layout follows util-linux's
   uuid/uuid.h so that a system uuid/uuid.h can replace this one.  */

#ifndef _UUID_UUID_H
#define _UUID_UUID_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned char uuid_t[16];

/* Length of the string form, including the terminating NUL.  */
#define UUID_STR_LEN 36

void uuid_generate (uuid_t out);
void uuid_generate_random (uuid_t out);
void uuid_clear (uuid_t uu);
int uuid_is_null (const uuid_t uu);
int uuid_compare (const uuid_t uu1, const uuid_t uu2);
void uuid_copy (uuid_t dst, const uuid_t src);
int uuid_parse (const char *in, uuid_t uu);
void uuid_unparse (const uuid_t uu, char *out);
void uuid_unparse_lower (const uuid_t uu, char *out);

#ifdef __cplusplus
}
#endif

#endif /* _UUID_UUID_H */
