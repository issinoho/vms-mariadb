$! VMSMARIADB$CONFIGURE.COM - set up the MariaDB server (vms-mariadb) as a
$! service: its own account, a data directory, boot start and clean shutdown
$!
$! Run once by the system manager, after PRODUCT INSTALL VMSMARIADB:
$!
$!     $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$CONFIGURE
$!
$! It asks for the data directory, the port, the account and its UIC, and
$! root's password, shows the AUTHORIZE commands for the account and, once
$! confirmed:
$!   - adds the account (batch access only, privileges TMPMBX and NETMBX,
$!     quotas for a server), unless it exists already;
$!   - creates the data directory with the system tables (or keeps an
$!     existing one), sets root's password (new data directories only),
$!     creates the SHUTDOWN-only account vmsmariadb_shutdown with a random
$!     password kept in <datadir>VMSMARIADB$SHUTDOWN.CNF, and gives the
$!     data directory to the account;
$!   - writes the site file SYS$MANAGER:VMSMARIADB$CONFIG.COM;
$!   - prints the lines for SYSTARTUP_VMS.COM and SYSHUTDWN.COM.
$!
$! Parameters (each one not given is asked for, with a default):
$!   P1  data directory, on an ODS-5 disk, at least two levels deep:
$!       dev:[MARIADB.DATA] (its parent, dev:[MARIADB], is the account's
$!       login directory; dev:[MARIADB.DATA_TMP] is the server's tmpdir)
$!   P2  port (3306)
$!   P3  account (MARIADB)
$!   P4  UIC of a new account ([360,1], or the next free group)
$!   P5  options, comma-separated: NOCONFIRM (ask nothing; root's password
$!       then comes from the logical name VMSMARIADB$CONFIGURE_ROOTPW),
$!       NOAUTOSTART (STARTUP START will not start the server)
$! The logical name VMSMARIADB$CONFIG names another site file.
$!
$! Needs SYSPRV, CMKRNL and WORLD.
$!
$ set noon
$ say = "write sys$output"
$ status = 44
$ saved_privs = f$setprv("SYSPRV,CMKRNL,WORLD")
$ saved_default = f$environment("DEFAULT")
$ if .not. f$privilege("SYSPRV,CMKRNL,WORLD")
$ then
$   say "VMSMARIADB$CONFIGURE: needs SYSPRV, CMKRNL and WORLD (run it as SYSTEM)"
$   goto done
$ endif
$ if f$trnlnm("VMSMARIADB$ROOT") .eqs. ""
$ then
$   say "VMSMARIADB$CONFIGURE: VMSMARIADB$ROOT is not defined; run SYS$STARTUP:VMSMARIADB$STARTUP.COM"
$   goto done
$ endif
$ opts = "," + f$edit(p5, "UPCASE,COLLAPSE") + ","
$ interactive = f$locate(",NOCONFIRM,", opts) .eq. f$length(opts) .and. -
    f$mode() .eqs. "INTERACTIVE"
$ autostart = "YES"
$ if f$locate(",NOAUTOSTART,", opts) .lt. f$length(opts) then autostart = "NO"
$ cfg = f$trnlnm("VMSMARIADB$CONFIG")
$ if cfg .eqs. "" then cfg = "SYS$MANAGER:VMSMARIADB$CONFIG.COM"
$ server = "@VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER"
$ warnings = 0
$ say ""
$ say "    MariaDB (vms-mariadb) service configuration"
$ say ""
$ if f$search(cfg) .nes. "" then say "    ''cfg' exists: this run replaces it."
$!
$! --- the data directory ---
$ask_datadir:
$ answer == p1
$ if answer .eqs. "" then call ask "Data directory, on an ODS-5 disk, e.g. DKA100:[MARIADB.DATA]" ""
$ d = f$edit(answer, "UPCASE,TRIM")
$ p1 = ""
$ if d .eqs. "" .or. f$locate("]", d) .eq. f$length(d) .or. f$parse(d,,,"DEVICE") .eqs. ""
$ then
$   say "    Give the data directory as dev:[dir.dir]."
$   if interactive then goto ask_datadir
$   goto done
$ endif
$ dev = f$parse(d,,,"DEVICE")
$ dir = f$parse(d,,,"DIRECTORY") - "[" - "]" - "<" - ">"
$ if f$locate(".", dir) .eq. f$length(dir)
$ then
$   say "    ''d': use a directory at least two levels deep (dev:[MARIADB.DATA])."
$   if interactive then goto ask_datadir
$   goto done
$ endif
$ ods5 = 0
$ if f$getdvi(dev, "EXISTS") then ods5 = f$getdvi(dev, "ACPTYPE") .eqs. "F11V5"
$ if .not. ods5
$ then
$   say "    ''dev' is not a mounted ODS-5 disk."
$   if interactive then goto ask_datadir
$   goto done
$ endif
$ datadir = dev + "[" + dir + "]"
$ tmpdir = dev + "[" + dir + "_TMP]"
$ call last_element 'dir'
$ dname = last_element
$ hdir = f$extract(0, f$length(dir) - f$length(dname) - 1, dir)
$ home = dev + "[" + hdir + "]"
$ datadir_file = home + dname + ".DIR"
$ tmpdir_file = home + dname + "_TMP.DIR"
$ existing = f$search(datadir - "]" + ".mysql]db.frm") .nes. ""
$ if .not. existing .and. (f$search(datadir - "]" + "...]*.*") .nes. "" .or. -
    f$search(tmpdir - "]" + "...]*.*") .nes. "")
$ then
$   say "    ''datadir' (or ''tmpdir') holds files but no system tables."
$   if interactive then goto ask_datadir
$   goto done
$ endif
$ if existing .and. f$search(datadir + "mariadbd.pid") .nes. ""
$ then
$   say "    ''datadir'mariadbd.pid exists: a server is using it (or crashed)."
$   say "    Stop that server first."
$   goto done
$ endif
$!
$! --- the port ---
$ answer == p2
$ if answer .eqs. "" then call ask "TCP port" "3306"
$ port = f$integer(answer)
$ if port .le. 0 .or. port .gt. 65535
$ then
$   say "    ''answer' is not a port number."
$   goto done
$ endif
$ call find_process MARIADBD_'port'
$ if found_pid .nes. ""
$ then
$   say "    Warning: a process MARIADBD_''port' (''found_pid') is running; the service"
$   say "    will not start while it does."
$   warnings = warnings + 1
$ endif
$!
$! --- the account ---
$ answer == p3
$ if answer .eqs. "" then call ask "Account the server runs as" "MARIADB"
$ account = f$edit(answer, "UPCASE,TRIM")
$ n = f$identifier(account, "NAME_TO_NUMBER")
$ new_account = n .eq. 0
$ if .not. new_account
$ then
$   if n .lt. 0
$   then
$     say "    ''account' is a rights identifier, not an account."
$     goto done
$   endif
$   g = n / 65536
$   m = n - g * 65536
$   call octal 'g'
$   og = octal_string
$   call octal 'm'
$   uic = "[" + og + "," + octal_string + "]"
$   say "    Account ''account' exists (UIC ''uic'): it is used as it is.  It needs"
$   say "    BATCH access, /FLAGS=NODISUSER, no RESTRICTED flag, and quotas for a"
$   say "    server (README.VMS)."
$ else
$   if p4 .eqs. ""
$   then
$     g = %O360
$free_loop:
$     if f$identifier(g * 65536 + 1, "NUMBER_TO_NAME") .nes. "" .or. -
        f$identifier(g * 65536 + %XFFFF, "NUMBER_TO_NAME") .nes. ""
$     then
$       g = g + 1
$       goto free_loop
$     endif
$     call octal 'g'
$     call ask "UIC for the new account ''account'" "[''octal_string',1]"
$   else
$     answer == p4
$   endif
$   uic = f$edit(answer, "UPCASE,COLLAPSE")
$   og = f$element(0, ",", uic - "[" - "]")
$   om = f$element(1, ",", uic - "[" - "]")
$   call is_octal "''og'"
$   ok = is_octal
$   call is_octal "''om'"
$   if .not. ok .or. .not. is_octal .or. om .eqs. ","
$   then
$     say "    ''uic' is not a UIC ([group,member], octal)."
$     goto done
$   endif
$   g = %O'og'
$   m = %O'om'
$   if g .le. f$getsyi("MAXSYSGROUP")
$   then
$     say "    ''uic' is a system UIC (group <= MAXSYSGROUP); choose another."
$     goto done
$   endif
$   if f$identifier(g * 65536 + m, "NUMBER_TO_NAME") .nes. ""
$   then
$     say "    ''uic' belongs to ", f$identifier(g * 65536 + m, "NUMBER_TO_NAME"), "; choose another."
$     goto done
$   endif
$   uic = "[" + og + "," + om + "]"
$ endif
$!
$! --- quotas: FILLM must stay below CHANNELCNT ---
$ fillm = 1000
$ channelcnt = f$getsyi("CHANNELCNT")
$ if channelcnt - 100 .lt. fillm
$ then
$   fillm = channelcnt - 100
$   say "    Warning: SYSGEN CHANNELCNT is ''channelcnt': FILLM ''fillm' instead of 1000"
$   say "    (the server's table cache is sized from it)."
$   warnings = warnings + 1
$ endif
$!
$! --- can the account reach its files? ---
$! Every directory above the data directory needs execute access for it.
$ call last_element 'dir'
$ i = 0
$ path = ""
$trav_loop:
$ if i .ge. element_count - 1 then goto trav_done
$ e = f$element(i, ".", dir)
$ parent = path
$ if parent .eqs. "" then parent = "000000"
$ dirfile = dev + "[" + parent + "]" + e + ".DIR"
$ if path .eqs. "" then path = e
$ if path .nes. e then path = path + "." + e
$ i = i + 1
$ if f$search(dirfile) .eqs. "" then goto trav_loop
$ if f$locate(account, f$file_attributes(dirfile, "UIC")) .lt. -
     f$length(f$file_attributes(dirfile, "UIC")) then goto trav_loop
$ call world_has 'dirfile' E
$ if .not. world_has
$ then
$   say "    Warning: ''dirfile' gives WORLD no execute access; give the account"
$   say "    execute access:  $ SET SECURITY/ACL=(IDENTIFIER=''account',ACCESS=EXECUTE) ''dirfile'"
$   warnings = warnings + 1
$ endif
$ goto trav_loop
$trav_done:
$! ... and run the kit's images.
$ call world_has VMSMARIADB$ROOT:[BIN]MARIADBD.EXE E
$ if .not. world_has
$ then
$   say "    Warning: WORLD cannot execute VMSMARIADB$ROOT:[BIN]MARIADBD.EXE."
$   warnings = warnings + 1
$ endif
$!
$! --- root's password (a new data directory only) ---
$ if existing
$ then
$   say "    ''datadir' has system tables: it is kept as it is (root's password"
$   say "    too); its files will be owned by ''account'."
$ else
$   if interactive
$   then
$pw_again:
$     set terminal/noecho
$     read/end_of_file=pw_eof/prompt="Password for the MariaDB root accounts: " sys$command pw
$     say ""
$     read/end_of_file=pw_eof/prompt="Again: " sys$command pw2
$     say ""
$     set terminal/echo
$     if pw .eqs. "" .or. pw .nes. pw2
$     then
$       say "    Empty, or the two differ; again."
$       goto pw_again
$     endif
$     pw2 = ""
$   else
$     pw = f$trnlnm("VMSMARIADB$CONFIGURE_ROOTPW")
$     if pw .eqs. ""
$     then
$       say "    NOCONFIRM: define VMSMARIADB$CONFIGURE_ROOTPW to root's password."
$       goto done
$     endif
$   endif
$ endif
$!
$! --- summary and confirmation ---
$ node = f$getsyi("NODENAME")
$ say ""
$ say "    Data directory  ''datadir' (temporary files ''tmpdir')"
$ if existing then say "                    existing: kept"
$ say "    Port            ''port'"
$ say "    Account         ''account' ''uic', login directory ''home'"
$ say "    Node            ''node'"
$ say "    Start at boot   ''autostart'"
$ say "    Site file       ''cfg'"
$ if new_account
$ then
$   uaf_add = "/UIC=" + uic + " /DEVICE=" + dev + " /DIRECTORY=[" + hdir + "]" + -
      " /NOPWDEXPIRED /PWDLIFETIME=NONE /FLAGS=(NODISUSER,DISMAIL,DISNEWMAIL)" + -
      " /NOINTERACTIVE /NONETWORK /NOLOCAL /NODIALUP /NOREMOTE /BATCH" + -
      " /PRIVILEGES=(TMPMBX,NETMBX) /DEFPRIVILEGES=(TMPMBX,NETMBX)"
$   uaf_quotas = "/PGFLQUOTA=8000000 /FILLM=" + f$string(fillm) + -
      " /BYTLM=1000000 /BIOLM=500 /DIOLM=500 /ASTLM=1000 /TQELM=500 /ENQLM=4000" + -
      " /PRCLM=5 /WSDEFAULT=4096 /WSQUOTA=65536 /WSEXTENT=262144"
$   say ""
$   say "    The account is added with (the password is random; nobody logs in):"
$   say "    UAF> ADD ''account' /PASSWORD=<random> ''uaf_add'"
$   say "    UAF> MODIFY ''account' ''uaf_quotas'"
$ endif
$ if warnings .gt. 0 then say "    (''warnings' warning(s) above)"
$ say ""
$ if interactive
$ then
$   call ask "Go ahead" "YES"
$   if .not. answer
$   then
$     say "    Nothing changed."
$     status = 1
$     goto done
$   endif
$ endif
$!
$! --- the account ---
$ if new_account
$ then
$   uaf_com = "SYS$SCRATCH:VMSMARIADB$CONFIGURE_UAF.TMP"
$   open/write o 'uaf_com'
$   set security/protection=(S:RWED,O:RWED,G,W) 'uaf_com'
$   write o "ADD ", account, " /PASSWORD=M", f$extract(0, 24, f$unique()), " ", uaf_add
$   write o "MODIFY ", account, " ", uaf_quotas
$   write o "EXIT"
$   close o
$   set default SYS$SYSTEM
$   define/user sys$input 'uaf_com'
$   run SYS$SYSTEM:AUTHORIZE
$   set default 'saved_default'
$   delete/nolog 'uaf_com';*
$   if f$identifier(account, "NAME_TO_NUMBER") .eq. 0
$   then
$     say "VMSMARIADB$CONFIGURE: AUTHORIZE did not add ''account'"
$     goto done
$   endif
$   say "VMSMARIADB$CONFIGURE: added account ''account' ''uic'"
$ endif
$ if f$parse(home) .eqs. ""
$ then
$   create/directory/owner='uic'/protection=(S:RWE,O:RWE,G,W) 'home'
$   say "VMSMARIADB$CONFIGURE: created ''home'"
$ endif
$!
$! --- the data directory ---
$ if .not. existing
$ then
$   server INSTALL_DB 'datadir'
$   if .not. $status
$   then
$     say "VMSMARIADB$CONFIGURE: INSTALL_DB failed; nothing more done"
$     goto done
$   endif
$ endif
$ if f$search(tmpdir_file) .eqs. "" then create/directory/version_limit=1 'tmpdir'
$ set security/protection=(S:RWED,O:RWED,G,W) 'tmpdir_file'
$ cnf = datadir + "VMSMARIADB$SHUTDOWN.CNF"
$ if f$search(cnf) .nes. "" then delete/nolog 'cnf';*
$ call to_unix 'datadir'
$ ucnf = unix_path + "/VMSMARIADB$SHUTDOWN.CNF"
$! Statements for a second mariadbd --bootstrap: no server needs to run.
$! FLUSH PRIVILEGES loads the grant tables (bootstrap starts without them).
$! The password goes in as hex, so that no character of it needs quoting.
$ sql = tmpdir + "VMSMARIADB$CONFIGURE.SQL"
$ open/write o 'sql'
$ write o "FLUSH PRIVILEGES;"
$ if .not. existing
$ then
$   call to_hex
$   pw = ""
$   write o "SET @pw = CONVERT(X'", hex_string, "' USING utf8mb4);"
$   hex_string == ""
$   write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE('localhost'), ' IDENTIFIED BY ', QUOTE(@pw));"
$   write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE('127.0.0.1'), ' IDENTIFIED BY ', QUOTE(@pw));"
$   write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE('::1'), ' IDENTIFIED BY ', QUOTE(@pw));"
$   write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE(LOWER(@@hostname)), ' IDENTIFIED BY ', QUOTE(@pw));"
$   write o "SET @pw = NULL;"
$ endif
$! The shutdown account: SHUTDOWN only, a random password (OpenSSL's
$! RAND_bytes), written by the server straight into the option file.
$ write o "SET @sp = HEX(RANDOM_BYTES(16));"
$ write o "EXECUTE IMMEDIATE CONCAT('CREATE OR REPLACE USER vmsmariadb_shutdown@', QUOTE('localhost'), ' IDENTIFIED BY ', QUOTE(@sp));"
$ write o "EXECUTE IMMEDIATE CONCAT('CREATE OR REPLACE USER vmsmariadb_shutdown@', QUOTE('127.0.0.1'), ' IDENTIFIED BY ', QUOTE(@sp));"
$ write o "GRANT SHUTDOWN ON *.* TO vmsmariadb_shutdown@'localhost';"
$ write o "GRANT SHUTDOWN ON *.* TO vmsmariadb_shutdown@'127.0.0.1';"
$ write o "SELECT CONCAT('[client]', CHAR(10), 'user=vmsmariadb_shutdown', CHAR(10), 'password=', @sp, CHAR(10)) INTO DUMPFILE '", ucnf, "';"
$ write o "SET @sp = NULL;"
$ close o
$ set security/protection=(S:RWED,O:RWED,G,W) 'sql'
$ server BOOTSTRAP 'datadir' 'sql'
$ status = $status
$ delete/nolog 'sql';*
$ if .not. status .or. f$search(cnf) .eqs. ""
$ then
$   say "VMSMARIADB$CONFIGURE: setting up the accounts failed; nothing more done"
$   if status then status = 44
$   goto done
$ endif
$!
$! --- give the data to the account ---
$ set security/owner='uic'/protection=(S:RWED,O:RWED,G,W) -
    'datadir_file','tmpdir_file','f$string(datadir - "]" + "...]*.*;*")','f$string(tmpdir - "]" + "...]*.*;*")'
