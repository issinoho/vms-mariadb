// C++17 features needed by MariaDB 11.8 and later (CMAKE_CXX_STANDARD 17).
#include <variant>  /* first: STARLET BREAKDEF defines __union, which breaks <variant> */
#include <charconv>
#include <cstdio>
#include <optional>
#include <shared_mutex>
#include <string_view>
#include <variant>
#include <tuple>
#include <mutex>

struct S { static inline int counter = 1; };

template <typename T> int kind(T) {
  if constexpr (sizeof(T) == 8) return 8; else return 0;
}

int main()
{
  std::optional<int> o = 5;
  std::string_view sv = "hello";
  std::variant<int, double> v = 2.5;
  auto [a, b] = std::make_tuple(1, 2);
  std::shared_mutex sm;
  { std::shared_lock<std::shared_mutex> l(sm); }
  { std::scoped_lock l(sm); }
  char buf[32];
  auto r = std::to_chars(buf, buf + sizeof buf, 12345);
  *r.ptr = 0;
  int parsed = 0;
  std::from_chars(buf, r.ptr, parsed);
  std::printf("__cplusplus %ld opt %d sv %u var %g sb %d inl %d ifc %d chars %s/%d\n",
              (long) __cplusplus, *o, (unsigned) sv.size(), std::get<double>(v), a + b,
              S::counter, kind(1.0), buf, parsed);
  std::printf("CXX17 DONE\n");
  return 0;
}
