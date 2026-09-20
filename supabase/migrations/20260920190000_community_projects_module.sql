-- =====================================================================
-- Section 47 of the extended planning doc (docs/database-plan-extended.md):
-- a general "community project" structure (the motivating example is a
-- meal train for new parents, but it's deliberately generic enough to
-- also serve a clothing donation drive, errands for an elderly resident,
-- etc.) — a project is the wrapper, a slot is the individual claimable
-- unit of help.
--
-- NOTE on reactions.target_type: widening (not replacing) the existing
-- check, same care as the residents.status fix in the developer-presale
-- migration — the current live list is
-- ('post','comment','event','potluck_item','announcement'), confirmed
-- live before writing this.
-- =====================================================================

create table if not exists community_projects (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  title text not null,                    -- "Meal train — the Cohen family"
  project_type text not null default 'other'
    check (project_type in ('meal_train','donation','errand','other')),
  description text,
  beneficiary_name text,                  -- display only: "the Cohen family" — not necessarily a registered resident (could be a newborn, a guest)
  beneficiary_resident_id uuid references residents(id),   -- optional, if the beneficiary is an existing resident
  initiated_by_resident_id uuid references residents(id),
  initiated_by_staff_id uuid references staff_users(id),
  status text not null default 'active' check (status in ('active','completed','cancelled')),
  created_at timestamptz not null default now(),
  check (initiated_by_resident_id is not null or initiated_by_staff_id is not null)
);

create table if not exists community_project_slots (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references community_projects(id),
  slot_date date,                         -- null if the slot isn't date-based (e.g. "item to donate")
  needed_description text,                -- "hot meal for 4", "size 38 shoes"
  claimed_by_resident_id uuid references residents(id),
  claimed_at timestamptz,
  status text not null default 'open'
    check (status in ('open','claimed','completed','cancelled')),
  completion_note text,                   -- what was actually brought/done
  photo_url text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (project_id, slot_date)           -- one slot per date in a date-based project (NULLs don't collide, so non-dated projects are unaffected)
);

-- 47.4: reuse the existing polymorphic reactions table instead of a new one
alter table reactions drop constraint if exists reactions_target_type_check;
alter table reactions add constraint reactions_target_type_check
  check (target_type in ('post','comment','event','potluck_item','announcement','community_project_slot'));

-- ------------------------------------------------------------
-- 47.7 — RLS: community_project_slots has no direct community_id, so it's
-- enforced indirectly through project_id -> community_projects.community_id,
-- the same pattern used throughout this schema.
-- ------------------------------------------------------------
alter table community_projects enable row level security;
drop policy if exists tenant_isolation on community_projects;
create policy tenant_isolation on community_projects
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table community_project_slots enable row level security;
drop policy if exists tenant_isolation on community_project_slots;
create policy tenant_isolation on community_project_slots
  using (
    project_id in (
      select id from community_projects
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- resident (Lovable app) side — it's a neighbour-to-neighbour feature,
-- everyone in the community browses projects and slots (same marketplace
-- shape as community_resources/parking_listings)
drop policy if exists app_read_community_projects on community_projects;
create policy app_read_community_projects on community_projects
  for select to authenticated
  using (community_id = current_community_id());

drop policy if exists app_create_own_project on community_projects;
create policy app_create_own_project on community_projects
  for insert to authenticated
  with check (
    initiated_by_resident_id = current_resident_id()
    and community_id = current_community_id()
  );

drop policy if exists app_read_community_slots on community_project_slots;
create policy app_read_community_slots on community_project_slots
  for select to authenticated
  using (
    project_id in (select id from community_projects where community_id = current_community_id())
  );

-- the project's own initiator adds slots (one-by-one, or the app inserts
-- several at once for a meal_train's consecutive days per 47.6)
drop policy if exists app_create_slots_for_own_project on community_project_slots;
create policy app_create_slots_for_own_project on community_project_slots
  for insert to authenticated
  with check (
    project_id in (
      select id from community_projects
      where community_id = current_community_id() and initiated_by_resident_id = current_resident_id()
    )
  );

-- 47.2: claiming an open slot, or updating a slot you already claimed
-- (e.g. marking it completed with a note/photo) — the WITH CHECK's
-- "claimed_by_resident_id = current_resident_id()" is what stops a
-- resident from tampering with a slot someone else already claimed, since
-- the row's claimed_by would stay as the other resident's id, failing
-- the check
drop policy if exists app_claim_or_update_own_slot on community_project_slots;
create policy app_claim_or_update_own_slot on community_project_slots
  for update to authenticated
  using (project_id in (select id from community_projects where community_id = current_community_id()))
  with check (
    project_id in (select id from community_projects where community_id = current_community_id())
    and claimed_by_resident_id = current_resident_id()
  );

-- ------------------------------------------------------------
-- Indexes
-- ------------------------------------------------------------
create index if not exists idx_community_projects_community on community_projects(community_id);
create index if not exists idx_community_project_slots_project on community_project_slots(project_id);
create index if not exists idx_community_project_slots_claimed_by on community_project_slots(claimed_by_resident_id);
