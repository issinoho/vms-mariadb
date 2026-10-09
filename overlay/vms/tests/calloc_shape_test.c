/* calloc_shape_test.c - BUILD.COM compiles this with the build's own clang
   flags (vms/build/<config>/vms_crtl_init.rsp, i.e. clang_common.rsp), as C
   and as C++, and runs it before MMS.  VSI clang lowers memset() and bzero()
   to OTS$FILL but assumes the call returns its destination, so the
   "allocate, clear if not NULL, return the pointer" shape of THD::calloc,
   ma_calloc_root and new_ma_field_extension can return some other block
   (vms-php PORTING_LOG #17; docs/PORTING_LOG.md).  clang_common.rsp's
   -fno-builtin-memset -fno-builtin-bzero avoid it; this fails the build if
   they are lost or stop working.  Prints "CALLOC_SHAPE: PASS" or "...: FAIL". */
#include <stdio.h>
#include <string.h>
#include <strings.h>

static char arena[4096];
static size_t used;

__attribute__((noinline)) void *alloc_root(size_t len)
{
  void *p = arena + used;
  used += (len + 15) & ~(size_t) 15;
  return p;
}

__attribute__((noinline)) void *calloc_root_memset(size_t len)
{
  void *p;
  if ((p = alloc_root(len)))
    memset(p, 0, len);
  return p;
}

__attribute__((noinline)) void *calloc_root_bzero(size_t len)
{
  void *p;
  if ((p = alloc_root(len)))
    bzero(p, len);
  return p;
}

int main(void)
{
  void *a = calloc_root_memset(40), *b = calloc_root_bzero(40);
  int ok = a == (void *) arena && b == (void *) (arena + 48);
  if (!ok)
    printf("CALLOC_SHAPE: memset gave %p (want %p), bzero gave %p (want %p)\n",
           a, (void *) arena, b, (void *) (arena + 48));
  printf("CALLOC_SHAPE: %s\n", ok ? "PASS" : "FAIL");
  return 0;
}
