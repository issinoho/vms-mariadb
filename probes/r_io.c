/* r_io.c - file I/O semantics the MariaDB storage engines depend on.
   Runs in the current directory; creates and removes files under [.IOPROBE]. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>

static void say(const char *what, int ok, const char *detail)
{
  printf("IO %-34s %s %s\n", what, ok ? "yes" : "NO ", detail ? detail : "");
}

static char errbuf[200];
static const char *err(void)
{
  snprintf(errbuf, sizeof errbuf, "errno=%d (%s)", errno, strerror(errno));
  return errbuf;
}

static int create(const char *name)
{
  int fd = open(name, O_RDWR | O_CREAT | O_TRUNC, 0660);
  if (fd < 0) return -1;
  close(fd);
  return 0;
}

int main(void)
{
  char buf[8192], buf2[8192];
  int fd, fd2, r;
  struct stat st;
  const char *f = "ioprobe/data.bin";

  mkdir("ioprobe", 0770);

  /* Flags that exist at compile time. */
#ifdef O_DIRECT
  say("O_DIRECT defined", 1, NULL);
#else
  say("O_DIRECT defined", 0, NULL);
#endif
#ifdef O_DSYNC
  say("O_DSYNC defined", 1, NULL);
#else
  say("O_DSYNC defined", 0, NULL);
#endif
#ifdef O_SYNC
  say("O_SYNC defined", 1, NULL);
#else
  say("O_SYNC defined", 0, NULL);
#endif
#ifdef O_CLOEXEC
  say("O_CLOEXEC defined", 1, NULL);
#else
  say("O_CLOEXEC defined", 0, NULL);
#endif
#ifdef F_SETLK
  say("F_SETLK defined", 1, NULL);
#else
  say("F_SETLK defined", 0, NULL);
#endif
#ifdef F_FULLFSYNC
  say("F_FULLFSYNC defined", 1, NULL);
#else
  say("F_FULLFSYNC defined", 0, NULL);
#endif

  fd = open(f, O_RDWR | O_CREAT | O_TRUNC, 0660);
  say("open O_CREAT", fd >= 0, fd < 0 ? err() : NULL);
  if (fd < 0) return 1;

  /* pwrite/pread at offsets, including a gap (InnoDB extends files this way). */
  memset(buf, 'A', sizeof buf);
  r = (int) pwrite(fd, buf, 4096, 0);
  say("pwrite at 0", r == 4096, r != 4096 ? err() : NULL);
  memset(buf, 'B', sizeof buf);
  r = (int) pwrite(fd, buf, 4096, 65536);
  say("pwrite at 64K (gap)", r == 4096, r != 4096 ? err() : NULL);
  fstat(fd, &st);
  snprintf(buf2, sizeof buf2, "st_size=%lld (expect 69632)", (long long) st.st_size);
  say("fstat size after gap write", st.st_size == 69632, buf2);
  memset(buf2, 'x', 4096);
  r = (int) pread(fd, buf2, 4096, 32768);
  say("pread inside gap reads zeros", r == 4096 && buf2[0] == 0 && buf2[4095] == 0, NULL);
  r = (int) pread(fd, buf2, 4096, 65536);
  say("pread at 64K", r == 4096 && buf2[0] == 'B', NULL);
  r = (int) pwrite(fd, "C", 1, 100);
  r = (int) pread(fd, buf2, 3, 99);
  say("pwrite 1 byte mid-block", buf2[0] == 'A' && buf2[1] == 'C' && buf2[2] == 'A', NULL);
  r = (int) pwrite(fd, buf, 1000, 69632);
  fstat(fd, &st);
  snprintf(buf2, sizeof buf2, "st_size=%lld (expect 70632)", (long long) st.st_size);
  say("odd-length append size", st.st_size == 70632, buf2);

  /* Same file opened twice for writing (handlers open tables repeatedly). */
  fd2 = open(f, O_RDWR);
  say("second O_RDWR open of same file", fd2 >= 0, fd2 < 0 ? err() : NULL);
  if (fd2 >= 0) {
    r = (int) pwrite(fd2, "Z", 1, 0);
    r = (int) pread(fd, buf2, 1, 0);
    say("write via fd2 visible via fd1", buf2[0] == 'Z', NULL);
    close(fd2);
  }

  r = fsync(fd);
  say("fsync", r == 0, r ? err() : NULL);
#ifdef HAVE_FDATASYNC_PROBE
  r = fdatasync(fd);
  say("fdatasync", r == 0, r ? err() : NULL);
