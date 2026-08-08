# -*- coding: utf-8 -*-
"""Read one person's absences LIVE from Fusion and show them as timesheet rows.

    python pull_absence.py --person-number RI2824 --from 2026-08-01 --to 2026-08-31
    python pull_absence.py --person-number RI2824 --week 2026-08-03

This is the absence half of the inbound integration on its own, because absence
is the one input that is read per person per date at page load rather than
prepopulated (RULE-008: leave is system-owned by Absence Management, the employee
cannot type it and cannot delete it).

TWO LOOKUPS, AND THE FIRST IS THE ONE PEOPLE GET WRONG
  /hcmRestApi/.../absences takes personId - the internal numeric id. It does NOT
  take PersonNumber, and passing the person number returns 200 with zero items,
  which reads exactly like "this person has no leave". So the person number is
  resolved to a PersonId first, and the resolution is printed.

QUERY TRAPS, both already paid for on this pod
  * the filter separator is ' AND ', never ';' - a semicolon returns 400
  * filter on OVERLAP, not containment. An absence that started before the window
    and runs into it still puts leave on these days, so the test is
    endDate >= from AND startDate <= to. Using startDate >= from silently drops it.

Read-only. GET only. Credentials come from integration/bip/.env, never printed.
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
    for k in ('FUSION_BASE_URL', 'FUSION_USER', 'FUSION_PASSWORD'):
        cfg[k] = os.environ.get(k, cfg.get(k, ''))
        if not cfg[k]:
            sys.exit('%s is not set.' % k)
    return cfg


class Fusion:
    def __init__(self, cfg, insecure=False):
        self.base = cfg['FUSION_BASE_URL'].rstrip('/')
        self.auth = base64.b64encode(
            ('%s:%s' % (cfg['FUSION_USER'], cfg['FUSION_PASSWORD'])).encode()).decode()
        self.ctx = ssl.create_default_context()
        if insecure:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE
        self.calls = 0

    def get(self, url, params=None, timeout=90):
        if url.startswith('/'):
            url = self.base + url
        if params:
            url += ('&' if '?' in url else '?') + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={
            'Authorization': 'Basic ' + self.auth,
            'Accept': 'application/json',
            'REST-Framework-Version': '4',
        })
        self.calls += 1
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=self.ctx) as r:
                return r.status, json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode('utf-8', 'replace')[:300]
        except Exception as e:                                   # noqa: BLE001
            return 0, str(e)[:300]

    def items(self, url, params=None):
        st, body = self.get(url, params)
        if st != 200 or not isinstance(body, dict):
            return st, [], body
        return st, body.get('items', []), body


def resolve_person(fx, person_number):
    """PersonNumber -> PersonId. Tries each resource and reports what answered."""
    tries = [
        ('workers', HCM + '/workers', "PersonNumber='%s'" % person_number),
        ('emps', HCM + '/emps', "PersonNumber='%s'" % person_number),
        ('publicWorkers', HCM + '/publicWorkers', "PersonNumber='%s'" % person_number),
    ]
    for label, path, q in tries:
        st, rows, body = fx.items(path, {'q': q, 'limit': 5})
        if st != 200:
            print('  %-14s %s  %s' % (label, st, str(body)[:110].replace('\n', ' ')))
            continue
        print('  %-14s 200  %d row(s)' % (label, len(rows)))
        if rows:
            r = rows[0]
            pid = r.get('PersonId')
            name = (r.get('DisplayName') or r.get('PersonName')
                    or ((r.get('names') or [{}])[0].get('DisplayName')))
            return pid, name, label
    return None, None, None


def daterange(a, b):
    d = a
    while d <= b:
        yield d
        d += dt.timedelta(days=1)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--person-number', help='e.g. RI2824')
    ap.add_argument('--person-id', help='Fusion PersonId, if already known')
    ap.add_argument('--week', help='any date in the week, YYYY-MM-DD')
    ap.add_argument('--from', dest='dfrom', help='YYYY-MM-DD')
    ap.add_argument('--to', dest='dto', help='YYYY-MM-DD')
    ap.add_argument('--insecure', action='store_true')
    a = ap.parse_args()

    if a.week:
        d = dt.date.fromisoformat(a.week)
        lo = d - dt.timedelta(days=d.weekday())
        hi = lo + dt.timedelta(days=6)
    elif a.dfrom and a.dto:
        lo, hi = dt.date.fromisoformat(a.dfrom), dt.date.fromisoformat(a.dto)
    else:
        sys.exit('Give --week, or --from and --to.')

    fx = Fusion(load_env(ENV), a.insecure)
    print('POD     %s' % fx.base.split('//')[-1].split('.')[0])
    print('WINDOW  %s .. %s' % (lo, hi))
    print('=' * 78)

    pid, name = a.person_id, None
    if not pid:
        print('RESOLVING %s' % a.person_number)
        pid, name, via = resolve_person(fx, a.person_number)
        if not pid:
            sys.exit('\nCould not resolve %s to a PersonId on this pod.'
                     % a.person_number)
        print('  -> PersonId %s  %s  (via %s)' % (pid, name or '', via))

    print('-' * 78)
    print('ABSENCES')
    st, rows, body = fx.items(HCM + '/absences', {
        'q': "personId=%s AND endDate>='%s' AND startDate<='%s'" % (pid, lo, hi),
        'limit': 100})
    if st != 200:
        print('  status %s  %s' % (st, str(body)[:250]))
        sys.exit(1)
    if not rows:
        print('  none returned for this window.')
    for x in rows:
        print('  %s .. %s  dur=%-6s type=%-22s status=%s / %s' % (
            x.get('startDate'), x.get('endDate'), x.get('duration'),
            str(x.get('absenceType') or x.get('absenceTypeId'))[:22],
            x.get('absenceStatusCd'), x.get('approvalStatusCd')))
        for k in ('absenceTypeId', 'startDateDuration', 'endDateDuration',
                  'absencePatternCd', 'employer', 'startTime', 'endTime'):
            if x.get(k) is not None:
                print('        %-18s %s' % (k, x.get(k)))

    # ── what the timesheet would draw ────────────────────────────────────
    print('-' * 78)
    print('AS TIMESHEET LEAVE ROWS')
    # An absence is a span; the grid is a cell per day. Expand it, and count only
    # the days inside the window - a leave that runs past the window contributes
    # only its overlapping days to this week.
    per_day = {}
    for x in rows:
        try:
            s = dt.date.fromisoformat(str(x.get('startDate'))[:10])
            e = dt.date.fromisoformat(str(x.get('endDate'))[:10])
        except (TypeError, ValueError):
            print('  ! unparseable dates on one row, skipped: %s .. %s'
                  % (x.get('startDate'), x.get('endDate')))
            continue
        span = [d for d in daterange(max(s, lo), min(e, hi))]
        if not span:
            continue
        # duration is the WHOLE absence in days; split it across its own length,
        # not across the visible part, or a leave straddling the window inflates.
        whole = (e - s).days + 1
        try:
            dur = float(x.get('duration') or whole)
        except (TypeError, ValueError):
            dur = float(whole)
        per_dayval = dur / whole if whole else 0.0
        for d in span:
            per_day.setdefault(d, []).append((x.get('absenceStatusCd'), per_dayval))

    if not per_day:
        print('  no leave falls inside the window.')
    for d in sorted(per_day):
        parts = per_day[d]
        days = sum(p[1] for p in parts)
        sts = '/'.join(sorted({str(p[0]) for p in parts}))
        print('  %s  %-3s  leave %.2f day(s)  ~%.2f h at 8h/day   [%s]' % (
            d, d.strftime('%a'), days, days * 8, sts))

    print('-' * 78)
    print('%d REST calls.' % fx.calls)
    print('NOTE  status SUBMITTED/Scheduled is a FUTURE approved absence and still '
          'blocks\n      time entry; Completed is one that has already been taken.')


if __name__ == '__main__':
    main()
