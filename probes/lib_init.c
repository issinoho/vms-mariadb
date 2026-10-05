/* lib_init.c - can clang code run a LIB$INITIALIZE routine that sets DECC$
   features before main() (and before argv is parsed)? */
#include <stdio.h>
#include <unixlib.h>

static void set_features(void)
{
  int i;
  static const char *names[] = { "DECC$EFS_CHARSET", "DECC$FILE_SHARING",
                                 "DECC$FD_LOCKING", "DECC$ARGV_PARSE_STYLE", NULL };
  for (i = 0; names[i]; i++) {
    int idx = decc$feature_get_index(names[i]);
    if (idx >= 0) decc$feature_set_value(idx, 1, 1);
  }
}

#pragma extern_model save
#pragma extern_model strict_refdef "LIB$INITIALIZE" nopic, con, rel, gbl, noshr, noexe, nowrt, novec, long
extern void (*const vms_lib_init)(void) = set_features;
#pragma extern_model restore
int LIB$INITIALIZE(void);
int (*vms_lib_init_ref)(void) = LIB$INITIALIZE;

int main(int argc, char **argv)
{
  printf("LIBINIT EFS_CHARSET=%d FILE_SHARING=%d FD_LOCKING=%d ARGV_PARSE_STYLE=%d argv[1]=%s\n",
         decc$feature_get_value(decc$feature_get_index("DECC$EFS_CHARSET"), 1),
         decc$feature_get_value(decc$feature_get_index("DECC$FILE_SHARING"), 1),
         decc$feature_get_value(decc$feature_get_index("DECC$FD_LOCKING"), 1),
         decc$feature_get_value(decc$feature_get_index("DECC$ARGV_PARSE_STYLE"), 1),
         argc > 1 ? argv[1] : "-");
  return 0;
}
