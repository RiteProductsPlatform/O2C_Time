# O2C Time — consolidated open points

08-Aug-2026. Merges the 27 open items in `O2C_Time_Scope_and_Integration` with
everything new from the BRD walkthrough and your scenario sheet.

`S-nn` = carried from the scope document, same number, so the two can be read
together. `N-nn` = new, from the BRD transcript or the xlsx.

**58 open points** — 31 new, 27 carried over. Twelve of them block the flag
matrix and should be taken first.

---

## A. Blocks the flag matrix — take these first

The BRD asks for one deliverable before more code: the finished flag matrix,
reviewed. These twelve decide what goes in its columns.

| # | Point | Owner |
|---|---|---|
| N-01 | **Is `Default Approved` a status, a flag, or `Defaulted` plus a flag?** Your two sheets do it differently. Today nothing approves a defaulted week — `run_delivery_defaulting` sets the status and stops. | functional |
| N-02 | **`Late Approval`** — add it? Today a manager approving after the delivery cut-off looks identical to one approving on time. | functional |
| N-03 | **`Revoked`** — add it as a week flag? The three revoke procedures exist and write audit rows, but nothing on the week records it. Your scenario 28. | functional |
| N-04 | **Can a week be defaulted by *both* parties?** Your scenario 8 says yes and says we will need to know why later. `DEFAULTED_BY` is one value with a two-value check constraint and physically cannot hold both. | functional |
| N-05 | **The post-cut-off flag** the BRD asks for by name — *"an indicator that it was done beyond the cut-off"*. Not built under any name. Decides the shape of the accrual hand-over. | functional + accrual |
| N-06 | **`ADJUSTMENT_DRIVER`** — Client / Employee / Manager / System. Your proposal; the BRD lists the same drivers. Confirm the value set. | functional |
| S-07 | **Remove `Closed` from the status set** — you removed it from the model, the database constraint and `confirm_month` still use it. | build, after N-01 |
| S-08 | **Keep `Defaulted` as both status and flag, or collapse?** `Overridden` settled 06-Aug — flag only. | functional |
| N-07 | **Month-level status and flag** for your scenarios 16–18 — *"not sure what status to keep here"*. Depends on N-01. | functional |
| N-08 | **Does accrual need manager approval?** You decided it does not. `RULE-020` and the BRD both say it does — *"there is a very specific approval that we will consider for month-end close, which is what will flow into the accrual model."* Nothing has been changed on the strength of the decision. | functional — **conflict** |
| S-11 | **May a `Defaulted` week be confirmed?** Currently blocked; advance closure is the stated exception. Overlaps N-01. | functional |
| S-23 | **What triggers the accrual write**, now that approval does not — at month confirmation, on a schedule, or continuously? | functional + accrual |

---

## B. Scope — four features the BRD names as required

The walkthrough calls these "the four extras" and treats them as in scope. Each
needs a yes, a no, or a stated deferral the sponsor has seen.

| # | Point | State today |
|---|---|---|
| N-09 | **Contractor unbilled hours → specific exception approval.** *"I am paying a contractor for 100 hours, it means 100 hours of money you are collecting."* | dropped from the flag model 30-Jul-2026 |
| N-10 | **Salary hold, and its employee correction screen.** You asked for the concept to be removed from the scope document; the BRD names it as a feature with a screen we have not built. | procedures built, screen not, concept descoped |
| N-11 | **Client timesheet attachment screen** — per project per month, overlays the approved *or defaulted* sheet, multiple attachments, explicitly **not** in the main sheet and **not** in the app. | `OC_TS_CLIENT_DOC` exists, screen does not |
| N-12 | **Employee mobile app.** The BRD assumes it from day one and hangs the no-excuse defaulting argument on it — *"because they are giving you an app, you better go submit."* | phase 2 |

---

## C. Rules that need a decision before they can be coded

