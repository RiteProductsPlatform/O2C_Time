"""
O2C Time — deploy and run the Fusion BIP master-data extracts.

    # one-off: check connectivity and entitlements
    python run_extract.py --check

    # validate every extract compiles and returns rows, without writing files
    python run_extract.py --validate

    # deploy the data models into the Fusion catalog (do this once per pod)
    python run_extract.py --deploy

    # run them and write CSV
    python run_extract.py --run ALL --out ./extracts
    python run_extract.py --run WORKERS --effective-date 2026-08-01

Scheduling: --run ALL is the monthly MasterSync. It must complete BEFORE
MonthlyPopulation, or the month is built from last month's allocations.
Daily deltas are a REST job, not this.
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import sys
import time
from datetime import date
from typing import Dict, List, Optional

from bip_client import BipClient, BipError
from extracts import ALL_EXTRACTS, BY_NAME

CATALOG_FOLDER = "/Custom/O2C_TIME"


def model_path(name: str) -> str:
    return "%s/O2C_%s.xdm" % (CATALOG_FOLDER, name)


def _client(args) -> BipClient:
    return BipClient(verify_tls=not args.insecure)


def cmd_check(args) -> int:
    c = _client(args)
    print("base url : %s" % c.base_url)
    print("user     : %s" % c.user)
    if not c.validate_login():
        print("login    : FAILED — check FUSION_USER / FUSION_PASSWORD")
        return 1
    print("login    : ok")
    ent = c.entitlements()
    for k, v in ent.items():
        print("  %-22s %s" % (k, "yes" if v else "no"))
    if not ent.get("isDataModelDeveloper"):
        print("\nWARNING: the account cannot author data models, so --deploy "
              "will fail. It can still --run models someone else deployed.")
    return 0


def cmd_deploy(args) -> int:
    c = _client(args)
    rc = 0
    for ex in _selected(args.deploy):
        path = model_path(ex["name"])
        # The default matters: it is what a manual run in the BIP UI uses, and
        # it keeps a scheduled run sane if the caller forgets the parameter.
        xdm = c.build_data_model(ex["sql"], ex["columns"],
                                 description="O2C Time %s (%s -> %s)"
                                 % (ex["name"], ex["integration"], ex["target"]),
                                 defaults={"P_EFFECTIVE_DATE": args.effective_date})
        try:
            c.upload_data_model(path, xdm)
            print("  deployed  %-12s -> %s" % (ex["name"], path))
        except BipError as exc:
            print("  FAILED    %-12s %s" % (ex["name"], exc))
            rc = 1
    return rc


def _run_one(c: BipClient, ex: Dict, eff: str, chunked: bool) -> List[Dict[str, str]]:
    """Run a deployed model; fall back to an ad-hoc deploy if it is absent."""
    path = model_path(ex["name"])
    params = {"P_EFFECTIVE_DATE": eff} if ":P_EFFECTIVE_DATE" in ex["sql"] else None

    if not c.object_exists(path):
        # Substitute the bind inline — an ad-hoc model has no parameter defined.
        sql = ex["sql"].replace(":P_EFFECTIVE_DATE", "'%s'" % eff)
        c.upload_data_model(path, c.build_data_model(sql, ex["columns"]))
        params = None

    raw = c.run_data_model(path, params=params, chunked=chunked)
    return c.rows(raw)


def cmd_validate(args) -> int:
    c = _client(args)
    eff = args.effective_date
    rc = 0
    print("%-12s %-10s %8s  %s" % ("EXTRACT", "STATUS", "ROWS", "TARGET"))
    print("-" * 66)
    for ex in _selected(args.validate):
        path = model_path(ex["name"])
        try:
            sql = ex["sql"].replace(":P_EFFECTIVE_DATE", "'%s'" % eff)
            probe = "SELECT COUNT(*) AS N FROM (%s)" % sql
            n = c.query(probe, ["N"], path=CATALOG_FOLDER + "/_validate.xdm")
            count = n[0]["N"] if n else "?"
            print("%-12s %-10s %8s  %s" % (ex["name"], "ok", count, ex["target"]))
        except BipError as exc:
            msg = str(exc)
            ora = [t for t in msg.split() if t.startswith("ORA-")]
            print("%-12s %-10s %8s  %s"
                  % (ex["name"], "FAILED", "-", (ora[0] if ora else msg[:60])))
            if args.verbose:
                print("      %s" % msg[:500])
            rc = 1
    return rc


def cmd_run(args) -> int:
    c = _client(args)
    eff = args.effective_date
    os.makedirs(args.out, exist_ok=True)
    rc = 0
    for ex in _selected(args.run):
        t0 = time.time()
        try:
            rows = _run_one(c, ex, eff, args.chunked)
        except BipError as exc:
            print("  FAILED  %-12s %s" % (ex["name"], str(exc)[:160]))
            rc = 1
            continue

        target = os.path.join(args.out, "%s.csv" % ex["name"].lower())
        cols = ex["columns"]
        with io.open(target, "w", encoding="utf-8", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k in cols})
        print("  %-12s %7d rows  %5.1fs  -> %s"
              % (ex["name"], len(rows), time.time() - t0, target))
    return rc


def _selected(value: str) -> List[Dict]:
    if not value or value.upper() == "ALL":
        return ALL_EXTRACTS
    out = []
    for name in value.split(","):
        key = name.strip().upper()
        if key not in BY_NAME:
            raise SystemExit("unknown extract %r; known: %s"
                             % (key, ", ".join(BY_NAME)))
        out.append(BY_NAME[key])
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="connectivity + entitlements")
    g.add_argument("--deploy", nargs="?", const="ALL", metavar="NAMES",
                   help="deploy data models (default ALL)")
    g.add_argument("--validate", nargs="?", const="ALL", metavar="NAMES",
                   help="compile and count rows, write nothing")
    g.add_argument("--run", nargs="?", const="ALL", metavar="NAMES",
                   help="run and write CSV")
    ap.add_argument("--out", default="./extracts", help="CSV output directory")
    ap.add_argument("--effective-date", default=date.today().isoformat(),
                    help="AS OF date for the effective-dated joins (YYYY-MM-DD)")
    ap.add_argument("--chunked", action="store_true",
                    help="stage and page the output — use for bulk extracts")
    ap.add_argument("--insecure", action="store_true",
                    help="skip TLS verification (lower environments only)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    try:
        if args.check:
            return cmd_check(args)
        if args.deploy:
            return cmd_deploy(args)
        if args.validate:
            return cmd_validate(args)
        if args.run:
            return cmd_run(args)
    except BipError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
