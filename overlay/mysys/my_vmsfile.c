/* Copyright (c) 2026, the vms-mariadb contributors.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; version 2 of the License.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335  USA */

/*
  File I/O for mysys on OpenVMS (the counterpart of my_winfile.cc).

  The OpenVMS C RTL buffers file data per descriptor.  A descriptor that
  has written a block keeps serving that block from its own buffer, so it
  never sees what is later written to the same file through another
  descriptor, whatever open() options or DECC$ features are used
  (vms-mariadb docs/DECISIONS.md, D10).  MariaDB's engines open the same
  file several times (MyISAM once per table instance, for example) and
  expect POSIX semantics.

  So mysys keeps one internal "master" descriptor per file, found by
  (st_dev, st_ino), and does all data I/O for every descriptor of that file
  through it with pread()/pwrite(): one buffer per file, coherent within
  the process.  Each descriptor returned by my_open() is still a real C RTL
  descriptor, but a read-only one whatever the caller asked for: closing a
  writable channel writes that channel's (stale) idea of the end of file
  into the file header, which would undo what the master has synced.  So
  fcntl() write locks on these descriptors fail (external locking is not
  supported).  The position of each descriptor is kept here, so
  read()/write()/lseek() keep their meaning, including O_APPEND.

  The file size is kept here too, because the C RTL's own idea of it is
  unreliable: fstat()'s st_size lags behind writes until fsync() or close(),
  lseek(SEEK_END) still reports the old size after ftruncate(), and a
  pread() past the end of file, although it returns 0, moves the end of file
  to that offset when the file is closed (probes in vms-mariadb, D10).  So
  reads are clamped at the size kept here, and SEEK_END, fstat() and stat()
  report it.
  Descriptors not opened through my_vms_open() (mkstemp() temporary files,
  stdio) are passed through to the C RTL unchanged.

  Other processes do not share the master: tools such as aria_chk must not
  work on the files of a running server, which is already the rule when
  external locking is off.  The process must run with DECC$FILE_SHARING
  (two opens of one file) and DECC$FD_LOCKING (several threads on one
  master descriptor); mariadbd sets both at image start-up.
*/

#include "mysys_priv.h"

#ifdef __VMS
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>

typedef struct vms_file
{
  dev_t dev;
  ino_t ino;
  int master;                   /* descriptor all data I/O goes through */
  int refs;                     /* my_vms_open() descriptors of this file */
  my_off_t size;                /* the real end of file */
  pthread_mutex_t lock;         /* size updates; atomic O_APPEND writes */
  struct vms_file *next;
} VMS_FILE;

typedef struct
{
  VMS_FILE *file;               /* NULL: not shared, plain C RTL calls */
  my_off_t pos;
  int append;
} VMS_FD;

#define VMS_MAX_FD 65536        /* larger descriptors are not shared */
#define VMS_BUCKETS 1024

static VMS_FD *vms_fds;
static VMS_FILE *vms_buckets[VMS_BUCKETS];
/* Static storage: PTHREAD_MUTEX_INITIALIZER is fine here (not on a stack). */
static pthread_mutex_t vms_lock= PTHREAD_MUTEX_INITIALIZER;

static VMS_FD *fd_entry(File fd)
{
  if (fd < 0 || fd >= VMS_MAX_FD || !vms_fds || !vms_fds[fd].file)
    return NULL;
  return &vms_fds[fd];
}

static VMS_FILE **bucket(dev_t dev, ino_t ino)
{
  return &vms_buckets[(size_t) ((ino ^ dev) % VMS_BUCKETS)];
}

/* After a write of n bytes at offset: grow the size if the write did. */
static void grew(VMS_FILE *f, my_off_t offset, ssize_t n)
{
  if (n > 0)
  {
    pthread_mutex_lock(&f->lock);
    if (offset + (my_off_t) n > f->size)
      f->size= offset + (my_off_t) n;
    pthread_mutex_unlock(&f->lock);
  }
}

/*
  pread() through the master, never past the end of file: such a read
  would move the C RTL's end of file (see above).
*/
static ssize_t clamped_pread(VMS_FILE *f, uchar *buffer, size_t count,
                             my_off_t offset)
{
  my_off_t size= f->size;
  if (offset >= size)
    return 0;
  if (count > size - offset)
    count= (size_t) (size - offset);
  return pread(f->master, buffer, count, (off_t) offset);
}


