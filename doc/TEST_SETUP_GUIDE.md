# O2C Time Module — Fusion Setup & Test Data Guide

> How to set up calendars and absences in Oracle Fusion for the 12 workers already
> loaded via HDL, so the SC-01 … SC-25 scenarios can be tested.
>
> Assessed against `HDL/Worker/Worker.dat` (as loaded) and the as-built
> `O2C_Time/` module. Prepared 2026-07-30.

---

## 0. Read this first — the two-track problem

**The inbound OIC flows do not exist yet.** INT-001…006 are designed; nothing
actually moves data from Fusion into `OC_TIME_WORKER`, `OC_TIME_CALENDAR`,
`OC_TIME_ABSENCE` etc.

So setting up Fusion perfectly will **not** make the app testable on its own. You
need two tracks, and they answer different questions:

| Track | What it proves | Do it when |
|---|---|---|
| **A — Seed the ATP cache directly** (`db/90_test_seed.sql`) | The 25 functional scenarios, all business rules, the whole UI | **Now.** Unblocks testing today. |
| **B — Set up Fusion properly** (this guide) | That the *integration* reads the right objects and maps them correctly | Before/with the OIC build |

Track B is what you asked about and is below. Track A is the companion script so
you are not blocked waiting for OIC.

---

## 1. What you already have

`Worker.dat` loaded 12 workers, all `WorkerType = E`, all US / NewYork /
US1 Business Unit, all hired 2024-01-01. Jobs came from `Job.dat`.

**The line-manager hierarchy is already there** (`AssignmentSupervisor`), which is
genuinely useful — it gives you RULE-015 for free:

```
RI9001  Navamani Solairajan        (Manager)
   └── RI2894  Santosh Kumar Kanala   (Product Specialist)   ← line manager of 10
         ├── RI2249  Saicharan Vadlakonda
         ├── RI2900  SaiSowmith Kantipudi
         ├── RI2824  Sam Joshuva Paul Jeevan S
         ├── RI2963  Shaik Wajahad Ali
         ├── RI2985  Aadhiseshan Anandavijaya
         ├── RI2935  Shivani Rathore
         ├── RI3004  Gayathri Radhakrishnan
         ├── CRI0406 Ranganayaki Venugopalan
         ├── CRI0398 Kishore Krovvidi
         └── RI2914  Venkata Bhaskar Reddy Sang
```

Santosh manages ten people, and **Navamani manages Santosh** — so Santosh's own
timesheet is approved by Navamani, never by himself. That is exactly what
`CHK_OC_TSA_SELF` / RULE-015 enforces, and you can now test it with real data.

## 2. What is missing in Fusion

| Gap | Blocks | Severity |
|---|---|---|
| **No work schedules or schedule assignments** | Shift per day (FLD-008), standard hours (FLD-011), RULE-011, SC-05 | High — population has nothing to resolve |
| **No calendar events / holidays** | Corporate layer, SC-03, SC-21 | High |
| **No absence records** | Leave rows (FLD-014, RULE-008), leave-loss absentees (PROC-006, SC-12) | High |
| **No contingent worker** — all 12 are `WorkerType = E` | SC-11, RULE-021, and RA-012 stays unanswerable | Medium |
| **All workers in one country** | Deputation / base-vs-deputed country (PROC-001) | Low — acceptable for now |
| **No PPM projects / tasks / resource assignments** | Everything (there is nothing to charge to) | High — but FSCM, not HDL |

---

## 3. Fusion setup, in dependency order

### 3.1 Calendar events — the CORPORATE layer

**Setup and Maintenance → Workforce Deployment → Workforce Structures → Manage Calendar Events**

Create public holidays with coverage by **Geography = United States** (or by Legal
Employer `US1 Legal Entity` if you want them to apply to exactly your test set).

For July 2026, note that **4-Jul-2026 falls on a Saturday**, so the US observes it
on **Friday 3-Jul-2026** — which is realistically useful because it lands in
Week 1 and gives you a mid-week holiday to test against:

| Date | Name | Category | Coverage |
|---|---|---|---|
| 2026-07-03 | Independence Day (observed) | Public Holiday | Geography = United States |
| 2026-09-07 | Labor Day | Public Holiday | Geography = United States |

> **Naming matters.** The sync will write `OC_TIME_CALENDAR.SCOPE_KEY` from the
> worker's country. My seed used the literal string `'United States'`. Whatever
> the sync derives — `US`, `USA`, `United States` — must match exactly, because
> `resolve_day` looks the scope key up with `=`, not a fuzzy match. Pick one form
> and use it in both places.

