/* <stdatomic.h> and C11 keywords. */
#include <stdatomic.h>
#include <stdio.h>

static _Atomic long long counter;
_Static_assert(sizeof(long long) == 8, "long long is 64-bit");

int main(void)
{
  atomic_fetch_add(&counter, 3);
  printf("stdatomic %s\n", atomic_load(&counter) == 3 ? "ok" : "FAIL");
  printf("C11_STDATOMIC DONE\n");
  return 0;
}
