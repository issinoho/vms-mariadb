$! MAKE_KIT.COM - build the VMSMARIADB PCSI kit (x86-64)
$!
$! Usage:  @[.VMS.KIT]MAKE_KIT
$! Needs both built configurations (@[.VMS]BUILD CLIENT and SERVER):
$! [.VMSOBJ]*.EXE (the clients) and [.VMSOBJ_SERVER]MARIADBD.EXE, plus the
$! error messages ([.VMSGEN.SQL.SHARE]), character sets ([.SQL.SHARE.CHARSETS])
$! and bootstrap SQL ([.VMSGEN.SCRIPTS]) that the server build pushes.  The
$! product description and text module (PRODUCT-X86VMS.PCSI$DESC/$TEXT),
$! procedures and documentation were put in [.VMS.KIT] by tools/prepare.sh.
$! Writes the kit to [.KIT_X86_64]: the sequential kit (.PCSI) and a
$! compressed copy (.PCSI$COMPRESSED).
$!
$ set noon
$ status = 44
$ saved_default = f$environment("DEFAULT")
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [--]
$ arch = f$edit(f$getsyi("ARCH_NAME"), "UPCASE")
$ if arch .nes. "X86_64"
$ then
$   write sys$error "MAKE_KIT: the VMSMARIADB kit is x86-64 only"
$   goto done
$ endif
$ base = "X86VMS"
$!
$! KIT_PRODUCER, KIT_PRODUCT, PCSI_VERSION, KIT_VERSION from kit.env
$ open/read env [.VMS.KIT]KIT.ENV
$env_loop:
$ read/end=env_done env line
$ name = f$element(0, "=", line)
$ 'name' = f$element(1, "=", line)
$ goto env_loop
$env_done:
$ close env
$!
$ server = "[.VMSOBJ_SERVER]MARIADBD.EXE"
$ clients = "MARIADB,MARIADB-ADMIN,MARIADB-CHECK,MARIADB-DUMP,MARIADB-IMPORT," + -
    "MARIADB-SHOW,MARIADB-SLAP,MY_PRINT_DEFAULTS,PERROR"
$ missing = 0
$ if f$search(server) .eqs. "" then missing = 1
$ i = 0
$chk_loop:
$ c = f$element(i, ",", clients)
$ if c .eqs. "," then goto chk_done
$ if f$search("[.VMSOBJ]''c'.EXE") .eqs. "" then missing = 1
$ i = i + 1
$ goto chk_loop
$chk_done:
$ if missing
$ then
$   write sys$error "MAKE_KIT: images missing from [.VMSOBJ] or [.VMSOBJ_SERVER]; build first"
$   goto done
$ endif
$!
$! PRODUCT PACKAGE looks each file up by name in one flat material
$! directory (destinations are in the PDF).  The error messages are all
$! ERRMSG.SYS, one per language directory, so each is copied as
$! <LANGUAGE>_ERRMSG.SYS and the PDF names it with "source".
$ out = "[.KIT_''arch']"
$ mat = "[.KIT_''arch'.MAT]"
$ if f$search("KIT_''arch'.DIR") .eqs. "" then create/directory 'out'
$ if f$search("[.KIT_''arch']MAT.DIR") .eqs. "" then create/directory 'mat'
$ if f$search("''out'*.PCSI*;*") .nes. "" then delete/nolog 'out'*.PCSI*;*
$ if f$search("''mat'*.*;*") .nes. "" then delete/nolog 'mat'*.*;*
$ copy/nolog 'server' 'mat'
$ i = 0
$cp_loop:
$ c = f$element(i, ",", clients)
$ if c .eqs. "," then goto cp_done
$ copy/nolog [.VMSOBJ]'c'.EXE 'mat'
$ i = i + 1
$ goto cp_loop
$cp_done:
$ copy/nolog [.VMS.KIT]VMSMARIADB$STARTUP.COM,VMSMARIADB$SHUTDOWN.COM,VMSMARIADB$SETUP.COM, -
    VMSMARIADB$SERVER.COM,VMSMARIADB$CONFIGURE.COM 'mat'
$ copy/nolog [.VMS.KIT]README.VMS,[]COPYING.,CREDITS. 'mat'
$ copy/nolog [.SQL.SHARE.CHARSETS]*.* 'mat'
$ copy/nolog [.VMS]BOOTSTRAP_HEADER.SQL 'mat'
$ copy/nolog [.VMSGEN.SCRIPTS]MARIADB_SYSTEM_TABLES.SQL,MARIADB_PERFORMANCE_TABLES.SQL, -
    MARIADB_SYSTEM_TABLES_DATA.SQL,FILL_HELP_TABLES.SQL,MARIA_ADD_GIS_SP_BOOTSTRAP.SQL, -
    MARIADB_SYS_SCHEMA.SQL 'mat'
$lang_loop:
$ f = f$search("[.VMSGEN.SQL.SHARE.*]ERRMSG.SYS")
$ if f .eqs. "" then goto lang_done
$ d = f$edit(f$parse(f,,,"DIRECTORY"), "UPCASE") - "]"
$ lang = f$element(0, "]", f$extract(f$locate(".SHARE.", d) + 7, 999, d))
$ copy/nolog 'f' 'mat''lang'_ERRMSG.SYS
$ goto lang_loop
$lang_done:
$ matspec = f$parse(mat,,,"DEVICE","NO_CONCEAL") + f$parse(mat,,,"DIRECTORY","NO_CONCEAL")
$!
$ write sys$output "MAKE_KIT: ''KIT_PRODUCER' ''base' ''KIT_PRODUCT' ''PCSI_VERSION' (MariaDB ''KIT_VERSION')"
$ product package 'KIT_PRODUCT' -
    /producer='KIT_PRODUCER' /base_system='base' /version='PCSI_VERSION' -
    /source=[.VMS.KIT]PRODUCT-'base'.PCSI$DESC -
    /material='matspec' -
    /destination='out' -
    /format=sequential -
    /options=noconfirm /log
$ status = $status
$ kit = f$search("''out'*.PCSI")
$ if kit .eqs. ""
$ then
$   status = 44
$   goto done
$ endif
$ write sys$output "MAKE_KIT: kit ", kit
$ product copy 'KIT_PRODUCT' -
    /producer='KIT_PRODUCER' /base_system='base' /version='PCSI_VERSION' -
    /source='out' /destination='out' /format=compressed /options=noconfirm
$ ckit = f$search("''out'*.PCSI$COMPRESSED")
$ if ckit .nes. "" then write sys$output "MAKE_KIT: compressed kit ", ckit
$done:
$ set default 'saved_default'
$ exit status