$ set security/protection=(S:R,O:RW,G,W) 'cnf'
$ say "VMSMARIADB$CONFIGURE: ''datadir' belongs to ''account'"
$!
$! --- the site file ---
$ open/write o 'cfg'
$ write o "$! VMSMARIADB$CONFIG.COM - site configuration of the MariaDB service"
$ write o "$! (vms-mariadb), written by VMSMARIADB$CONFIGURE.COM on ", f$cvtime(,"ABSOLUTE")
$ write o "$! and read by SYS$STARTUP:VMSMARIADB$STARTUP.COM START and"
$ write o "$! SYS$STARTUP:VMSMARIADB$SHUTDOWN.COM.  It may be edited:"
$ write o "$!   autostart  YES or NO: does STARTUP START start the server?"
$ write o "$!   node       the only node that starts it (one node per data directory)"
$ write o "$!   queue      the batch queue for the start job"
$ write o "$!   option     one more mariadbd option (or use <datadir>MY.CNF)"
$ write o "$!   shutdown_timeout  seconds SHUTDOWN waits for the server to exit"
$ write o "$ vmsmariadb_datadir == """, datadir, """"
$ write o "$ vmsmariadb_port == """, port, """"
$ write o "$ vmsmariadb_account == """, account, """"
$ write o "$ vmsmariadb_node == """, node, """"
$ write o "$ vmsmariadb_autostart == """, autostart, """"
$ write o "$ vmsmariadb_queue == ""SYS$BATCH"""
$ write o "$ vmsmariadb_option == """""
$ write o "$ vmsmariadb_shutdown_timeout == ""300"""
$ close o
$ set security/protection=(S:RWED,O:RWED,G,W) 'cfg'
$ say "VMSMARIADB$CONFIGURE: wrote ''cfg'"
$ say ""
$ say "    Add to SYS$MANAGER:SYSTARTUP_VMS.COM, after TCP/IP and the batch"
$ say "    queues have started (it replaces a plain @VMSMARIADB$STARTUP line):"
$ say "    $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM START"
$ say "    and to SYS$MANAGER:SYSHUTDWN.COM:"
$ say "    $ @SYS$STARTUP:VMSMARIADB$SHUTDOWN.COM"
$ say ""
$ say "    To start the server now:  $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM START"
$ say ""
$ status = 1
$done:
$ if f$type(pw) .nes. "" then pw = ""
$ set default 'saved_default'
$ saved_privs = f$setprv(saved_privs)
$ exit status
$!
$pw_eof:
$ set terminal/echo
$ say ""
$ say "    Nothing changed."
$ goto done
$!
$! p1 = prompt, p2 = default; the reply (or the default) in the global
$! answer.  Without a terminal (NOCONFIRM), the default.
$ask: subroutine
$ answer == p2
$ if .not. interactive then exit 1
$ read/end_of_file=ask_eof/prompt="''p1' [''p2']: " sys$command reply
$ reply = f$edit(reply, "TRIM")
$ if reply .nes. "" then answer == reply
$ask_eof:
$ exit 1
$ endsubroutine
$!
$! The last dot-separated element of p1 and the number of elements, in
$! the globals last_element and element_count
$last_element: subroutine
$ i = 0
$le_loop:
$ e = f$element(i, ".", p1)
$ if e .eqs. "." then goto le_done
$ last_element == e
$ i = i + 1
$ goto le_loop
$le_done:
$ element_count == i
$ exit 1
$ endsubroutine
$!
$! Is p1 a non-empty string of octal digits?  In the global is_octal.
$is_octal: subroutine
$ is_octal == p1 .nes. ""
$ i = 0
$io_loop:
$ if i .ge. f$length(p1) then exit 1
$ if f$locate(f$extract(i, 1, p1), "01234567") .eq. 8 then is_octal == 0
$ i = i + 1
$ goto io_loop
$ endsubroutine
$!
$! The integer p1 in octal, without leading zeros, in the global octal_string
$octal: subroutine
$ s = f$fao("!OL", f$integer(p1))
$oc_loop:
$ if f$length(s) .gt. 1 .and. f$extract(0, 1, s) .eqs. "0"
$ then
$   s = f$extract(1, 99, s)
$   goto oc_loop
$ endif
$ octal_string == s
$ exit 1
$ endsubroutine
$!
$! Does file p1's protection give WORLD access p2 (R, W, E or D)?  In the
$! global world_has.
$world_has: subroutine
$ pro = f$file_attributes(p1, "PRO")
$ w = f$extract(f$locate("WORLD=", pro) + 6, 4, pro)
$ w = f$element(0, ",", w)
$ world_has == f$locate(p2, w) .lt. f$length(w)
$ exit 1
$ endsubroutine
$!
$! pw (the caller's symbol) in hex, in the global hex_string
$to_hex: subroutine
$ h = ""
$ i = 0
$th_loop:
$ if i .ge. f$length(pw) then goto th_done
$ h = h + f$fao("!XB", f$cvui(0, 8, f$extract(i, 1, pw)))
$ i = i + 1
$ goto th_loop
$th_done:
$ hex_string == h
$ exit 1
$ endsubroutine
$!
$! The PID of the process named p1, or "", in the global found_pid.
$find_process: subroutine
$ found_pid == ""
$ ctx = ""
$ x = f$context("PROCESS", ctx, "PRCNAM", p1, "EQL")
$ pid = f$pid(ctx)
$ if pid .nes. "" then found_pid == pid
$ if f$type(ctx) .eqs. "PROCESS_CONTEXT" then x = f$context("PROCESS", ctx, "CANCEL")
$ exit 1
$ endsubroutine
$!
$! dev:[a.b.c] -> /dev/a/b/c (physical device, concealed roots expanded), in
$! the global symbol unix_path
$to_unix: subroutine
$ spec = p1
$ u = "/" + (f$parse(spec,,,"DEVICE","NO_CONCEAL") - ":")
$ d = f$parse(spec,,,"DIRECTORY","NO_CONCEAL") - "][" - "[" - "]" - "<" - ">"
$ d = d - ".000000"
$ i = 0
$tu_loop:
$ e = f$element(i, ".", d)
$ if e .eqs. "." .or. e .eqs. "" .or. e .eqs. "000000" then goto tu_done
$ u = u + "/" + e
$ i = i + 1
$ goto tu_loop
$tu_done:
$ unix_path == u
$ exit 1
$ endsubroutine
