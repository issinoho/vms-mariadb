/* format_attr_test.c - BUILD.COM compiles this with the build's own clang
   flags (clang_common.rsp, so vms_lp64.h defines printf as vms_lp64_printf)
   and -Werror=ignored-attributes -Werror=format before MMS.  Without patch
   0029 (my_attribute.h), ATTRIBUTE_FORMAT(printf, ...) reaches clang as
   format(vms_lp64_printf, ...), which it ignores with a warning and no format
   checking.  With -DFORMAT_ATTR_BAD the compile must fail on the bad calls,
   which shows the checking is live. */
#include <stdio.h>
#include <my_attribute.h>

int my_fmt(const char *fmt, ...) ATTRIBUTE_FORMAT(printf, 1, 2);
struct handler
{
  int (*fmt)(void *cs, const char *fmt, ...) ATTRIBUTE_FORMAT_FPTR(printf, 2, 3);
};

int use(struct handler *h)
{
#ifdef FORMAT_ATTR_BAD
  return my_fmt("%d", "x") + h->fmt(0, "%s", 1);
#else
  return my_fmt("%d", 1) + h->fmt(0, "%s", "x");
#endif
}
