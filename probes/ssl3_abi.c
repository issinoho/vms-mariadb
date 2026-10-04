/* ssl3_abi.c - can clang (LP64) code call VSI's SSL3 (OpenSSL 3.0) images?
   SSL3 is built by VSI; if it was built with a 32-bit 'long', values returned
   as long / unsigned long (ERR_get_error, BIO_ctrl, SSL_CTX_ctrl) and structs
   holding them would come back wrong.  Link with SSL3$LIBSSL_SHR and
   SSL3$LIBCRYPTO_SHR (64-bit pointer images). */
#include <stdio.h>
#include <string.h>
#include <openssl/opensslv.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>

int main(void)
{
  unsigned char md[EVP_MAX_MD_SIZE];
  unsigned int mdlen = 0;
  unsigned long e;
  long r;
  char ebuf[256];
  BIO *b;
  SSL_CTX *ctx;
  BIGNUM *bn;

  printf("SSL3 header version %s, OPENSSL_VERSION_NUMBER %#lx\n", OPENSSL_VERSION_TEXT,
         (unsigned long) OPENSSL_VERSION_NUMBER);
  printf("SSL3 OpenSSL_version_num() %#lx\n", (unsigned long) OpenSSL_version_num());
  printf("SSL3 OpenSSL_version() %s\n", OpenSSL_version(OPENSSL_VERSION));
  printf("SSL3 sizeof long %u, BN_ULONG %u\n", (unsigned) sizeof(long), (unsigned) sizeof(BN_ULONG));

  EVP_Digest("abc", 3, md, &mdlen, EVP_sha256(), NULL);
  printf("SSL3 sha256(abc) len %u %02x%02x%02x%02x (expect ba7816bf)\n", mdlen, md[0], md[1], md[2], md[3]);

  /* An error code: ERR_get_error returns unsigned long. */
  ERR_clear_error();
  b = BIO_new_file("no/such/file.pem", "r");
  e = ERR_get_error();
  ERR_error_string_n(e, ebuf, sizeof ebuf);
  printf("SSL3 ERR_get_error %#lx lib %d reason %d: %s\n", e, ERR_GET_LIB(e), ERR_GET_REASON(e), ebuf);
  if (b) BIO_free(b);

  /* BIO_ctrl returns long; BIO_get_fd on a memory BIO is -1. */
  b = BIO_new(BIO_s_mem());
  r = BIO_ctrl(b, BIO_C_GET_FD, 0, NULL);
  printf("SSL3 BIO_ctrl(mem, GET_FD) %ld (expect -1)\n", r);
  BIO_write(b, "hello", 5);
  r = BIO_ctrl(b, BIO_CTRL_PENDING, 0, NULL);
  printf("SSL3 BIO_ctrl(mem, PENDING) %ld (expect 5)\n", r);
  BIO_free(b);

  /* SSL_CTX_ctrl returns long; options are uint64_t in 3.0. */
  ctx = SSL_CTX_new(TLS_client_method());
  r = SSL_CTX_set_timeout(ctx, 3000000000L);
  r = SSL_CTX_get_timeout(ctx);
  printf("SSL3 SSL_CTX timeout %ld (expect 3000000000)\n", r);
  r = SSL_CTX_ctrl(ctx, SSL_CTRL_GET_MAX_PROTO_VERSION, 0, NULL);
  printf("SSL3 SSL_CTX_ctrl(GET_MAX_PROTO) %ld (expect 0)\n", r);
  r = SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  printf("SSL3 set_min_proto_version %ld min %ld\n", r, SSL_CTX_get_min_proto_version(ctx));
  printf("SSL3 SSL_CTX_get_options %#llx\n", (unsigned long long) SSL_CTX_get_options(ctx));
  SSL_CTX_free(ctx);

  bn = BN_new();
  BN_set_word(bn, 0xFFFFFFFFUL);
  BN_add_word(bn, 1);
  printf("SSL3 BN 2^32 = %s, BN_get_word %#lx\n", BN_bn2hex(bn), (unsigned long) BN_get_word(bn));
  BN_free(bn);

  r = RAND_bytes(md, 16);
  printf("SSL3 RAND_bytes %ld\n", r);
  printf("SSL3_ABI DONE\n");
  return 0;
}
