# Postman — O2C Timesheet ORDS surface

`O2C_Time.postman_collection.json` — 78 requests across the four ORDS modules.

## Import and run

1. Postman → **Import** → `O2C_Time.postman_collection.json`.
2. Check the `baseUrl` collection variable. Default:
   `https://ords-sit.rite.digital/ords/o2c_time`
3. Run **`1. Auth` → `login`** first.

That last step matters. The login request carries a test script that stores the
token and the signed-in employee id as collection variables, and every other
request reads them from there. Without it you get a valid-looking request with
an empty `actorEmpId`, and the server refuses it for a reason that has nothing
to do with what you were testing.

## Switching persona

Change the `email` collection variable and run `login` again:

| Email | Role | Worker |
|---|---|---|
| `admin@rite.digital` | `ROLE_TIME_ADMIN` | none — the common admin |
| `navamani.solairajan@rite.digital` | `ROLE_TIME_MANAGER` | `RI9001` |
| `Santoshkumar.kanala@rite.digital` | `ROLE_TIME_ADMIN` | `RI2894` |
| `sampaul.jeevan@rite.digital` | `ROLE_TIME_EMPLOYEE` | `RI2824` |

All twelve seeded workers have a login. Password is `Rite@123` throughout —
test data only, from `db/90_test_seed.sql`.

The admin is worth signing in as at least once: it has no `OC_TIME_WORKER` row,
so it exercises the `OC_TIME_USER.APP_ROLE` override branch of
`V_OC_TIME_SIGNIN`, which is the case that the older identity-provider model
could not handle at all.

## Variables you fill in as you go

`periodId`, `projectId`, `tsWeekId` and `confirmId` start empty. The GET
requests that list them tell you what to use:

| To get | Run |
|---|---|
| `periodId` | `2. Employee` → `getPeriods` |
| `projectId` | `3. Manager` → `getManagerProjects` |
| `tsWeekId` | `2. Employee` → `getWeeks`, or `3. Manager` → `getWeeksForApproval` |
| `confirmId` | `4. Admin` → `getConfirmedMonths` |

## Regenerating

```sh
python postman/build_collection.py
```

The collection is **generated from `services/oc_time/openapi3.json`**, never
hand-edited — so a request cannot point at a path that is not deployed. Re-run
it after adding an endpoint, and re-import.

The generator also diffs the spec against the `ORDS.DEFINE_HANDLER` calls in
`db/ords/` and warns either way:

- **deployed but not described** — the endpoint exists and answers, but is
  invisible to `callRest` and to this collection. That is how the whole
  `oc.time.auth` module and the three dormant `push/*` endpoints went missing:
  the build checks only ever verified that every `callRest` resolves to an
  operation, never the reverse.
- **described but not deployed** — the request would 404.

## A note on auth

These endpoints take the token in the **body** (`logout`) or the **path**
(`session/{token}`), not an `Authorization` header. That is the same contract
the main O2C application's `oc_auth` uses, kept deliberately so the two apps
behave identically.

Nothing else on the surface checks the token yet — RA-002 has ORDS anonymous
access as acceptable in lower environments only, to be hardened before PROD.
So a request will answer even without running `login` first; the reason to run
it is the collection variables it fills in.
