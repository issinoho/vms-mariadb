/*
  vms_lp64.h - 64-bit 'long' in the C RTL interfaces, for clang on OpenVMS.

  VSI C++'s clang on x86-64 is LP64: long is 64 bits.  The VSI C RTL is not:
  it implements every 'long' interface as 32-bit (under __clang__ its
  <stdlib.h> even declares 'unsigned int strtoul()').  So strtol(), strtoul(),
  atol(), labs(), ftell() and fseek() truncate, printf("%ld"), "%lu", "%zu",
  "%td" print only the low 32 bits, "%p" only half a pointer, and
  scanf("%ld") stores 32 bits (vms-mariadb docs/DECISIONS.md D12).
  Limitation: formats with positional arguments ("%2$ld") are passed on
  unchanged (see vms_lp64_fmt()).

  This header is force-included into every compile (clang -include, from
  vms/config/clang_common.rsp).  It includes the C RTL's <stdio.h>,
  <stdlib.h> and <limits.h> first, then:
    - maps strtol/strtoul/atol/labs to strtoll/strtoull/atoll/llabs and
      ftell/fseek to ftello/fseeko;
    - wraps the printf and scanf families: the format is rewritten so that
      the 'l', 'z' and 't' length modifiers of integer conversions become
      'll' (and "%p" becomes "%#llx"), then the C RTL function is called;
    - defines LONG_MAX, LONG_MIN and ULONG_MAX for a 64-bit long.
  Values passed as 'long' already occupy 8-byte argument slots, so only the
  conversions change.  Code compiled into shareable images we do not build
  (libc++'s LIBCXX, for one) is not affected.
*/
#ifndef VMS_LP64_H
#define VMS_LP64_H

#if defined(__VMS) && defined(__clang__) && defined(__LP64__)

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <limits.h>
#include <sys/types.h>

#undef LONG_MAX
#undef LONG_MIN
#undef ULONG_MAX
#define LONG_MAX __LONG_MAX__
#define LONG_MIN (-__LONG_MAX__ - 1L)
#define ULONG_MAX (__LONG_MAX__ * 2UL + 1UL)
/* VSI's ULLONG_MAX is 18446744073709551615u, an unsigned long under LP64,
   which makes overloads on long long / unsigned long long ambiguous. */
#undef LLONG_MAX
#undef LLONG_MIN
#undef ULLONG_MAX
#define LLONG_MAX __LONG_LONG_MAX__
#define LLONG_MIN (-__LONG_LONG_MAX__ - 1LL)
#define ULLONG_MAX (__LONG_LONG_MAX__ * 2ULL + 1ULL)