HDL alternative: `CalendarEvent.dat` supports this business object if you prefer
loading over the UI.

### 3.2 Shifts → Workday patterns → Work schedules → assignment

This is the four-step chain that produces both **standard hours** and the
**shift name** the grid shows read-only.

Because RULE-011 requires a *named* shift per employee per day, use a
**Time work schedule** (start/end times), not just Elapsed. Elapsed gives you
hours but no shift identity.

**Step 1 — Manage Shifts.** Create shifts matching the `SHIFT_TYPE` lookup already
seeded in `OC_TIME_LOOKUP`:

| Shift name | Type | Start | End | Hours |
|---|---|---|---|---|
| Regular | Time | 09:00 | 18:00 | 8 (1h unpaid break) |
| Night | Time | 22:00 | 06:00 | 8 |
| Early | Time | 06:00 | 15:00 | 8 |
| Split | Time | — | — | 8 (two blocks) |

**Step 2 — Manage Workday Patterns.** A 7-day pattern:
`Mon–Fri = Regular`, `Sat/Sun = off`. Create a second pattern with
`Thu = Night` if you want the SC-21 precedence test (§4).

**Step 3 — Manage Work Schedules.** Wrap the pattern in a schedule, e.g.
`US-STD-8H`, effective from 2024-01-01 so it covers your hire dates.

**Step 4 — Assign it.** Either:
- **Manage Work Schedule Assignment Administration** — assign at
  *Legal Employer = US1 Legal Entity* so all 12 inherit it in one action; then
- override for **one** worker (see §4) to prove the SHIFT layer beats the others.

> **Verify the read path before building the sync.** My own INT-004 note flags this
> and it is still open: `scheduleRequests` may be write-only, and work-schedule
> readability over REST varies by release. Confirm with
> `GET /hcmRestApi/resources/11.13.18.05/timeRecordGroups/describe` and
> `.../workSchedules/describe` on *your* pod before committing the OIC mapping.
> If there is no clean read, the fallback is HCM Extracts.

### 3.3 Absence setup

**Setup and Maintenance → Absence Management**

**Step 1 — Manage Absence Plans.** You need at least one qualification or
no-entitlement plan per type; the plan is what makes the type recordable.

**Step 2 — Manage Absence Types.** Create three, because the module treats them
differently:

| Absence type | Purpose in testing | Maps to |
|---|---|---|
| **Vacation** | A normal, coverable absence | `IS_LOP='N'`, `IS_MATERNITY='N'` |
| **Leave Without Pay** | Must be **excluded** from leave-loss coverage and from the billing-loss calculation | `IS_LOP='Y'` |
| **Maternity Leave** | Must be **excluded** from leave-loss coverage | `IS_MATERNITY='Y'` |

**Step 3 — Record the absences.** Absence Administration → Absence Records, or
`Me → Time and Absences → Add Absence`, or HDL `PersonAbsenceEntry.dat`.

All test absences must end up **Approved** — `populate_month` only reads
`approval_status = 'Approved'`, so a Submitted absence will silently not appear.

Suggested records (all in the open July 2026 period):

| Person | Dates | Type | Why |
|---|---|---|---|
| RI2935 Shivani | Mon 2026-07-20, Tue 2026-07-21 | Vacation | The absentee in SC-12 leave-loss coverage |
| RI2914 Venkata | Wed 2026-07-22 | Leave Without Pay | Proves LOP is excluded from the SC-12 absentee list |
| RI3004 Gayathri | — | *(none)* | Must stay absence-free — she is the **cover** in SC-12 |
| RI2824 Sam | Fri 2026-07-10 | Vacation | A leave row on the primary test employee's grid (FLD-014) |

> **A gap this exposes.** `OC_TIME_ABSENCE` has `IS_LOP` and `IS_MATERNITY`
> booleans, but nothing in the build maps a *Fusion absence type name* onto them —
> the sync would have to hard-code the strings. Recommend seeding a lookup type
> `ABSENCE_CLASS` in `OC_TIME_LOOKUP` (`code = Fusion type name`,
> `meaning = LOP | MATERNITY | NORMAL`) so the classification is configuration
> rather than code. Small addition, and it means adding a fourth absence type
> later needs no redeploy.

### 3.4 Add one contingent worker

All 12 workers are `WorkerType = E`, so **SC-11 and RULE-021 cannot be tested at
all** today, and RA-012 (contractor salary hold) has nothing to reason about.

