# -*- coding: utf-8 -*-
"""Pull one person's absences from Fusion and land them on the timesheet.

    python sync_absence.py --person-number RI2824 --period 3 \
                           --from 2026-08-01 --to 2026-08-31

Runs the whole INT-006 chain end to end and shows each hop, because when a leave
row does not appear on the screen the useful question is always *which* hop
dropped it:

    1  HCM /absences                    read live, per person, per date window
    2  GET  oc/time/me/{emp}            the worker's standard hours per day
    3  POST oc/time/admin/sync/absence  MERGE into OC_TIME_ABSENCE
    4  POST oc/time/admin/jobs/populate build the Leave rows in OC_TS_ENTRY
    5  GET  oc/time/weeks + grid        read back what the employee will see

WHY BOTH A SYNC AND A POPULATE
  Step 3 only caches the absence. The timesheet cell is made in step 4, where
  populate_month joins OC_TIME_ABSENCE to the COMMON/LEAVE task and the
  employee's allocation. Doing 3 without 4 leaves the leave invisible, which is
  the single most likely reason a leave that plainly exists in Fusion is not on
  the grid.

TWO MAPPINGS THAT HAVE TO BE EXACT
  * DURATION_HOURS. Fusion gives `duration` in DAYS ("1 Days" on the screen).
    The timesheet stores HOURS, so it is days x the worker's standard hours per
    day, read from the worker rather than assumed to be 8.
  * APPROVAL_STATUS. Fusion says 'APPROVED'; populate_month filters on exactly
    'Approved'. Send the wrong case and the absence caches fine and then never
    becomes a row - it fails silently at the last step.

Idempotent: step 3 is a MERGE on (employee, date, type) and step 4 leaves an
existing entry alone. Re-running changes nothing.

Credentials come from integration/bip/.env and are never printed.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import io
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(HERE, os.pardir, 'bip', '.env')
HCM = '/hcmRestApi/resources/11.13.18.05'


def load_env(path):
    cfg = {}
    if not os.path.exists(path):
        sys.exit('No .env at %s' % path)
    for ln in io.open(path, encoding='utf-8'):
        ln = ln.strip()
        if ln and not ln.startswith('#') and '=' in ln:
            k, v = ln.split('=', 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    for k in ('FUSION_BASE_URL', 'FUSION_USER', 'FUSION_PASSWORD', 'ORDS_BASE_URL'):
        cfg[k] = os.environ.get(k, cfg.get(k, ''))
        if not cfg[k]:
            sys.exit('%s is not set.' % k)
    return cfg


CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(url, params=None, body=None, auth=None, method=None, timeout=180):
    if params:
        url += ('&' if '?' in url else '?') + urllib.parse.urlencode(params)
    data = None
    headers = {'Accept': 'application/json'}
    if auth:
        headers['Authorization'] = 'Basic ' + auth
        headers['REST-Framework-Version'] = '4'
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            raw = r.read().decode('utf-8')
            try:
                return r.status, json.loads(raw)
            except ValueError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')[:600]
    except Exception as e:                                       # noqa: BLE001
        return 0, str(e)[:300]


def step(n, title):
    print('\n%s' % ('-' * 78))
    print('%d  %s' % (n, title))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--person-number', required=True)
    ap.add_argument('--period', required=True, type=int, help='O2C_TIME period_id')
    ap.add_argument('--from', dest='dfrom', required=True)
    ap.add_argument('--to', dest='dto', required=True)
    ap.add_argument('--actor', default='SYNC_ABSENCE')
    ap.add_argument('--dry-run', action='store_true',
                    help='read and map only; write nothing')
    a = ap.parse_args()

    cfg = load_env(ENV)
    fbase = cfg['FUSION_BASE_URL'].rstrip('/')
    obase = cfg['ORDS_BASE_URL'].rstrip('/')
    fauth = base64.b64encode(
        ('%s:%s' % (cfg['FUSION_USER'], cfg['FUSION_PASSWORD'])).encode()).decode()
    emp = a.person_number
    lo, hi = a.dfrom, a.dto

    print('FUSION  %s' % fbase.split('//')[-1].split('.')[0])
    print('ORDS    %s' % obase.split('//')[-1].split('/')[0])
    print('PERSON  %s      WINDOW %s .. %s      PERIOD %s'
          % (emp, lo, hi, a.period))
    print('=' * 78)

    # 1 ── resolve, then read the absences live ---------------------------
    step(1, 'HCM /absences (live)')
    st, body = call(fbase + HCM + '/workers',
                    {'q': "PersonNumber='%s'" % emp, 'limit': 1}, auth=fauth)
    rows = body.get('items', []) if isinstance(body, dict) else []
    if st != 200 or not rows:
        sys.exit('   could not resolve %s (status %s)' % (emp, st))
    pid = rows[0].get('PersonId')
    print('   PersonNumber %s -> PersonId %s' % (emp, pid))

    st, body = call(fbase + HCM + '/absences', {
        'q': "personId=%s AND endDate>='%s' AND startDate<='%s'" % (pid, lo, hi),
        'limit': 100}, auth=fauth)
    if st != 200:
        sys.exit('   absences returned %s: %s' % (st, str(body)[:200]))
    absences = body.get('items', [])
    print('   %d absence(s)' % len(absences))
    for x in absences:
        print('     %s .. %s  %s day(s)  %s  [%s/%s]' % (
            x.get('startDate'), x.get('endDate'), x.get('duration'),
            x.get('absenceType'), x.get('absenceStatusCd'),
            x.get('approvalStatusCd')))
    if not absences:
        sys.exit('   nothing to sync.')

    # 2 ── the worker's standard day, for days -> hours --------------------
    step(2, 'GET oc/time/me — standard hours per day')
    st, me = call(obase + '/oc/time/me/' + emp)
    std = None
    if st == 200 and isinstance(me, dict):
        src = me.get('items', [me])[0] if me.get('items') else me
        std = src.get('std_hours_per_day') or src.get('stdHoursPerDay')
    if not std:
        std = 8
        print('   not returned (status %s) - falling back to 8h' % st)
    else:
        print('   %s h/day' % std)
    std = float(std)

    # 3 ── map ------------------------------------------------------------
    step(3, 'map to the INT-006 contract')
    payload = []
    for x in absences:
        s = dt.date.fromisoformat(str(x.get('startDate'))[:10])
        e = dt.date.fromisoformat(str(x.get('endDate'))[:10])
        whole = (e - s).days + 1
        try:
            days = float(x.get('duration') or whole)
        except (TypeError, ValueError):
            days = float(whole)
        per_day = days / whole if whole else 0.0
        d = s
        while d <= e:
            payload.append({
                'EMPLOYEE_ID': emp,
                'ABSENCE_DATE': d.isoformat(),
                'ABSENCE_TYPE': x.get('absenceType') or 'Leave',
                # days -> hours, and never over the 0..24 check constraint
                'DURATION_HOURS': round(min(per_day * std, 24.0), 2),
                # exact case: populate_month filters on 'Approved'
                'APPROVAL_STATUS': ('Approved'
                                    if str(x.get('approvalStatusCd')).upper()
                                    == 'APPROVED' else 'Pending'),
            })
            d += dt.timedelta(days=1)
    for r in payload:
        print('   %s  %-16s %5.2f h  %s' % (
            r['ABSENCE_DATE'], r['ABSENCE_TYPE'], r['DURATION_HOURS'],
            r['APPROVAL_STATUS']))

    if a.dry_run:
        print('\n--dry-run: nothing written.')
        return

    # 4 ── cache it -------------------------------------------------------
    step(4, 'POST oc/time/admin/sync/absence')
    st, res = call(obase + '/oc/time/admin/sync/absence',
                   body={'actor': a.actor, 'final': 'Y', 'rows': payload})
    print('   %s  %s' % (st, res))
    if st != 200:
        sys.exit('   sync failed - stopping before populate.')

    # 5 ── turn it into timesheet cells -----------------------------------
    step(5, 'POST oc/time/admin/jobs/populate/%s  (employee %s)' % (a.period, emp))
    st, res = call(obase + '/oc/time/admin/jobs/populate/%s' % a.period,
                   params={'employeeId': emp, 'actor': a.actor}, body={})
    print('   %s  %s' % (st, res))

    # 6 ── read back exactly what the employee will see -------------------
    step(6, 'read back')
    st, wk = call(obase + '/oc/time/weeks/%s/%s' % (emp, a.period))
    weeks = wk.get('items', []) if isinstance(wk, dict) else []
    if not weeks:
        print('   no weeks returned (status %s)' % st)
        return
    # The grid is pivoted to named weekday columns - mon_hours .. sun_hours -
    # not to a d1..d7 array. Guessing the shape prints "(no hours)" over a row
    # that is in fact correct, which is worse than not printing it at all.
    days = ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
    for w in weeks:
        wid = w.get('ts_week_id')
        st, g = call(obase + '/oc/time/grid/%s' % wid)
        lines = g.get('items', []) if isinstance(g, dict) else []
        if not any(str(r.get('is_leave')) == 'Y' for r in lines):
            continue
        print('   week %-5s %s .. %s  %-18s' % (
            wid, str(w.get('week_start'))[:10], str(w.get('week_end'))[:10],
            w.get('week_status')))
        print('        %-24s %-6s %s' % (
            'project / task', 'total',
            '  '.join('%5s' % d.title() for d in days)))
        for r in lines:
            cells = '  '.join(
                '%5s' % (r.get(d + '_hours') if r.get(d + '_hours') else '.')
                for d in days)
            print('     %s  %-24s %-6s %s' % (
                'LV' if str(r.get('is_leave')) == 'Y' else '  ',
                ('%s / %s' % (r.get('project_number'), r.get('task_code')))[:24],
                r.get('line_total'), cells))
        # A leave day that still carries worked hours is scenario 21: absence
        # landed after the sheet was populated and nothing took the hours off.
        for d in days:
            tot = sum(float(r.get(d + '_hours') or 0) for r in lines)
            lv = sum(float(r.get(d + '_hours') or 0)
                     for r in lines if str(r.get('is_leave')) == 'Y')
            if lv and tot > 24:
                print('        ! %s totals %.2f h (%.2f of it leave) - over the '
                      '24h day rule' % (d.title(), tot, lv))


if __name__ == '__main__':
    main()
