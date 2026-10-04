// C++11/14 language and library features MariaDB 10.6-11.4 relies on.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <functional>
#include <algorithm>
#include <unordered_map>
#if __cplusplus >= 201402L
#include <shared_mutex>
#endif

#ifdef NO_TLS
static int tls_counter = 0;
#else
static thread_local int tls_counter = 0;
#endif
static std::atomic<uint64_t> a64{0};
static std::atomic<uint32_t> a32{0};
static std::mutex m;
static std::condition_variable cv;
static int ready = 0;

int main()
{
  std::printf("__cplusplus %ld\n", (long) __cplusplus);
  std::printf("sizeof void* %u long %u size_t %u long long %u\n",
              (unsigned) sizeof(void *), (unsigned) sizeof(long),
              (unsigned) sizeof(size_t), (unsigned) sizeof(long long));
  std::printf("atomic<uint64_t> lock_free %d\n", (int) a64.is_lock_free());

  std::vector<std::thread> ts;
  for (int i = 0; i < 8; i++)
    ts.emplace_back([i] {
      for (int j = 0; j < 100000; j++) { a64.fetch_add(1); a32++; tls_counter++; }
      std::lock_guard<std::mutex> g(m);
      ready++;
      cv.notify_all();
    });
  {
    std::unique_lock<std::mutex> lk(m);
    bool ok = cv.wait_for(lk, std::chrono::seconds(30), [] { return ready == 8; });
    std::printf("condvar wait_for %s\n", ok ? "ok" : "TIMEOUT");
  }
  for (auto &t : ts) t.join();
  std::printf("atomics %s (%llu)\n", a64 == 800000 && a32 == 800000 ? "ok" : "FAIL",
              (unsigned long long) a64.load());
  std::printf("thread_local main %d (expect 0)\n", tls_counter);

  uint64_t expected = 800000;
  bool cas = a64.compare_exchange_strong(expected, 1);
  std::printf("cas %s\n", cas && a64 == 1 ? "ok" : "FAIL");

  auto t0 = std::chrono::steady_clock::now();
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - t0).count();
  std::printf("sleep_for 50ms took %ldms\n", (long) ms);
  std::printf("hardware_concurrency %u\n", std::thread::hardware_concurrency());

  std::unique_ptr<int[]> p(new int[4]);
  std::unordered_map<int, std::function<int(int)>> fm;
  fm[1] = [](int x) { return x * 2; };
#if __cplusplus >= 201402L
  std::shared_timed_mutex sm;
  { std::shared_lock<std::shared_timed_mutex> sl(sm); }
  auto up = std::make_unique<int>(3);
  std::printf("c++14 library ok %d\n", *up + fm[1](1) - 5);
#endif
  std::printf("CXX_THREADS DONE\n");
  return 0;
}
