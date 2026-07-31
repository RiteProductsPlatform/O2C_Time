# CrewRite → OTL / Projects / Payroll — Integration Spec (reusable for O2C Time Module)

> **Purpose.** A reusable integration blueprint distilled from the CrewRite (Crew Rite V2) solution, so the
> O2C employee Time Module can implement the same downstream transfers (OTL, Oracle Projects, Oracle Payroll)
> and adapt them to its own targets (Revenue Accrual, Billing).
> **Baseline:** CrewRite data model + FSD `CR-FSD-2026-001` v2.0 + the live VBCS app (`CrewRite_Mounika`).
> **Prepared:** 2026-07-30.

---

## 0. Read this first — what is real vs. designed

| Layer | State in CrewRite | Reusable? |
|---|---|---|
| **Transfer status / batch tracking** on the time-card header | ✅ **Built & verified** in the VBCS app | Reuse the pattern as-is |
| **Routing rules** (what goes to OTL vs Payroll vs Projects) | ✅ Defined in FSD (`CR-B-BR03`, §7.5) | Reuse |
| **Source fields** available to build payloads (`CR_TIME_CARD_LINES`, `CR_COMPENSATION_ELEMENTS`) | ✅ Verified in the live schema | Reuse the field mapping |
| **Outbound payload assembly & the actual push** to OTL/Projects/Payroll | ⚠️ **NOT in the VBCS repo** — done server-side via **OIC / ORDS** (not present here) | Contract below; confirm exact field names against the backend repo before build |

> The VBCS frontend only calls `prepareHeaderTransfer(transferType)`, which sets
> `otl_transfer_status | payroll_transfer_status | projects_transfer_status = 'Transferred'` and PUTs the header
> back. **No REST call to OTL/Projects/Payroll exists in the frontend.** Treat the payload tables below as the
> *target contract* to implement in the O2C backend, not as copied code.

---

## 1. Routing rules — what goes where

From FSD `CR-B-BR03` / §7.5:

| Data | Path | Notes |
|---|---|---|
| **Hour-based entries** (Regular + OT) | **→ OTL → Projects** | OTL applies its own OT rules; only regular + OT hours sent. Absences are **not** re-sent. |
| **Non-hourly compensation** (per diem, bonus, safety bonus, custom) | **→ Payroll (direct)** + **→ Projects** | Payroll = element entries; Projects = cost/billing. |
| **POET cost/billing** (hourly + non-hourly) | **→ Projects** | Costed or uncosted (configurable) to avoid double-booking with Payroll — see Open Item OI-003. |

All transfers are **post-approval**, **OIC async batch**, and every record is retained in staging **permanently** for audit (`CR-D-BR07`).

---

## 2. Transfer lifecycle & tracking model  *(verified — reuse as-is)*

Timesheet lifecycle: `Draft → Submitted → Approved → Transferred` (`Rejected` returns to Draft).

Transfer is tracked **per target** on `CR_TIME_CARD_HEADER`:

| Column | Meaning |
|---|---|
| `status` | Header status (Draft/Submitted/Approved/Transferred…) |
| `otl_transfer_status`, `otl_export_status`, `otl_batch_id` | OTL transfer state + batch |
| `payroll_transfer_status`, `payroll_batch_id` | Payroll transfer state + batch |
| `projects_transfer_status`, `projects_batch_id` | Projects transfer state + batch |

**Pattern (from `main-datagrid_dev-page.js`):**
```js
// transferType: 'otl' | 'payroll' | 'projects'
prepareHeaderTransfer(transferType) {
  if (transferType === 'otl')      item.otl_transfer_status      = 'Transferred';
  if (transferType === 'payroll')  item.payroll_transfer_status  = 'Transferred';
  if (transferType === 'projects') item.projects_transfer_status = 'Transferred';
  // PUT header back; the actual push is a server-side OIC/ORDS job keyed off this status
}
```

> **Reuse in O2C:** put the same **per-target `*_transfer_status` + `*_batch_id`** columns on the O2C timesheet /
> accrual header (add `accrual_transfer_status/_batch_id` and `billing_transfer_status/_batch_id`). A backend job
> polls "Approved + not yet transferred", builds the payload, pushes via OIC, and stamps status + batch id.

