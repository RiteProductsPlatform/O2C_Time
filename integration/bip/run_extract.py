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
from extracts import ALL_EXTRACTS, BY_NAME, VERIFIED

CATALOG_FOLDER = "/Custom/O2C_TIME"


def _load_dotenv() -> None:
    """
    Read integration/bip/.env into the environment, if it exists.

    Exists so the credentials stop being retyped — or pasted into chat, which
    has happened more than once and is how a password ends up somewhere it
    cannot be rotated from. The file is git-ignored; see .env.example.

    Deliberately does NOT overwrite a variable that is already set, so an
    explicit `$env:FUSION_PASSWORD = ...` for a one-off run still wins over the
    file, and a CI runner's injected secrets are never clobbered by a stray
    checked-out .env.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.exists(path):
        return
    with io.open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = val


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
                                 defaults={"P_EFFECTIVE_DATE": args.effective_date,
                                           "P_LAST_SYNC": args.since})
        try:
            c.upload_data_model(path, xdm)
            print("  deployed  %-12s -> %s" % (ex["name"], path))
        except BipError as exc:
            print("  FAILED    %-12s %s" % (ex["name"], exc))
            rc = 1
    return rc


def _run_one(c: BipClient, ex: Dict, eff: str, chunked: bool,
             since: str = "1900-01-01") -> List[Dict[str, str]]:
    """
    Push the current SQL, then run it.

    THE MODEL IS ALWAYS REDEPLOYED, and that is the whole point of this
    function. It used to run whatever was already in the catalog and only
    deploy when nothing was there, which meant an edit to extracts.py silently
    had no effect on --run or --load: the pod kept executing the SQL from
    whenever it was last deployed.

    That is not theoretical. Scoping the sync to 46 projects validated at 46 and
    then loaded 424, because --validate compiles the SQL fresh while --run
    reused a model deployed before the change. Nothing errored; the numbers were
    just wrong, which is the same silent-staleness family as README note 2.

    An account with only run rights cannot deploy. That is a legitimate
    production split, so the upload failing is not fatal — but it does mean the
    SQL on the pod is somebody else's, so say so rather than let it pass.
    """
    path = model_path(ex["name"])
    params = {}
    if ":P_EFFECTIVE_DATE" in ex["sql"]:
        params["P_EFFECTIVE_DATE"] = eff
    # Always sent when the model declares it. Omitting a declared bind is
    # the silent-zero-rows failure the module docstring warns about.
    if ":P_LAST_SYNC" in ex["sql"]:
        params["P_LAST_SYNC"] = since
    params = params or None

    try:
        xdm = c.build_data_model(
            ex["sql"], ex["columns"],
            description="O2C Time %s (%s -> %s)"
                        % (ex["name"], ex["integration"], ex["target"]),
            defaults={"P_EFFECTIVE_DATE": eff, "P_LAST_SYNC": since})
        c.upload_data_model(path, xdm)
    except BipError as exc:
        if not c.object_exists(path):
            raise
        print("  ! %s: could not redeploy (%s). Running the model already in "
              "the catalog — its SQL may not match extracts.py."
              % (ex["name"], str(exc)[:80]))

    raw = c.run_data_model(path, params=params, chunked=chunked)
    return c.rows(raw)


def _dup_keys(ex, rows):
    """Rows whose declared key is not unique. Empty list when the key holds.

    Every extract carries a "key" naming the columns the loader MERGEs on, and
    until 10-Aug-2026 NOTHING READ IT -- it was a comment in the shape of code.
    That is worth stating plainly: a duplicate key is not a cosmetic problem.
    MERGE refuses two source rows matching one target row with ORA-30926,
    "unable to get a stable set of rows in the source tables", which names
    neither the report nor the offending values, and the feed simply stops.

    Found by measuring WORKERS: 5991 rows, 5850 people, 140 rehires each
    holding two periods of service. The extract had looked healthy since the
    day it was written.
    """
    key = ex.get("key") or []
    if not key:
        return []
    seen, dup = set(), []
    for r in rows:
        k = tuple(r.get(c, "") for c in key)
        if k in seen:
            dup.append(k)
        seen.add(k)
    return dup


def cmd_validate(args) -> int:
    c = _client(args)
    eff = args.effective_date
    rc = 0
    print("%-12s %-10s %8s %7s  %s"
          % ("EXTRACT", "STATUS", "ROWS", "DUPKEYS", "TARGET"))
    print("-" * 74)
    for ex in _selected(args.validate):
        path = model_path(ex["name"])
        try:
            # EVERY bind must be inlined, not just the one we remember. This
            # inlined P_EFFECTIVE_DATE only, so when P_LAST_SYNC was added the
            # probe still carried an unbound :P_LAST_SYNC -> NULL ->
            # GREATEST(...) > NULL is never true -> all eleven extracts reported
            # "ok, 0 rows". Exactly the silent-zero the module docstring warns
            # about, reproduced by the tool meant to catch it.
            sql = (ex["sql"].replace(":P_EFFECTIVE_DATE", "'%s'" % eff)
                            .replace(":P_LAST_SYNC", "'%s'" % args.since))
            left = [b for b in ("P_EFFECTIVE_DATE", "P_LAST_SYNC")
                    if ":" + b in sql]
            if left:
                raise BipError("bind(s) not inlined for the probe: %s — the "
                               "count would be meaningless" % ", ".join(left))
            probe = "SELECT COUNT(*) AS N FROM (%s)" % sql
            n = c.query(probe, ["N"], path=CATALOG_FOLDER + "/_validate.xdm")
            count = n[0]["N"] if n else "?"

            # The declared key, checked in the database rather than by pulling
            # every row back. A non-zero here means the MERGE will raise
            # ORA-30926 and the feed will not load at all.
            dups = "-"
            key = ex.get("key") or []
            if key and str(count).isdigit():
                dprobe = ("SELECT COUNT(*) AS N FROM (SELECT DISTINCT %s FROM (%s))"
                          % (", ".join(key), sql))
                dn = c.query(dprobe, ["N"],
                             path=CATALOG_FOLDER + "/_validate.xdm")
                if dn and str(dn[0]["N"]).isdigit():
                    dups = int(count) - int(dn[0]["N"])
                    if dups:
                        rc = 1
                        dups = "%d BAD" % dups

            print("%-12s %-10s %8s %7s  %s"
                  % (ex["name"], "ok", count, dups, ex["target"]))
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
            rows = _run_one(c, ex, eff, args.chunked, args.since)
        except BipError as exc:
            print("  FAILED  %-12s %s" % (ex["name"], str(exc)[:160]))
            rc = 1
            continue

        target = os.path.join(args.out, "%s.csv" % ex["name"].lower())
        cols = ex["columns"]
        with io.open(target, "w", encoding="utf-8", newline="") as fh:
            bad = _dup_keys(ex, rows)
            if bad:
                print("  %-12s WARNING  %d duplicate %s key(s); the MERGE will "
                      "raise ORA-30926. e.g. %s"
                      % (ex["name"], len(bad), "+".join(ex["key"]), bad[0]))
            w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k in cols})
        print("  %-12s %7d rows  %5.1fs  -> %s"
              % (ex["name"], len(rows), time.time() - t0, target))
    return rc


# Which sync endpoint each extract loads through, and in what order.
#
# ORDER IS A FOREIGN-KEY CONSTRAINT, not a preference. OC_TIME_ALLOCATION has
# FKs to both project and worker, OC_TIME_TASK to project. Load allocations
# first and every row lands in OC_TIME_SYNC_FAILED.
LOAD_ORDER = [
    ("WORKERS", "worker"),
    ("PROJECTS", "project"),
    ("TASKS", "task"),
    ("ALLOCATIONS", "allocation"),
    ("ABSENCES", "absence"),
]

# 500 rows per POST. Small enough that one CLOB stays comfortable and a failure
# costs little to repeat; large enough that 5,976 workers is twelve calls.
CHUNK = 500


def cmd_load(args) -> int:
    """
    Extract from Fusion, then POST into the ORDS cache.

    This is the step that did not exist: --run wrote a CSV and stopped, so the
    inbound path ended at a file and OC_TIME_* stayed empty.

    The MERGE deliberately lives in ORDS, not here. It sits next to the
    constraints it has to satisfy, and any caller — this loader, OIC, a manual
    repair — gets identical behaviour. This end only chunks and reports.
    """
    import json
    import urllib.request

    base = args.ords_base or os.environ.get("ORDS_BASE_URL")
    if not base:
        raise SystemExit("--load needs --ords-base or ORDS_BASE_URL "
                         "(e.g. https://host/ords/o2c_time)")
    base = base.rstrip("/")

    c = _client(args)
    eff = args.effective_date
    selected = {e["name"] for e in _selected(args.load)}
    rc = 0

    for name, entity in LOAD_ORDER:
        if name not in selected:
            continue

        ex = BY_NAME[name]
        try:
            rows = _run_one(c, ex, eff, args.chunked, args.since)
        except BipError as exc:
            print("  FAILED  %-12s extract: %s" % (name, str(exc)[:120]))
            rc = 1
            continue

        cols = ex["columns"]
        job_id: Optional[int] = None
        up = fail = 0
        t0 = time.time()

        for i in range(0, len(rows), CHUNK):
            chunk = [{k: r.get(k, "") for k in cols} for r in rows[i:i + CHUNK]]
            payload = {
                "rows": chunk,
                "actor": "BIP_LOADER",
                # The job id threads through every chunk so a 6,000-row load is
                # ONE row on the Sync Status page rather than twelve.
                "jobRunId": job_id,
                "final": "Y" if i + CHUNK >= len(rows) else "N",
            }
            req = urllib.request.Request(
                "%s/oc/time/admin/sync/%s" % (base, entity),
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST")
            try:
                with urllib.request.urlopen(req, timeout=300) as resp:
                    body = json.loads(resp.read().decode("utf-8"))
            except Exception as exc:                      # noqa: BLE001
                print("  FAILED  %-12s chunk %d: %s"
                      % (name, i // CHUNK, str(exc)[:120]))
                rc = 1
                break

            if body.get("error"):
                print("  FAILED  %-12s chunk %d: %s"
                      % (name, i // CHUNK, body["error"][:120]))
                rc = 1
                break

            job_id = body.get("jobRunId", job_id)
            up += body.get("upserted", 0)
            fail += body.get("failed", 0)

        flag = "  <-- check sync/failed" if fail else ""
        print("  %-12s %6d upserted  %4d failed  %5.1fs  job %s%s"
              % (name, up, fail, time.time() - t0, job_id, flag))

    print("\nRows that failed are queued in OC_TIME_SYNC_FAILED and visible on "
          "the Sync Status page; POST sync/retry/{failedId} re-drives one.")
    return rc


def _selected(value: str) -> List[Dict]:
    """
    Resolve the --run / --validate / --deploy selector to extract definitions.

    "ALL" means every VERIFIED extract, not every extract. An extract whose SQL
    has not been confirmed against a pod can return zero rows while reporting
    success (README note 2), so letting one into the monthly MasterSync by
    default would quietly blank a column nobody had checked. Naming it
    explicitly still runs it — that is how it gets verified in the first place.
    """
    if not value or value.upper() == "ALL":
        skipped = [e["name"] for e in ALL_EXTRACTS if not e.get("verified", True)]
        if skipped:
            print("  (ALL excludes unverified: %s — name them explicitly to run)"
                  % ", ".join(skipped))
        return VERIFIED

    out = []
    for name in value.split(","):
        key = name.strip().upper()
        if key not in BY_NAME:
            raise SystemExit("unknown extract %r; known: %s"
                             % (key, ", ".join(BY_NAME)))
        ex = BY_NAME[key]
        if not ex.get("verified", True):
            print("  ! %s is NOT verified against a pod. Zero rows means the "
                  "object or a literal is wrong, not that there is no data."
                  % ex["name"])
        out.append(ex)
    return out


def main(argv=None) -> int:
    _load_dotenv()
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
    g.add_argument("--load", nargs="?", const="ALL", metavar="NAMES",
                   help="run AND post into the ORDS cache (the full inbound path)")
    ap.add_argument("--out", default="./extracts", help="CSV output directory")
    ap.add_argument("--since", default="1900-01-01", metavar="YYYY-MM-DD",
                    help="incremental cut-off (:P_LAST_SYNC). The default "
                         "1900-01-01 means a FULL REFRESH, which is what the "
                         "monthly run wants. The daily run passes the last "
                         "successful run's timestamp.")
    ap.add_argument("--effective-date", default=date.today().isoformat(),
                    help="AS OF date for the effective-dated joins (YYYY-MM-DD)")
    ap.add_argument("--chunked", action="store_true",
                    help="stage and page the output — use for bulk extracts")
    ap.add_argument("--ords-base", default=None,
                    help="ORDS base for --load, e.g. https://host/ords/o2c_time "
                         "(or set ORDS_BASE_URL)")
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
        if args.load:
            return cmd_load(args)
    except BipError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
