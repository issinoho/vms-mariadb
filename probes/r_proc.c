/* r_proc.c - process, thread, signal, memory and dynamic-loading behaviour. */
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/mman.h>

static void say(const char *what, int ok, const char *detail)
{
  printf("PROC %-34s %s %s\n", what, ok ? "yes" : "NO ", detail ? detail : "");
}

static char errbuf[200];
static const char *err(void)
{
  snprintf(errbuf, sizeof errbuf, "errno=%d (%s)", errno, strerror(errno));
  return errbuf;
}

static pthread_key_t key;
static void key_dtor(void *p) { (void) p; }
static void *thr(void *arg)
{
  pthread_setspecific(key, arg);
  return pthread_getspecific(key);
}

static volatile sig_atomic_t got_sig;
static void on_sig(int s) { got_sig = s; }

int main(void)
{
  char d[200];
  int r;

  snprintf(d, sizeof d, "%ld", sysconf(_SC_PAGESIZE));
  say("sysconf(_SC_PAGESIZE)", 1, d);
#ifdef _SC_NPROCESSORS_ONLN
  snprintf(d, sizeof d, "%ld", sysconf(_SC_NPROCESSORS_ONLN));
  say("sysconf(_SC_NPROCESSORS_ONLN)", 1, d);
#else
  say("_SC_NPROCESSORS_ONLN defined", 0, NULL);
#endif
#ifdef RLIMIT_NOFILE
  {
    struct rlimit rl;
    r = getrlimit(RLIMIT_NOFILE, &rl);
    snprintf(d, sizeof d, "cur=%lld max=%lld", (long long) rl.rlim_cur, (long long) rl.rlim_max);
    say("getrlimit(RLIMIT_NOFILE)", r == 0, r ? err() : d);
  }
#else
  say("RLIMIT_NOFILE defined (getrlimit)", 0, NULL);
#endif
  {
    /* Threads with a 1 MB stack, as mysqld sets thread_stack. */
    pthread_t t;
    pthread_attr_t a;
    size_t ss = 0;
    void *ret = NULL;
    pthread_key_create(&key, key_dtor);
    pthread_attr_init(&a);
    r = pthread_attr_setstacksize(&a, 1024 * 1024);
    pthread_attr_getstacksize(&a, &ss);
    snprintf(d, sizeof d, "%lu", (unsigned long) ss);
    say("pthread_attr_setstacksize 1MB", r == 0, d);
    r = pthread_create(&t, &a, thr, (void *) &a);
    pthread_join(t, &ret);
    say("pthread_create + TSD key", r == 0 && ret == (void *) &a, r ? strerror(r) : NULL);
  }
  {
    pthread_mutex_t m;
    pthread_mutexattr_t ma;
    pthread_cond_t c;
    struct timespec ts;
    pthread_mutexattr_init(&ma);
    r = pthread_mutexattr_settype(&ma, PTHREAD_MUTEX_ERRORCHECK);
    say("PTHREAD_MUTEX_ERRORCHECK", r == 0, r ? strerror(r) : NULL);
#ifdef PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP
    say("PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP", 1, NULL);
#else
    say("PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP", 0, NULL);
#endif
    pthread_mutex_init(&m, &ma);
    pthread_cond_init(&c, NULL);
    pthread_mutex_lock(&m);
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 50 * 1000000;
    if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
    r = pthread_cond_timedwait(&c, &m, &ts);
    say("pthread_cond_timedwait timeout", r == ETIMEDOUT, r != ETIMEDOUT ? strerror(r) : NULL);
    pthread_mutex_unlock(&m);
  }
  {
    struct timespec ts;
    r = clock_gettime(CLOCK_MONOTONIC, &ts);
    say("clock_gettime(CLOCK_MONOTONIC)", r == 0, r ? err() : NULL);
  }
  {
    struct sigaction sa;
    sigset_t set;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sig;
    r = sigaction(SIGHUP, &sa, NULL);
    raise(SIGHUP);
    say("sigaction + raise(SIGHUP)", r == 0 && got_sig == SIGHUP, r ? err() : NULL);
    sigemptyset(&set);
    sigaddset(&set, SIGTERM);
    /* No pthread_sigmask in the CRTL (probes f_/g_pthread_sigmask). */
    r = sigprocmask(SIG_BLOCK, &set, NULL);
    say("sigprocmask block SIGTERM", r == 0, r ? err() : NULL);
    sigprocmask(SIG_UNBLOCK, &set, NULL);
  }
  {
    /* Anonymous mmap (my_large_malloc, Aria/InnoDB buffers). */
#ifdef MAP_ANONYMOUS
    void *p = mmap(NULL, 64 * 1024 * 1024, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    snprintf(d, sizeof d, "%p", p);
    say("mmap MAP_ANONYMOUS 64MB", p != MAP_FAILED, p == MAP_FAILED ? err() : d);
    if (p != MAP_FAILED) munmap(p, 64 * 1024 * 1024);
#else
    say("MAP_ANONYMOUS defined", 0, NULL);
#endif
  }
  {
    /* Where malloc puts large blocks: below 4 GB means 32-bit (P0) heap. */
    size_t total = 0, chunk = 256 * 1024 * 1024;
    void *ptrs[64];
    int n = 0;
    unsigned long long hi = 0;
    while (n < 16) {
      void *p = malloc(chunk);
      if (!p) break;
      ptrs[n++] = p;
      total += chunk;
      if ((unsigned long long) (size_t) p > hi) hi = (unsigned long long) (size_t) p;
    }
    snprintf(d, sizeof d, "%lu MB in 256MB blocks, highest %#llx", (unsigned long) (total >> 20), hi);
    say("malloc 4GB in 256MB blocks", total == 16 * chunk, d);
    while (n) free(ptrs[--n]);
  }
  {
    pid_t p = getpid();
    snprintf(d, sizeof d, "%ld", (long) p);
    say("getpid", p > 0, d);
  }
  printf("R_PROC DONE\n");
  return 0;
}
