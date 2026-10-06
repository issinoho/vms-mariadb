$! PROBE_RUN.COM - input of the probe's detached processes: report who we are
$! and which quotas we got, then log out.
$ set noon
$ write sys$output "PROBE username=", f$edit(f$getjpi("","USERNAME"),"TRIM"), " uic=", f$getjpi("","UIC"), -
    " mode=", f$getjpi("","MODE"), " prcnam=", f$getjpi("","PRCNAM")
$ write sys$output "PROBE pgflquota=", f$getjpi("","PGFLQUOTA"), " fillm=", f$getjpi("","FILLM"), -
    " diolm=", f$getjpi("","DIOLM"), " biolm=", f$getjpi("","BIOLM"), " astlm=", f$getjpi("","ASTLM")
$ privs = f$getjpi("","CURPRIV")
$ write sys$output "PROBE privileges: ", f$length(privs), " chars; SETPRV ", -
    f$locate("SETPRV", privs) .lt. f$length(privs), " CMKRNL ", f$locate("CMKRNL", privs) .lt. f$length(privs), -
    " TMPMBX ", f$locate("TMPMBX", privs) .lt. f$length(privs)
$ logout