File my_vms_open(const char *path, int oflag, int mode)
{
  int fd, master, truncate_it= 0, fd_unshared= 0;
  struct stat st;
  VMS_FILE *f, **b;

  /*
    O_TRUNC on an existing file makes a new version of it on VMS, and a
    master already open on the file would be left on the old version.
    Truncate through the master instead.
  */
  if ((oflag & O_TRUNC) && !(oflag & O_EXCL))
  {
    oflag&= ~O_TRUNC;
    truncate_it= 1;
  }
  if ((fd= open(path, oflag, mode)) < 0)
    return fd;
  /*
    The caller's descriptor never does I/O: make it a read-only channel, so
    that closing it cannot rewrite the end of file in the file header.
  */
  if (fd < VMS_MAX_FD && (oflag & O_ACCMODE) != O_RDONLY &&
      !fstat(fd, &st) && S_ISREG(st.st_mode))
  {
    int ro= open(path, O_RDONLY);
    if (ro < 0 || dup2(ro, fd) < 0)
      fd_unshared= 1;
    if (ro >= 0)
      close(ro);
  }
  if (fd_unshared || fd >= VMS_MAX_FD || fstat(fd, &st) || !S_ISREG(st.st_mode))
  {
    if (truncate_it && ftruncate(fd, 0))
    {
      int save= errno;
      close(fd);
      errno= save;
      return -1;
    }
    return fd;
  }

  pthread_mutex_lock(&vms_lock);
  if (!vms_fds &&
      !(vms_fds= (VMS_FD *) calloc(VMS_MAX_FD, sizeof(VMS_FD))))
  {
    pthread_mutex_unlock(&vms_lock);
    return fd;                          /* unshared, as without this layer */
  }
  b= bucket(st.st_dev, st.st_ino);
  for (f= *b; f; f= f->next)
    if (f->dev == st.st_dev && f->ino == st.st_ino)
      break;
  if (!f)
  {
    if ((master= open(path, O_RDWR)) < 0 &&
        (master= open(path, O_RDONLY)) < 0)
    {
      pthread_mutex_unlock(&vms_lock);
      return fd;                        /* unshared */
    }
    if (!(f= (VMS_FILE *) calloc(1, sizeof(*f))))
    {
      close(master);
      pthread_mutex_unlock(&vms_lock);
      return fd;
    }
    f->dev= st.st_dev;
    f->ino= st.st_ino;
    f->master= master;
    /* Freshly opened, the C RTL's end of file is the file header's. */
    f->size= (my_off_t) lseek(master, 0, SEEK_END);
    pthread_mutex_init(&f->lock, NULL);
    f->next= *b;
    *b= f;
  }
  f->refs++;
  vms_fds[fd].file= f;
  vms_fds[fd].pos= 0;
  vms_fds[fd].append= (oflag & O_APPEND) != 0;
  pthread_mutex_unlock(&vms_lock);

  if (truncate_it && my_vms_chsize(fd, 0))
  {
    int save= errno;
    my_vms_close(fd);
    errno= save;
    return -1;
  }
  return fd;
}


int my_vms_close(File fd)
{
  VMS_FD *e;
  VMS_FILE *f, *last= NULL, **p;
  int err;

  pthread_mutex_lock(&vms_lock);
  if ((e= fd_entry(fd)))
  {
    f= e->file;
    e->file= NULL;
    if (--f->refs == 0)
    {
      for (p= bucket(f->dev, f->ino); *p != f; p= &(*p)->next) ;
      *p= f->next;
      last= f;
    }
  }
  pthread_mutex_unlock(&vms_lock);
  err= close(fd);
  /*
    The master closes after the caller's descriptor: the channel closed last
    writes its idea of the end of file into the file header, and only the
    master's is right.
  */
  if (last)
  {
    if (close(last->master))
      err= -1;
    pthread_mutex_destroy(&last->lock);
    free(last);
  }
  return err ? -1 : 0;
}


