-- =====================================================================
-- Sections 43, 45, 46, 50 of the extended planning doc
-- (docs/database-plan-extended.md): notes/tasks/contacts, for a resident,
-- for a resident's personal reminders, for an external unit owner with no
-- account, and for the venture's own business relationships.
--
-- Deliberately NOT included in this migration (see section 43.3/44/45.3):
--   - sales_lead_tasks — depends on `sales_leads`, which doesn't exist yet
--     (sections 36-40, a separate later module). Adding it now would
--     reference a table that isn't there.
--   - The unified cross-source task calendar for Upper HQ's Founder
--     Console (sales leads + venture relationships + owner tasks) — the
--     query itself needs no schema, but it can't UNION in sales_lead_tasks
--     until that table exists. resident_tasks/owner_tasks/
--     venture_relationship_tasks below are ready to be UNIONed the moment
--     it is.
--   - The "unit_finish_selections" branch of "my tasks" (46.3/46.5) —
--     depends on the developer sale module (section 42), not built yet.
-- =====================================================================

-- ------------------------------------------------------------
-- 43.2 — staff's internal record on a resident: notes, tasks, contacts.
-- Deliberately staff-only (46.1: a resident must never see staff's
-- internal notes/tasks about them) — so, same as
-- resource_blackout_periods elsewhere in this schema, these get ONLY the
-- staff-side tenant_isolation policy, no app_* policy at all. That policy
-- is a safe no-op for a resident's own session (app.current_community_id
-- is only ever set by the Retool/staff connection, never by the app), so
-- nothing extra is needed to keep this private from residents.
-- ------------------------------------------------------------
create table if not exists resident_notes (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references residents(id),
  body text not null,
  occurred_at timestamptz not null default now(),
  created_by_staff_id uuid not null references staff_users(id),
  created_at timestamptz not null default now()
);

create table if not exists resident_tasks (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references residents(id),
  title text not null,
  description text,
  planned_date date,
  actual_completed_at timestamptz,
  status text not null default 'open' check (status in ('open','done','cancelled')),
  assigned_to_staff_id uuid references staff_users(id),
  created_by_staff_id uuid not null references staff_users(id),
  created_at timestamptz not null default now()
);

create table if not exists resident_contacts (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references residents(id),
  full_name text not null,
  relation text,              -- e.g. "spouse", "parent", "emergency contact"
  phone text,
  email text,
  notes text,
  created_at timestamptz not null default now()
);

-- 43.4: "overdue" is derived from time, not a stored flag (same principle
-- as parking listing expiry and deal validity elsewhere in this schema)
create or replace view resident_tasks_overdue as
select * from resident_tasks where status = 'open' and planned_date < current_date;

