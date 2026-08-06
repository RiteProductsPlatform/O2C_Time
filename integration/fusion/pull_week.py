# -*- coding: utf-8 -*-
"""Pull one week's timesheet inputs LIVE from Fusion, the way the screen will.

    python pull_week.py --project DS20001-1 --week 2026-08-03
    python pull_week.py --project 8811 --week 2026-08-03 --person 300000333185728

This is the inbound integration as a runnable thing: no extract, no staged copy,
no database. It asks Fusion for exactly what a timesheet week needs, in the order
the screen needs it, and prints what the grid would be prepopulated with.

WHY IT EXISTS AS A SCRIPT

Where the live call is finally made from - the page through the VB proxy, or the
database - is still open (scope document, open item 22). This settles the part
that does not depend on that decision: which resources answer, what they return,
and which fields are actually populated on this pod. Whichever runtime wins, the
calls below are the calls it has to make.

EVERY ENDPOINT HERE WAS VERIFIED AGAINST THE POD, and two of the obvious guesses
were wrong, so they are recorded:

  * projectPlans/{id}/child/Tasks        404 - does not exist on this pod
  * projectTaskAssignments               404
  * projectPlanResourceAssignments       404
  * projectResourceAssignmentDetails     404
  * personAssignmentLaborSchedules       403 - not entitled for this account

  Task-level resource assignment IS reachable, but only as a child of the task
  and only through the href Fusion returns:
      projects/{id}/child/Tasks -> links[name=LaborResourceAssignments].href
  Constructing that path by hand returns 404. Follow the link.

Read-only. GET only. Credentials come from integration/bip/.env and are never
printed or logged.
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

FSCM = '/fscmRestApi/resources/11.13.18.05'
HCM = '/hcmRestApi/resources/11.13.18.05'


# ── connection ───────────────────────────────────────────────────────────
def load_env(path):
    cfg = {}
    if not os.path.exists(path):
        sys.exit('No .env at %s - set FUSION_BASE_URL / FUSION_USER / '
                 'FUSION_PASSWORD there, or in the environment.' % path)
    for line in io.open(path, encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
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
        """GET, returning (status, body). Absolute hrefs are followed as given."""
        if url.startswith('/'):
            url = self.base + url
        if params:
            url += ('&' if '?' in url else '?') + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={
            'Authorization': 'Basic ' + self.auth,
            'Accept': 'application/json',
            # v4 or the child collections answer with a different envelope
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
            return st, []
        return st, body.get('items', [])


# ── helpers ──────────────────────────────────────────────────────────────
def week_of(datestr):
    d = dt.date.fromisoformat(datestr)
    mon = d - dt.timedelta(days=d.weekday())
    return mon, mon + dt.timedelta(days=6)


def child_href(row, name):
    """The href Fusion gives for a child collection. Do not build these by hand."""
    for l in row.get('links', []):
        if l.get('name') == name and l.get('rel') == 'child':
            return l.get('href')
    return None


def line(ch='-', n=78):
    print(ch * n)


# ── the pull ─────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--project', required=True, help='ProjectNumber, e.g. DS20001-1')
    ap.add_argument('--week', required=True, help='any date in the week, YYYY-MM-DD')
    ap.add_argument('--person', help='Fusion PersonId, for the absence read')
    ap.add_argument('--insecure', action='store_true', help='skip TLS verify (lower envs)')
    a = ap.parse_args()

    mon, sun = week_of(a.week)
    fx = Fusion(load_env(ENV), a.insecure)

    print('POD    %s' % fx.base.split('//')[-1].split('.')[0])
    print('WEEK   %s .. %s' % (mon, sun))
    line('=')

    # 1 ── the project ----------------------------------------------------
    st, rows = fx.items(FSCM + '/projects', {
        'q': "ProjectNumber='%s'" % a.project, 'limit': 1})
    if not rows:
        sys.exit('Project %s not found (status %s).' % (a.project, st))
    p = rows[0]
    pid = p['ProjectId']
    print('PROJECT  %s  %s' % (p.get('ProjectNumber'), p.get('ProjectName')))
    print('         id=%s  status=%s  BU=%s' % (
        pid, p.get('ProjectStatus'), p.get('BusinessUnitName')))
    print('         type=%s  org=%s' % (
        p.get('ProjectTypeName'), p.get('ProjectOrganizationName')))

    # 2 ── who may charge to it -------------------------------------------
    line()
    print('RESOURCES')
    st, team = fx.items(FSCM + '/projects/%s/child/ProjectTeamMembers' % pid,
                        {'limit': 100})
    if not team:
        print('  none - nobody can charge time to this project')
    for t in team:
        print('  %-26s person=%-18s alloc=%s%%  trackTime=%s' % (
            str(t.get('PersonName'))[:26], t.get('PersonId'),
            t.get('ResourceAllocationPercentage'), t.get('TrackTimeFlag')))
        print('        role=%s  %s .. %s' % (
            t.get('ProjectRole'), t.get('StartDate'), t.get('FinishDate') or 'open'))
        if not t.get('TrackTimeFlag'):
            print('        ^ TrackTimeFlag is false - this project is INVISIBLE to '
                  'time entry until it is set')

    st, lab = fx.items(FSCM + '/projectLaborResources',
                       {'q': 'ProjectId=%s' % pid, 'limit': 100})
    for r in lab:
        print('  labour: %-22s alloc=%s%%  status=%s  %s .. %s' % (
            str(r.get('Name'))[:22], r.get('Allocation'),
            r.get('AssignmentStatusCode'), r.get('FromDate'), r.get('ToDate') or 'open'))
        if r.get('AssignmentStatusCode') == 'PLANNING_ONLY':
            print('        ^ PLANNING_ONLY - planned, not a confirmed assignment')

    # 3 ── tasks, and who is assigned to each ------------------------------
    line()
    print('TASKS  (chargeable ones are what a timesheet line can point at)')
    st, tasks = fx.items(FSCM + '/projects/%s/child/Tasks' % pid, {'limit': 200})
    chargeable = []
    task_assign = 0
    for t in tasks:
        ch = bool(t.get('ChargeableFlag'))
        if ch:
            chargeable.append(t)
        href = child_href(t, 'LaborResourceAssignments')
        assigns = []
        if href:
            _, assigns = fx.items(href, {'limit': 50})
            task_assign += len(assigns)
        print('  %-8s %-30s chargeable=%-5s billable=%-5s assigned=%d' % (
            t.get('TaskNumber'), str(t.get('TaskName'))[:30], ch,
            bool(t.get('BillableFlag')), len(assigns)))
        for x in assigns:
            print('           -> %s  %s' % (
                x.get('ResourceName') or x.get('PersonName') or x.get('ResourceId'),
                x.get('PlannedEffort') or ''))

    # 4 ── POET ------------------------------------------------------------
    line()
    print('POET')
    print('  P  project            %s' % p.get('ProjectNumber'))
    print('  O  expenditure org    %s' % (p.get('ProjectOrganizationName') or
                                          '(from the person\'s assignment)'))
    print('  T  chargeable tasks   %d of %d' % (len(chargeable), len(tasks)))
    st, et = fx.items(FSCM + '/expenditureTypes', {'limit': 200})
    hours = [e for e in et if (e.get('UnitOfMeasure') or '').upper() in ('HOURS', 'HRS')]
    print('  E  expenditure types  %d total%s' % (
        len(et), (', %d in HOURS' % len(hours)) if hours else
        ' (UOM not returned on this pod - confirm which are HOURS)'))

    # 5 ── absence for the week -------------------------------------------
    if a.person:
        line()
        print('ABSENCE  person %s, %s .. %s' % (a.person, mon, sun))
        # ' AND ', never ';'. The semicolon separator returns 400 on this pod.
        # Overlap, not containment: an absence that began last week and runs into
        # this one still puts leave on these days, and startDate>=monday misses it.
        st, abs_ = fx.items(HCM + '/absences', {
            'q': "personId=%s AND endDate>='%s' AND startDate<='%s'"
                 % (a.person, mon, sun),
            'limit': 50})
        if st != 200:
            print('  status %s - check the query syntax or the entitlement' % st)
        elif not abs_:
            print('  none in this week')
        for x in abs_:
            print('  %s .. %s  %s h  status=%s/%s' % (
                x.get('startDate'), x.get('endDate'), x.get('duration'),
                x.get('absenceStatusCd'), x.get('approvalStatusCd')))

    # 6 ── what the grid would show ---------------------------------------
    line('=')
    print('WHAT THE TIMESHEET WOULD PREPOPULATE')
    if not team:
        print('  nothing - no team member on the project')
    elif not chargeable:
        print('  nothing - no chargeable task to charge against')
    elif task_assign == 0:
        print('  One line per person, on the FIRST chargeable task (%s %s),' % (
            chargeable[0].get('TaskNumber'), chargeable[0].get('TaskName')))
        print('  because no task-level assignment came back. Hours per working day')
        print('  = standard hours x allocation %.')
        for t in team:
            print('    %-24s -> %s  at %s%%' % (
                str(t.get('PersonName'))[:24], chargeable[0].get('TaskNumber'),
                t.get('ResourceAllocationPercentage')))
    else:
        print('  Task-level assignments exist (%d) - a line per assigned task.'
              % task_assign)
    blockers = []
    if not team:
        blockers.append('no team member')
    if not chargeable:
        blockers.append('no chargeable task')
    if team and not any(t.get('TrackTimeFlag') for t in team):
        blockers.append('TrackTimeFlag false for every team member')
    if blockers:
        print('\n  BLOCKED BY: ' + '; '.join(blockers))

    line()
    print('%d REST calls.' % fx.calls)


if __name__ == '__main__':
    main()
