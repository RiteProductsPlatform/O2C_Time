# Plan — reconciling the BRD walkthrough and the scenario sheet with what is built

Drafted 08-Aug-2026 from two inputs, read in full:

- `doc/Time Scenarios and status.xlsx` — two sheets. **For Review** (44 scenarios,
  your annotations and questions in the remarks column) and **Rough work**
  (25 scenarios adding a third dimension, *Payroll Cutoff*, and a
  *Downstream Action* column).
- `doc/transcript from BRD explanation video.docx` — the 38-minute walkthrough,
  426 paragraphs.

Everything below is stated against the code as it stands (`db/01`–`db/13`,
`OC_TIME_PKG`), not against the requirement pack.

---

## 1. The sentence the next phase should be built around

From the walkthrough, near the end and said twice:

> "You have to write down all the flags from a technical perspective, create it
> as a prop for Excel against actions and get that reviewed, because your biggest
> mistakes will come only in the flags. Your flags are going to be used for
> integration and everything runs based on it. The whole testing will be based on
> flags. All other programs you can fix."

> "Time is not complicated. Time is just getting programmed data, accepting hours
> and integrating it out. That is very straightforward. If you can't handle your
> flags properly, your data won't be correct, your integrations won't work."

Your **Rough work** sheet is that deliverable, half-finished. It should be
completed and signed off *before* any more code, because two of the changes it
implies are structural (§3, §4) and are cheap now and expensive later.

Everything else in this plan is downstream of that sheet.

---

## 2. Vocabulary — your sheet against the database today

### Status

| In `CHK_OC_TSW_STATUS` today | On your sheet | Action |
|---|---|---|
| Not yet submitted | ✔ | keep |
| Submitted | ✔ | keep |
| Approved | ✔ | keep |
| Rejected | ✔ | keep |
| Defaulted | ✔ | keep |
| Overridden and approved | *(you list it as a flag, not a status)* | **demote to flag** |
| Closed | *(you removed it)* | **drop** |
| — | **Default Approved** | **new — decide status or flag** |

`Default Approved` is the significant one. Today `run_delivery_defaulting` sets
`week_status = 'Defaulted'`, `defaulted_by = 'MANAGER'` and **nothing is
approved** — a defaulted week is not an approved week anywhere in the code. Your
sheet uses `Default Approved` to mean *the manager never acted, the cut-off
passed, and the hours go downstream anyway*. That is a real and different state
and the accrual side needs to tell it apart from a real approval.

### Flags