| # | Point | State today |
|---|---|---|
| N-13 | **Withdraw only before the weekly cut-off** — your note. `revoke_week` allows it whenever the status is `Submitted` and the period is `Open`; no cut-off test. | needs the test |
| N-14 | **No weekly cut-off for manager approval** — recommended, and the BRD agrees (the delivery cut-off is the manager's only hard one; approval cadence is a preference). Confirm and close your scenario 10. | recommendation, unconfirmed |
| N-15 | **Absence correction** — inside the delivery cut-off it reflects directly, past it flows as an adjustment. Your principle, and the BRD lists late absence as a post-cut-off driver. Needs its own rule id. | not implemented |
| N-16 | **Scenario 21 — auto-revoke or notify only?** Recommend notify. Auto-revoke destroys the employee's evidence that they submitted on time, then defaulting penalises them for it. | not implemented |
| N-17 | **Leave-loss coverage exclusions** — *"any form of absence other than long leaves, maternity and ELOP will not be considered."* No exclusion by absence type today. | `assign_cover` built without it |
| N-18 | **Cover person constraints** — must not be absent that day, and must not already be covering someone else that day. *"I can't be working for two people."* | not enforced |
| N-19 | **Unbilled reason list** — the BRD says 4–5 values chosen at entry. `save_entry` accepts `p_unbilled_reason`; there is no dictionary behind it. Ours or Fusion's? | no LOV |
| S-02 | **Task-level spread of prepopulated hours** — one line, or divided across chargeable tasks? Your original question. | one line |
| S-06 | **Concurrent 100% allocations on two projects** seed 16h/day, uncapped until the 24-hour rule. Correct in Fusion, or cap in the module? | uncapped |
| S-05 | **Where a leave row attaches** for an employee with no active allocation — dropped silently today. | dropped |
| S-13 | **"Time Card Required" eligibility** read and enforced? | not read |

---

## D. Population and scheduling — the BRD against "everything live"

| # | Point |
|---|---|
| N-20 | **Does prepopulation stay a scheduled job?** The BRD requires it — monthly on the 28th/29th for the whole next month, plus a delta job several times a day. It cannot be live: the sheet must exist before the employee opens it, and the accrual month must be complete for people who never log in. Recommended reconciliation: keep both jobs, have them read Fusion **live at run time** instead of from a cache. Master-data *sync* stays removed. |
| N-21 | **Per-country run timing.** *"If you ran this program at 8 in the night in India, US data may not even be inside — you might have to run it 2 or 3 times."* Both population jobs and both defaulting jobs run once against `SYSDATE` with no time-zone awareness. `OC_TIME_PERIOD` is already keyed by `PAYROLL_COUNTRY`, so the model supports it. |
| N-22 | **Missing delta triggers** — termination reversals, deputations and transfers. `populate_daily` handles allocation change, project/WBS move and new hire; not those three. |
| N-23 | **Advance close: flag or date range?** Ours is one `ADVANCE_CLOSE` Y/N. The BRD describes a control table with an explicit start and end date — *"1st to 30th June normally; this month I want to start from the 28th."* |
| S-04 | **Fusion availability** — with no cache, a pod outage stops a timesheet being opened. Acceptable? |
| S-22 | **Where the live Fusion call is made from** — the page through the server-side proxy, or the database. Decides how much rule enforcement can stay in the database; the database option needs a privilege grant not proven on this pod. |
| S-03 | **Does worker identity stay local** now the extract is removed? Sign-in cannot wait on Fusion, and the finance administrator is not a worker in HCM. |
| S-12 | **Fusion `PersonId` / `AssignmentNumber` available to the module** — needed for any absence or OTL call keyed on the person. |
| S-15 | **Period auto-close has no job.** |

---

## E. Accrual hand-over — theirs to define, ours to build

| # | Point |
|---|---|
| S-19 | **Structure of the accrual staging table** — summary, employee-wise complete timesheet, and adjustments, in our schema for them to pull. Being defined on the accrual side. |
| S-20 | **One accrual interface or two?** The existing interface is already a day-wise pull carrying adjustments, so `ACCRUAL_STATUS` and `PARTNER_STATUS` may be tracking the same hand-off. |
| S-24 | **Which month a retro adjustment accrues to.** The module records `SOURCE_PERIOD_ID` and `POST_PERIOD_ID` on the adjustment and puts **neither** on the interface row, so the consumer must infer it. Both are needed: source drives the revenue period, post drives which pull takes it. The BRD's worked example is exactly this. |
| S-25 | **The staging row must carry the status of the hours** — without it accrual cannot tell provisional from final, or true up when approval arrives. |
| N-24 | **View or interface table?** The BRD leans hard to a view — *"fundamentally you don't have to do an extraction; all you need to do is create a view based on the table he is already using"* — which supports the built pull path over the dormant push. Their call. |
| N-25 | **Is the grain "employee by day: working hours, unbilled hours, absence" as three separate measures?** That is what the BRD says we owe them. Our interface carries the split; nobody on their side has confirmed the shape. |
| S-01 | **Independence from OTL** — decide. The OTL push is on hold meanwhile. |

---

## F. Fusion configuration — not ours

| # | Point |
|---|---|
| S-09 | Third-party transaction source registered in Fusion, and the `ExpenditureBatch` naming agreed. |
| S-10 | Expenditure type per project confirmed — this pod has no per-task transaction controls, so one configured value applies to everything. |
| S-17 | Where `REVENUE_MODEL` and `LEAVE_LOSS_FLAG` come from. Neither is read from Fusion, both are null today, so **leave loss cannot fire for any project**. |
| S-18 | Test data per revenue model — T&M, FCP with and without leave loss, Milestone. Functional team owns this, agreed. |

---

## G. Build items already identified — no decision needed, just scheduling

| # | Item | Why it matters |
|---|---|---|
| N-26 | **`UK_OC_TSE_CELL` needs `ADJUSTMENT_ID`.** One `Reversal` row per cell today, so a second correction on the same day overwrites the first — 8h → 4h → 5h nets to 45 instead of 40. Data-model change; cheap now, expensive after go-live. | correctness |
| N-27 | **Source period, post period, post-cut-off flag and driver onto the accrual interface**, and key the pull on post period. This is S-24 and S-25 as one change. | the double-count |
| N-28 | **Prior-month adjustment queue for managers.** *"The manager will go to the next month, will see the data and approve it again for those corrections."* `approve_adjustment` has the dual approval; nothing surfaces the reversal in the current month's queue. | BRD requirement |
| N-29 | **`approve_week` approves every entry in the week with no project filter** — a manager owning one of an employee's two projects approves both. Unrelated to the flag work, but it corrupts exactly the data N-27 protects. | defect |
| S-21 | Make the schema match the single status set — week, day, month and retro-adjustment statuses are separate columns with different permitted values. | consistency |
| S-14 | Rejected-cost read-back so a failed post is visible. | operability |
| S-26 | Re-confirming a month marks the confirmation pending again while rows the consumer already took stay marked processed. | minor |
| S-27 | Nothing enforces that a post-accrual change goes through an adjustment — the duplicate guard tests existence, not value, so a direct change after accrual never reaches the consumer. | correctness |
| S-16 | Session token strengthening before production — one line and a `DBMS_CRYPTO` grant. | security debt |

---

## H. Inputs we are waiting on

| # | Item |
|---|---|
| N-30 | **The cut-off "handling" document** the BRD promises — *"a separate document that we'll give you called handling… we'll tell you what the different cut-offs are, how you handle them for various reasons, especially for accrual."* Not in `doc/`. Would answer most of section A. |
| N-31 | **The control table walkthrough** — *"the control table has already been designed, we will give you all that as a walk through."* Not in `doc/`. Answers N-23 directly. |
| S-19 | The accrual staging structure, above — same dependency, different team. |
