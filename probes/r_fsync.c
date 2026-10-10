/* r_fsync.c - what does fsync() do on VMS, for InnoDB's durability (Stage C, C0.1)?
   r_fsync time   cost (QIOs from JPI$_DIRIO, microseconds) of InnoDB's write patterns:
                  16 KB page pwrite()+fsync(), batches of pwrite() then one fsync(),
                  fsync() with nothing dirty, O_DSYNC page writes, 512-byte
                  sequential log writes + fsync()
   r_fsync vis    does a pwrite() reach the file before fsync()? Read the block back
                  through a separate $QIO channel (RMS UFO, no C RTL buffer), before and
                  after fsync(), and with O_DSYNC
   r_fsync kill 0|1  rewrite page 2 and extend a 16-page file to 48 pages, fsync() if 1,
                  then $DELPRC itself (what STOP/ID does to mariadbd); run it SPAWNed
   r_fsync check  after kill: the file's size by stat() (the header's end of file),
                  which pages hold the new data by read() and by $QIO past that end
   File R_FSYNC.TMP in the current directory; `check` deletes it. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <jpidef.h>
#include <iodef.h>
#include <rms.h>
#include <starlet.h>
#include <lib$routines.h>

#define PAGE 16384
#define N 256
static char buf[PAGE], rbuf[PAGE];
static char name[]= "r_fsync.tmp";

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

static void report(const char *what, int calls, long d0, double t0)
{
  printf("%-44s %6.2f QIO/op %9.1f us/op\n", what,
         (double) (dirio() - d0) / calls, (now() - t0) * 1e6 / calls);
}

static void make_file(int pages, int c)
{
  int fd= open(name, O_CREAT | O_TRUNC | O_RDWR, 0644), i;
  if (fd < 0) { perror("create"); exit(1); }
  memset(buf, c, PAGE);
  for (i= 0; i < pages; i++)
    if (write(fd, buf, PAGE) != PAGE) { perror("write"); exit(1); }
  fsync(fd);
  close(fd);
}

/* A $QIO channel onto the file, shared with the C RTL's descriptors. */
static unsigned short qchan(void)
{
  struct FAB fab= cc$rms_fab;
  int st;
  fab.fab$l_fna= name;
  fab.fab$b_fns= (unsigned char) strlen(name);
  fab.fab$b_fac= FAB$M_BIO | FAB$M_GET;
  fab.fab$b_shr= FAB$M_SHRGET | FAB$M_SHRPUT | FAB$M_SHRUPD | FAB$M_UPI;
  fab.fab$l_fop= FAB$M_UFO;
  if (!((st= sys$open(&fab, 0, 0)) & 1)) { printf("sys$open %d\n", st); exit(1); }
  return (unsigned short) fab.fab$l_stv;
}

/* Read page `pg` through the channel; returns its first byte, or -status. */
static int qread(unsigned short chan, int pg)
{
  struct { unsigned short st, cnt; unsigned int dev; } iosb;
  int st= sys$qiow(0, chan, IO$_READVBLK, (void *) &iosb, 0, 0, rbuf, PAGE,
                   (unsigned int) pg * (PAGE / 512) + 1, 0, 0, 0);
  if (!(st & 1)) return -st;
  if (!(iosb.st & 1)) return -(int) iosb.st;
  return (unsigned char) rbuf[0];
}