size_t my_vms_pread(File fd, uchar *buffer, size_t count, my_off_t offset)
{
  VMS_FD *e= fd_entry(fd);
  if (!e)
    return (size_t) pread(fd, buffer, count, (off_t) offset);
  return (size_t) clamped_pread(e->file, buffer, count, offset);
}


size_t my_vms_pwrite(File fd, const uchar *buffer, size_t count, my_off_t offset)
{
  VMS_FD *e= fd_entry(fd);
  ssize_t n;
  if (!e)
    return (size_t) pwrite(fd, buffer, count, (off_t) offset);
  n= pwrite(e->file->master, buffer, count, (off_t) offset);
  grew(e->file, offset, n);
  return (size_t) n;
}


size_t my_vms_read(File fd, uchar *buffer, size_t count)
{
  VMS_FD *e= fd_entry(fd);
  ssize_t n;
  if (!e)
    return (size_t) read(fd, buffer, count);
  if ((n= clamped_pread(e->file, buffer, count, e->pos)) > 0)
    e->pos+= n;
  return (size_t) n;
}


size_t my_vms_write(File fd, const uchar *buffer, size_t count)
{
  VMS_FD *e= fd_entry(fd);
  ssize_t n;
  if (!e)
    return (size_t) write(fd, buffer, count);
  if (e->append)
  {
    VMS_FILE *f= e->file;
    pthread_mutex_lock(&f->lock);
    e->pos= f->size;
    if ((n= pwrite(f->master, buffer, count, (off_t) e->pos)) > 0)
      f->size= e->pos + (my_off_t) n;
    pthread_mutex_unlock(&f->lock);
  }
  else
  {
    n= pwrite(e->file->master, buffer, count, (off_t) e->pos);
    grew(e->file, e->pos, n);
  }
  if (n > 0)
    e->pos+= n;
  return (size_t) n;
}


my_off_t my_vms_lseek(File fd, my_off_t pos, int whence)
{
  VMS_FD *e= fd_entry(fd);
  longlong newpos;
  if (!e)
    return (my_off_t) lseek(fd, (off_t) pos, whence);
  switch (whence) {
  case SEEK_SET: newpos= (longlong) pos; break;
  case SEEK_CUR: newpos= (longlong) e->pos + (longlong) pos; break;
  case SEEK_END: newpos= (longlong) e->file->size + (longlong) pos; break;
  default:
    errno= EINVAL;
    return (my_off_t) -1;
  }
  if (newpos < 0)
  {
    errno= EINVAL;
    return (my_off_t) -1;
  }
  return e->pos= (my_off_t) newpos;
}


int my_vms_fsync(File fd)
{
  VMS_FD *e= fd_entry(fd);
  return fsync(e ? e->file->master : fd);
}


int my_vms_chsize(File fd, my_off_t newlength)
{
  VMS_FD *e= fd_entry(fd);
  VMS_FILE *f;
  int r;
  if (!e)
    return ftruncate(fd, (off_t) newlength);
  f= e->file;
  pthread_mutex_lock(&f->lock);
  /*
    Flush first: ftruncate() leaves dirty buffered blocks past the new end
    in place, and close() would write them back, extending the file again.
  */
  if (!(r= fsync(f->master)) && !(r= ftruncate(f->master, (off_t) newlength)))
    f->size= newlength;
  pthread_mutex_unlock(&f->lock);
  return r;
}


/* fstat(), with the size kept here. */
int my_vms_fstat(File fd, struct stat *buf)
{
  VMS_FD *e= fd_entry(fd);
  if (fstat(fd, buf))
    return -1;
  if (e)
    buf->st_size= (off_t) e->file->size;
  return 0;
}


/*
  stat(): if the file is open through this layer, its st_size in the file
  header may be stale; report the size kept here.
*/
int my_vms_stat(const char *path, struct stat *buf)
{
  VMS_FILE *f;
  if (stat(path, buf))
    return -1;
  pthread_mutex_lock(&vms_lock);
  for (f= *bucket(buf->st_dev, buf->st_ino); f; f= f->next)
    if (f->dev == buf->st_dev && f->ino == buf->st_ino)
    {
      buf->st_size= (off_t) f->size;
      break;
    }
  pthread_mutex_unlock(&vms_lock);
  return 0;
}

#endif /* __VMS */
