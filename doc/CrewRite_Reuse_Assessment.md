# CrewRite → O2C Time Module — Reuse Assessment

> What the O2C employee Time Module can adopt from CrewRite (Crew Rite V2).
> Assessed against the **as-built** O2C module in `O2C_Time/` (21 tables, 3 ORDS
> modules, 11 VBCS pages), not against the BRD — so every gap below is real code
> that is missing, not a documentation gap.
>
> Sources: `CrewRite_Knowledge_Base.md`, `Integration_Spec_OTL_Projects_Payroll.md`.
> Assessed: 2026-07-30.

---

## 0. Bottom line

**There is no integration code to reuse.** The CrewRite integration spec is explicit
about this: the outbound payload assembly and the actual push to OTL / Projects /
Payroll are **server-side OIC/ORDS jobs that are not in the CrewRite repo**. The
VBCS front end only stamps a status column and PUTs the header back.

So "reuse the integrations" resolves to three different things, worth separating
because they carry very different effort and risk:

| What | Availability | Value to O2C |
|---|---|---|
| **Field-mapping contracts** (source column → OTL / Projects / Payroll target) | Documented, unverified against the real API | **High** — a starting contract for our unbuilt OTL push |
| **Patterns** (per-target transfer status, NVL default cascade, idempotency, completeness gate) | Verified in the live CrewRite app | **High** — directly transplantable |
| **Actual integration code / OIC flows** | **Absent** | None available |

Two further caveats from the source spec, both material:

- CrewRite's **absence integration is designed, not built** — so it cannot be
  copied for our INT-006.
- CrewRite's live Oracle endpoints point at a **dev pod with basic/anonymous
  auth**. Nothing about its transport security should be carried across.

The most valuable output of this exercise is not what we can copy — it is **five
concrete gaps in the O2C build that CrewRite exposes** (§2).

---

## 1. Adoption scorecard

`ADOPT` = take it · `ADAPT` = take the idea, change the shape · `HAVE` = already
built, no action · `SKIP` = crew-specific or out of scope

### Concepts

| CrewRite concept | Verdict | Note |
|---|---|---|
| Per-target `*_transfer_status` + **`*_batch_id`** | **ADOPT** | We have per-target *status*; we have **no per-target batch id** — see §2.3 |
| Hierarchical defaults, NVL cascade (Installation→Customer→Contract→Project) | **ADOPT** | Directly answers our open **RA-008** — see §3.1 |
| Centralized Spring Boot RBAC service (shared PaaS) | **ADOPT** | We are reinventing role resolution locally — see §3.2 |
| Completeness check before transfer (≥40 h/week) | **ADAPT** | Take the *indicator*, not the hard gate — see §3.3 |
| Lockdown (freeze timesheets during a payroll window) | **ADAPT** | We freeze by period status only; payroll windows cut across periods |
| Field-source matrix discipline | **HAVE** | `DATA_MODEL.md` + DDL comments already cite every FLD-xxx source |
| Integration status dashboard (pending/transferred/failed + drill-down) | **HAVE** | PAGE-011 (outbound) + PAGE-010 (inbound) |
| Staging retained permanently for audit | **HAVE** | Interface rows never deleted; `OC_TS_AUDIT` permanent; 7-year policy stated |
| Idempotency driven off status + batch id | **HAVE** | `PROCESSED_FLAG` + `UK_XX_TSIF_ROW` |
| Late submission → retro | **HAVE** | `LATE_SUBMISSION_FLAG` + the Cancel/Adjustment net-off |
| Absences read-only, count toward completeness, never re-sent to OTL | **HAVE / carry forward** | We do the first two; the third is a **rule for our unbuilt OTL push** — §5.2 |
| Multi-tenant config, DFFs, dynamic layout engine (`CR_SETUP_*`) | **SKIP** | O2C is one org, ~200 named users |
| Combination ID, Crew Explode, equipment→person derived time | **SKIP** | Crew-level constructs; our grain is employee × day × WBS |
| FBDI bulk setup (500+ customers) | **SKIP** | One org |

### Integrations

| Direction | CrewRite | Verdict for O2C |
|---|---|---|
| HCM → app (workers, jobs, assignments, shifts, eligibility) | REST setup + nightly volume sync | **HAVE** design (INT-001/004), aligned pattern |
| FSCM → app (projects, tasks) **filtered by `Crew Time Entry Enabled`** | REST | **ADOPT the filter** — §2.4 |
| Absence Mgmt → app | REST, display-only | **HAVE** design; CrewRite's is unbuilt so nothing to copy |
| FSCM → app, **PO data for contingent workers** | REST | **ADOPT** — §2.5 |
| app → **OTL** (hours) | OIC async, post-approval | **ADOPT the mapping** as our INT-007 contract — §5.1 |
| app → **Projects** (POET expenditure items) | OIC async, costed/uncosted | **ADAPT** — needs expenditure type/org first (§2.1) |
| app → **Payroll** (non-hourly element entries) | OIC async, `payroll_element_map` | **SKIP for now** — O2C has no compensation-element model, and salary is out of scope beyond the hold |
| app → **Revenue Accrual** | — (does not exist in CrewRite) | **O2C-specific, already built** |