---

## 3. Source data — where payload fields come from  *(verified schema)*

### `CR_TIME_CARD_LINES` (hour + POET + location + rates) — the OTL / Projects source
Key columns:
`person_id`, `project_id`, `project_number`, `project_name`, `task_id`, `task_number`, `task_name`,
`expenditure_type`, `expenditure_id`, `department` *(= expenditure organization)*, `hours`, `ot_hours`,
`time_type`, `time_type_code`, `work_date`, `work_week`, `shift`, `shift_code`, `shift_differential`,
`differential_amount`, `pay_rate`, `write_in_rate`, `per_diem`, `meal_per_diem_amount`, `mileage`,
`combination_id`, `combination_name`, `trade_code`, `trade_name`,
location → `state`, `state_code`, `county`, `county_name`, `city`, `city_name`,
overrides → `daily_overtime_override`, `weekly_overtime_override`, `double_time_override`, `seventh_day_override`,
`ot_threshold_measure`, flags → `federally_funded(_flag)`, `salary_ot_override_flag`, `silica_exposure_flag`,
`comments`, plus DFFs `attribute1-5 / attribute_num1-5 / attribute_date1-5` and `extra1-10`.

### `CR_COMPENSATION_ELEMENTS` — the Payroll source
`comp_element_id`, `element_name`, `customer_label`, `rate_type` (per-hour / flat / per-day), `rate_amount`,
`hours_threshold`, **`payroll_element_map`** (→ Oracle Payroll element name), `parent_type` / `parent_id`,
`enabled`, `effective_start_date`, `effective_end_date`.

### `CR_TIME_CARD_HEADER` — context
`time_card_id`, `crew_id`, `assignment_id`, `week_end_date`, `work_date`, `status`, transfer columns (§2).

---

## 4. Integration 1 — Transfer to **OTL** (hours)

- **Trigger:** header `Approved`; hour-based lines only. **Only Regular + OT hours** are sent; OTL then applies its own rules. Absences are **not** re-sent (avoid duplication).
- **Grain:** one time record per person × POET × work_date × time_type.

| OTL time-record field (target) | Source (`CR_TIME_CARD_LINES`) |
|---|---|
| Person / Resource | `person_id` (→ person number / assignment) |
| Project | `project_id` / `project_number` |
| Task | `task_id` / `task_number` |
| Expenditure Type | `expenditure_type` / `expenditure_id` |
| Expenditure Organization | `department` |
| Hours (Regular) | `hours` |
| Overtime hours | `ot_hours` |
| Time Type | `time_type` / `time_type_code` |
| Work Date | `work_date` |
| Shift | `shift` / `shift_code`, `shift_differential` |
| Location (tax) | `state_code`, `county_name`, `city_name` |
| Trade / billing title | `trade_code` / `trade_name` |
| Reference | `time_entry_line_id`, `time_card_id`, `otl_batch_id` |

> Confirm the exact OTL element/time-attribute names against your OTL setup — the left column is the **concept**,
> not a guaranteed Oracle API field name.

---

## 5. Integration 2 — Transfer to **Oracle Projects** (POET cost / billing)

- **Trigger:** header `Approved`; both hourly and non-hourly.
- **Grain:** one **Expenditure Item** per person × POET × date (hours as quantity; non-hourly as amount).
- **Costed vs uncosted:** configurable to avoid double-booking cost already sent via Payroll (**Open Item OI-003** — confirm before build).

| Projects Expenditure Item field (target) | Source |
|---|---|
| Project Number | `project_number` |
| Task Number | `task_number` |
| Expenditure Type | `expenditure_type` |
| Expenditure Organization | `department` |
| Person / Incurred-by | `person_id` |
| Expenditure Item Date | `work_date` |
| Quantity | `hours` (labor) **or** element `rate_amount` (non-hourly) |
| UOM | `HOURS` (labor) / `CURRENCY` (non-hourly) |
| Raw cost / bill rate | `pay_rate` / `write_in_rate` / `shift_differential` |
| Comment | `comments` |
| Reference / batch | `time_card_id`, `projects_batch_id` |

---

## 6. Integration 3 — Transfer to **Oracle Payroll** (non-hourly elements)

