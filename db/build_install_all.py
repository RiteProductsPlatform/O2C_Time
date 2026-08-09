# -*- coding: utf-8 -*-
"""Flatten install_time.sql into one self-contained script for SQL Developer.

    python build_install_all.py          # writes install_time_ALL.sql

WHY THIS EXISTS

install_time.sql uses `@@child.sql` includes, which SQL*Plus resolves relative
to the calling script. That is the right structure for the repository and it is
the wrong thing to hand to SQL Developer here, for two reasons:

  1. `@@` only resolves in SQL Developer when the script has been OPENED FROM A
     FILE and executed with Run Script (F5). Pasted into a worksheet, or run
     with Run Statement (Ctrl+Enter), the includes are silently skipped and the
     install appears to succeed while creating nothing.

  2. This repository lives under "OneDrive - RITE/O2C/Time Module/...". SQL
     Developer does not quote the path it builds for an include, so a directory
     containing a space is a long-standing way for `@@` to fail. The path here
     has two.

Flattening removes the question. The output is one file with no includes, so it
behaves identically opened, pasted, or run through SQLcl, on any path.

GENERATED, NOT MAINTAINED. Re-run this after changing any script in the install
order; do not hand-edit the output. The order is read from install_time.sql
itself rather than restated here, so a script added to the installer is picked
up automatically and one that is missing from it stays missing in both.
"""
from __future__ import annotations

import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'install_time.sql')
OUT = os.path.join(HERE, 'install_time_ALL.sql')

BANNER = """--==============================================================
-- %s
--
-- GENERATED FILE - DO NOT EDIT.
-- Produced by db/build_install_all.py from install_time.sql and the %d
-- scripts it includes. Edit those and re-run the generator.
--
-- This is install_time.sql with every @@include expanded inline, so it runs
-- anywhere: SQL Developer (opened or pasted), SQLcl, or SQL*Plus. The include
-- form is fragile in SQL Developer when the path contains a space, and this
-- repository lives under "OneDrive - RITE/.../Time Module/".
--
-- RUNNING IT IN SQL DEVELOPER
--   1. Open this file, or paste the whole thing into a worksheet.
--   2. Connect as the O2C_TIME schema owner.
--   3. Press F5 - "Run Script". NOT Ctrl+Enter, which executes one statement
--      and will look like it worked.
--   4. Watch the Script Output pane. The verification block at the end lists
--      every object and its status; nothing should be INVALID.
--
--   WHENEVER SQLERROR EXIT FAILURE ROLLBACK is left in on purpose: an installer
--   should stop at the first real failure rather than carry on and leave a
--   half-built schema. In SQL Developer that also DISCONNECTS the worksheet,
--   which looks alarming and is not damage - reconnect and read the last error
--   in the output. Every script is idempotent, so re-running after a fix is
--   safe and is the intended way to recover.
--==============================================================

"""


def read(path):
    return io.open(path, encoding='utf-8').read()


def main():
    if not os.path.exists(SRC):
        sys.exit('install_time.sql not found beside this script')
    src = read(SRC)

    includes = re.findall(r'^@@(\S+)\s*$', src, re.M)
    missing = [f for f in includes if not os.path.exists(os.path.join(HERE, f))]
    if missing:
        sys.exit('install_time.sql includes files that do not exist: %s'
                 % ', '.join(missing))

    def expand(m):
        rel = m.group(1)
        body = read(os.path.join(HERE, rel)).rstrip()
        return (
            '\n--=============================================================='
            '\n-- BEGIN %s\n'
            '--==============================================================\n'
            '%s\n'
            '--== END %s ==\n' % (rel, body, rel))

    out = re.sub(r'^@@(\S+)\s*$', expand, src, flags=re.M)
    out = BANNER % (os.path.basename(OUT), len(includes)) + out

    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out)

    # A flattened installer that still contains an include did not flatten.
    left = re.findall(r'^@@?\S+\s*$', out, re.M)
    if left:
        sys.exit('FAILED: %d include(s) survived: %s' % (len(left), left[:3]))

    print('wrote %s' % OUT)
    print('  %d scripts inlined, %d lines, %.0f KB'
          % (len(includes), out.count('\n') + 1, len(out) / 1024))
    for f in includes:
        print('    %s' % f)


if __name__ == '__main__':
    main()
