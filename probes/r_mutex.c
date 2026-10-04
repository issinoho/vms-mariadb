/* r_mutex.c - why does a stack mutex set up by PTHREAD_MUTEX_INITIALIZER
   fail to lock (EINVAL) on OpenVMS x86-64, when static and heap ones work?
   (DECISIONS D5, Stage B step 0.2.) */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static void t(const char *what, pthread_mutex_t *m)
{
  int r = pthread_mutex_lock(m);
  printf("MTX %-44s %16p align16=%d lock=%d%s\n", what, (void *) m,
         (int) (((uintptr_t) m) % 16 == 0), r, r ? " (FAIL)" : "");
  if (!r) pthread_mutex_unlock(m);
}

static void stack_tests(const char *who)
{
  char name[80];
  struct { char pad[8]; pthread_mutex_t m; } odd = { {0}, PTHREAD_MUTEX_INITIALIZER };
  pthread_mutex_t a = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_t __attribute__((aligned(64))) b = PTHREAD_MUTEX_INITIALIZER;
  static const pthread_mutex_t proto = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_t c;
  pthread_mutex_t *h = malloc(sizeof *h);
  memcpy(&c, &proto, sizeof c);
  *h = proto;
  snprintf(name, sizeof name, "%s stack, INITIALIZER", who); t(name, &a);
  snprintf(name, sizeof name, "%s stack aligned(64), INITIALIZER", who); t(name, &b);
  snprintf(name, sizeof name, "%s stack +8, INITIALIZER", who); t(name, &odd.m);
  snprintf(name, sizeof name, "%s stack, memcpy of static proto", who); t(name, &c);
  snprintf(name, sizeof name, "%s heap, copy of static proto", who); t(name, h);
  free(h);
}

static void *thr(void *arg) { (void) arg; stack_tests("thread"); return NULL; }

int main(void)
{
  pthread_t th;
  pthread_attr_t at;
  static pthread_mutex_t s = PTHREAD_MUTEX_INITIALIZER;
  printf("MTX sizeof %u\n", (unsigned) sizeof(pthread_mutex_t));
  t("static, INITIALIZER", &s);
  stack_tests("main");
  pthread_create(&th, NULL, thr, NULL);
  pthread_join(th, NULL);
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 1024 * 1024);
  pthread_create(&th, &at, thr, NULL);
  pthread_join(th, NULL);
  printf("R_MUTEX DONE\n");
  return 0;
}