#endif
  r = ftruncate(fd, 8192);
  fstat(fd, &st);
  say("ftruncate shrink", r == 0 && st.st_size == 8192, r ? err() : NULL);
  r = ftruncate(fd, 1048576);
  fstat(fd, &st);
  say("ftruncate grow", r == 0 && st.st_size == 1048576, r ? err() : NULL);

  /* Byte-range locks. */
  {
    struct flock fl;
    memset(&fl, 0, sizeof fl);
    fl.l_type = F_WRLCK; fl.l_whence = SEEK_SET; fl.l_start = 0; fl.l_len = 1;
    r = fcntl(fd, F_SETLK, &fl);
    say("fcntl F_SETLK write lock", r == 0, r ? err() : NULL);
    fl.l_type = F_UNLCK;
    r = fcntl(fd, F_SETLK, &fl);
    say("fcntl F_SETLK unlock", r == 0, r ? err() : NULL);
  }

  /* lseek + write past EOF, and O_APPEND. */
  {
    off_t o = lseek(fd, 2 * 1048576, SEEK_SET);
    r = (int) write(fd, "E", 1);
    fstat(fd, &st);
    say("lseek past EOF + write", o == 2 * 1048576 && r == 1 && st.st_size == 2 * 1048576 + 1, NULL);
  }
  close(fd);

  fd = open(f, O_WRONLY | O_APPEND);
  r = (int) write(fd, "ABC", 3);
  close(fd);
  stat(f, &st);
  say("O_APPEND write", r == 3 && st.st_size == 2 * 1048576 + 4, NULL);

  /* Rename over an existing file (frm/par replacement, ddl log). */
  create("ioprobe/new.tmp");
  r = rename("ioprobe/new.tmp", f);
  say("rename over existing file", r == 0, r ? err() : NULL);
  r = stat("ioprobe/new.tmp", &st);
  say("rename source gone", r != 0, NULL);

  /* Unlink an open file. */
  fd = open(f, O_RDWR);
  r = unlink(f);
  say("unlink open file", r == 0, r ? err() : NULL);
  if (fd >= 0) close(fd);
  r = stat(f, &st);
  say("unlinked file gone", r != 0, NULL);
  {
    int versions = 0;
    create("ioprobe/v.dat");
    create("ioprobe/v.dat");
    unlink("ioprobe/v.dat");
    versions = stat("ioprobe/v.dat", &st) == 0;
    say("O_TRUNC reuses file (no 2nd version)", !versions, versions ? "unlink left an older version" : NULL);
    while (unlink("ioprobe/v.dat") == 0) ;
  }

  /* Names MariaDB creates in the datadir. */
  {
    static const char *names[] = {
      "ioprobe/t1.frm", "ioprobe/t1.MAI", "ioprobe/t1.MAD", "ioprobe/db.opt",
      "ioprobe/ib_logfile0", "ioprobe/ibdata1", "ioprobe/aria_log.00000001",
      "ioprobe/#sql-1a2b_3.frm", "ioprobe/#sql-backup-1a2b-3.MAI",
      "ioprobe/t@002d1.frm", "ioprobe/MixedCase.frm", "ioprobe/a.b.c.d",
      "ioprobe/ddl_recovery.log", "ioprobe/x#P#p0.ibd", "ioprobe/.hidden",
      "ioprobe/mysql-bin.000001", "ioprobe/sp ace.frm", NULL };
    int i;
    for (i = 0; names[i]; i++) {
      r = create(names[i]);
      snprintf(buf2, sizeof buf2, "%s", r ? err() : "");
      say(names[i], r == 0 && stat(names[i], &st) == 0, buf2);
    }
  }

  /* What readdir reports for them (case, version suffix, dots). */
  {
    DIR *d = opendir("ioprobe");
    struct dirent *de;
    printf("IO readdir:");
    while (d && (de = readdir(d)) != NULL) printf(" [%s]", de->d_name);
    printf("\n");
    if (d) closedir(d);
  }
  {
    char rp[1024];
    char *p = realpath("ioprobe/t1.frm", rp);
    printf("IO realpath ioprobe/t1.frm -> %s\n", p ? p : err());
    p = getcwd(rp, sizeof rp);
    printf("IO getcwd -> %s\n", p ? p : err());
  }
  {
    /* mkdir of a database directory with a dot and a mixed-case name */
    r = mkdir("ioprobe/Db.Two", 0770);
    say("mkdir name with a dot", r == 0, r ? err() : NULL);
    r = rmdir("ioprobe/Db.Two");
    say("rmdir name with a dot", r == 0, r ? err() : NULL);
  }
  /* open() on a directory (my_sync_dir / innodb os_file_flush on dirs). */
  fd = open("ioprobe", O_RDONLY);
  say("open() a directory", fd >= 0, fd < 0 ? err() : NULL);
  if (fd >= 0) close(fd);

  printf("R_IO DONE\n");
  return 0;
}