- **Trigger:** header `Approved`; **non-hourly** elements only (per diem, bonus, safety bonus, custom). Hours do **not** go to Payroll.
- **Grain:** one **Payroll Element Entry** per person × element × date.

| Payroll Element Entry field (target) | Source |
|---|---|
| Person Number | worker (`person_number`) via `person_id` |
| Assignment Number | worker assignment |
| Element Name | `CR_COMPENSATION_ELEMENTS.payroll_element_map` (maps `element_name` → Oracle element) |
| Input value — Amount | `rate_amount` (flat) / computed |
| Input value — Rate & type | `rate_amount` + `rate_type` (per-hour / flat / per-day) |
| Eligibility | `hours_threshold` |
| Effective / Work Date | line `work_date`, element `effective_start/end_date` |
| Customer-facing label | `customer_label` (invoice display; distinct from payroll name) |
| Reference / batch | `time_card_id`, `payroll_batch_id` |

---

## 7. Transport & framework

- **Middleware:** Oracle Integration Cloud (**OIC**) async batch; backend staging via **ORDS / Spring Boot**.
- **Idempotency:** drive off `*_transfer_status` + `*_batch_id`; never re-send a `Transferred` record.
- **Retry / error:** retry with backoff; on failure set status `Failed` + capture error; surface on the Integration Status dashboard (`CR-D-BR12`). Staging rows retained permanently (`CR-D-BR07`).
- **Security caveat:** CrewRite's live Oracle endpoints point at a **dev pod** with basic/anonymous auth — harden endpoints, credentials (vault), and TLS before O2C production.

---

## 8. Applying this to the O2C Time Module

O2C's downstream differs — **Revenue Accrual + Billing** are primary, Payroll is for salary — but the mechanics reuse directly:

| CrewRite integration | O2C equivalent | Reuse |
|---|---|---|
| OTL (hours) | Optional; O2C's hours feed **Revenue Accrual** (employee-day at **WBS** grain) + Projects cost | Reuse POET/hours mapping; **grain = employee × day × WBS** (not crew POET) |
| Projects (POET cost) | Projects cost / accrual feed | Reuse mapping + costed/uncosted logic |
| Payroll (non-hourly) | Payroll salary feed + **salary-hold** flow (OT, shift, holiday-working) | Reuse element-entry contract (`payroll_element_map`) |
| — (new) | **Revenue Accrual** — monthly rows + separate **adjustment/reversal** rows (±, net-off) | New target, **same OIC/status-tracking framework** |
| — (new) | **Billing** — unbilled→billed, cap, milestone/T&M/FCP/volume | New target, same framework |

**Reuse checklist for O2C**
- [ ] Per-target `*_transfer_status` + `*_batch_id` columns on the O2C header (add `accrual_*`, `billing_*`).
- [ ] Post-approval OIC batch job pattern (poll Approved → build payload → push → stamp status/batch).
- [ ] Source→target field mapping tables (§4–6) as the starting contract.
- [ ] Costed/uncosted decision (OI-003) to prevent Payroll/Projects double-booking.
- [ ] Reversal/net-off logic for post-close corrections → Revenue Accrual (O2C-specific; highest risk).
- [ ] Confirm exact target API field names against the backend/OIC integration repo.

---

## 9. Open items / caveats

1. **Payload is server-side.** Exact OTL/Projects/Payroll field names live in the OIC/ORDS integration, not the VBCS repo — validate against the backend before coding O2C.
2. **Costed vs uncosted** for non-hourly to Projects — unresolved (FSD OI-003).
3. **Absence** is **not re-sent** to OTL — and note absence integration itself is **not built** in CrewRite (designed only), so O2C must build the absence connector separately.
4. **Dev-environment endpoints/auth** must be hardened for production.
5. **Grain difference:** CrewRite is crew-level POET; O2C is **employee × day × WBS** — adjust keys and aggregation accordingly.

---

*Source: CrewRite `CR_TIME_CARD_HEADER` / `CR_TIME_CARD_LINES` / `CR_COMPENSATION_ELEMENTS` schema + service contracts, and FSD §5, §7.5, business rules CR-B-BR03 / CR-D-BR01–12. Payload contracts are the target to implement; verify against the OIC/ORDS backend.*