---

## 2. Gaps in the O2C build that CrewRite exposes

These are the findings worth acting on. Each was verified absent from the DDL.

### 2.1 No expenditure type or expenditure organization — blocks OTL *and* Projects

**Severity: high.** POET is **P**roject / **O**rganization / **E**xpenditure type /
**T**ask. Our model has project and task. It has neither of the other two:

```
grep -i expenditure db/*.sql   →  1 hit, and it is inside a seed comment string
```

Both the OTL time record and a Projects expenditure item require expenditure type
and expenditure organization to cost correctly. Without them the INT-007 OTL push
cannot be built, and it will not be discovered until integration.

**Adopt:** `EXPENDITURE_TYPE` on `OC_TIME_TASK` (it is a task attribute in Fusion
PPM), and `EXPENDITURE_ORG` on `OC_TIME_ALLOCATION` — CrewRite sources the latter
from the employee's department, which is the right default. Carry both onto
`OC_TS_ENTRY` at population time so the entry is self-describing, and add them to
`XX_O2C_TIMESHEET_ACCRUAL_IF`.

### 2.2 No overtime model at all

**Severity: high — and partly a scope question for the business.**

```
grep -iE "OVERTIME|OT_HOURS|DOUBLE_TIME|REGULAR_HOURS" db/*.sql   →  none
```

Our build acknowledges overtime exists — RULE-012's own note says weekends are
enterable for *"overtime/weekend work"* — but there is nowhere to record that a
given hour **is** overtime. Hours above standard are simply hours. Consequences:

- Revenue accrual cannot bill OT at a different rate, because it cannot see OT.
- The OTL push has no `ot_hours` to send, so OTL would treat everything as regular.
- `BILLING_LOSS_HOURS` measures the shortfall below standard but nothing measures
  the excess above it.

CrewRite's model is directly adoptable and already parameterised the way finance
thinks about it: **OT allowed**, **threshold measure** (daily or weekly), **OT
limit**, **OT multiplier** (1.5× / 2.0×), **double-time threshold**. It also
auto-splits Regular + OT at submission rather than asking the employee to classify
their own hours — which is the right call.

**Recommendation:** raise this with the BRD owner before building. It may be a
deliberate v0.3 omission, but if OT bills differently it is a revenue gap, and it
is far cheaper to add the column now than after the accrual interface is live.

### 2.3 No per-target batch id on the confirmation

**Severity: medium.** `OC_TS_MONTH_CONFIRM` tracks `OTL_STATUS`, `ACCRUAL_STATUS`
and `PARTNER_STATUS` — good — but `BATCH_ID` exists only on the interface table.
There is no `OTL_BATCH_ID` or `PARTNER_BATCH_ID`.

When an OIC batch fails halfway you need to name the batch to retry or reconcile
it. Status alone tells you *that* it failed, not *what* to re-drive.

**Adopt:** add `OTL_BATCH_ID`, `PARTNER_BATCH_ID` (and `ACCRUAL_BATCH_ID`
denormalised from the interface rows for symmetry). One `ALTER TABLE`.

### 2.4 Every active Fusion project would land in the employee LOV

**Severity: medium, trivial to fix.** CrewRite filters projects by a
`Crew Time Entry Enabled` flag so only projects intended for time entry appear
(CR-B-BR08). We filter on `status = 'Active'` only.

In a real Fusion instance that means every active project in the enterprise —
including ones no one charges time to — reaching `V_OC_TS_TASK_LOV` and the project
picker.

**Adopt:** `TIME_ENTRY_ENABLED CHAR(1) DEFAULT 'N'` on `OC_TIME_PROJECT`, set by
the sync, and add it to the LOV views and `getMyProjects`.

### 2.5 No PO linkage for contingent workers — and it blocks an open item

**Severity: medium.** We model contractors (`WORKER_TYPE = 'Contractor'`,
RULE-021 unbilled exception) but hold no PO number or line. CrewRite makes
PO Number / PO Line **mandatory when `System Person Type = CWK`**, and CWK time
creates AP receipts via pass-through (CR-A-BR02).

