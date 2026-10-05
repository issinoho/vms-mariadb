/* io_paths.c - what does a small read cost through each path the mysys file
   layer could use?  Follows io_count.c (every pread() costs an extra QIO,
   ~0.37 ms each).  On a 16 MB file (IO_PATHS.TMP, deleted at the end), 512-byte
   and 8 KB reads, sequential and random, through:
     C RTL read() with no seek, pread(), lseek()+read() to the current offset;
     $QIOW IO$_READVBLK on a channel from RMS (FOP UFO) - the floor for any
     C RTL replacement;
   and the write paths (pwrite(), lseek()+write(), with the fsync() in the
   time); printing QIOs (JPI$_DIRIO) and microseconds per call. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include <jpidef.h>
#include <iodef.h>
#include <rms.h>
#include <starlet.h>
#include <lib$routines.h>

#define FILE_SIZE (16L * 1024 * 1024)
#define CALLS 4096
static char buf[128 * 1024];
static char name[]= "io_paths.tmp";
static long offs[CALLS];

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

static void report(const char *what, size_t n, long d0, double t0)
{
  printf("%-34s %5lu B: %5.2f QIO/call %8.1f us/call\n", what, (unsigned long) n,
         (double) (dirio() - d0) / CALLS, (now() - t0) * 1e6 / CALLS);
}

/* op 0 read() no seek, 1 pread(), 2 lseek()+read(), 3 pwrite(), 4 lseek()+write() */
static void crtl(const char *what, int op, size_t n, int random)
{
  int fd= open(name, O_RDWR), i;
  long d0= dirio(), pos= 0;
  double t0= now();
  for (i= 0; i < CALLS; i++)
  {
    long off= random ? offs[i] : (long) i * (long) n;
    if (op == 0) read(fd, buf, n);
    else if (op == 1) pread(fd, buf, n, off);
    else if (op == 2) { lseek(fd, random ? off : pos, SEEK_SET); read(fd, buf, n); pos+= n; }
    else if (op == 3) pwrite(fd, buf, n, off);
    else { lseek(fd, random ? off : pos, SEEK_SET); write(fd, buf, n); pos+= n; }
  }
  if (op >= 3) { fsync(fd); report(what, n, d0, t0); }
  else report(what, n, d0, t0);
  close(fd);
}

static void qio(const char *what, size_t n, int random)
{
  struct FAB fab= cc$rms_fab;
  struct { unsigned short st, cnt; unsigned int dev; } iosb;
  unsigned short chan;
  int i, st;
  long d0;
  double t0;
  fab.fab$l_fna= name;
  fab.fab$b_fns= (unsigned char) strlen(name);
  fab.fab$b_fac= FAB$M_BIO | FAB$M_GET;
  fab.fab$b_shr= FAB$M_SHRGET | FAB$M_SHRPUT | FAB$M_UPI;
  fab.fab$l_fop= FAB$M_UFO;
  if (!((st= sys$open(&fab, 0, 0)) & 1)) { printf("sys$open %d\n", st); return; }
  chan= (unsigned short) fab.fab$l_stv;
  d0= dirio(); t0= now();
  for (i= 0; i < CALLS; i++)
  {
    long off= random ? offs[i] : (long) i * (long) n;
    unsigned int vbn= (unsigned int) (off / 512) + 1;
    /* a read that is not block-aligned needs the covering blocks */
    size_t len= ((off % 512) + n + 511) / 512 * 512;
    st= sys$qiow(0, chan, IO$_READVBLK, (void *) &iosb, 0, 0, buf, len, vbn, 0, 0, 0);
    if (!(st & 1) || !(iosb.st & 1)) { printf("qio %d %d\n", st, iosb.st); break; }
  }
  report(what, n, d0, t0);
  sys$dassgn(chan);
}

int main(void)
{
  int fd= open(name, O_CREAT | O_TRUNC | O_RDWR, 0644), i;
  if (fd < 0) { perror("create"); return 1; }
  memset(buf, 'x', sizeof(buf));
  for (i= 0; i < FILE_SIZE / (long) sizeof(buf); i++)
    if (write(fd, buf, sizeof(buf)) != (ssize_t) sizeof(buf)) { perror("write"); return 1; }
  close(fd);
  srand(42);
  for (i= 0; i < CALLS; i++)   /* unaligned random offsets, like row positions */
    offs[i]= ((long) rand() * 997L) % (FILE_SIZE - 16384);

  crtl("C RTL read(), no seek, sequential", 0, 512, 0);
  crtl("C RTL pread(), sequential", 1, 512, 0);
  crtl("C RTL lseek(cur)+read(), sequential", 2, 512, 0);
  crtl("C RTL pread(), random", 1, 512, 1);
  crtl("C RTL pread(), random", 1, 8192, 1);
  crtl("C RTL lseek()+read(), random", 2, 512, 1);
  crtl("C RTL lseek()+read(), random", 2, 8192, 1);
  crtl("C RTL pwrite(), random, +fsync", 3, 8192, 1);
  crtl("C RTL lseek()+write(), random, +fsync", 4, 8192, 1);
  crtl("C RTL lseek()+write(), sequential, +fsync", 4, 8192, 0);
  qio("$QIOW READVBLK, sequential", 512, 0);
  qio("$QIOW READVBLK, random", 512, 1);
  qio("$QIOW READVBLK, random", 8192, 1);
  qio("$QIOW READVBLK, random (2nd pass)", 8192, 1);
  unlink(name);
  return 0;
}
