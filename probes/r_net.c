/* r_net.c - socket behaviour needed by vio/ and the server's listener. */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <poll.h>
#include <sys/un.h>

static void say(const char *what, int ok, const char *detail)
{
  printf("NET %-34s %s %s\n", what, ok ? "yes" : "NO ", detail ? detail : "");
}

static char errbuf[200];
static const char *err(void)
{
  snprintf(errbuf, sizeof errbuf, "errno=%d (%s)", errno, strerror(errno));
  return errbuf;
}

int main(void)
{
  int ls, cs, as, r, one = 1;
  struct sockaddr_in sa;
  socklen_t len = sizeof sa;
  struct pollfd pfd;
  char buf[64];

  ls = socket(AF_INET, SOCK_STREAM, 0);
  r = setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (char *) &one, sizeof one);
  say("SO_REUSEADDR", r == 0, r ? err() : NULL);
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  sa.sin_port = 0;
  r = bind(ls, (struct sockaddr *) &sa, sizeof sa);
  say("bind 127.0.0.1:0", r == 0, r ? err() : NULL);
  listen(ls, 16);
  getsockname(ls, (struct sockaddr *) &sa, &len);

  r = fcntl(ls, F_SETFL, fcntl(ls, F_GETFL) | O_NONBLOCK);
  say("fcntl O_NONBLOCK on socket", r == 0, r ? err() : NULL);
  as = accept(ls, NULL, NULL);
  say("non-blocking accept -> EWOULDBLOCK", as < 0 && (errno == EWOULDBLOCK || errno == EAGAIN), as < 0 ? err() : "accepted?");

  cs = socket(AF_INET, SOCK_STREAM, 0);
  fcntl(cs, F_SETFL, fcntl(cs, F_GETFL) | O_NONBLOCK);
  r = connect(cs, (struct sockaddr *) &sa, sizeof sa);
  say("non-blocking connect", r == 0 || errno == EINPROGRESS, r ? err() : NULL);

  pfd.fd = ls; pfd.events = POLLIN; pfd.revents = 0;
  r = poll(&pfd, 1, 5000);
  say("poll() on listening socket", r == 1 && (pfd.revents & POLLIN), r < 0 ? err() : NULL);
  as = accept(ls, NULL, NULL);
  say("accept after poll", as >= 0, as < 0 ? err() : NULL);

  pfd.fd = cs; pfd.events = POLLOUT; pfd.revents = 0;
  r = poll(&pfd, 1, 5000);
  say("poll() POLLOUT on connecting socket", r == 1, r < 0 ? err() : NULL);
  fcntl(cs, F_SETFL, fcntl(cs, F_GETFL) & ~O_NONBLOCK);
  r = setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, (char *) &one, sizeof one);
  say("TCP_NODELAY", r == 0, r ? err() : NULL);
  r = setsockopt(cs, SOL_SOCKET, SO_KEEPALIVE, (char *) &one, sizeof one);
  say("SO_KEEPALIVE", r == 0, r ? err() : NULL);
  {
    struct timeval tv = { 2, 0 };
    r = setsockopt(as, SOL_SOCKET, SO_RCVTIMEO, (char *) &tv, sizeof tv);
    say("SO_RCVTIMEO", r == 0, r ? err() : NULL);
  }
  r = (int) send(cs, "hello", 5, 0);
  pfd.fd = as; pfd.events = POLLIN; pfd.revents = 0;
  poll(&pfd, 1, 5000);
  r = (int) recv(as, buf, sizeof buf, 0);
  say("send/recv", r == 5 && memcmp(buf, "hello", 5) == 0, r < 0 ? err() : NULL);
  r = (int) recv(as, buf, sizeof buf, MSG_PEEK | MSG_DONTWAIT);
  say("MSG_DONTWAIT on empty socket", r < 0 && (errno == EWOULDBLOCK || errno == EAGAIN), r >= 0 ? "returned data" : err());
  shutdown(cs, SHUT_RDWR);
  close(cs);
  r = (int) recv(as, buf, sizeof buf, 0);
  say("recv after peer close returns 0", r == 0, r < 0 ? err() : NULL);
  close(as);
  close(ls);

  {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    r = getaddrinfo("localhost", "3306", &hints, &res);
    say("getaddrinfo localhost", r == 0, r ? gai_strerror(r) : NULL);
    if (res) freeaddrinfo(res);
    hints.ai_flags = AI_PASSIVE;
    r = getaddrinfo(NULL, "3306", &hints, &res);
    say("getaddrinfo passive", r == 0, r ? gai_strerror(r) : NULL);
    if (res) freeaddrinfo(res);
  }
  {
    int s6 = socket(AF_INET6, SOCK_STREAM, 0);
    say("AF_INET6 socket", s6 >= 0, s6 < 0 ? err() : NULL);
#ifdef IPV6_V6ONLY
    if (s6 >= 0) {
      int zero = 0;
      r = setsockopt(s6, IPPROTO_IPV6, IPV6_V6ONLY, (char *) &zero, sizeof zero);
      say("IPV6_V6ONLY=0 (dual stack)", r == 0, r ? err() : NULL);
    }
#endif
    if (s6 >= 0) close(s6);
  }
  {
    int us = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un su;
    say("AF_UNIX socket", us >= 0, us < 0 ? err() : NULL);
    if (us >= 0) {
      memset(&su, 0, sizeof su);
      su.sun_family = AF_UNIX;
      strcpy(su.sun_path, "netprobe.sock");
      unlink(su.sun_path);
      r = bind(us, (struct sockaddr *) &su, sizeof su);
      say("AF_UNIX bind", r == 0, r ? err() : NULL);
      close(us);
      unlink(su.sun_path);
    }
    {
      int sv[2];
      r = socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
      say("socketpair", r == 0, r ? err() : NULL);
    }
  }
  printf("R_NET DONE\n");
  return 0;
}
