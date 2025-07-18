/* Interfaces for obtaining random bytes.
   Copyright (C) 2016-2025 Free Software Foundation, Inc.
   This file is part of the GNU C Library.

   The GNU C Library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   The GNU C Library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with the GNU C Library; if not, see
   <https://www.gnu.org/licenses/>.  */

#ifndef _SYS_RANDOM_H
#define _SYS_RANDOM_H 1

#include <features.h>
#include <sys/types.h>

/* Flags for use with getrandom.  */
#define GRND_NONBLOCK 0x01
#define GRND_RANDOM 0x02
#define GRND_INSECURE 0x04

__BEGIN_DECLS

// zig patch: getrandom and getentropy were added in glibc 2.25
#if (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 25) || __GLIBC__ > 2

/* Write LENGTH bytes of randomness starting at BUFFER.  Return the
   number of bytes written, or -1 on error.  */
ssize_t getrandom (void *__buffer, size_t __length,
                   unsigned int __flags) __wur
                   __attr_access ((__write_only__, 1, 2));

/* Write LENGTH bytes of randomness starting at BUFFER.  Return 0 on
   success or -1 on error.  */
int getentropy (void *__buffer, size_t __length) __wur
                __attr_access ((__write_only__, 1, 2));

#endif /* glibc 2.25 or later */

__END_DECLS

#endif /* _SYS_RANDOM_H */