$! inner.com - stands in for a long build: ~40 s busy wait (no WAIT: it hangs over ssh).
$ until = f$cvtime("+0-00:00:40.00")
$loop:
$ if f$cvtime() .lts. until then goto loop
$ write sys$output "INNER-END"
