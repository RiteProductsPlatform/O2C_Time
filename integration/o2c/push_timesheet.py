"""
O2C Time -> main O2C application: consolidated timesheet push.

On month confirmation the Time module is the system of record for time capture.
This hands the confirmed month to the main O2C application, whose existing
timesheet -> accrual chain then generates the accrual. It replaces the RitePulse
feed into the same endpoints.

    O2C_TIME (ORDS)                     main O2C application (ORDS)
    ---------------                     ---------------------------
    GET  push/header/{confirmId}   -->  POST /oc/accrual/timesheet/import
                                          returns tsHeaderId
    GET  push/line/{confirmId}/{e} -->   POST /oc/accrual/timesheet/lines/import/{id}
    POST push/ack/{confirmId}      <--  outcome recorded as PARTNER_STATUS

Both target endpoints upsert, so re-running a month is safe and self-correcting.
That is what makes the retry story simple: on partial failure, run it again.

Two properties of the source worth knowing:

  * the push views read XX_O2C_TIMESHEET_ACCRUAL_IF, which is the frozen,
    manager-confirmed set. Reversal rows are stored there with NEGATIVE hours,
    so a plain SUM nets a retro correction against its Adjustment pair.
  * a project with no MAIN_PROJECT_ID is returned as push_state='BLOCKED'
    rather than filtered out, so a month that cannot be handed over is loud
    rather than silently missing.

Credentials and base URLs come from the environment (NFR-005):

    O2C_TIME_URL   https://<ords-host>/ords/o2c_time
    O2C_MAIN_URL   https://<ords-host>/ords/<main schema>
    O2C_MAIN_USER  optional basic-auth user for the main app
    O2C_MAIN_PASS  optional basic-auth password

Usage:
    python push_timesheet.py --confirm-id 42
    python push_timesheet.py --confirm-id 42 --dry-run
    python push_timesheet.py --confirm-id 42 --generate-accrual
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Dict, List, Optional, Tuple


class PushError(RuntimeError):
    pass


class Rest:
    def __init__(self, base: str, user: Optional[str] = None,
                 password: Optional[str] = None, verify_tls: bool = True,
                 timeout: int = 120):
        self.base = base.rstrip("/")
        self.timeout = timeout
        self._auth = None
        if user:
            raw = ("%s:%s" % (user, password or "")).encode()
            self._auth = "Basic " + base64.b64encode(raw).decode()
        self._ctx = ssl.create_default_context()
        if not verify_tls:
            self._ctx.check_hostname = False
            self._ctx.verify_mode = ssl.CERT_NONE

    def _call(self, method: str, path: str,
              body: Optional[dict] = None) -> Tuple[int, dict]:
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Accept": "application/json"}
        if data:
            headers["Content-Type"] = "application/json"
        if self._auth:
            headers["Authorization"] = self._auth

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=self._ctx) as r:
                raw = r.read().decode("utf-8", "replace")
                return r.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            try:
                return exc.code, json.loads(raw)
            except ValueError:
                return exc.code, {"error": raw[:400]}
        except Exception as exc:
            raise PushError("%s %s unreachable: %s" % (method, url, exc)) from exc

    def get(self, path: str) -> List[dict]:
        status, body = self._call("GET", path)
        if status >= 400:
            raise PushError("GET %s -> %s: %s" % (path, status, body.get("error", body)))
        return body.get("items", [])

    def post(self, path: str, body: dict) -> Tuple[int, dict]:
        return self._call("POST", path, body)


def push_confirmation(confirm_id: int, time_api: Rest, main_api: Rest,
                      dry_run: bool = False,
                      generate_accrual: bool = False) -> int:
    headers = time_api.get("/oc/time/admin/push/header/%d" % confirm_id)
    if not headers:
        print("Nothing to push: confirmation %d has no interface rows." % confirm_id)
        return 1

    blocked = [h for h in headers if h.get("push_state") != "READY"]
    ready = [h for h in headers if h.get("push_state") == "READY"]

    print("confirmation %d: %d employee(s), %d ready, %d blocked"
          % (confirm_id, len(headers), len(ready), len(blocked)))
    for b in blocked:
        print("  BLOCKED  %-10s %s" % (b.get("employee_id"), b.get("push_state")))

    if blocked and not ready:
        print("\nNothing can be pushed. Map MAIN_PROJECT_ID on OC_TIME_PROJECT first.")
        return 1

    if dry_run:
        for h in ready:
            lines = time_api.get("/oc/time/admin/push/line/%d/%s"
                                 % (confirm_id, urllib.parse.quote(str(h["employee_id"]))))
            print("  would push %-10s %6.2f bill / %6.2f non-bill / %6.2f leave, %d day(s)"
                  % (h["employee_id"], float(h["billable_hours"] or 0),
                     float(h["non_billable_hours"] or 0),
                     float(h["leave_hours"] or 0), len(lines)))
        return 0

    ok = 0
    failed: List[str] = []

    for h in ready:
        emp = str(h["employee_id"])
        payload = {
            "projectId":        h["project_id"],
            "employeeId":       emp,
            "employeeName":     h["employee_name"],
            "billingStatus":    h["billing_status"],
            "periodYear":       h["period_year"],
            "periodMonth":      h["period_month"],
            "billableHours":    h["billable_hours"],
            "nonBillableHours": h["non_billable_hours"],
            "leaveHours":       h["leave_hours"],
            "createdBy":        "O2C_TIME",
        }
        status, body = main_api.post("/oc/accrual/timesheet/import", payload)
        if status >= 400 or "tsHeaderId" not in body:
            failed.append("%s: header -> %s %s" % (emp, status, body.get("error", body)))
            print("  FAILED   %-10s %s" % (emp, body.get("error", body)))
            continue

        ts_header_id = body["tsHeaderId"]

        lines = time_api.get("/oc/time/admin/push/line/%d/%s"
                             % (confirm_id, urllib.parse.quote(emp)))
        line_fail = 0
        for ln in lines:
            lstatus, lbody = main_api.post(
                "/oc/accrual/timesheet/lines/import/%s" % ts_header_id,
                {
                    "entryDate":        ln["entry_date"],
                    "billableHours":    ln["billable_hours"],
                    "nonBillableHours": ln["non_billable_hours"],
                    "isLeave":          ln["is_leave"],
                    "remarks":          ln.get("remarks"),
                    "createdBy":        "O2C_TIME",
                })
            if lstatus >= 400:
                line_fail += 1
                failed.append("%s %s: line -> %s" % (emp, ln["entry_date"], lbody.get("error")))

        if line_fail:
            print("  PARTIAL  %-10s header %s, %d/%d line(s) failed"
                  % (emp, ts_header_id, line_fail, len(lines)))
        else:
            ok += 1
            print("  pushed   %-10s header %-8s %d line(s)" % (emp, ts_header_id, len(lines)))

    # Report the outcome back so PAGE-011 can show whether a confirmed month
    # actually landed. Partial counts as Failed: it needs another run, and the
    # endpoints upsert so re-running is safe.
    state = "Success" if (ok == len(ready) and not failed) else "Failed"
    msg = "pushed %d/%d" % (ok, len(ready))
    if blocked:
        msg += "; %d blocked (no MAIN_PROJECT_ID)" % len(blocked)
        state = "Failed"
    time_api.post("/oc/time/admin/push/ack/%d" % confirm_id,
                  {"status": state, "message": msg[:2000]})
    print("\n%s - %s" % (state, msg))

    if state == "Success" and generate_accrual:
        gstatus, gbody = main_api.post("/oc/accrual/accruals/generate",
                                       {"projectId": ready[0]["project_id"],
                                        "periodYear": ready[0]["period_year"],
                                        "periodMonth": ready[0]["period_month"]})
        print("accruals/generate -> %s %s" % (gstatus, gbody))

    if failed:
        print("\nfirst failures:")
        for f in failed[:10]:
            print("  " + f)
    return 0 if state == "Success" else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--confirm-id", type=int, required=True,
                    help="OC_TS_MONTH_CONFIRM.CONFIRM_ID to hand over")
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would be pushed, write nothing")
    ap.add_argument("--generate-accrual", action="store_true",
                    help="call accruals/generate after a fully successful push")
    ap.add_argument("--insecure", action="store_true",
                    help="skip TLS verification (lower environments only)")
    args = ap.parse_args(argv)

    time_url = os.environ.get("O2C_TIME_URL", "")
    main_url = os.environ.get("O2C_MAIN_URL", "")
    missing = [n for n, v in (("O2C_TIME_URL", time_url),
                              ("O2C_MAIN_URL", main_url)) if not v]
    if missing:
        print("Missing environment variable(s): " + ", ".join(missing), file=sys.stderr)
        return 2

    verify = not args.insecure
    time_api = Rest(time_url, verify_tls=verify)
    main_api = Rest(main_url, os.environ.get("O2C_MAIN_USER"),
                    os.environ.get("O2C_MAIN_PASS"), verify_tls=verify)

    try:
        return push_confirmation(args.confirm_id, time_api, main_api,
                                 args.dry_run, args.generate_accrual)
    except PushError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
