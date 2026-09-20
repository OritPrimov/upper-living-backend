-- =====================================================================
-- Section 53 of the extended planning doc (docs/database-plan-extended.md):
-- unit-level apartment info, and owner/tenant relationships with validity
-- dates.
--
-- Two of the doc's three sub-parts are already covered by earlier work and
-- need no schema change here:
--   - 53.3 (ownership with start/end dates) is already fully covered by
--     `ownership_periods` (start_date/end_date + ownership_share +
--     transfer_reason), built in 20260906130000_gap_fixes_from_airtable_schema.sql
--     as the doc's own "unit_owners, but time-boxed" replacement.
--   - The doc's proposed `unit_tenancies` table already exists live as
--     `tenancy_periods` (same migration) — this file only EXTENDS it with
--     the columns the doc's section 53.4 needs that aren't there yet
--     (full_name/phone/email fallback contact, created_by_staff_id, and
--     making resident_id nullable for a tenant with no account yet), not
--     creating a new table.
--
-- 53.2 (apartment-level details on `units`) is genuinely new. NOTE: the doc
-- names the new column `unit_type`, but `units.unit_type` already exists
-- with a different meaning (residential/office/commercial — building use,
-- from the same gap-fixes migration). Renamed to `apartment_type` here to
-- avoid overwriting it; same enum values the doc specifies.
-- =====================================================================

-- ------------------------------------------------------------
-- 53.2 — apartment-level details
-- ------------------------------------------------------------
alter table units
  add column if not exists size_sqm numeric(6,2),
  add column if not exists rooms numeric(3,1),
  add column if not exists apartment_type text
    check (apartment_type in ('standard','garden','duplex','penthouse','other')),
  add column if not exists parking_spots_count int not null default 0,
  add column if not exists storage_units_count int not null default 0;

-- ------------------------------------------------------------
-- 53.4 — extend tenancy_periods (the live `unit_tenancies`) to support a
-- tenant who doesn't have an app account yet, same pattern as
-- ownership_periods already does for owners.
-- ------------------------------------------------------------
alter table tenancy_periods
  add column if not exists full_name text,
  add column if not exists phone text,
  add column if not exists email text,
  add column if not exists created_by_staff_id uuid references staff_users(id);

-- backfill full_name for existing rows from the linked resident, so the
-- not-null constraint below doesn't break current data
update tenancy_periods tp
set full_name = r.full_name
from residents r
where tp.resident_id = r.id and tp.full_name is null;

alter table tenancy_periods alter column full_name set not null;
alter table tenancy_periods alter column resident_id drop not null;

-- ------------------------------------------------------------
-- 53.6 — RLS: a resident should see only their own ownership/tenancy
-- rows, not the whole unit's. Staff-side tenant_isolation already exists
-- on both tables from the original gap-fixes migration.
-- ------------------------------------------------------------
drop policy if exists app_read_own_ownership on ownership_periods;
create policy app_read_own_ownership on ownership_periods
  for select to authenticated
  using (resident_id = current_resident_id());

drop policy if exists app_read_own_tenancy on tenancy_periods;
create policy app_read_own_tenancy on tenancy_periods
  for select to authenticated
  using (resident_id = current_resident_id());
