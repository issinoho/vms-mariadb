/* r_vmem.c - InnoDB's buffer pool memory calls on VMS (Stage C, C0.2).
   11.4's buf_pool_t::create() reserves innodb_buffer_pool_size_max (default
   8 TB on 64-bit) with my_large_virtual_alloc():
     mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
   commits the pool inside it with my_virtual_mem_commit():
     mmap(ptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0)
   decommits (shrink) with mprotect(PROT_NONE), and releases with munmap().
   Prints each call's result and the page file quota it used (JPI$_PAGFILCNT).
   A PROT_NONE mapping is charged in full against the page file, and a failed
   one may still be charged: sizes over a quarter of the quota left are skipped
   (2026-10-10, 4-6 GB attempts exhausted a node's 1.8 GB of page files). */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <jpidef.h>
#include <lib$routines.h>

#ifndef MAP_ANON
# define MAP_ANON MAP_ANONYMOUS
#endif
#define MB (1024UL * 1024)

static long pgfl(void)   /* remaining page file quota, in pagelets */
{
  int item= JPI$_PAGFILCNT;
  unsigned int v= 0;
  lib$getjpi(&item, 0, 0, &v, 0, 0);
  return (long) v;
}

static char *reserve(size_t size)
{
  long q= pgfl();
  char *p= mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  printf("reserve %8lu MB PROT_NONE: %s %p errno %d, quota used %ld MB\n",
         (unsigned long) (size / MB), p == MAP_FAILED ? "FAILED" : "ok",
         (void *) p, p == MAP_FAILED ? errno : 0, (q - pgfl()) / 2048);
  return p == MAP_FAILED ? NULL : p;
}

static int touch(char *p, size_t size, int c, int expect)
{
  size_t i;
  int bad= 0;
  for (i= 0; i < size; i+= 8192)
  {
    if (expect >= 0 && p[i] != expect) bad++;
    p[i]= (char) c;
  }
  return bad;
}

int main(void)
{
  static const size_t sizes[]= { 8UL << 40, 1UL << 40, 64UL << 30, 4UL << 30, (4UL << 30) - 8192, 3UL << 30, 2UL << 30, 1UL << 30 };
  char *res= NULL, *p;
  size_t rsize= 0, i;
  long q;

  printf("sizeof(size_t) %d, sizeof(void *) %d, MAP_NORESERVE %s\n",
         (int) sizeof(size_t), (int) sizeof(void *),
#ifdef MAP_NORESERVE
         "defined"
#else
         "undefined"
#endif
         );
  printf("page file quota left at start: %ld MB\n", pgfl() / 2048);

  for (i= 0; i < sizeof sizes / sizeof *sizes; i++)
  {
    char *r;
    if (sizes[i] / MB > (size_t) pgfl() / 2048 / 4)
    {
      printf("reserve %8lu MB: skipped, over a quarter of the quota left\n",
             (unsigned long) (sizes[i] / MB));
      continue;
    }
    r= reserve(sizes[i]);
    if (r && !res) { res= r; rsize= sizes[i]; }
    else if (r && munmap(r, sizes[i])) printf("munmap: errno %d\n", errno);
  }
  if (!res) { printf("no reservation succeeded\n"); return 1; }
  printf("keeping the %lu MB reservation\n", (unsigned long) (rsize / MB));

  q= pgfl();
  p= mmap(res, 256 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
  printf("commit 256 MB MAP_FIXED at start: %s %p (want %p) errno %d, quota used %ld MB\n",
         p == MAP_FAILED ? "FAILED" : "ok", (void *) p, (void *) res,
         p == MAP_FAILED ? errno : 0, (q - pgfl()) / 2048);
  if (p != res) return 1;
  printf("touch: %d pages not zero\n", touch(p, 256 * MB, 'a', 0));
  printf("quota used after touching: %ld MB\n", (q - pgfl()) / 2048);

  p= mmap(res + 256 * MB, 256 * MB, PROT_READ | PROT_WRITE,
          MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
  printf("grow: commit next 256 MB: %s, first part kept: %d pages changed\n",
         p == res + 256 * MB ? "ok" : "FAILED", touch(res, 256 * MB, 'a', 'a'));
  if (p == res + 256 * MB) touch(p, 256 * MB, 'b', 0);

  q= pgfl();
  printf("decommit second 256 MB, mprotect PROT_NONE: %d", mprotect(res + 256 * MB, 256 * MB, PROT_NONE));
  printf(", quota freed %ld MB\n", (pgfl() - q) / 2048);
  p= mmap(res + 256 * MB, 256 * MB, PROT_READ | PROT_WRITE,
          MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
  printf("recommit it: %s, %d pages not zero\n", p == res + 256 * MB ? "ok" : "FAILED",
         p == res + 256 * MB ? touch(p, 256 * MB, 'c', 0) : -1);

  q= pgfl();
  printf("release, munmap whole reservation: %d", munmap(res, rsize));
  printf(", quota freed %ld MB\n", (pgfl() - q) / 2048);

  p= mmap(NULL, 64 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON
#ifdef MAP_NORESERVE
          | MAP_NORESERVE
#endif
          , -1, 0);
  printf("commit(NULL) 64 MB RW: %s %p\n", p == MAP_FAILED ? "FAILED" : "ok", (void *) p);
  if (p != MAP_FAILED) munmap(p, 64 * MB);
  printf("R_VMEM-DONE\n");
  return 0;
}
