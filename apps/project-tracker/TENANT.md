# AECOM-BD-Jason tenant ID

UUID: **833cc9ee-81b6-4e79-a4d7-e104fa37aa12**

Created: 2026-05-05 (Phase 10.1.3)
Slug:    `aecom-bd-jason` (human-friendly identifier; the UUID is the
         spine across all three identity subsystems)

## Used by

This UUID is the spine of multi-tenant identity for the AECOM-BD-Jason
tenant. It MUST be reused — never regenerated per environment — across:

- **Postgres** — value of `tenant_id` on every row in the
  `project_tracker.*` tables (10.1.3, this commit)
- **Keycloak** — `id` (or attribute `tenant_id`) of the
  `aecom-bd-jason` organization in the `secforge-tenants` realm
  (10.1.4 will provision)
- **SpiceDB** — `organization:aecom-bd-jason` object's external id
  field (10.1.4 will seed tuples)

## Why pinned

Regenerating the UUID per environment would break every audit trail
that joins across the three identity systems (e.g. "who edited this
PT row?" would not resolve to "this Keycloak user via this SpiceDB
membership" without a stable tenant identifier).

If you need a NEW tenant (e.g. a second AECOM business line), generate
a new UUID and document it in a new section below — never reuse this
one.

## Provenance

```
$ uuidgen
833cc9ee-81b6-4e79-a4d7-e104fa37aa12
```

Authority: this file. If a script or manifest references the UUID, it
should source it from this file (or from a constant clearly tagged as
"AECOM-BD-Jason tenant id from apps/project-tracker/TENANT.md") rather
than reproducing the literal independently.