Reload **CRI0398 Kishore Krovvidi** as a contingent worker — the `CRI` prefix
already suggests that was the intent. In `Worker.dat`, on both `WorkTerms` and
`WorkRelationship`, set `WorkerType = C` and supply the placement/PO details CWK
requires. The `AssignmentSupervisor` row can stay as-is.

This also gives you a live case for the PO gap identified in the CrewRite
assessment (§2.5 there): a contingent worker with no PO number is exactly the
condition that makes invoice-driven contractor pay unactionable.

### 3.5 PPM — projects, tasks, resource assignments

HDL is HCM-only, so this side is FBDI or REST against FSCM. The module needs four
projects; three are new, one is already seeded locally.

| Project | Model | Leave loss | PM | Members |
|---|---|---|---|---|
| **PRJ-1001** | T&M | N | RI2894 Santosh | RI2824 (100%), RI2900 (50%), RI2963 (100%) |
| **PRJ-1002** | T&M | N | **RI9001 Navamani** | RI2900 (50%) |
| **PRJ-1003** | **FCP** | **Y** | RI2894 Santosh | RI2935, RI3004 (**Unbilled**), RI2914, CRI0406 |
| **PRJ-ORG** | — | N | — | everyone, implicitly (already seeded) |

Three deliberate choices in that table:

- **PRJ-1002 has a different PM.** RI2900 is split 50/50 across PRJ-1001 and
  PRJ-1002, so a retro move of her hours between them routes to **two different
  managers** — the only way to test the dual-approval path in
  `approve_adjustment` (RA-014).
- **PRJ-1003 is FCP with leave loss on.** That is the entry condition for
  PROC-006; without it PAGE-006 correctly shows nothing.
- **RI3004 is Unbilled on PRJ-1003.** `V_OC_TS_LLC_ELIGIBLE_COVER` only offers
  colleagues who are `BILLING_STATUS = 'Unbilled'` on the same project. With
  everyone billable the cover LOV is empty and SC-12 stalls.

Each project also needs at least two WBS tasks with an **expenditure type** — see
the caveat in §7.

---

## 4. The calendar precedence test (SC-21)

Precedence is `Shift > Client > Project > Corporate`. To prove it you need one
date per layer where that layer wins. Week 3 of July 2026 (Mon 13 – Sun 19) is a
clean full week, so use it:

| Date | Layers present | Expected result | Proves |
|---|---|---|---|
| **Mon 13-Jul** | Corporate only (working, 8h) | working, **8h**, no shift | Corporate is the floor |
| **Tue 14-Jul** | Corporate 8h **+ Project 9h** | working, **9h** | Project beats Corporate |
| **Wed 15-Jul** | Corporate 8h + Project 9h **+ Client holiday** | **non-working, 0h** | Client beats Project |
| **Thu 16-Jul** | all three **+ Shift = Night 8h** | working, **8h, Night** | Shift beats everything |

Set this up as:
- **Corporate** — the geography holiday calendar plus the standard work pattern
- **Project** — `PRJ-1001` project standard hours = 9h for that country
- **Client** — a client-holiday entry for the customer on PRJ-1001, 15-Jul
- **Shift** — override RI2824's work schedule so Thursday is the Night pattern

Wednesday 15-Jul doubles as the **SC-03** test: the client site is closed, so the
employee splits the day between billable hours and the `Client Holiday` common
task.

---

## 5. Test cast — role and purpose per worker

`APP_ROLE` is what drives the whole menu (RULE-022), and it is single-valued in
`OC_TIME_WORKER`. Suggested assignment:

