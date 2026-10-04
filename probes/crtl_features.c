/* crtl_features.c - list every DECC$ feature the C RTL knows, with its
   current value and range (decc$feature_get_index & co, <unixlib.h>). */
#include <stdio.h>
#include <unixlib.h>

int main(void)
{
  int i;
  for (i = 0; i < 1000; i++) {
    char *name = decc$feature_get_name(i);
    if (name == NULL)
      break;
    printf("FEATURE %-40s value=%d default=%d min=%d max=%d\n", name,
           decc$feature_get_value(i, 1), decc$feature_get_value(i, 0),
           decc$feature_get_value(i, 2), decc$feature_get_value(i, 3));
  }
  printf("CRTL_FEATURES DONE (%d)\n", i);
  return 0;
}
