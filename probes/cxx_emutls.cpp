// Does -femulated-tls get thread_local past VSI C++'s check? If it compiles,
// the link shows which runtime entry (__emutls_get_address) it needs.
#include <cstdio>
static thread_local int tls_counter = 7;
int main()
{
  std::printf("emutls %d\n", tls_counter);
  return 0;
}
