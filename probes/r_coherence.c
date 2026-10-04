/* r_coherence.c - when does a write through one descriptor become visible
   through a second descriptor of the same file?  (DECISIONS D6, Stage B
   step 0.1.)  Run with DECC$FILE_SHARING enabled (vms_probe.com's feature
   logicals), or the second open() fails.

   Each variant: fd1 creates the file and writes 32 KB of 'A'; fd2 opens it.
   Then, through pread/pwrite (or lseek + read/write):
     W2R1      fd2 writes 'Z' at 100, fd1 reads 100 (fd1 has touched that block)
     W2S2R1    same, with fsync(fd2) before the read
     W2R1cold  fd2 writes 'Y' at 20000, fd1 reads 20000 (block fd1 never read)
     W1R2      fd1 writes 'X' at 200, fd2 reads 200
     W1S1R2    same, with fsync(fd1) first
   and prints the byte seen ('A' = stale).  Then fstat sizes after fd2
   extends the file. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char big[32768];

static int openv(const char *name, int flags, const char *o1, const char *o2)
{
  if (o2) return open(name, flags, 0660, o1, o2);
  if (o1) return open(name, flags, 0660, o1);
  return open(name, flags, 0660);
}

static void wr(int fd, int seek, char c, off_t at)
{
  if (seek) { lseek(fd, at, SEEK_SET); write(fd, &c, 1); }
  else pwrite(fd, &c, 1, at);
}

static char rd(int fd, int seek, off_t at)
{
  char c = '?';
  if (seek) { lseek(fd, at, SEEK_SET); read(fd, &c, 1); }
  else pread(fd, &c, 1, at);
  return c;
}

static void variant(const char *tag, int extra, int seek, const char *o1, const char *o2)
{
  const char *f = "ioprobe2/coh.dat";
  int fd1, fd2;
  char r[5];
  struct stat st1, st2;

  unlink(f);
  fd1 = openv(f, O_RDWR | O_CREAT | O_TRUNC | extra, o1, o2);
  if (fd1 < 0) {
    int vms = vaxc$errno;
    printf("COH %-22s open1 failed: %s (VMS %%X%08X: %s)\n", tag, strerror(errno), vms,
           strerror(EVMSERR, vms));
    return;
  }
  memset(big, 'A', sizeof big);
  write(fd1, big, sizeof big);
  fsync(fd1);
  fd2 = openv(f, O_RDWR | extra, o1, o2);
  if (fd2 < 0) { printf("COH %-22s open2 failed: %s\n", tag, strerror(errno)); close(fd1); return; }

  (void) rd(fd1, seek, 100);           /* fd1 now has the first block cached */
  (void) rd(fd2, seek, 200);           /* and so does fd2 */
  wr(fd2, seek, 'Z', 100);
  r[0] = rd(fd1, seek, 100);
  fsync(fd2);
  r[1] = rd(fd1, seek, 100);
  wr(fd2, seek, 'Y', 20000);
  r[2] = rd(fd1, seek, 20000);
  wr(fd1, seek, 'X', 200);
  r[3] = rd(fd2, seek, 200);
  fsync(fd1);
  r[4] = rd(fd2, seek, 200);
  wr(fd2, seek, 'E', 40000);
  fstat(fd1, &st1);
  fstat(fd2, &st2);
  printf("COH %-22s W2R1=%c W2S2R1=%c W2R1cold=%c W1R2=%c W1S1R2=%c  size1=%lld size2=%lld%s\n",
         tag, r[0], r[1], r[2], r[3], r[4], (long long) st1.st_size, (long long) st2.st_size,
         (r[0] == 'Z' && r[1] == 'Z' && r[2] == 'Y' && r[3] == 'X' && r[4] == 'X') ? "  COHERENT" : "");
  close(fd2);
  close(fd1);
  unlink(f);
}

int main(void)
{
  mkdir("ioprobe2", 0770);
  variant("default", 0, 0, NULL, NULL);
  variant("default lseek+rw", 0, 1, NULL, NULL);
  variant("O_SYNC", O_SYNC, 0, NULL, NULL);
  variant("O_DSYNC", O_DSYNC, 0, NULL, NULL);
  variant("shr=get,put,upd", 0, 0, "shr=get,put,upd", NULL);
  variant("shr=..,upi", 0, 0, "shr=get,put,upd,upi", NULL);
  variant("ctx=bin", 0, 0, "ctx=bin", NULL);
  variant("ctx=xplct", 0, 0, "ctx=xplct", NULL);
  variant("ctx=nocvt", 0, 0, "ctx=nocvt", NULL);
  variant("mbc=1", 0, 0, "mbc=1", NULL);
  variant("mbf=1", 0, 0, "mbf=1", NULL);
  variant("rop=rea", 0, 0, "rop=rea", NULL);
  variant("rop=wbh off? rop=rah", 0, 0, "rop=rah", NULL);
  variant("fop=wck", 0, 0, "fop=wck", NULL);
  variant("ctx=xplct shr=upi", 0, 0, "ctx=xplct", "shr=get,put,upd,upi");
  variant("O_SYNC shr=upi", O_SYNC, 0, "shr=get,put,upd,upi", NULL);
  printf("R_COHERENCE DONE\n");
  return 0;
}
