$! outer.com - stands in for vms.sh's wrapper: runs inner.com, then writes a marker.
$ set noon
$ write sys$output "OUTER-START"
$ proc = f$environment("PROCEDURE")
$ here = f$parse(proc,,,"DEVICE") + f$parse(proc,,,"DIRECTORY")
$ @'here'inner.com
$ write sys$output "OUTER-AFTER-INNER"
$ open/write m 'here'sd_outer.done
$ close m
