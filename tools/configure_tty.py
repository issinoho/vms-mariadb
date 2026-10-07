#!/usr/bin/env python3
"""configure_tty.py <node> <datadir> <port> <account> <uic> - run
VMSMARIADB$CONFIGURE.COM interactively, as an administrator would, in an ssh
terminal session (tools/installcheck.sh with CONFIGURE_TTY=1).

Answers each prompt, gives two different root passwords once (configure must
ask again), takes the default at "Go ahead", and checks that the password
never appears in the session (it is read with the terminal's echo off).  The
site file is <workdir>SVCTEST_CONFIG.COM (logical name VMSMARIADB$CONFIG), as
in the non-interactive phase.  The root password comes from TTY_ROOTPW.
Prints the session; the last line is CONFIGURE_TTY: PASS or FAIL.

DCL details: lines end with CR (an LF is Ctrl/J, which deletes a word), and
the site's prompt is unknown, so wait for the login output to settle and set
our own.  Needs pexpect.
"""
import os
import sys

import pexpect

node, datadir, port, account, uic = sys.argv[1:6]
pw = os.environ["TTY_ROOTPW"]
top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
row = next(l.split() for l in open(os.path.join(top, "tools", "nodes.conf"))
           if l.split()[:1] == [node])
host, sshport, user, workdir = row[2], row[3], row[4], row[5]
key = os.environ.get("VMS_SSH_KEY", os.path.expanduser("~/.ssh/vms_ed25519"))

log = []


class Tee:
    def write(self, s):
        log.append(s)
        sys.stdout.write(s)

    def flush(self):
        sys.stdout.flush()


c = pexpect.spawn("ssh", ["-tt", "-i", key, "-p", sshport, "-o", "BatchMode=yes",
                          f"{user}@{host}"], encoding="latin-1", timeout=120)
c.linesep = "\r"
c.logfile_read = Tee()
ok = True


def step(pattern, reply=None, timeout=120):
    global ok
    i = c.expect([pattern, pexpect.TIMEOUT, pexpect.EOF], timeout=timeout)
    if i != 0:
        print(f"\nCONFIGURE_TTY: no {pattern!r}")
        ok = False
        raise SystemExit
    if reply is not None:
        c.sendline(reply)


try:
    # Let LOGIN.COM finish (quiet for 5 s), then use our own prompt.
    while True:
        try:
            c.read_nonblocking(4096, timeout=5)
        except pexpect.TIMEOUT:
            break
    c.sendline('set prompt="TTY$ "')
    step(r"TTY\$ ", "set default " + workdir)
    step(r"TTY\$ ", "set process/privilege=(SYSPRV,CMKRNL,WORLD)")
    step(r"TTY\$ ", f"define/process VMSMARIADB$CONFIG {workdir}SVCTEST_CONFIG.COM")
    step(r"TTY\$ ", f'write sys$output "TTY account=", f$identifier("{account}","NAME_TO_NUMBER")')
    step(r"TTY account=(-?\d+)")
    if c.match.group(1) != "0":
        print(f"\nCONFIGURE_TTY: account {account} exists already; not touching it")
        ok = False
        raise SystemExit
    step(r"TTY\$ ", "@VMSMARIADB$ROOT:[000000]VMSMARIADB$CONFIGURE")
    step(r"Data directory, on an ODS-5 disk, e\.g\. [^\r\n]*\]: ", datadir)
    step(r"TCP port \[3306\]: ", port)
    step(r"Account the server runs as \[MARIADB\]: ", account)
    step(r"UIC for the new account \S+ \[(\[\d+,\d+\])\]: ", uic)
    print(f"\n(offered UIC {c.match.group(1)})")
    step(r"Password for the MariaDB root accounts: ", pw)
    step(r"Again: ", pw + "x")
    step(r"Empty, or the two differ; again\.")
    step(r"Password for the MariaDB root accounts: ", pw)
    step(r"Again: ", pw)
    step(r"Go ahead \[YES\]: ", "")
    step(r"VMSMARIADB\$CONFIGURE: wrote ", None, timeout=900)
    step(r"TTY\$ ", "logout")
    c.expect([pexpect.EOF, pexpect.TIMEOUT], timeout=30)
except SystemExit:
    pass
finally:
    c.close(force=True)

session = "".join(log)
if pw in session:
    print("\nCONFIGURE_TTY: the root password was echoed")
    ok = False
print("\nCONFIGURE_TTY: " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
