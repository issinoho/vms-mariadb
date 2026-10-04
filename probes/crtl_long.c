/* crtl_long.c - do the C RTL's functions that take or return 'long' give
   64-bit results to clang (LP64) code?  (vms-pcre2 test 2 under clang.) */
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int main(void)
{
  char *end;
  unsigned long ul;
  long l;
  FILE *f;
  printf("LONG sizeof(long) %u ULONG_MAX %lu LONG_MAX %ld\n", (unsigned) sizeof(long), ULONG_MAX, LONG_MAX);
  errno = 0; ul = strtoul("11000000000", &end, 10);
  printf("LONG strtoul(11000000000) = %lu errno=%d %s\n", ul, errno, ul == 11000000000UL ? "ok" : "WRONG");
  errno = 0; l = strtol("-11000000000", &end, 10);
  printf("LONG strtol(-11000000000) = %ld errno=%d %s\n", l, errno, l == -11000000000L ? "ok" : "WRONG");
  errno = 0; l = strtol("-5", &end, 10);
  printf("LONG strtol(-5) = %ld %s\n", l, l == -5 ? "ok" : "WRONG");
  l = atol("9000000000");
  printf("LONG atol(9000000000) = %ld %s\n", l, l == 9000000000L ? "ok" : "WRONG");
  l = labs(-9000000000L);
  printf("LONG labs(-9000000000) = %ld %s\n", l, l == 9000000000L ? "ok" : "WRONG");
  { ldiv_t d = ldiv(9000000000L, 7L);
    printf("LONG ldiv(9000000000,7) = %ld r %ld %s\n", d.quot, d.rem, d.quot == 1285714285L && d.rem == 5 ? "ok" : "WRONG"); }
  { char b[64]; snprintf(b, sizeof b, "%ld %lu %lx", -9000000000L, 18000000000UL, 0x123456789aUL);
    printf("LONG printf %%ld/%%lu/%%lx: %s %s\n", b, strcmp(b, "-9000000000 18000000000 123456789a") ? "WRONG" : "ok"); }
  { long a; unsigned long b; sscanf("-9000000000 18000000000", "%ld %lu", &a, &b);
    printf("LONG sscanf %%ld/%%lu: %ld %lu %s\n", a, b, a == -9000000000L && b == 18000000000UL ? "ok" : "WRONG"); }
  f = fopen("crtl_long.tmp", "w+");
  fseek(f, 5000000000L, SEEK_SET);
  printf("LONG fseek(5e9)/ftell = %ld %s\n", ftell(f), ftell(f) == 5000000000L ? "ok" : "WRONG (32-bit ftell; use ftello)");
  fclose(f); remove("crtl_long.tmp");
  printf("LONG clock() type size %u, CLOCKS_PER_SEC %ld\n", (unsigned) sizeof(clock_t), (long) CLOCKS_PER_SEC);
  return 0;
}