| In `OC_TS_WEEK` today | On your sheet | Action |
|---|---|---|
| `DEFAULTED_FLAG` | Defaulted | keep |
| `LATE_SUBMISSION_FLAG` | Late submission | keep |
| `ADVANCE_CLOSURE_FLAG` | Advance closure | keep |
| `OVERRIDDEN_FLAG` | Defaulted and Overridden | keep, rename the label |
| `HAS_REVERSAL_FLAG` | Reversal(−) | keep |
| `HAS_ADJUSTMENT_FLAG` | Adjustment(+) | keep |
| — | **Revoked** | **new** |
| — | **Late Approval** *(Rough work)* | **new** |
| — | **Default Approved** *(Rough work)* | **new**, if it is not a status |
| — | **post-cut-off correction** *(the BRD's, unnamed on your sheet)* | **new — §3** |

`Revoked` — the actions exist (`revoke_week`, `revoke_decision`,
`revoke_week_decision`) and each writes a row to `OC_TS_APPROVAL`, but nothing on
the week records that it happened. Your scenario 28 asks for it. Recommend: a
flag set by all three, cleared on the next submit.

`Late Approval` — does not exist in any form. Today a manager approving after the
delivery cut-off is indistinguishable from one approving on time.

---

## 3. The gap that will bite hardest — the post-cut-off flag and which month an adjustment belongs to

This is the part of the walkthrough with the most airtime, and it is the part the
build is furthest from.

> "The corrections that are going to be done beyond the payroll cut off or book
> close cut off or anything is going to be separately tagged. You have to create
> a flag. It is not that you have to write a separate line, but you have to
> create an additional flag or some kind of indicator that it was done beyond the
> cut-off. And based on that you will provide the data to the accrual engine."

> "In your capture and approval it is important to differentiate the data between
> the two cut-offs. Anything that is done to data that has crossed the current
> cut-off will be tagged and given into the accrual module as a separate
> adjustment line."

**What exists.** `OC_TS_ADJUSTMENT` already carries `SOURCE_PERIOD_ID` (the month
the work belongs to, derived from the work date) and `POST_PERIOD_ID` (the month
it is being posted in, from `get_open_period_id`). Both are set by
`apply_adjustment`. That is the right model and it is already there.

**What is missing.** Neither column reaches
`XX_O2C_TIMESHEET_ACCRUAL_IF`. The consumer pulls with
`GET accrual/pull/:year/:month` and has no way to tell a July line that arrived
in August from an original July line. That is exactly the double-count you asked
about, and it is a five-column change:

| Column to add to the interface | Meaning |
|---|---|
| `SOURCE_PERIOD` | the month the hours were worked — drives the revenue period |
| `POST_PERIOD` | the month we are handing them over — drives which pull picks them up |
| `POST_CUTOFF_FLAG` | Y when `POST_PERIOD <> SOURCE_PERIOD`; the BRD's flag |
| `ADJUSTMENT_DRIVER` | Client / Employee / Manager / System (your own proposal) |
| `ADJUSTMENT_SEQ` | which correction this is, for the key problem below |

and one change to the pull: key it on `POST_PERIOD`, not on the work date. A
consumer that has already taken July must never see July again except as a
tagged adjustment line.

**The worked example in the walkthrough is ours, exactly.** Person was on the
wrong project for three days at month end; the month closed on the old project;
the allocation was corrected afterwards.

> "So old project will have the reversal for three days... She will get the new
> entry for her approval as a manager. She will approve the three days. As a
> manager, you will approve reversal of three days. So it will go in the
> adjustment module and create one line against your project for three days
> reversal. In our project, this month will be the full month and it will add one
> line for three days of incremental revenue as a separate line. **But the period
> will be last month's.** The billing... you will apply it in this month."

So: source period drives the revenue period, post period drives the hand-over.
Both columns are needed; neither is sufficient alone.

**It also settles the reversal-sign argument.**

> "It is full reversal, full. Whatever you applied, I will reverse the full value.
> Whatever the new treatment she is giving, I will put into the system... you know
> what was the record that was approved, you will take the same record, create a
> reversal."

Reverse the *entire* original approved record, then post the new value as a fresh
line. Never net. `approve_adjustment` already does this — it MERGEs
`-ABS(old_hours)` as `Reversal` and `+ABS(new_hours)` as `Adjustment` on the
original work date. Correct as written.

**But it only survives one correction.** `UK_OC_TSE_CELL` is
`(ts_week_id, project_id, task_id, entry_date, entry_type)` with no adjustment
reference, so there can be exactly one `Reversal` row per cell. A second
correction on the same day **overwrites** the first reversal instead of adding
one, and the net comes out wrong. Worked through on 8h → 4h → 5h it produces 45
where it should produce 40. Adding `ADJUSTMENT_ID` to that unique key fixes it
and is a data-model change, so it wants doing before there is live data.

**And the manager sees it in the following month.**

> "That is where the manager will go to the next month, will see the data and
> approve it again for those corrections."

`approve_adjustment` has the dual approval (RA-014, both old and new project
manager) but nothing surfaces a prior-month reversal in the current month's
manager queue. That view does not exist.

---

## 4. Four features the walkthrough names as required

It lists them as "four extras". Their state:

**1. Contractor unbilled hours → specific exception approval.**
> "If any contractor has an unbilled hour there is an exception approval needed,
> because contractors are supposed to be back-to-back billed. I am paying a
> contractor for 100 hours, it means 100 hours of money you are collecting."

Dropped from the flag model on 30-Jul-2026 as out of scope. The BRD makes it a
named requirement. **Needs an explicit re-scope decision, either direction.**

**2. Leave loss coverage.** Built — `generate_llc_lines`, `assign_cover`,
`approve_cover`. Two rules from the walkthrough are not coded:
- *"Any form of absence other than long leaves, maternity and ELOP will not be considered"* — no exclusion by absence type today.
- *"You can't allow on the same day. I can't be working for two people"* — the cover person must not themselves be absent that day, and must not already be covering someone else that day. Only the whole-day assumption (RA-013) is recorded.

**3. Salary hold / salary stopping tool.** Built — `run_salary_stopping`,
`release_salary_hold`, contractors excluded (RA-012). **You asked for it to be
removed from the scope document.** The BRD makes it a named feature with a
screen we have not built:

> "I will give a screen where my employee will go inside and whichever dates I
> have not submitted, I will be able to now apply for correction. I will put a
> reason and say correcting the number and then submitting, it will go to your
> manager. Once it is approved then it goes back to payroll and you get your money
> next month. But it does not affect the accounting process."

Recommend: keep the code, mark it *deferred* rather than *out of scope*, and put
the deferral in front of the sponsor explicitly — being silent about it is the
risk, not the deferral itself.

**4. Client timesheet attachment.** Table `OC_TS_CLIENT_DOC` exists
(`db/06_client_docs_sync.sql`); the screen does not. Requirements from the
walkthrough, none of which are in the metadata:
- per project, per month
- overlays the approved *or defaulted* timesheet, by week or whole month
- multiple attachments
- **explicitly not in the main timesheet and not in the app** — *"when you're submitting for close, the customer-signed timesheet will not be available; it takes two weeks to get"*

Also named in passing and currently phase 2: the **employee mobile app**. The
walkthrough treats it as present from day one — *"one is we give a page, two is we
give an app page"* — and hangs the whole no-excuse defaulting argument on it:
*"because they are giving you an app, you better go submit."*

And smaller: an **unbilled reason list of 4–5 values** chosen at entry.
`save_entry` accepts `p_unbilled_reason` but there is no dictionary behind it.

---

## 5. Population — the BRD and "everything live" collide less than it looks

**What the walkthrough specifies.** A monthly program run on the 28th/29th that
forward-populates the whole of the next month, 1st to 31st, from current
allocation. Then a second program running two or three times a day, per country,
applying deltas from the effective date forward: allocation percentage changes,
project and WBS moves, new hires, terminations, termination reversals,
deputations, transfers. *"This means it will override your old record only for
that day."* Timed per country because *"if you ran this program at 8 in the night
in India, US data may not even be inside."*

**What you decided recently.** Remove the daily and monthly sync; take everything
live from Fusion REST.

**These are two different things and only one of them is in conflict.**

- *Master-data sync* — workers, projects, tasks, allocations into our cache. You
  removed it, and the walkthrough supports that: *"one format in which you will
  take the data in is what you will define. They will give you that extract
  tomorrow with multiple sources."* That is your source-agnostic contract, endorsed.
- *Prepopulation* — writing `OC_TS_ENTRY` rows. The BRD requires it and it cannot
  be live. A timesheet has to exist with its defaults before the employee opens
  it, and the accrual month has to be complete for people who never log in at all.

**Recommendation:** keep `populate_month` and `populate_daily` as scheduled jobs,
but have them read allocation, calendar and absence **live from Fusion REST at
run time** instead of from a synced cache. Both positions hold. They are
scheduled *jobs*, not a *sync*.

**Confirmed already correct:** `resolve_day` gives the `SHIFT` calendar layer the
highest precedence, so a shift day that is also a corporate holiday still
populates hours, and a non-shift day populates zero — exactly the Tuesday-to-
Saturday example in the walkthrough. The 15-minute rounding is in place
(`ROUND(x*4)/4`), and `validate_day` enforces the 24-hour ceiling (RULE-003).

**Not handled today:** termination reversals, deputations and transfers as
delta triggers; `populate_daily` handles allocation change but not those three.
And the per-country run timing — both defaulting jobs and both population jobs
run once, against `SYSDATE`, with no time-zone awareness, although
`OC_TIME_PERIOD` is already keyed by `PAYROLL_COUNTRY` so the data model supports
it.

---

## 6. Answers to the questions you wrote in the sheet

| Your note | Answer |
|---|---|
| Sc 8 — *"Employee Defaulted, Manager Defaulted, because we will know why we need to adjust this later"* | Right, and today it cannot be recorded. `DEFAULTED_BY` is a single value with `CHECK IN ('EMPLOYEE','MANAGER')`, so a week that missed *both* cut-offs keeps only the last writer. Recommend two flags, `DEFAULTED_BY_EMPLOYEE` and `DEFAULTED_BY_MANAGER`, and derive the display label from the pair. |
| Sc 9 — *"After the delivery cutoff can manager take any action?"* | Yes. Delivery defaulting sets the status but deliberately does **not** lock the week — only weekly (employee) defaulting locks. So the manager can still act. What must change: an action taken after the delivery cut-off raises `Late Approval`, and if the month is already confirmed it becomes an adjustment, not an edit. |
| Sc 10 — *"Is there weekly cutoff for manager approval?"* | No, and recommend keeping it that way. The walkthrough gives the manager the **delivery** cut-off only (*"3 PM on Monday, there is a delivery date cut-off, there will be a configuration table"*) and says manager approval cadence is a preference — daily, weekly, fortnightly. One hard manager cut-off, not two. |
| *"Withdraw — please suggest whether we can give the option — only before weekly cutoff"* | Achievable and a small change. Today `revoke_week` allows it whenever the status is `Submitted` and the period is `Open`; it does not test the weekly cut-off. Add that test and the message. |
| Sc 18 — *"Not sure what status / flag to keep here"* | These are the month-level ones. They should be settled *after* the flag matrix, not before — the answer depends on whether `Default Approved` is a status or a flag. |
| Absence correction — *"if there is a leave approved in the absence system it gets reflected irrespective of status or flag if it is inside the delivery cutoff; if past then it should flow as adjustment"* | Agreed, implementable, and it matches the walkthrough (*"some absence was not entered but got entered later"* is listed as a post-cut-off correction driver). Should get its own rule id. It also depends on the live absence read, which is why the absence-not-rendering item matters more than it looked. |
| Sc 21 — *"can we notify the employee to revoke and resubmit, or auto revoke and notify"* | Notify only. Auto-revoking a submitted week silently destroys the employee's evidence that they submitted on time, and then the defaulting job penalises them for it. |
| Sc 28 — *"Revoked (not sure)"* | Make it a flag. Set by all three revoke procedures, cleared on the next submit. |
| *"The client does not accept the hours — this will be managed by delivery manager in the accrual timesheet"* | Agreed. It means no new status in this module: it is the post-cut-off adjustment path in §3, with `ADJUSTMENT_DRIVER = 'Client'`. The walkthrough says the same — *"customer says no, no, I'm not going to pay for these 10 hours"* is listed as a reversal driver. |
| *"For storing into the accrual table we don't need manager approval"* (your earlier decision) | This one conflicts with both. `RULE-020` gates `confirm_month` on all-approved, and the walkthrough is explicit that there is a **specific month-end approval** distinct from the routine one: *"there is a very specific approval that we will consider for month-end close, which is what will flow into the accrual model."* Worth reopening before it is coded — I have not changed anything on the strength of it. |

---

## 7. The Rough work sheet — Payroll Cutoff and Downstream Action

The third dimension is right and it lines up with §4 feature 3.

- **Payroll cut-off is per country and separate from month end** — *"payroll
  normally cuts off around the 20th, so they can pay you by the 30th."* The
  columns exist: `OC_TIME_PERIOD.PAYROLL_CUTOFF` and `PAYROLL_COUNTRY`, with the
  period already unique on `(year, month, payroll_country)`. Nothing reads
  `PAYROLL_CUTOFF` today except `run_salary_stopping`.
- **Downstream Action** (Billing Reversal / push to next billing cycle / Payroll
  adjustment next payroll) should stay a **derived** column in the matrix, not a
  stored field. It is a function of (source period, post period, flags, driver).
  Storing it creates a second source of truth that will drift from the flags —
  which is the exact failure the walkthrough warns about.

---

## 8. Proposed order of work

**Phase 0 — decisions.** Nothing else starts cleanly until these land:
`Default Approved` status or flag · contractor unbilled in or out · salary hold
deferred or reinstated · client document screen in or out · prepopulation stays
scheduled (§5) · month-end approval before accrual, or not (§6 last row).

**Phase 1 — the flag matrix, finished and signed.** Merge *For Review* and
*Rough work* into one sheet: Scenario · Employee status · Manager status · Flags ·
Source period · Post period · Downstream action · Rule id. This is the
walkthrough's explicit ask and the review it wants held.

**Phase 2 — data model, while there is no live data.**
`UK_OC_TSE_CELL` + `ADJUSTMENT_ID` · source/post period and the post-cut-off flag
onto the accrual interface · the pull keyed on post period · the new flags ·
`DEFAULTED_BY` split into two.

**Phase 3 — rules.** Weekly cut-off test on withdraw · `Late Approval` on
post-delivery approval · leave-loss exclusions and the same-day cover rule ·
absence correction inside/outside the delivery cut-off · per-country job timing ·
termination reversal, deputation and transfer as delta triggers.

**Phase 4 — screens.** Revoke and its flag chip · the new flag chips throughout ·
the prior-month adjustment queue for managers (§3) · the client document screen.

**Phase 5 — deferred, tracked, visible.** Salary hold and its correction screen ·
contractor unbilled approval · mobile.

---

## 9. Still unanswered after both documents

1. Is `Default Approved` a status, a flag, or a status plus `Defaulted`? Your two
   sheets do it differently.
2. Where does the "unbilled reason" list of 4–5 values come from — Fusion, or ours?
3. The walkthrough promises two documents that would answer most of §3 and §6:
   *"a separate document called handling"* on cut-offs, and a **control table
   walkthrough** (*"the control table has already been designed"*). Neither is in
   `doc/`. Both are worth chasing before Phase 2 — our advance-close model is a
   single `ADVANCE_CLOSE` flag, and the walkthrough describes a control table with
   an explicit start and end date (*"1st to 30th June normally; this month I want
   to start from the 28th"*).
4. Whether the accrual consumer takes a view over our tables or the interface
   table. The walkthrough leans strongly to the view — *"fundamentally you don't
   have to do an extraction; all you need to do is create a view based on the
   table he is already using"* — which supports the built pull path over the
   dormant push, but the decision is theirs and it changes what §3 delivers.
5. Whether the accrual hand-over is "employee by day: working hours, unbilled
   hours, absence" as three separate measures. That is what the walkthrough says
   we owe them. Our interface carries the split, but nobody on their side has
   confirmed the shape.

---

## 10. One unrelated defect found while checking the above

`approve_week` approves **every entry in the week with no project filter**. A
manager who owns one of an employee's two projects approves both. It is not
related to the flag work, but it will corrupt exactly the data §3 is trying to
protect, so it should be fixed in Phase 2 alongside the key change.