static void do_time(void)
{
  int fd, i;
  long d0;
  double t0;
  make_file(64, 'x');
  srand(7);
  fd= open(name, O_RDWR);
  d0= dirio(); t0= now();
  for (i= 0; i < N; i++)
  { pwrite(fd, buf, PAGE, (off_t) (rand() % 64) * PAGE); fsync(fd); }
  report("16 KB pwrite + fsync, random", N, d0, t0);
  d0= dirio(); t0= now();
  for (i= 0; i < N; i++)
  {
    pwrite(fd, buf, PAGE, (off_t) (rand() % 64) * PAGE);
    if (i % 32 == 31) fsync(fd);
  }
  report("16 KB pwrite, fsync per 32 (per write)", N, d0, t0);
  d0= dirio(); t0= now();
  for (i= 0; i < N; i++) fsync(fd);
  report("fsync, nothing dirty", N, d0, t0);
  close(fd);
  fd= open(name, O_RDWR | O_DSYNC);
  d0= dirio(); t0= now();
  for (i= 0; i < N; i++) pwrite(fd, buf, PAGE, (off_t) (rand() % 64) * PAGE);
  report("16 KB pwrite, O_DSYNC, random", N, d0, t0);
  close(fd);
  fd= open(name, O_RDWR);
  d0= dirio(); t0= now();
  for (i= 0; i < N; i++) { pwrite(fd, buf, 512, (off_t) i * 512); fsync(fd); }
  report("512 B pwrite + fsync, sequential (redo)", N, d0, t0);
  close(fd);
  fd= open(name, O_RDWR | O_DSYNC);
  d0= dirio(); t0= now();
  for (i= 0; i < N; i++) pwrite(fd, buf, 512, (off_t) i * 512);
  report("512 B pwrite, O_DSYNC, sequential (redo)", N, d0, t0);
  close(fd);
  unlink(name);
}

static void vis_case(const char *what, int flags)
{
  int fd;
  unsigned short chan;
  make_file(8, 'x');
  fd= open(name, O_RDWR | flags);
  chan= qchan();
  memset(buf, 'A', PAGE);
  pwrite(fd, buf, PAGE, 3 * PAGE);
  printf("%-22s after pwrite: QIO sees '%c'", what, qread(chan, 3));
  fsync(fd);
  printf(", after fsync: '%c'\n", qread(chan, 3));
  sys$dassgn(chan);
  close(fd);
  unlink(name);
}

static void do_kill(int sync)
{
  int fd, i;
  struct stat st;
  make_file(16, 'x');
  fd= open(name, O_RDWR);
  memset(buf, 'K', PAGE);
  pwrite(fd, buf, PAGE, 2 * PAGE);
  for (i= 16; i < 48; i++) pwrite(fd, buf, PAGE, (off_t) i * PAGE);
  if (sync) fsync(fd);
  stat(name, &st);
  printf("kill %d: wrote page 2 and pages 16-47; stat size before death %ld\n",
         sync, (long) st.st_size);
  fflush(stdout);
  sys$delprc(0, 0);
  printf("still alive?\n");
}

static void do_check(void)
{
  struct stat st;
  int fd, i, n, k= 0, kq= 0, eof= 0;
  unsigned short chan;
  char seen[49];
  if (stat(name, &st)) { perror("stat"); return; }
  printf("check: stat size %ld (%ld pages)\n", (long) st.st_size, (long) st.st_size / PAGE);
  fd= open(name, O_RDONLY);
  for (i= 0; i < 48; i++)
  {
    n= (int) pread(fd, rbuf, PAGE, (off_t) i * PAGE);
    seen[i]= n <= 0 ? '-' : rbuf[0];
    if (n > 0 && rbuf[0] == 'K') k++;
  }
  seen[48]= 0;
  close(fd);
  printf("check: read() pages 0-47:  %s (%d 'K')\n", seen, k);
  chan= qchan();
  for (i= 0; i < 48; i++)
  {
    int c= qread(chan, i);
    seen[i]= c < 0 ? '-' : (char) c;
    if (c == 'K') kq++;
    if (c < 0 && !eof) { eof= 1; printf("check: $QIO status at page %d: %d\n", i, -c); }
  }
  sys$dassgn(chan);
  printf("check: $QIO  pages 0-47:   %s (%d 'K')\n", seen, kq);
  unlink(name);
}

int main(int argc, char **argv)
{
  const char *m= argc > 1 ? argv[1] : "";
  if (!strcmp(m, "time")) do_time();
  else if (!strcmp(m, "vis"))
  {
    vis_case("buffered", 0);
    vis_case("O_DSYNC", O_DSYNC);
  }
  else if (!strcmp(m, "kill")) do_kill(argc > 2 && atoi(argv[2]));
  else if (!strcmp(m, "check")) do_check();
  else { fprintf(stderr, "usage: r_fsync time|vis|kill 0|1|check\n"); return 2; }
  return 0;
}
