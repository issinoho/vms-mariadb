/* poll_wake.c - mariadbd's shutdown wake-up: the main thread sits in
   poll(-1) on a listening socket and the read end of a pipe (or socketpair);
   another thread writes the other end.  Does poll() return? */
#include <errno.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>

static int wfd;
static void *writer(void *arg)
{
  char c= 'x';
  (void) arg;
  sleep(2);
  printf("WAKE writer: write()=%d\n", (int) write(wfd, &c, 1));
  fflush(stdout);
  return NULL;
}

static void trial(const char *what, int use_pipe)
{
  int ls, other[2], r;
  struct sockaddr_in sa;
  struct pollfd p[2];
  pthread_t th;
  time_t t0;
  ls= socket(AF_INET, SOCK_STREAM, 0);
  memset(&sa, 0, sizeof sa);
  sa.sin_family= AF_INET; sa.sin_addr.s_addr= htonl(INADDR_LOOPBACK);
  bind(ls, (struct sockaddr *) &sa, sizeof sa); listen(ls, 5);
  fcntl(ls, F_SETFL, O_NONBLOCK);
  if (use_pipe ? pipe(other) : socketpair(AF_UNIX, SOCK_STREAM, 0, other)) return;
  wfd= other[1];
  p[0].fd= ls; p[0].events= POLLIN; p[0].revents= 0;
  p[1].fd= other[0]; p[1].events= POLLIN; p[1].revents= 0;
  pthread_create(&th, NULL, writer, NULL);
  t0= time(NULL);
  r= poll(p, 2, 15000);           /* mariadbd uses -1; 15 s bounds the probe */
  printf("WAKE %-11s poll=%d after %ds, wake-end revents=%#x %s\n", what, r,
         (int) (time(NULL) - t0), p[1].revents, r == 1 && (p[1].revents & POLLIN) ? "OK" : "NOT WOKEN");
  fflush(stdout);
  pthread_join(th, NULL);
  close(ls); close(other[0]); close(other[1]);
}

int main(void)
{
  trial("pipe", 1);
  trial("socketpair", 0);
  return 0;
}