This matters beyond tidiness: **RA-012** is open in our own metadata precisely
because contractors are *"invoice-driven pay"* — and we excluded them from salary
stopping for that reason. A PO reference is what makes invoice-driven contractor
time actionable.

**Adopt:** `PO_NUMBER`, `PO_LINE_NUMBER`, `PRICE_TYPE` on `OC_TIME_ALLOCATION`,
mandatory when the worker type is Contractor. It gives RA-012 a concrete answer.

---

## 3. Architectural reuse worth an ADR

### 3.1 Hierarchical defaults with an NVL cascade → answers RA-008

Our `OC_TIME_CONFIG` is keyed `(config_name, scope_key)` but every seeded row uses
`scope_key = 'GLOBAL'`. It is a flat table wearing the shape of a hierarchy.

Meanwhile **RA-008 is open**: *"Revision/backdating window: single org-wide value
or per country/client/project?"* And `ADJUSTMENT_MONTHS` currently lives on
`OC_TIME_PERIOD`, which means per period — a third answer again.

CrewRite already solved exactly this shape: one row per level, lowest non-null
wins, with a Default button + pencil icon in the UI marking overridden values, and
`PARENT_TYPE`/`PARENT_ID` as the polymorphic link. Adopting it converts RA-008 from
a decision someone has to make by decree into a structure that supports whichever
answer they pick.

**Recommendation:** adopt the cascade as `Installation → Customer → Project` (we
have no contract layer), resolve with `NVL`, and move the window settings into it.
This is a design decision, not a refactor I should make unilaterally.

### 3.2 The shared RBAC service already exists in the Rite PaaS estate

CrewRite uses a **centralized Spring Boot Authorization Service shared across Crew
Rite V2, Onboard Rite and Equip Rite**, with a documented contract:

- role source of truth: Fusion HCM `userAccounts?expand=userAccountRoles`
- `POST /authz/session-context {application_code, person_number}` → resolved role + page/action permissions
- `POST /authz/check-permission {session_id, page_code, action_code}` per request
- 12-hour role cache; fail-safe = retry once, then Employee-equivalent + a degraded banner
- tables partitioned by `APPLICATION_ID` — i.e. **built to host additional applications**

Our build resolves the role locally from `OC_TIME_WORKER.APP_ROLE`, populated by
the HCM sync. That works, but it is a fourth implementation of the same thing in
the same estate, and it means O2C role mappings are maintained separately from
every other Rite app.

**Recommendation:** decide deliberately. Registering O2C Time as another
`APPLICATION_ID` gets us role mapping, caching, audit and a fail-safe mode we would
otherwise build ourselves. The cost is a runtime dependency on that service, which
is why the fail-safe design matters. Either way our defence-in-depth stance is
already correct — `navigateChain` re-checks entitlement server-side rather than
trusting the menu.

### 3.3 Completeness: take the indicator, not the gate

CrewRite blocks transfer below 40 hours per resource per week, on the grounds that
an incomplete timesheet is revenue leakage.

**Do not copy the block.** In O2C a shortfall below standard hours is a *legitimate
tracked outcome* — that is precisely what `BILLING_LOSS_HOURS` is, derived
automatically by RULE-009, with an unbilled reason of "Billing Loss". Blocking on
it would prevent recording a real business fact.

**Do copy the visibility.** CrewRite's red / amber / green completeness indicator
against required hours is genuinely useful and we have nothing equivalent: PAGE-004
shows total hours but never contrasts them with the standard the employee was
expected to work. A manager approving 40 timesheets cannot currently see at a
glance which ones are short.

**Adopt:** a completeness column on PAGE-004 and PAGE-005 — `total ÷ standard`
with a severity chip. Cheap, and it uses data we already compute.

---

## 4. Inbound integrations — what transfers

Our INT-001…006 are designed but unbuilt (the OIC flows do not exist), so
CrewRite's inbound experience is useful mainly as design confirmation.

**Confirms our approach:**
- REST for low-volume setup data, nightly sync for volume (CR-B-BR07) — matches
  our `OC_TIME_SYNC_JOB` job types exactly.
- Absence is read-only in the time app, counts toward completeness, and is never
  re-sent downstream (CR-C-BR08) — matches RULE-008 and our `IS_LEAVE` handling.
- Terminated workers blocked from new entry with auto-deactivation (CR-A-BR01) —
  we have `STATUS`/`TERMINATION_DATE` on `OC_TIME_WORKER` but **no rule enforcing
  it**. Worth adding: population already skips inactive workers, but nothing stops
  an entry against a worker terminated mid-period.

**Adds to our approach:** the `Crew Time Entry Enabled` project filter (§2.4) and
CWK PO data (§2.5).