#ifdef __cplusplus
extern "C" {
#endif

/*
  Rewrite a printf (scanf= 0) or scanf (scanf= 1) format for the C RTL.
  Returns fmt itself when nothing needs changing, else 'buf' (size 'size'),
  or a malloc()ed copy that the caller frees (*heap set) when buf is short.
*/
static inline const char *vms_lp64_fmt(const char *fmt, char *buf, size_t size,
                                       int scanf, char **heap)
{
  const char *p;
  char *out, *o;
  size_t need;
  int change= 0;

  *heap= NULL;
  /*
    Positional formats ("%2$ld") are left alone: the C RTL rejects "ll" and
    "j" together with a position (snprintf returns -1), so such formats keep
    the 32-bit limitation instead of failing.  MariaDB's own positional
    messages go through my_snprintf(), which does not have it.
  */
  if (!fmt || strchr(fmt, '$'))
    return fmt;
  for (p= fmt; *p; p++)
    if (*p == '%' && (strpbrk(p + 1, "lztp") != NULL))
    {
      change= 1;
      break;
    }
  if (!change)
    return fmt;
  need= strlen(fmt) * 2 + 8;     /* each conversion grows by at most 4 */
  if (need <= size)
    out= buf;
  else if (!(out= *heap= (char *) malloc(need)))
    return fmt;
  for (p= fmt, o= out; *p; )
  {
    if (*p != '%')
    {
      *o++= *p++;
      continue;
    }
    *o++= *p++;
    if (*p == '%')
    {
      *o++= *p++;
      continue;
    }
    /* flags, field width, precision, scanf's '*' and digits$ */
    while (*p && strchr("-+ #0'*$.123456789", *p))
      *o++= *p++;
    if (*p == 'l' && p[1] == 'l')
    {
      *o++= *p++;
      *o++= *p++;
    }
    else if ((*p == 'l' || *p == 'z' || *p == 't') && p[1] &&
             strchr("diouxXn", p[1]))
    {
      *o++= 'l';
      *o++= 'l';
      p++;
    }
    else if (!scanf && *p == 'p')
    {
      /* "%p" prints 32 bits of the pointer in the C RTL */
      *o++= '#';
      *o++= 'l';
      *o++= 'l';
      *o++= 'x';
      p++;
      continue;
    }
    else if (scanf && *p == '[')
    {
      /* a scanset: copy it whole ("[]...]" and "[^]...]" included) */
      *o++= *p++;
      if (*p == '^')
        *o++= *p++;
      if (*p == ']')
        *o++= *p++;
      while (*p && *p != ']')
        *o++= *p++;
      if (*p)
        *o++= *p++;
      continue;
    }
    if (*p)
      *o++= *p++;                 /* length letter or conversion */
  }
  *o= 0;
  return out;
}

#define VMS_LP64_FMT_BUF 512
#define VMS_LP64_BEGIN(fmt, scan)                                        \
  char vms_lp64_buf[VMS_LP64_FMT_BUF];                                   \
  char *vms_lp64_heap;                                                   \
  const char *vms_lp64_f= vms_lp64_fmt((fmt), vms_lp64_buf,              \
                                       sizeof vms_lp64_buf, (scan),      \
                                       &vms_lp64_heap)
#define VMS_LP64_END free(vms_lp64_heap)

static inline int vms_lp64_vfprintf(FILE *f, const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 0); r= vfprintf(f, vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_vprintf(const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 0); r= vprintf(vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_vsprintf(char *s, const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 0); r= vsprintf(s, vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_vsnprintf(char *s, size_t n, const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 0); r= vsnprintf(s, n, vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_fprintf(FILE *f, const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vfprintf(f, fmt, ap); va_end(ap); return r; }
static inline int vms_lp64_printf(const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vprintf(fmt, ap); va_end(ap); return r; }
static inline int vms_lp64_sprintf(char *s, const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vsprintf(s, fmt, ap); va_end(ap); return r; }
static inline int vms_lp64_snprintf(char *s, size_t n, const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vsnprintf(s, n, fmt, ap); va_end(ap); return r; }

static inline int vms_lp64_vfscanf(FILE *f, const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 1); r= vfscanf(f, vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_vscanf(const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 1); r= vscanf(vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_vsscanf(const char *s, const char *fmt, va_list ap)
{ int r; VMS_LP64_BEGIN(fmt, 1); r= vsscanf(s, vms_lp64_f, ap); VMS_LP64_END; return r; }
static inline int vms_lp64_fscanf(FILE *f, const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vfscanf(f, fmt, ap); va_end(ap); return r; }
static inline int vms_lp64_scanf(const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vscanf(fmt, ap); va_end(ap); return r; }
static inline int vms_lp64_sscanf(const char *s, const char *fmt, ...)
{ int r; va_list ap; va_start(ap, fmt); r= vms_lp64_vsscanf(s, fmt, ap); va_end(ap); return r; }

static inline long vms_lp64_ftell(FILE *f) { return (long) ftello(f); }
static inline int vms_lp64_fseek(FILE *f, long off, int whence)
{ return fseeko(f, (off_t) off, whence); }

#ifdef __cplusplus
}
#endif

/*
  Object-like macros, so that every use of the name is renamed the same way:
  MariaDB's charset handler has a member called snprintf, and a function-like
  macro would rename the calls (cs->cset->snprintf(...)) but not the member.
*/
#define printf    vms_lp64_printf
#define fprintf   vms_lp64_fprintf
#define sprintf   vms_lp64_sprintf
#define snprintf  vms_lp64_snprintf
#define vprintf   vms_lp64_vprintf
#define vfprintf  vms_lp64_vfprintf
#define vsprintf  vms_lp64_vsprintf
#define vsnprintf vms_lp64_vsnprintf
#define scanf     vms_lp64_scanf
#define fscanf    vms_lp64_fscanf
#define sscanf    vms_lp64_sscanf
#define vscanf    vms_lp64_vscanf
#define vfscanf   vms_lp64_vfscanf
#define vsscanf   vms_lp64_vsscanf
#define strtol    strtoll
#define strtoul   strtoull
#define atol      atoll
#define labs      llabs
#define ftell     vms_lp64_ftell
#define fseek     vms_lp64_fseek

#ifdef __cplusplus
/* std::printf(...) and friends after <cstdio>/<cstdlib> */
namespace std {
  using ::vms_lp64_printf; using ::vms_lp64_fprintf; using ::vms_lp64_sprintf;
  using ::vms_lp64_snprintf; using ::vms_lp64_vprintf; using ::vms_lp64_vfprintf;
  using ::vms_lp64_vsprintf; using ::vms_lp64_vsnprintf; using ::vms_lp64_scanf;
  using ::vms_lp64_fscanf; using ::vms_lp64_sscanf; using ::vms_lp64_vscanf;
  using ::vms_lp64_vfscanf; using ::vms_lp64_vsscanf; using ::vms_lp64_ftell;
  using ::vms_lp64_fseek;
}
#endif

#endif /* __VMS && __clang__ && __LP64__ */
#endif /* VMS_LP64_H */