alter table resident_notes enable row level security;
drop policy if exists tenant_isolation on resident_notes;
create policy tenant_isolation on resident_notes
  using (
    resident_id in (
      select id from residents
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

alter table resident_tasks enable row level security;
drop policy if exists tenant_isolation on resident_tasks;
create policy tenant_isolation on resident_tasks
  using (
    resident_id in (
      select id from residents
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

alter table resident_contacts enable row level security;
drop policy if exists tenant_isolation on resident_contacts;
create policy tenant_isolation on resident_contacts
  using (
    resident_id in (
      select id from residents
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- ------------------------------------------------------------
-- 46.2 — "my tasks" for the resident: personal reminders they add
-- themselves. Opposite privacy shape from the tables above: RLS here is
-- scoped to the resident's own row, not the whole community — a resident
-- must not see a neighbour's personal reminders.
-- ------------------------------------------------------------
create table if not exists resident_personal_tasks (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references residents(id),
  title text not null,
  planned_date date,
  actual_completed_at timestamptz,
  status text not null default 'open' check (status in ('open','done','cancelled')),
  created_at timestamptz not null default now()
);

alter table resident_personal_tasks enable row level security;

-- staff (Retool) side, for support/debugging — same safe-no-op-for-residents
-- pattern as every other tenant_isolation policy in this schema
drop policy if exists tenant_isolation on resident_personal_tasks;
create policy tenant_isolation on resident_personal_tasks
  using (
    resident_id in (
      select id from residents
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- resident (Lovable app) side — only their own rows
drop policy if exists app_read_own_personal_tasks on resident_personal_tasks;
create policy app_read_own_personal_tasks on resident_personal_tasks
  for select to authenticated
  using (resident_id = current_resident_id());

drop policy if exists app_create_own_personal_tasks on resident_personal_tasks;
create policy app_create_own_personal_tasks on resident_personal_tasks
  for insert to authenticated
  with check (resident_id = current_resident_id());

drop policy if exists app_update_own_personal_tasks on resident_personal_tasks;
create policy app_update_own_personal_tasks on resident_personal_tasks
  for update to authenticated
  using (resident_id = current_resident_id())
  with check (resident_id = current_resident_id());

-- ------------------------------------------------------------
-- 50.2 — tasks against an external unit owner who has no app account.
-- NOTE: the doc calls the referenced table `unit_owners`, but it already
-- exists live as `ownership_periods` (built as the time-boxed replacement
-- for unit_owners in 20260906130000) — referencing that instead of
-- creating a table that would collide.
-- ------------------------------------------------------------
create table if not exists owner_tasks (
  id uuid primary key default gen_random_uuid(),
  unit_owner_id uuid not null references ownership_periods(id),
  title text not null,
  planned_date date,
  actual_completed_at timestamptz,
  status text not null default 'open' check (status in ('open','done')),
  created_by_staff_id uuid not null references staff_users(id),
  created_at timestamptz not null default now()
);

alter table owner_tasks enable row level security;
drop policy if exists tenant_isolation on owner_tasks;
create policy tenant_isolation on owner_tasks
  using (
    unit_owner_id in (
      select op.id from ownership_periods op
      join units u on u.id = op.unit_id
      join buildings b on b.id = u.building_id
      where b.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- ------------------------------------------------------------
-- 45 — the venture's own business relationships (investors, lawyers,
-- accountants, advisors, vendors, partners) — Orit's internal Upper HQ
-- data, with no per-community tenant boundary at all. Same shape as
-- sales_leads (deliberately not merged with it — see 45.2: a venture
-- relationship has no pipeline "stage" or conversion to an organization).
-- RLS follows the same pattern already used for other platform-level
-- tables (platform_payments, platform_plans, organization_subscriptions):
-- enabled, but with no policies — access is via the Retool/staff
-- connection only, and default-denied to every other role.
-- ------------------------------------------------------------
create table if not exists venture_relationships (
  id uuid primary key default gen_random_uuid(),
  name text not null,                 -- "Vertex Ventures", "Sagi & Co. Law Firm"
  category text not null check (category in ('investor','legal','accounting','advisor','vendor','partner','other')),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now()
);

create table if not exists venture_relationship_notes (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null references venture_relationships(id),
  body text not null,
  occurred_at timestamptz not null default now(),
  created_by_staff_id uuid not null references staff_users(id),
  created_at timestamptz not null default now()
);

create table if not exists venture_relationship_tasks (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null references venture_relationships(id),
  title text not null,
  description text,
  planned_date date,
  actual_completed_at timestamptz,
  status text not null default 'open' check (status in ('open','done','cancelled')),
  assigned_to_staff_id uuid references staff_users(id),
  created_by_staff_id uuid not null references staff_users(id),
  created_at timestamptz not null default now()
);

create table if not exists venture_relationship_contacts (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null references venture_relationships(id),
  full_name text not null,
  role text,
  phone text,
  email text,
  created_at timestamptz not null default now()
);

create or replace view venture_relationship_tasks_overdue as
select * from venture_relationship_tasks where status = 'open' and planned_date < current_date;

alter table venture_relationships enable row level security;
alter table venture_relationship_notes enable row level security;
alter table venture_relationship_tasks enable row level security;
alter table venture_relationship_contacts enable row level security;

-- ------------------------------------------------------------
-- Indexes
-- ------------------------------------------------------------
create index if not exists idx_resident_notes_resident on resident_notes(resident_id);
create index if not exists idx_resident_tasks_resident on resident_tasks(resident_id);
create index if not exists idx_resident_tasks_planned_date on resident_tasks(planned_date) where status = 'open';
create index if not exists idx_resident_contacts_resident on resident_contacts(resident_id);
create index if not exists idx_resident_personal_tasks_resident on resident_personal_tasks(resident_id);
create index if not exists idx_owner_tasks_unit_owner on owner_tasks(unit_owner_id);
create index if not exists idx_owner_tasks_planned_date on owner_tasks(planned_date) where status = 'open';
create index if not exists idx_venture_relationship_notes_relationship on venture_relationship_notes(relationship_id);
create index if not exists idx_venture_relationship_tasks_relationship on venture_relationship_tasks(relationship_id);
create index if not exists idx_venture_relationship_contacts_relationship on venture_relationship_contacts(relationship_id);
