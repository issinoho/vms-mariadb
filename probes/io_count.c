/* io_count.c - how many disk QIOs does the C RTL issue for read(), pread()
   and pwrite() of a given size?  A full-table scan on the server did about
   one direct I/O per 75 bytes read.  Writes a 16 MB file (IO_COUNT.TMP, in
   the current directory, deleted at the end), then reads and rewrites it
   with several buffer sizes, printing the direct I/O count (JPI$_DIRIO) and
   time for each pass. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <jpidef.h>
#include <lib$routines.h>

#define FILE_SIZE (16L * 1024 * 1024)
static char buf[128 * 1024];

static long dirio(void)
{
  int item= JPI$_DIRIO;
  unsigned int v= 0;
  lib$getjpi(&item, 0, 0, &v, 0, 0);
  return (long) v;
}

static double now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void pass(const char *name, int oflag, int op, size_t chunk)
{
  long d0, i, n= FILE_SIZE / (long) chunk;
  double t0;
  int fd= open("io_count.tmp", oflag);
  if (fd < 0) { perror(name); return; }
  d0= dirio(); t0= now();
  for (i= 0; i < n; i++)
  {
    ssize_t r;
    off_t off= (off_t) i * chunk;
    switch (op)
    {
    case 0: r= read(fd, buf, chunk); break;
    case 1: r= pread(fd, buf, chunk, off); break;
    default: r= pwrite(fd, buf, chunk, off); break;
    }
    if (r != (ssize_t) chunk) { printf("%s: short %ld at %ld\n", name, (long) r, (long) off); break; }
  }
  printf("%-22s %7lu bytes: %8ld QIOs (%6.1f bytes/QIO) %6.2fs\n", name,
         (unsigned long) chunk, dirio() - d0,
         (double) FILE_SIZE / (double) (dirio() - d0 > 0 ? dirio() - d0 : 1), now() - t0);
  close(fd);
}

int main(void)
{
  long i;
  int fd= open("io_count.tmp", O_CREAT | O_TRUNC | O_RDWR, 0644);
  if (fd < 0) { perror("create"); return 1; }
  memset(buf, 'x', sizeof(buf));
  for (i= 0; i < FILE_SIZE / (long) sizeof(buf); i++)
    if (write(fd, buf, sizeof(buf)) != (ssize_t) sizeof(buf)) { perror("write"); return 1; }
  close(fd);

  pass("read RDONLY", O_RDONLY, 0, 128 * 1024);
  pass("read RDWR", O_RDWR, 0, 128 * 1024);
  pass("pread RDONLY", O_RDONLY, 1, 128 * 1024);
  pass("pread RDWR", O_RDWR, 1, 128 * 1024);
  pass("pread RDWR", O_RDWR, 1, 8192);
  pass("pread RDWR", O_RDWR, 1, 512);
  pass("pwrite RDWR", O_RDWR, 2, 128 * 1024);
  pass("pwrite RDWR", O_RDWR, 2, 8192);
  unlink("io_count.tmp");
  return 0;
}