| Person | Name | APP_ROLE | Why this role |
|---|---|---|---|
| RI2894 | Santosh Kumar Kanala | **ROLE_TIME_ADMIN** | Account owner and the real line manager of ten. Admin is a superset of Manager in the nav, so one login reaches all 11 pages. PM of PRJ-1001/1003. |
| RI9001 | Navamani Solairajan | **ROLE_TIME_MANAGER** | A *pure* manager, to prove the Manager menu differs from Admin. Approves Santosh's own time → **RULE-015**. PM of PRJ-1002. |
| RI2824 | Sam Joshuva Paul Jeevan S | ROLE_TIME_EMPLOYEE | Primary employee. 100% PRJ-1001. SC-01, 03, 04, 05, 08, 09, 10, 16, 17 |
| RI2900 | SaiSowmith Kantipudi | ROLE_TIME_EMPLOYEE | 50/50 split across two projects with two PMs → FLD-006 split grid, SC-17 dual approval |
| RI2963 | Shaik Wajahad Ali | ROLE_TIME_EMPLOYEE | **The defaulter** — never submits → SC-06, SC-13, SC-19 |
| RI2935 | Shivani Rathore | ROLE_TIME_EMPLOYEE | Absent on the FCP project → SC-12 absentee |
| RI3004 | Gayathri Radhakrishnan | ROLE_TIME_EMPLOYEE | **Unbilled** on the FCP project → the SC-12 cover. Keep absence-free. |
| RI2914 | Venkata Bhaskar Reddy | ROLE_TIME_EMPLOYEE | LOP absence → proves LOP exclusion from leave-loss |
| CRI0406 | Ranganayaki Venugopalan | ROLE_TIME_EMPLOYEE | Fourth FCP member, so PRJ-1003 can be fully approved for SC-18 |
| CRI0398 | Kishore Krovvidi | **ROLE_TIME_CONTRACTOR** | Reload as CWK → SC-11, RULE-021 |
| RI2985 | Aadhiseshan Anandavijaya | **ROLE_TIME_NONE** | SC-23 — must see an empty menu |
| RI2249 | Saicharan Vadlakonda | ROLE_TIME_EMPLOYEE | **Deliberately no allocation** → SC-22 failed-record queue + retry |

RI2249 having no allocation is intentional: `populate_month` writes a
`NO_WBS_TASK` failure for exactly that case, which is what PAGE-010's retry
button acts on.

---

## 6. Scenario coverage

Periods already seeded: **JUN-2026 Closed**, **JUL-2026 Open**, **AUG-2026 Closed
(future)**. JUL-2026 cut-offs: payroll 2-Aug, delivery 3-Aug, finance 5-Aug,
book 7-Aug, MEC 8-Aug, client 10-Aug. Weeks are clipped to the month:

```
Week 1  01-Jul (Wed) → 05-Jul (Sun)   5 days
Week 2  06-Jul (Mon) → 12-Jul (Sun)   7 days
Week 3  13-Jul (Mon) → 19-Jul (Sun)   7 days
Week 4  20-Jul (Mon) → 26-Jul (Sun)   7 days
Week 5  27-Jul (Mon) → 31-Jul (Fri)   5 days
```

| Scenario | Needs | Status after this guide |
|---|---|---|
| SC-01 Pre-populate & submit | allocation + open period + calendar | ✅ |
| SC-02 Future month frozen | AUG-2026 | ✅ already seeded |
| SC-03 Leave / holiday / client-holiday tasks | client holiday 15-Jul + common tasks | ✅ |
| SC-04 Sat/Sun editable, default 0 | weekend non-working in the pattern | ✅ |
| SC-05 Shift read-only | work schedule assigned | ✅ after §3.2 |
| SC-06 Weekly cut-off defaulting | RI2963 not submitting + run the job | ✅ |
| SC-07 Multi-select monthly approve | ≥2 employees on PRJ-1001 | ✅ |
| SC-08 Weekly & date-wise approval | a submitted week | ✅ |
| SC-09 Reject with reason + remarks | RI2824 Week 2 | ✅ |
| SC-10 Override & approve | RI2824 pending week | ✅ |
| SC-11 Contractor unbilled exception | **a CWK worker** | ⚠️ blocked until §3.4 |
| SC-12 Leave-loss coverage | FCP+LL project, absentee, unbilled cover | ✅ after §3.3 + §3.5 |
| SC-13 Salary stopping split | RI2963 with some weeks submitted, some defaulted | ✅ |
| SC-14 Advance close a future month | AUG-2026 | ✅ |
| SC-15 Late submission flag | submit a past week after cut-off | ✅ |
| SC-16 Correction after rejection | rejected week → resubmit | ✅ |
| SC-17 Day-wise retro Project/WBS change | JUN-2026 closed + 2 projects + 2 PMs | ✅ |
| SC-18 Monthly confirm all-at-once | PRJ-1003 fully approved | ✅ |
| SC-19 Accrual gated until all approved | PRJ-1001 with RI2963 unapproved | ✅ |
| SC-20 Period single-open / no overlap | DB only — try inserting a second Open period | ✅ no data needed |
| SC-21 Calendar precedence | the four-date conflict in §4 | ✅ after §3.1–3.2 |
| SC-22 Failed record retry | RI2249 with no allocation | ✅ |
| SC-23 RBAC menu by role | 4 distinct APP_ROLE values incl. NONE | ✅ |
| SC-24 Client timesheet upload | any project + period | ✅ |
| SC-25 Performance of list pages | volume data | ⚠️ needs a bulk generator, not this cast |

