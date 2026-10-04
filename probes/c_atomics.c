/* C atomics and builtins used by include/my_atomic.h and friends, plus type
   sizes for the compiler/qualifier combination it is built with. */
#include <stdio.h>
#include <stddef.h>
#include <sys/types.h>

int main(void)
{
  long long v = 0, exp = 0;
  int i = 0;
  printf("sizeof void* %u long %u size_t %u off_t %u time_t %u\n",
         (unsigned) sizeof(void *), (unsigned) sizeof(long),
         (unsigned) sizeof(size_t), (unsigned) sizeof(off_t), (unsigned) sizeof(time_t));
#ifdef __STDC_VERSION__
  printf("__STDC_VERSION__ %ld\n", (long) __STDC_VERSION__);
#endif
#if defined(__clang__) || defined(__GNUC__)
  __atomic_add_fetch(&v, 5, __ATOMIC_SEQ_CST);
  exp = 5;
  i = __atomic_compare_exchange_n(&v, &exp, 7, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  __sync_fetch_and_add(&v, 1);
  printf("__atomic/__sync builtins: %s\n", (i && v == 8) ? "ok" : "FAIL");
  printf("__atomic_always_lock_free(8) %d\n", (int) __atomic_always_lock_free(8, 0));
#else
  printf("__atomic/__sync builtins: not a GNU-compatible compiler\n");
#endif
  printf("C_ATOMICS DONE\n");
  return 0;
}
