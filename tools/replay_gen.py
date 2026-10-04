#!/usr/bin/env python3
"""replay_gen.py <cmake-build-dir> <out-dir> [answered-vars-file]

Turn every platform check a host-side CMake run performed (from
CMakeFiles/CMakeConfigureLog.yaml, sources kept by --debug-trycompile) into a
self-contained source file that tools/vms_replay.com compiles, links and, where
needed, runs with clang on a VMS node.

Rewrites, so the answers mean what MariaDB expects on VMS:
  - CheckFunctionExists links `char f(void)` without a header, which fails for
    ordinary CRTL functions under clang (the DECC$ name mapping comes from the
    headers; docs/PHASE0.md).  It is replayed as "declared by a CRTL header (or
    a macro) and links".
  - CheckTypeSize reads INFO:size[] out of the host's object file; the replay
    prints that string from a wrapper program instead.
  - Compiler and linker flag checks (have_C__*, have_CXX__*, HAVE_LINK_FLAG_*)
    are about GCC options the MMS build never uses, and CheckLibraryExists asks
    about separate libraries VMS does not have: both are answered "no" here,
    without a replay (policy.txt).

  - Run checks get a wrapper main that prints "REPLAY-EXIT <n>", because a C
    exit code does not map one-to-one onto $STATUS.

Output: chk_NNNN.c / .cpp, manifest.txt ("NNNN VAR MODULE KIND LANG RUNVAR
CHECKVAR"; KIND is L link, R run, S size; RUNVAR is try_run's exit-code
variable and CHECKVAR the CHECK_*_SOURCE_RUNS result variable, "-" if none),
policy.txt ("VAR VALUE reason").
"""
import os
import re
import shlex
import sys
import yaml

HEADER_SUPERSET = """stdio.h stdlib.h string.h strings.h unistd.h fcntl.h time.h signal.h
pthread.h netdb.h errno.h sys/time.h sys/types.h sys/stat.h sys/socket.h
sys/resource.h sys/mman.h sys/times.h sys/utsname.h netinet/in.h arpa/inet.h
dirent.h pwd.h grp.h locale.h langinfo.h stdarg.h poll.h sched.h termios.h
sys/ioctl.h sys/file.h sys/statvfs.h sys/wait.h dlfcn.h malloc.h alloca.h
inttypes.h stdint.h wchar.h wctype.h sys/param.h utime.h sys/utime.h
math.h setjmp.h stddef.h limits.h float.h ctype.h assert.h""".split()

MODULE_RE = re.compile(r'Modules/(Check\w+)\.cmake')
COMPILE_RE = re.compile(r'(^|\s)(/usr/bin/)?(cc|c\+\+|gcc|g\+\+)\s.*\s-c\s')


def module_of(event):
    for frame in event.get('backtrace', []):
        m = MODULE_RE.search(frame)
        if m and m.group(1) not in ('CheckSourceCompiles', 'CheckSourceRuns'):
            return m.group(1)
    return 'try_' + event['kind'].split('-')[0][4:]  # raw try_compile/try_run


def compile_line(event):
    for line in event.get('buildResult', {}).get('stdout', '').splitlines():
        if COMPILE_RE.search(line):
            return shlex.split(line)
    return None


def defines_and_source(argv):
    defs, src = [], None
    for i, a in enumerate(argv):
        if a.startswith('-D'):
            body = a[2:]
            name, _, val = body.partition('=')
            defs.append((name, val if _ else '1'))
        elif a == '-c' and i + 1 < len(argv):
            src = argv[i + 1]
    return defs, src


def header_superset():
    lines = ['#ifdef __has_include']
    for h in HEADER_SUPERSET:
        lines.append('#if __has_include(<%s>)\n#include <%s>\n#endif' % (h, h))
    lines.append('#endif')
    return '\n'.join(lines) + '\n'


def common_defines():
    """-D options from overlay/vms/config/clang_common.rsp, as #defines."""
    top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lines = []
    for l in open(os.path.join(top, 'overlay', 'vms', 'config', 'clang_common.rsp')):
        l = l.strip()
        if l.startswith('-D'):
            name, _, val = l[2:].partition('=')
            lines.append('#define %s %s\n' % (name, val if _ else '1'))
    return ''.join(lines)


