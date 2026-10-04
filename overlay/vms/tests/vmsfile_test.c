/* vmsfile_test.c - tests for mysys/my_vmsfile.c (patch 0014): several
   my_open() descriptors of one file must see each other's writes at once,
   keep their own positions, and report the real file size.
   Run with DECC$FILE_SHARING and DECC$FD_LOCKING enabled (vms/tests/
   run_vmsfile_test.com).  Prints "VMSFILE <test>: PASS|FAIL" lines and
   "VMSFILE_TEST: <n> passed, <m> failed". */
#include <my_global.h>
#include <my_sys.h>
#include <my_dir.h>
#include <my_pthread.h>
#include <string.h>

static int passed, failed;
static const char *path= "vmsfile_test.dat";

static void check(const char *what, int ok, const char *detail)
{
  printf("VMSFILE %-40s %s %s\n", what, ok ? "PASS" : "FAIL", detail ? detail : "");
  if (ok) passed++; else failed++;
}

static char at(File fd, my_off_t off)
{
  uchar c= '?';
  my_pread(fd, &c, 1, off, MYF(0));
  return (char) c;
}

static my_off_t fsize(File fd)
{
  MY_STAT st;
  return my_fstat(fd, &st, MYF(0)) ? (my_off_t) -1 : (my_off_t) st.st_size;
}

#define NTHREADS 4
#define BLOCKS 64
static File tfd[NTHREADS];
static int terr[NTHREADS];

static void *worker(void *arg)
{
  int t= (int) (intptr_t) arg, round, b;
  uchar buf[512], rd[512];
  for (round= 0; round < 20; round++)
    for (b= t; b < BLOCKS; b+= NTHREADS)
    {
      memset(buf, 'a' + (round + b) % 26, sizeof buf);
      if (my_pwrite(tfd[t], buf, sizeof buf, (my_off_t) b * 512, MYF(MY_NABP)))
        terr[t]++;
      /* read a block another thread owns: it must be a whole block */
      if (my_pread(tfd[t], rd, sizeof rd, (my_off_t) ((b + 1) % BLOCKS) * 512, MYF(MY_NABP)))
        terr[t]++;
      else
      {
        int k;
        for (k= 1; k < (int) sizeof rd; k++)
          if (rd[k] != rd[0])
          {
            terr[t]++;                  /* torn: two writes mixed */
            break;
          }
      }
    }
  return NULL;
}

