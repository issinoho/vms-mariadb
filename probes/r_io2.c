/* r_io2.c - follow-up on r_io: when does st_size catch up, are writes through
   one descriptor visible through another, and does an RMS record format given
   to open() change either?  Run in a directory whose version limit is 1
   (vms_probe.com sets [.IOPROBE2] up that way) to see whether O_TRUNC and
   rename still leave older versions behind. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static char buf[65536];

static long long fsz(int fd)
{
  struct stat st;
  return fstat(fd, &st) == 0 ? (long long) st.st_size : -1;
}

static long long psz(const char *n)
{
  struct stat st;
  return stat(n, &st) == 0 ? (long long) st.st_size : -1;
}

static int openx(const char *name, int flags, const char *rms)
{
  if (rms == NULL) return open(name, flags, 0660);
  return open(name, flags, 0660, rms);
}

static void variant(const char *tag, const char *rms)
{
  char name[64], c = 0;
  int fd, fd2;
  long long e;
  snprintf(name, sizeof name, "ioprobe2/%s.dat", tag);

  fd = openx(name, O_RDWR | O_CREAT | O_TRUNC, rms);
  if (fd < 0) { printf("IO2 %-8s open failed errno=%d (%s)\n", tag, errno, strerror(errno)); return; }
  memset(buf, 'A', sizeof buf);
  pwrite(fd, buf, 16384, 0);
  printf("IO2 %-8s after pwrite 16K: fstat=%lld stat=%lld lseek_end=%lld\n", tag, fsz(fd), psz(name),
         (long long) lseek(fd, 0, SEEK_END));
  fsync(fd);
  printf("IO2 %-8s after fsync:       fstat=%lld stat=%lld\n", tag, fsz(fd), psz(name));

  fd2 = openx(name, O_RDWR, rms);
  if (fd2 < 0) {
    printf("IO2 %-8s second open failed errno=%d (%s)\n", tag, errno, strerror(errno));
  } else {
    printf("IO2 %-8s fd2 sees size:     fstat=%lld\n", tag, fsz(fd2));
    pwrite(fd2, "Z", 1, 100);
    pread(fd, &c, 1, 100);
    printf("IO2 %-8s fd2 pwrite -> fd1 pread before fsync: %c\n", tag, c);
    fsync(fd2);
    pread(fd, &c, 1, 100);
    printf("IO2 %-8s fd2 pwrite -> fd1 pread after fsync(fd2): %c\n", tag, c);
    pwrite(fd, "Y", 1, 200);
    pread(fd2, &c, 1, 200);
    printf("IO2 %-8s fd1 pwrite -> fd2 pread (no fsync): %c\n", tag, c);
    pwrite(fd2, buf, 4096, 16384);
    printf("IO2 %-8s fd2 extends to 20K: fd1 fstat=%lld fd2 fstat=%lld\n", tag, fsz(fd), fsz(fd2));
    close(fd2);
    printf("IO2 %-8s after close(fd2):  fd1 fstat=%lld stat=%lld\n", tag, fsz(fd), psz(name));
  }
  e = lseek(fd, 100000, SEEK_SET);
  errno = 0;
  printf("IO2 %-8s lseek(100000)=%lld write=%d errno=%d\n", tag, e, (int) write(fd, "E", 1), errno);
  printf("IO2 %-8s after seek+write:  fstat=%lld\n", tag, fsz(fd));
  close(fd);
  printf("IO2 %-8s after close:       stat=%lld (expect 100001)\n", tag, psz(name));

  /* Reopen with O_TRUNC, then rename another file over it. */
  fd = openx(name, O_RDWR | O_CREAT | O_TRUNC, rms);
  write(fd, "x", 1);
  close(fd);
  fd = open("ioprobe2/other.tmp", O_RDWR | O_CREAT | O_TRUNC, 0660);
  close(fd);
  rename("ioprobe2/other.tmp", name);
  unlink(name);
  printf("IO2 %-8s after O_TRUNC + rename + one unlink, name still exists: %s\n", tag,
         psz(name) >= 0 ? "YES (older version left)" : "no");
  while (unlink(name) == 0) ;
}

int main(void)
{
  mkdir("ioprobe2", 0770);
  variant("default", NULL);
  variant("ctx_stm", "ctx=stm");
  variant("rfm_udf", "rfm=udf");
  variant("rfm_fix", "rfm=fix");
  variant("shr_all", "shr=get,put,upd");
  {
    char rp[1024];
    char *p = realpath(".", rp);
    printf("IO2 realpath(.) -> %s\n", p ? p : strerror(errno));
  }
  printf("R_IO2 DONE\n");
  return 0;
}