def main():
    bdir, out = sys.argv[1], sys.argv[2]
    common = common_defines()
    answered = set()
    if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
        answered = {l.split()[0] for l in open(sys.argv[3]) if l.strip() and not l.startswith('#')}
    log = yaml.safe_load(open(os.path.join(bdir, 'CMakeFiles', 'CMakeConfigureLog.yaml')))
    os.makedirs(out, exist_ok=True)
    manifest, policy, seen = [], [], set()
    n = 0
    for ev in log['events']:
        if not ev['kind'].startswith('try_'):
            continue
        br = ev.get('buildResult', {})
        var = br.get('variable')
        if not var or var.startswith('CMAKE_') or var in seen or var in answered:
            continue
        seen.add(var)
        mod = module_of(ev)
        if (re.match(r'have_(C|CXX)_', var) or var.startswith('HAVE_LINK_FLAG_') or
                mod in ('CheckCCompilerFlag', 'CheckCXXCompilerFlag', 'CheckCompilerFlag')):
            policy.append((var, '', 'GCC/linker flag check; the MMS build sets its own qualifiers'))
            continue
        if mod == 'CheckLibraryExists':
            policy.append((var, '', 'no separate libraries on VMS; functions are in the CRTL'))
            continue
        argv = compile_line(ev)
        if argv is None:
            print('replay_gen: no compile line for %s (%s); answer it by hand' % (var, mod),
                  file=sys.stderr)
            continue
        defs, src = defines_and_source(argv)
        if not src or not os.path.exists(src):
            print('replay_gen: source gone for %s: %s' % (var, src), file=sys.stderr)
            continue
        lang = 'CXX' if re.search(r'\.(cxx|cpp|cc)$', src) else 'C'
        n += 1
        tag = '%04d' % n
        body = open(src, encoding='utf-8', errors='replace').read()
        defs = [(k, v) for k, v in defs if k not in ('_GNU_SOURCE',)]
        head = '/* %s: %s (%s), replayed from %s */\n' % (tag, var, mod, os.path.basename(src))
        kind = 'R' if ev['kind'].startswith('try_run') else 'L'
        runvar = ev.get('runResult', {}).get('variable', '-') if kind == 'R' else '-'
        checkvar = '-'
        if kind == 'R':
            m = re.match(r'Performing Test (\S+)', (ev.get('checks') or [''])[-1])
            checkvar = m.group(1) if m else '-'
        if mod == 'CheckFunctionExists':
            fn = dict(defs).get('CHECK_FUNCTION_EXISTS')
            body = (header_superset() +
                    '#ifdef %s\nint main(void) { return 0; }\n#else\n'
                    'int main(void) { void *p = (void *) &%s; return p == 0; }\n#endif\n' % (fn, fn))
            defs = []
        elif mod == 'CheckTypeSize':
            kind = 'S'
            # The original keeps info_size[] in the object; print it instead.
            body = ('#define main cmake_check_type_size_main\n' + body +
                    '\n#undef main\n#include <stdio.h>\n'
                    'int main(void) { printf("%.*s\\n", (int) sizeof(info_size), info_size); return 0; }\n')
        if kind == 'R':
            body = ('#define main replay_orig_main\n' + body +
                    '\n#undef main\n#include <stdio.h>\n'
                    'int main(int argc, char **argv) {\n'
                    '  int r = ((int (*)(int, char **)) replay_orig_main)(argc, argv);\n'
                    '  printf("REPLAY-EXIT %d\\n", r);\n  return 0;\n}\n')
        text = head + common + ''.join('#define %s %s\n' % (k, v) for k, v in defs) + body
        ext = 'cpp' if lang == 'CXX' else 'c'
        with open(os.path.join(out, 'chk_%s.%s' % (tag, ext)), 'w') as f:
            f.write(text)
        manifest.append('%s %s %s %s %s %s %s' % (tag, var, mod, kind, lang, runvar, checkvar))
    # Other clang options from clang_common.rsp (not -D, -O, -g) for every
    # replayed compile: vms_replay.com reads FLAGS.TXT.
    top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    flags = [l.strip() for l in open(os.path.join(top, 'overlay', 'vms', 'config', 'clang_common.rsp'))
             if l.strip() and not l.startswith('#') and not re.match(r'-(D|O|g)', l.strip())]
    with open(os.path.join(out, 'flags.txt'), 'w') as f:
        f.write(' '.join(flags) + '\n')
    with open(os.path.join(out, 'manifest.txt'), 'w') as f:
        f.write('\n'.join(manifest) + '\n')
    with open(os.path.join(out, 'policy.txt'), 'w') as f:
        for var, val, why in policy:
            f.write('%s %s %s\n' % (var, val or '""', why))
    print('replay_gen: %d checks to replay, %d answered by policy' % (len(manifest), len(policy)))


if __name__ == '__main__':
    main()
