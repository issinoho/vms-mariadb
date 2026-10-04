// tls_test.cc - tests for include/my_vms_tls.h (thread_local replacement, D5).
#include <my_vms_tls.h>
#include <cstdio>
#include <string>
#include <vector>
#include <atomic>
#include <pthread.h>

struct Thd { int id; };
static my_thread_local<Thd *> current;            // pointer: kept in the slot
static my_thread_local<long> counter;             // integer: kept in the slot
static std::atomic<int> destroyed{0};
struct Obj { std::vector<int> v; std::string s; ~Obj() { destroyed++; } };
static my_thread_local<Obj> obj;                  // object: one per thread
static int failures;

static void *worker(void *arg)
{
  Thd mine{(int) (intptr_t) arg};
  if (current.get() != nullptr || counter != 0 || !obj->v.empty())
    failures++;                                   // fresh per thread
  current= &mine;
  for (int i= 0; i < 100000; i++)
  {
    counter= counter + 1;
    obj->v.push_back(mine.id);
  }
  Obj &o= obj;
  o.s= "thread " + std::to_string(mine.id);
  if (current->id != mine.id || counter != 100000 || obj->v.size() != 100000 ||
      obj->v[99999] != mine.id || obj->s != o.s)
    failures++;
  return nullptr;
}

int main()
{
  pthread_t t[4];
  for (int i= 0; i < 4; i++)
    pthread_create(&t[i], nullptr, worker, (void *) (intptr_t) (i + 1));
  for (int i= 0; i < 4; i++)
    pthread_join(t[i], nullptr);
  std::printf("TLS isolation: %s\n", failures ? "FAIL" : "PASS");
  std::printf("TLS per-thread objects destroyed: %d of 4 %s\n", destroyed.load(),
              destroyed == 4 ? "PASS" : "FAIL");
  std::printf("TLS main thread untouched: %s\n",
              current.get() == nullptr && counter == 0 ? "PASS" : "FAIL");
  return failures || destroyed != 4;
}