**23 of 25 are reachable** with the setup above. SC-11 needs the CWK reload;
SC-25 needs volume data rather than a hand-built cast.

---

## 7. Two things to fix before the OIC sync is built

Both were identified in the CrewRite assessment and both bite here specifically.

**Expenditure type and expenditure organization do not exist in the model.** POET
is Project / Organization / Expenditure type / Task; `OC_TIME_TASK` has task, and
`OC_TIME_PROJECT` has project. When you create the PPM tasks in §3.5 they *will*
have an expenditure type in Fusion, and there is nowhere for the sync to put it.
Add `EXPENDITURE_TYPE` to `OC_TIME_TASK` and `EXPENDITURE_ORG` to
`OC_TIME_ALLOCATION` before writing the mapping, or the OTL push cannot be built.

**Absences must not be re-sent to OTL.** They originate in Absence Management,
which already feeds OTL. The accrual extract *should* carry leave hours — it needs
them for billing loss and leave-loss — but the OTL push must filter
`IS_LEAVE = 'Y'`. Worth writing into the INT-007 spec now, while it costs nothing.

---

## 8. Verifying the Fusion side over REST

Once set up, confirm each object is readable before wiring OIC. Substitute your
pod host.

```bash
# Workers + assignments + the supervisor hierarchy
GET /hcmRestApi/resources/11.13.18.05/workers?q=PersonNumber=RI2824
    &expand=assignments,assignments.assignmentSupervisors&onlyData=true

# Absences for one person in the period (drives INT-006)
GET /hcmRestApi/resources/11.13.18.05/absences
    ?q=personNumber=RI2935;startDate>=2026-07-01&onlyData=true
    &expand=absenceEntryDetails

# Calendar events / holidays  — confirm the resource name on your release
GET /hcmRestApi/resources/11.13.18.05/calendarEvents?onlyData=true

# Work schedules — READ PATH IS UNCONFIRMED, check describe first
GET /hcmRestApi/resources/11.13.18.05/workSchedules/describe
GET /hcmRestApi/resources/11.13.18.05/timeRecordGroups/describe

# PPM projects, tasks and resource assignments
GET /fscmRestApi/resources/11.13.18.05/projects?q=ProjectNumber=PRJ-1001
GET /fscmRestApi/resources/11.13.18.05/projects/{ProjectId}/child/Tasks
GET /fscmRestApi/resources/11.13.18.05/projectResourceAssignments?q=PersonNumber=RI2824
```

Use `/describe` on anything before assuming a field name — that is what my own
INT-004 note already warns about, and work schedules are the most likely to
differ on your release.

---

## 9. Testing today, without waiting for OIC

Run `O2C_Time/db/90_test_seed.sql` after the main install. It loads this exact
cast — 12 workers with the real hierarchy and the roles above, 4 projects, tasks,
allocations, the four calendar layers including the §4 precedence conflict, and
the §3.3 absences — straight into the ATP cache tables.

```sh
cd O2C_Time/db
sqlplus o2c_time/<pwd>@<tns> @install_time.sql     # once
sqlplus o2c_time/<pwd>@<tns> @90_test_seed.sql     # then this
```

> **If you installed before 2026-07-30, re-run `install_time.sql`.** Building this
> guide surfaced a real bug: the shell resolves the signed-in user by **email**,
> but the `getMe` handler was matching on `EMPLOYEE_ID` — so **sign-in could never
> succeed for anyone**. `ords/11_ords_time.sql` now matches on either. The install
> is idempotent, so re-running it is the whole fix.
>
> This is also why the `EMAIL` values in the seed matter: they must match what
> your identity provider returns. Only `RI2894` (Santosh) and `RI2824` (Sam) are
> known-good — the other ten are constructed and will need correcting, or those
> users will hit the "No active worker record was found" message.

Then drive the scenarios:

```
POST /oc/time/admin/jobs/populate/{periodId}       -- build the July grids
POST /oc/time/admin/jobs/defaulting/{periodId}     -- SC-06, SC-13
POST /oc/time/approval/salaryhold/run/{periodId}   -- SC-13
POST /oc/time/approval/llc/generate                -- SC-12
```

The seed is idempotent and safe to re-run. It is test data only — it never
touches the reference seed from `10_seed.sql`.
