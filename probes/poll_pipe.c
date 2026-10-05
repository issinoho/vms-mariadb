/* poll_pipe.c - does poll() see a listening socket become readable when the
   set also holds a pipe (mariadbd's termination pipe) or a socketpair end? */
#include <errno.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>

static void trial(const char *what, int use_pipe)
{
  int ls, cs, other[2], r;
  struct sockaddr_in sa;
  socklen_t len= sizeof sa;
  struct pollfd p[2];
  ls= socket(AF_INET, SOCK_STREAM, 0);
  memset(&sa, 0, sizeof sa);
  sa.sin_family= AF_INET; sa.sin_addr.s_addr= htonl(INADDR_LOOPBACK);
  bind(ls, (struct sockaddr *) &sa, sizeof sa); listen(ls, 5);
  getsockname(ls, (struct sockaddr *) &sa, &len);
  fcntl(ls, F_SETFL, O_NONBLOCK);
  r= use_pipe ? pipe(other) : socketpair(AF_UNIX, SOCK_STREAM, 0, other);
  if (r) { printf("POLL %-12s create failed: %s\n", what, strerror(errno)); return; }
  cs= socket(AF_INET, SOCK_STREAM, 0);
  connect(cs, (struct sockaddr *) &sa, sizeof sa);
  p[0].fd= ls; p[0].events= POLLIN; p[0].revents= 0;
  p[1].fd= other[0]; p[1].events= POLLIN; p[1].revents= 0;
  r= poll(p, 2, 3000);
  printf("POLL %-12s connect pending: poll=%d errno=%d listen.revents=%#x other.revents=%#x %s\n",
         what, r, r < 0 ? errno : 0, p[0].revents, p[1].revents,
         r == 1 && (p[0].revents & POLLIN) ? "OK" : "BROKEN");
  { char c= 'x'; write(other[1], &c, 1); }
  p[0].revents= p[1].revents= 0;
  r= poll(p + 1, 1, 3000);
  printf("POLL %-12s wake-up write: poll=%d revents=%#x %s\n", what, r, p[1].revents,
         r == 1 && (p[1].revents & POLLIN) ? "OK" : "BROKEN");
  close(cs); close(ls); close(other[0]); close(other[1]);
}

int main(void)
{
  trial("pipe", 1);
  trial("socketpair", 0);
  return 0;
}
