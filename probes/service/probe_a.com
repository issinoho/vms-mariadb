$! PROBE_A.COM - batch job submitted /USER=MDBPROBE: report the job's own
$! identity, then start a detached process the way VMSMARIADB$SERVER START does.
$ set noon
$ dir = f$parse(f$environment("PROCEDURE"),,,"DEVICE") + f$parse(f$environment("PROCEDURE"),,,"DIRECTORY")
$ write sys$output "BATCH username=", f$edit(f$getjpi("","USERNAME"),"TRIM"), " uic=", f$getjpi("","UIC"), -
    " pgflquota=", f$getjpi("","PGFLQUOTA"), " fillm=", f$getjpi("","FILLM")
$ run/detached/authorize/process_name="MDBPROBE_A"/input='dir'PROBE_RUN.COM -
    /output='dir'A_DET.TXT/error='dir'A_DET.TXT SYS$SYSTEM:LOGINOUT.EXE
$ write sys$output "BATCH run status ", $status