---

## 5. Outbound integrations — what transfers

### 5.1 The OTL mapping is a usable starting contract for INT-007

Our OTL push is unbuilt; `OTL_STATUS` is a placeholder. CrewRite's §4 mapping
gives us the field list and, more usefully, the **grain**: one time record per
person × POET × work_date × time_type.

Ours is employee × project × task × day × entry_type — the same shape once
expenditure type and org are added (§2.1). `ENTRY_TYPE` maps onto CrewRite's
`time_type` concept.

Treat the mapping as the **target contract to verify**, not as truth: the spec
itself flags that the left-hand column is the *concept*, not a guaranteed Oracle
API field name, and that the real names live in the OIC integration we do not have.

### 5.2 Carry one rule into the OTL push before it is built

**Absences must not be re-sent to OTL.** They originate in Oracle Absence
Management, which already feeds OTL; sending them again double-counts.

Our accrual extract *does* carry `LEAVE_HOURS`, and that is correct — revenue
accrual needs to see leave to compute billing loss and leave-loss coverage. But
the OTL push must exclude `IS_LEAVE = 'Y'` rows. Since the push does not exist
yet, this is a free correction now and an expensive one later.

### 5.3 Costed vs uncosted — the same question applies to us

CrewRite's **OI-003** is unresolved: whether non-hourly cost goes to Projects
costed or uncosted, to avoid double-booking cost already sent via Payroll.

We have a structurally identical risk with a different pair: OTL feeds Project
Costing natively **and** our interface feeds Revenue Accrual. Those are cost and
revenue respectively, so it is probably fine — but "probably" is not good enough
for a SOX-scoped flow, and it should be confirmed rather than assumed.

### 5.4 Payroll element entries — skip for now

CrewRite's Payroll integration exists to pay per diem, bonuses and allowances, via
a `payroll_element_map` from an internal element name to an Oracle Payroll element,
with a separate customer-facing label for invoicing.

O2C has **no compensation-element model** (`grep` for `ELEMENT`, `PER_DIEM`,
`DIFFERENTIAL`, `MILEAGE` → zero hits) and our Application_Scope puts payroll
processing out of scope: OTL feeds Payroll natively. The only payroll touchpoint we
own is the **salary hold**, which is already built.

One idea is worth keeping though: CrewRite deliberately separates the
**customer-facing label** from the internal name (CR-B-BR04). Our
`UNBILLED_REASON` is shown both internally *and* on the client-facing leave-loss
annexure. If a client should ever see different wording from our internal reason
code, that separation is the pattern.

---

## 6. Recommended sequence

Ordered by cost-to-fix-later, not by size.

**Before the OIC integration phase starts** — these change the schema, so they are
cheapest now:

1. Add expenditure type + expenditure organization (§2.1). Blocks OTL and Projects.
2. Decide the overtime question with the BRD owner (§2.2). Revenue impact.
3. Add per-target batch ids (§2.3).
4. Add `TIME_ENTRY_ENABLED` and the LOV filter (§2.4).
5. Add CWK PO fields (§2.5) and close RA-012 with them.
6. Write "exclude `IS_LEAVE` rows" into the INT-007 spec (§5.2).

**Architecture decisions, needing a call rather than code:**

7. Shared RBAC service vs local role resolution (§3.2).
8. Default cascade, which also resolves RA-008 (§3.1).
9. Confirm no cost/revenue double-booking between OTL→Costing and our accrual feed (§5.3).

**Cheap wins, any time:**

10. Completeness indicator on PAGE-004 / PAGE-005 (§3.3).
11. Enforce the terminated-worker block (§4).
12. Payroll-window lockdown, distinct from period close (§1 scorecard).

---

## 7. What deliberately does not transfer

Worth recording so it is not revisited: the grain difference is fundamental, not
incidental.

CrewRite is a **crew-level, multi-tenant, field-operations** product: a timekeeper
manages 200–300 people across 10+ projects, so Combination templates, Crew Explode
and equipment-time-derived-from-operator are essential to make data entry tractable.
Its unit of work is the crew-day.

O2C Time is **employee-level, single-org, professional services**: the employee
enters their own time and the unit of work is the employee-day at WBS grain. The
constructs that make CrewRite usable would be dead weight here — and its
multi-tenant machinery (DFFs, dynamic layout engine, FBDI bulk setup) solves a
problem we do not have.

The overlap is real but it is in the **plumbing** — status tracking, routing rules,
default resolution, transfer idempotency, RBAC — not in the domain model.

---

*Assessed against `O2C_Time/` as built. Every "missing" claim in §2 was verified by
grep against the DDL, not inferred from the BRD.*