int main(int argc, char **argv)
{
  File fd1, fd2, fd3, fd4;
  uchar big[32768], buf[16];
  char d[120];
  MY_STAT st;
  int i;
  pthread_t th[NTHREADS];
  (void) argc;
  MY_INIT(argv[0]);

  my_delete(path, MYF(0));
  fd1= my_open(path, O_RDWR | O_CREAT | O_TRUNC, MYF(MY_WME));
  memset(big, 'A', sizeof big);
  my_write(fd1, big, sizeof big, MYF(MY_NABP));
  fd2= my_open(path, O_RDWR, MYF(MY_WME));
  check("two opens", fd1 >= 0 && fd2 >= 0, NULL);
  (void) at(fd1, 100);
  (void) at(fd2, 200);

  my_pwrite(fd2, (uchar *) "Z", 1, 100, MYF(MY_NABP));
  check("fd2 write seen by fd1, no fsync", at(fd1, 100) == 'Z', NULL);
  my_pwrite(fd1, (uchar *) "X", 1, 200, MYF(MY_NABP));
  check("fd1 write seen by fd2 (fd2 wrote too)", at(fd2, 200) == 'X', NULL);
  my_pwrite(fd2, (uchar *) "Y", 1, 100, MYF(MY_NABP));
  check("fd2 rewrite seen by fd1", at(fd1, 100) == 'Y', NULL);

  /* positions are per descriptor */
  my_seek(fd1, 0, MY_SEEK_SET, MYF(0));
  my_read(fd1, buf, 4, MYF(MY_NABP));
  check("fd1 read at its position", memcmp(buf, "AAAA", 4) == 0, NULL);
  check("fd2 seek to end", my_seek(fd2, 0, MY_SEEK_END, MYF(0)) == 32768, NULL);
  my_write(fd2, (uchar *) "tail", 4, MYF(MY_NABP));
  check("fd1 position unchanged", my_tell(fd1, MYF(0)) == 4, NULL);
  snprintf(d, sizeof d, "fd1 %llu fd2 %llu", (ulonglong) fsize(fd1), (ulonglong) fsize(fd2));
  check("my_fstat size after append, no fsync", fsize(fd1) == 32772 && fsize(fd2) == 32772, d);
  check("my_stat size of open file",
        my_stat(path, &st, MYF(0)) && st.st_size == 32772, NULL);

  /* O_APPEND */
  fd3= my_open(path, O_WRONLY | O_APPEND, MYF(MY_WME));
  my_write(fd3, (uchar *) "app", 3, MYF(MY_NABP));
  my_pread(fd1, buf, 3, 32772, MYF(MY_NABP));
  check("O_APPEND write lands at the end", memcmp(buf, "app", 3) == 0 && fsize(fd1) == 32775, NULL);

  /* threads */
  for (i= 0; i < NTHREADS; i++)
    tfd[i]= my_open(path, O_RDWR, MYF(MY_WME));
  for (i= 0; i < NTHREADS; i++)
    pthread_create(&th[i], NULL, worker, (void *) (intptr_t) i);
  for (i= 0; i < NTHREADS; i++)
    pthread_join(th[i], NULL);
  for (i= 0; i < NTHREADS; i++)
    my_close(tfd[i], MYF(0));
  check("4 threads, 4 descriptors, no torn blocks",
        !terr[0] && !terr[1] && !terr[2] && !terr[3], NULL);
  check("last round visible to fd1", at(fd1, 5 * 512) == 'a' + (19 + 5) % 26, NULL);

  /* O_TRUNC while open elsewhere */
  fd4= my_open(path, O_RDWR | O_TRUNC, MYF(MY_WME));
  snprintf(d, sizeof d, "fd1 sees %llu", (ulonglong) fsize(fd1));
  check("O_TRUNC through another descriptor", fd4 >= 0 && fsize(fd1) == 0, d);
  my_write(fd4, (uchar *) "fresh", 5, MYF(MY_NABP));
  check("fd1 reads data written after truncate", at(fd1, 0) == 'f', NULL);

  /* reads past the end must not lengthen the file (C RTL quirk) */
  {
    uchar x;
    check("pread past EOF returns 0", my_pread(fd1, &x, 1, 1000, MYF(0)) == 0, NULL);
  }
  my_close(fd4, MYF(0));
  my_close(fd3, MYF(0));
  my_close(fd2, MYF(0));
  my_close(fd1, MYF(0));
  {
    MY_STAT cs;
    snprintf(d, sizeof d, "closed file: stat size %lld",
             my_stat(path, &cs, MYF(0)) ? (long long) cs.st_size : -1LL);
    check("closed file size (plain stat)", cs.st_size == 5, d);
  }
  fd1= my_open(path, O_RDONLY, MYF(MY_WME));
  snprintf(d, sizeof d, "size %llu byte4 %c", (ulonglong) fsize(fd1), at(fd1, 4));
  check("persisted after close", fd1 >= 0 && fsize(fd1) == 5 && at(fd1, 4) == 'h', d);
  my_close(fd1, MYF(0));
  my_delete(path, MYF(0));
  check("deleted", !my_stat(path, &st, MYF(0)), NULL);

  /*
    Durability: after my_sync(), the file header's end of file must stay
    right when another descriptor of the file is closed (plain stat() reads
    the header; a crash at that point would leave the file at that size).
  */
  {
    struct stat raw;
    File keep, early, w;
    my_delete(path, MYF(0));
    keep= my_open(path, O_RDWR | O_CREAT, MYF(MY_WME));
    early= my_open(path, O_RDWR, MYF(MY_WME));     /* opened while empty */
    w= my_open(path, O_RDWR, MYF(MY_WME));
    my_pwrite(w, big, sizeof big, 0, MYF(MY_NABP));
    my_sync(w, MYF(0));
    stat(path, &raw);
    snprintf(d, sizeof d, "header size %lld", (long long) raw.st_size);
    check("header size after my_sync", raw.st_size == (off_t) sizeof big, d);
    my_close(early, MYF(0));
    stat(path, &raw);
    snprintf(d, sizeof d, "header size %lld", (long long) raw.st_size);
    check("header size after closing another fd", raw.st_size == (off_t) sizeof big, d);
    my_close(w, MYF(0));
    my_close(keep, MYF(0));
    my_delete(path, MYF(0));
  }
  printf("VMSFILE_TEST: %d passed, %d failed\n", passed, failed);
  my_end(0);
  return failed != 0;
}
