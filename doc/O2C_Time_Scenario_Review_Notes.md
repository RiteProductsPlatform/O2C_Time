# Scenario review — your edits of 07-Aug-2026, noted

Read out of commit `58ebd9f` ("few comments") and compared against the generated
version in `ac774bb`. Ten edits, typed into the text rather than added as Word
comments, so they are recorded here where they will survive the next
regeneration of the document.

**Nothing has been changed in the module or in the scenarios document yet.** Four
of these are new model elements that need building, two conflict with what the
code does today, and one is a question you left blank.

---

## 1 · New model elements — do not exist yet

### `Correction needed` — a new employee status
*Scenarios 10 and 12.* You replaced "back with the employee" and "—" with
**Correction needed**.

Today the employee axis has two values, Not yet submitted and Submitted, and a
rejected week simply returns to Not yet submitted. A distinct value is better:
"never touched it" and "touched it, was sent back" are different situations, and
only the second needs chasing.

Cost: a third value on the employee axis, and every place that tests for
`'Not yet submitted'` has to decide which it means. `submit_week` already
distinguishes them internally — it sets the action to `Resubmit` when the prior
status was Rejected — so the information exists; it is just not exposed as a
status.

### `Late approval` — a new flag
*Scenario 9.* You replaced "Defaulted retained" with **Late approval**.

There is no such flag today. It is the manager-side mirror of Late submission,
and the symmetry is right: if we record that an employee missed their deadline,
we should record that an approver missed theirs. Note it is **additional to**
Defaulted rather than instead of it — the week was defaulted by the delivery job
and then approved late, so both are true.

### Manager can unlock a locked week
*Scenario 6.* You added "or unlock the lock and ask employee to edit".

There is no unlock action. `LOCKED_FLAG` is set by weekly defaulting and nothing
clears it. Today the only route is for the manager to edit the sheet themselves.
An unlock hands it back, which is often what you actually want — but it needs a
new action, and a decision on whether unlocking clears the Defaulted flag (it
should not; the default happened).

### Absence after submit can be an adjustment
*Scenario 27.* You added "or it can come as adjustment next open period".

Agreed, and it is the cleanest of the three routes. Worth noting it lands in the
**next open period** rather than the one the absence belongs to — the same
accrual-month question as open item 24.

---

## 2 · Two edits that conflict with the code

### Scenario 2 — employee status `Defaulted` on a late submission

You changed the employee status from Submitted to **Defaulted** for "submitted
after the weekly cut-off, then approved".

The code does the opposite, deliberately and recently:

> *"A submission is ALWAYS 'Submitted' (revised 30-Jul-2026). Landing after the
> weekly cut-off no longer changes the status — it raises the Late submission
> FLAG instead. 'Defaulted' is now produced only by the defaulting jobs."*

There is also a sequencing problem. If the weekly cut-off has already run, the
week is Defaulted **and locked**, and `assert_editable` refuses the submission
outright — so the employee cannot submit late into a defaulted week at all. The
row as edited describes a state that cannot be reached.

**Two readings, and they need different work:**

- *Late submission is a kind of defaulting* — then Defaulted stops meaning
  "filled in by a job" and the flag/status split collapses. Large change.
- *You meant the week was already defaulted and the employee then wants to
  correct it* — then the answer is the unlock action above, and the status is
  Defaulted with the employee editing after an unlock.

I have not applied either. It needs your call.

### Scenario 8 — delivery cut-off produces `Defaulted Approved`

You changed the manager status to **Default** and the flags to **Defaulted
Approved**.

Today `run_delivery_defaulting` sets only:

```sql
week_status = 'Defaulted', defaulted_flag = 'Y', defaulted_by = 'MANAGER'
```

It does **not** approve anything — no `day_status` is touched. And because
`confirm_month` filters on `day_status = 'Approved'`, a delivery-defaulted week's
hours **do not currently reach accrual at all**.

"Defaulted Approved" makes the manager's non-decision count as approval, so the
hours flow. That is a real and defensible change — it is what the weekly job
already does for the employee side — but it is a behaviour change, not a
relabelling, and it interacts with the decision that accrual no longer waits for
approval. Worth settling both together.

---

## 3 · The question you left blank

You added a row after 7: **"… manager never acts and past the delivery cutoff"**
with the columns empty.

**Answer: nothing happens.** That is the gap.

- Weekly defaulting selects `week_status = 'Not yet submitted'`
- Delivery defaulting selects `week_status = 'Submitted'`

Once the weekly job has written `Defaulted`, the delivery job can never see the
week again. So a week that was never submitted and never decided sits at
Defaulted, locked, indefinitely, with nobody prompted and no second safety net.

If scenario 8 becomes "Defaulted Approved", this row becomes more pressing rather
than less: the submitted-but-undecided case would auto-approve while the
never-submitted case stays stuck.

Options: let delivery defaulting also pick up `Defaulted` weeks whose days are
not approved; or add a separate sweep; or accept it and rely on the salary-stop
signal — except that is now out of scope, so nothing chases it at all.

---

## 4 · Wording, accepted as-is

| Scenario | Your edit |
|---|---|
| 16 | "( mostly for future period )" on advance closure |
| 18 | "Retro adjustment outside the window **(Outside 3 months)**" — matches `ADJUSTMENT_MONTHS`, default 3 |
| 6 | the unlock clause, above |
| 27 | the adjustment clause, above |

---

## What I need from you

1. **Scenario 2** — which of the two readings did you mean?
2. **Scenario 8** — confirm that a delivery-cut-off default should count as approved.
3. **The blank row** — which of the three options for the stuck week?
4. Then I will apply all ten to the scenarios document and raise the new elements
   (`Correction needed`, `Late approval`, unlock) as build items.
