/* lp64_test.c - tests for vms/include/vms_lp64.h (D12); compiled as C and
   as C++ with "-include vms/include/vms_lp64.h" by run_lp64_test.com. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stddef.h>
#ifdef __cplusplus
#include <cstdio>
#include <cstdlib>
#define STD std::
#else
#define STD
#endif

static int passed, failed;
static void t(const char *what, const char *got, const char *want)
{
  int ok= strcmp(got, want) == 0;
  STD printf("LP64 %-30s %-28s %s\n", what, got, ok ? "PASS" : "FAIL");
  if (ok) passed++; else failed++;
}

int main(void)
{
  char b[128];
  long l= -9000000000L; unsigned long ul= 18000000000UL;
  size_t z= 18000000000UL; ptrdiff_t d= -9000000000L;
  snprintf(b, sizeof b, "%ld", l); t("%ld", b, "-9000000000");
  STD snprintf(b, sizeof b, "%lu|%lx", ul, ul); t("std:: %lu|%lx", b, "18000000000|430e23400");
  sprintf(b, "%zu %zd %td", z, (ptrdiff_t) z, d); t("%zu %zd %td", b, "18000000000 18000000000 -9000000000");
  snprintf(b, sizeof b, "%5.2f %s %c %d %%", 3.14159, "x", 'y', 7); t("other conversions", b, " 3.14 x y 7 %");
  snprintf(b, sizeof b, "%-12ld|", 5L); t("%-12ld", b, "5           |");
  /* positional formats are passed on unchanged: small values only */
  snprintf(b, sizeof b, "%2$ld %1$ld", 1L, 5L); t("positional %2$ld (unchanged)", b, "5 1");
  snprintf(b, sizeof b, "%p", (void *) 0x123456789aUL); t("%p", b, "0x123456789a");
  snprintf(b, sizeof b, "%lld %llu", -9000000000LL, 18000000000ULL); t("%lld %llu untouched", b, "-9000000000 18000000000");
  { long a= 0; unsigned long c= 0; size_t s= 0; char w[16];
    sscanf("-9000000000 18000000000 18000000000 abc]", "%ld %lu %zu %[^]]", &a, &c, &s, w);
    snprintf(b, sizeof b, "%ld %lu %zu %s", a, c, s, w);
    t("sscanf %ld %lu %zu %[^]]", b, "-9000000000 18000000000 18000000000 abc"); }
  snprintf(b, sizeof b, "%lu", STD strtoul("11000000000", NULL, 10)); t("strtoul(11000000000)", b, "11000000000");
  snprintf(b, sizeof b, "%ld", strtol("-11000000000", NULL, 10)); t("strtol(-11000000000)", b, "-11000000000");
  snprintf(b, sizeof b, "%ld %ld", atol("9000000000"), labs(-9000000000L)); t("atol, labs", b, "9000000000 9000000000");
  snprintf(b, sizeof b, "%ld %lu", LONG_MAX, ULONG_MAX); t("LONG_MAX ULONG_MAX", b, "9223372036854775807 18446744073709551615");
  /*
    fseek/ftell go through fseeko/ftello.  Only a small offset here: ODS-5
    has no sparse files, and seeking a new file to 5 GB allocated (and
    zero-filled) 5 GB of disk.
  */
  { FILE *f= fopen("lp64_test.tmp", "w+");
    fputs("0123456789", f);
    fseek(f, 4L, SEEK_SET);
    snprintf(b, sizeof b, "%ld %c", ftell(f), getc(f)); t("fseek/ftell via *o", b, "4 4");
    fclose(f); remove("lp64_test.tmp"); }
  printf("LP64_TEST %s: %d passed, %d failed\n",
#ifdef __cplusplus
         "C++",
#else
         "C",
#endif
         passed, failed);
  return failed != 0;
}
