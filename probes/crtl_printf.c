/* crtl_printf.c - which printf/scanf length modifiers handle 64-bit values
   for clang (LP64) code on OpenVMS x86-64? */
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <stddef.h>

static void t(const char *what, const char *got, const char *want)
{
  printf("FMT %-22s %-24s %s\n", what, got, strcmp(got, want) ? "WRONG" : "ok");
}

int main(void)
{
  char b[80];
  long long ll = -9000000000LL; unsigned long long ull = 18000000000ULL;
  size_t z = 18000000000UL; ptrdiff_t pd = -9000000000L; intmax_t im = -9000000000LL;
  snprintf(b, sizeof b, "%lld", ll); t("%lld", b, "-9000000000");
  snprintf(b, sizeof b, "%llu", ull); t("%llu", b, "18000000000");
  snprintf(b, sizeof b, "%llx", ull); t("%llx", b, "430e23400");
  snprintf(b, sizeof b, "%zu", z); t("%zu", b, "18000000000");
  snprintf(b, sizeof b, "%zd", (ptrdiff_t) -9000000000L); t("%zd", b, "-9000000000");
  snprintf(b, sizeof b, "%td", pd); t("%td", b, "-9000000000");
  snprintf(b, sizeof b, "%jd", im); t("%jd", b, "-9000000000");
  snprintf(b, sizeof b, "%" PRId64, (int64_t) ll); t("PRId64 (" PRId64 ")", b, "-9000000000");
  snprintf(b, sizeof b, "%" PRIu64, (uint64_t) ull); t("PRIu64 (" PRIu64 ")", b, "18000000000");
  snprintf(b, sizeof b, "%p", (void *) 0x123456789aULL); printf("FMT %%p                    %s\n", b);
  snprintf(b, sizeof b, "%ld|%d", 5L, 7); t("%ld then %d", b, "5|7");
  snprintf(b, sizeof b, "%ld|%d", -9000000000L, 7); t("%ld (big) then %d", b, "-9000000000|7");
  { long long a = 0; unsigned long long c = 0; size_t s = 0;
    sscanf("-9000000000 18000000000 18000000000", "%lld %llu %zu", &a, &c, &s);
    snprintf(b, sizeof b, "%lld %llu %llu", a, c, (unsigned long long) s);
    t("sscanf %lld %llu %zu", b, "-9000000000 18000000000 18000000000"); }
  return 0;
}
