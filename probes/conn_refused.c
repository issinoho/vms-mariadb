/* conn_refused.c - for a refused connection to a closed loopback port, does a
   non-blocking connect() (Connector/C's pvio_socket_internal_connect) fail at
   once with ECONNREFUSED, or with EINPROGRESS and the refusal only from
   getsockopt(SO_ERROR)?  Only in the second case does a clienttest case on
   such a port exercise patch 0028.  Usage: run conn_refused [port] (default 1). */
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv)
{
  struct sockaddr_in sa;
  struct pollfd p;
  int s, r, e, inprogress, error = 0;
  socklen_t len = sizeof error;

  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_port = htons(argc > 1 ? atoi(argv[1]) : 1);
  sa.sin_addr.s_addr = inet_addr("127.0.0.1");
  s = socket(AF_INET, SOCK_STREAM, 0);
  fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
  r = connect(s, (struct sockaddr *) &sa, sizeof sa);
  e = errno;
  inprogress = r < 0 && e == EINPROGRESS;
  printf("CONN connect: %d errno=%d (%s); EINPROGRESS=%d ECONNREFUSED=%d\n",
         r, e, strerror(e), EINPROGRESS, ECONNREFUSED);
  if (inprogress)
  {
    p.fd = s; p.events = POLLOUT; p.revents = 0;
    r = poll(&p, 1, 5000);
    getsockopt(s, SOL_SOCKET, SO_ERROR, (char *) &error, &len);
    printf("CONN poll: %d revents=%#x SO_ERROR=%d (%s)\n", r, p.revents, error,
           strerror(error));
  }
  printf("CONN result: %s\n", inprogress ? "EINPROGRESS path" :
         e == ECONNREFUSED ? "refused at once" : "other");
  close(s);
  return 0;
}
