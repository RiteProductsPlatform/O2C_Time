"""
PPM data gaps the timesheet module cannot see, let alone fix.

Run after any master sync:

    python integration/bip/check_ppm_gaps.py

Every finding here is a correction somebody makes in PPM. None of them is a
code fault, and none is visible from the O2C_TIME schema -- which is the point.
A person missing from the feed never arrives to be counted as missing.

WHY THESE TWO TABLES BOTH MATTER
  PJF_PROJECT_PARTIES  team membership. Carries PJS_TRACK_TIME, which is
                       Fusion's own answer to "may this person book time to
                       this project". The ALLOCATIONS extract is anchored here.
  PJT_PROJECT_RESOURCE staffing. Carries ALLOCATION, the percentage.

The Manage Project Resources screen lists somebody once the RESOURCE row
exists, so a missing party row does not show there. Measured 17-Aug-2026 on
PCS10034: RI2824 and RI9001 held both, RI2894 held only the resource, and all
three appeared on screen. RI2894's 25% reached the timesheet as nothing at all.
"""
import sys, os, textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_extract                      # noqa: E402
run_extract._load_dotenv()
from bip_client import BipClient, BipError   # noqa: E402

DISCOVER = "/Custom/O2C_TIME/_discover.xdm"


def run(client, title, why, sql, cols, limit=60):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)
    print(textwrap.fill(textwrap.dedent(why).strip(), 72))
    print()
    try:
        rows = client.query(sql, cols, path=DISCOVER)
    except BipError as exc:
        msg = str(exc)
        ora = [t for t in msg.split() if t.startswith("ORA-")]
        print("  CHECK FAILED: %s" % (ora[0] if ora else msg[:140]))
        return 0
    if not rows:
        print("  clean")
        return 0
    width = [max(len(c), max(len(str(r.get(c, ""))) for r in rows)) for c in cols]
    print("  " + "  ".join(c.ljust(w) for c, w in zip(cols, width)))
    print("  " + "  ".join("-" * w for w in width))
    for r in rows[:limit]:
        print("  " + "  ".join(str(r.get(c, "")).ljust(w)
                               for c, w in zip(cols, width)))
    if len(rows) > limit:
        print("  ... %d more" % (len(rows) - limit))
    print("\n  %d finding(s)" % len(rows))
    return len(rows)


def main():
    c = BipClient()
    total = 0

    total += run(
        c,
        "1. Staffed in PPM, not a project team member",
        """
        These people have an allocation percentage and cannot record time
        against it. Fix: add them as a project TEAM MEMBER in PPM. Restricted
        to projects that somebody tracks time on, so the whole Vision demo
        estate does not report.
        """,
        """
SELECT p.segment1 AS PROJECT, papf.person_number AS PERSON,
       NVL(TO_CHAR(r.allocation),'-') AS ALLOC_PCT,
       TO_CHAR(r.start_date_active,'YYYY-MM-DD') AS FROM_DATE
  FROM pjt_project_resource r
  JOIN pjf_projects_all_b p ON p.project_id = r.project_id
  JOIN per_all_people_f papf ON papf.person_id = r.person_id
   AND TRUNC(SYSDATE) BETWEEN papf.effective_start_date AND papf.effective_end_date
 WHERE NOT EXISTS (SELECT 1 FROM pjf_project_parties pp
                    WHERE pp.project_id = r.project_id
                      AND pp.resource_source_id = r.person_id
                      AND pp.project_party_type = 'IN')
   AND EXISTS (SELECT 1 FROM pjf_project_parties tp
                WHERE tp.project_id = p.project_id
                  AND tp.project_party_type = 'IN'
                  AND tp.pjs_track_time = 'Y')
 ORDER BY p.segment1, papf.person_number
""",
        ["PROJECT", "PERSON", "ALLOC_PCT", "FROM_DATE"])

    total += run(
        c,
        "2. A team member with no staffing record",
        """
        The mirror image: they can book time and we have no percentage, so the
        extract falls back to 100%. Harmless on a single-project person and the
        reason a multi-project one over-allocates.
        """,
        """
SELECT p.segment1 AS PROJECT, papf.person_number AS PERSON,
       NVL(pp.pjs_track_time,'-') AS TRACK_TIME
  FROM pjf_project_parties pp
  JOIN pjf_projects_all_b p ON p.project_id = pp.project_id
  JOIN per_all_people_f papf ON papf.person_id = pp.resource_source_id
   AND TRUNC(SYSDATE) BETWEEN papf.effective_start_date AND papf.effective_end_date
 WHERE pp.project_party_type = 'IN'
   AND pp.pjs_track_time = 'Y'
   AND NOT EXISTS (SELECT 1 FROM pjt_project_resource r
                    WHERE r.project_id = pp.project_id
                      AND r.person_id  = pp.resource_source_id)
 ORDER BY p.segment1, papf.person_number
""",
        ["PROJECT", "PERSON", "TRACK_TIME"])

    total += run(
        c,
        "3. Allocated above 100% on a time-tracked project",
        """
        We apportion the standard day by these percentages, so a total above
        100 produces a day longer than the person works -- 80 hours against 8
        for anyone holding ten projects at 100%. Nothing downstream corrects
        it: the module is faithfully dividing what PPM stated.
        """,
        """
SELECT papf.person_number AS PERSON, SUM(r.allocation) AS TOTAL_PCT,
       COUNT(*) AS PROJECTS
  FROM pjt_project_resource r
  JOIN per_all_people_f papf ON papf.person_id = r.person_id
   AND TRUNC(SYSDATE) BETWEEN papf.effective_start_date AND papf.effective_end_date
 WHERE TRUNC(SYSDATE) BETWEEN NVL(r.start_date_active, TRUNC(SYSDATE))
                          AND NVL(r.end_date_active,   TRUNC(SYSDATE))
   AND EXISTS (SELECT 1 FROM pjf_project_parties tp
                WHERE tp.project_id = r.project_id
                  AND tp.project_party_type = 'IN'
                  AND tp.pjs_track_time = 'Y')
 GROUP BY papf.person_number
HAVING SUM(r.allocation) > 100
 ORDER BY SUM(r.allocation) DESC
""",
        ["PERSON", "TOTAL_PCT", "PROJECTS"], limit=25)

    total += run(
        c,
        "4. Time-tracked project with no Project Manager party",
        """
        RULE-015 routes every approval through the project manager. Without one
        the project reaches the manager landing page for nobody, and its hours
        can be entered and never approved.
        """,
        """
SELECT p.segment1 AS PROJECT, ptl.name AS PROJECT_NAME
  FROM pjf_projects_all_b p
  JOIN pjf_projects_all_tl ptl ON ptl.project_id = p.project_id
   AND ptl.language = USERENV('LANG')
 WHERE EXISTS (SELECT 1 FROM pjf_project_parties tp
                WHERE tp.project_id = p.project_id
                  AND tp.project_party_type = 'IN'
                  AND tp.pjs_track_time = 'Y')
   AND NOT EXISTS (SELECT 1
                     FROM pjf_project_parties mp
                     JOIN pjt_project_roles_vl mr
                       ON mr.project_role_id = mp.project_role_id
                    WHERE mp.project_id = p.project_id
                      AND mp.project_party_type = 'IN'
                      AND mr.name = 'Project Manager')
 ORDER BY p.segment1
""",
        ["PROJECT", "PROJECT_NAME"])

    print("\n" + "=" * 72)
    print("%d finding(s) in total. Every one is a PPM correction." % total)
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
