# HDL loads for the timesheet module

HCM Data Loader files. Written for a specific one-off, not a pipeline — the
running integration is `integration/bip/`, which **reads** from Fusion. This
directory is the rare case of putting something **back**.

## `Worker.dat` — work email for the test cohort

Ten people get a `W1` work email. Written 17-Aug-2026.

### Why it exists

Sign-in is keyed on email. Of the twelve people the module is tested with,
**only RI2894 had an email anywhere in Fusion** — the other eleven had no row
in `PER_EMAIL_ADDRESSES` at all, so `OC_TIME_WORKER.EMAIL` came back null and
`OC_TIME_USER.EMAIL` is `NOT NULL`. There was nothing to invite them with.

`db/57_worker_emails.sql` set the addresses locally as a stand-in. This is the
real fix: put them where they belong, and the local values are superseded
automatically — `sync/worker` sets `NVL(LOWER(r.email), w.email)`, so Fusion
wins the moment Fusion has an answer.

### Who is not in it

| | |
|---|---|
| `RI2894` Santosh | already has a `W1` address on the pod; reloading would collide |
| `CRI0398` Kishore | excluded by request |

### Checked before writing it

Guesses here fail slowly — HDL reports a row-level error hours later, or
worse, loads something subtly wrong. So each assumption was measured:

- every one of the ten has `effective_start_date` and `start_date` of
  **2024-01-01**, so `DateFrom 2024/01/01` sits inside the person record
- every one has **zero** rows in `PER_EMAIL_ADDRESSES`, so `MERGE` creates and
  overwrites nothing
- `W1` is the type the pod already uses — it is what RI2894 carries

### Loading it

```sh
zip Worker.zip Worker.dat        # the .dat name matters, the .zip name does not
```

**Tools → Data Exchange → Load HCM Data → Import and Load Data**, upload the
zip, then watch the process for row-level errors.

### The format is this pod's, not the generic one

Column order, owner and id pattern all copy a load already proven here:

```
METADATA|PersonEmail|PersonNumber|EmailType|EmailAddress|DateFrom|SourceSystemOwner|SourceSystemId
MERGE|PersonEmail|2070|W1|sambamurty.sana@rite.digital|2025/01/01|RITE_IN_CLOUD|RITE_IN_CLOUD_PersonEmail_2070
```

So `SourceSystemOwner` is **`RITE_IN_CLOUD`**, the owner registered on this
pod, and `SourceSystemId` follows `RITE_IN_CLOUD_PersonEmail_<PersonNumber>`.
The first draft of this file used `HRC_SQLLOADER` — HDL's generic default —
which this pod would have rejected. Copy the working shape rather than the
documented one.

`PrimaryFlag` is **not** in the metadata, matching that sample. HDL makes the
first address primary on its own, and every one of these ten is a first
address.

### After it loads

Run the WORKERS sync and check the `SOURCE` column in
`db/57_worker_emails.sql` section 2 — those rows should flip from `local` to
`Fusion`. That is the confirmation, not the HDL process status.

**`OC_TIME_USER.EMAIL` does not follow.** The login is a separate row and
nothing syncs it. The addresses here match what 57 already set, so the two stay
in step — but change one and you must change the other, or people sign in with
an address the worker record no longer has.
