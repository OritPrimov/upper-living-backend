-- =====================================================================
-- Section 42 of the extended planning doc (docs/database-plan-extended.md):
-- value for real-estate developers, from sale through handover — reusing
-- the existing community/resident/announcement infrastructure rather than
-- building a parallel product for the presale/construction phase.
--
-- NOTE on residents.status: the doc's 42.6 shows `DROP CONSTRAINT` +
-- re-`ADD CONSTRAINT` with only ('pending_approval','active','pre_move_in',
-- 'inactive') — which would silently drop 'moved_out' from the allowed
-- values (confirmed live: the current constraint is
-- ('pending_approval','active','inactive','moved_out')). Widening it to
-- add 'pre_move_in' while keeping all four existing values instead of
-- copying the doc's literal list.
-- =====================================================================

-- ------------------------------------------------------------
-- 42.2 — a community's lifecycle stage. The same `communities` row is
-- used from the moment a project goes to market, just earlier in its
-- lifecycle — not a separate "project" entity.
-- ------------------------------------------------------------
alter table communities
  add column if not exists lifecycle_stage text not null default 'active'
    check (lifecycle_stage in ('presale','construction','handover','active')),
  add column if not exists expected_handover_date date,
  add column if not exists actual_handover_date date;

-- ------------------------------------------------------------
-- 42.3 — the sale funnel itself, on the existing ownership_periods table
-- (the doc calls it `unit_owners`; see 20260920130000_units_module.sql
-- for why it's ownership_periods live).
-- ------------------------------------------------------------
alter table ownership_periods
  add column if not exists sale_status text not null default 'contracted'
    check (sale_status in ('reserved','contracted','cancelled','closed')),
  add column if not exists reserved_at timestamptz,
  add column if not exists contract_signed_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text;

-- 42.6: a buyer can get app access before handover, to join their future
-- neighbours' lobby, interest groups, and meet-up events. Widened (not
-- replaced) to keep 'moved_out'.
alter table residents drop constraint if exists residents_status_check;
alter table residents add constraint residents_status_check
  check (status in ('pending_approval','active','inactive','moved_out','pre_move_in'));

-- ------------------------------------------------------------
-- 42.4 — construction progress updates, proactive transparency for buyers
-- ------------------------------------------------------------
create table if not exists construction_milestones (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  title text not null,                 -- "ground floor pour", "windows installed"
  description text,
  planned_date date,
  actual_date date,
  status text not null default 'planned'
    check (status in ('planned','in_progress','completed','delayed')),
  photo_urls text[],
  is_published boolean not null default false,  -- staff can prep before publishing to buyers
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table construction_milestones enable row level security;
drop policy if exists tenant_isolation on construction_milestones;
create policy tenant_isolation on construction_milestones
  using (community_id = current_setting('app.current_community_id', true)::uuid);

-- ------------------------------------------------------------
-- 42.5 — finish/fit-out selections, replacing the spreadsheet. Residents
-- need read access to categories/options to choose, and to read/confirm
-- their own unit's selection — this is the live counterpart of the
-- "finish" screen already mocked up in Upper Residents.
-- ------------------------------------------------------------
create table if not exists finish_selection_categories (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  name text not null,                  -- "flooring", "sanitary fixtures", "electrical points"
  deadline_offset_days int,            -- how many days before handover this selection closes
  sort_order int not null default 0
);

create table if not exists finish_selection_options (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references finish_selection_categories(id),
  name text not null,                  -- "60x60 grey porcelain tile"
  extra_cost numeric(10,2) not null default 0,
  image_url text,
  is_default boolean not null default false   -- auto-selected if the buyer doesn't choose by the deadline
);

create table if not exists unit_finish_selections (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  category_id uuid not null references finish_selection_categories(id),
  option_id uuid references finish_selection_options(id),
  selected_by_resident_id uuid references residents(id),
  status text not null default 'pending'
    check (status in ('pending','confirmed','locked','defaulted')),
  deadline_at timestamptz,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (unit_id, category_id)
);

alter table finish_selection_categories enable row level security;
drop policy if exists tenant_isolation on finish_selection_categories;
create policy tenant_isolation on finish_selection_categories
  using (community_id = current_setting('app.current_community_id', true)::uuid);

drop policy if exists app_read_categories on finish_selection_categories;
create policy app_read_categories on finish_selection_categories
  for select to authenticated
  using (community_id = current_community_id());

alter table finish_selection_options enable row level security;
drop policy if exists tenant_isolation on finish_selection_options;
create policy tenant_isolation on finish_selection_options
  using (
    category_id in (
      select id from finish_selection_categories
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

drop policy if exists app_read_options on finish_selection_options;
create policy app_read_options on finish_selection_options
  for select to authenticated
  using (
    category_id in (
      select id from finish_selection_categories where community_id = current_community_id()
    )
  );

alter table unit_finish_selections enable row level security;
drop policy if exists tenant_isolation on unit_finish_selections;
create policy tenant_isolation on unit_finish_selections
  using (
    unit_id in (
      select u.id from units u
      join buildings b on b.id = u.building_id
      where b.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- a resident may read and confirm the selection for their own unit only
drop policy if exists app_read_own_unit_selection on unit_finish_selections;
create policy app_read_own_unit_selection on unit_finish_selections
  for select to authenticated
  using (unit_id = (select unit_id from residents where id = current_resident_id()));

drop policy if exists app_update_own_unit_selection on unit_finish_selections;
create policy app_update_own_unit_selection on unit_finish_selections
  for update to authenticated
  using (unit_id = (select unit_id from residents where id = current_resident_id()))
  with check (
    unit_id = (select unit_id from residents where id = current_resident_id())
    and selected_by_resident_id = current_resident_id()
  );

-- ------------------------------------------------------------
-- 42.7 — buyer referral program
-- ------------------------------------------------------------
create table if not exists buyer_referrals (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  referrer_resident_id uuid not null references residents(id),
  referred_name text not null,
  referred_phone text not null,
  status text not null default 'submitted'
    check (status in ('submitted','contacted','toured','purchased','rejected')),
  reward_status text not null default 'none'
    check (reward_status in ('none','pending','paid')),
  created_at timestamptz not null default now()
);

alter table buyer_referrals enable row level security;
drop policy if exists tenant_isolation on buyer_referrals;
create policy tenant_isolation on buyer_referrals
  using (community_id = current_setting('app.current_community_id', true)::uuid);

drop policy if exists app_read_own_referrals on buyer_referrals;
create policy app_read_own_referrals on buyer_referrals
  for select to authenticated
  using (referrer_resident_id = current_resident_id());

drop policy if exists app_create_own_referral on buyer_referrals;
create policy app_create_own_referral on buyer_referrals
  for insert to authenticated
  with check (
    referrer_resident_id = current_resident_id()
    and community_id = current_community_id()
  );

-- ------------------------------------------------------------
-- 42.8 — daily sales-funnel snapshot for the developer dashboard, built
-- by the same nightly ETL as fact_daily_engagement (section 4). No RLS,
-- matching every other analytics.fact_* table (BI/Retool access only).
-- ------------------------------------------------------------
create table if not exists analytics.fact_sales_funnel (
  community_id uuid not null,
  snapshot_date date not null,
  reserved_count int not null default 0,
  contracted_count int not null default 0,
  cancelled_count int not null default 0,
  closed_count int not null default 0,
  primary key (community_id, snapshot_date)
);

-- ------------------------------------------------------------
-- Indexes
-- ------------------------------------------------------------
create index if not exists idx_construction_milestones_community on construction_milestones(community_id);
create index if not exists idx_finish_selection_categories_community on finish_selection_categories(community_id);
create index if not exists idx_finish_selection_options_category on finish_selection_options(category_id);
create index if not exists idx_unit_finish_selections_unit on unit_finish_selections(unit_id);
create index if not exists idx_buyer_referrals_community on buyer_referrals(community_id);
create index if not exists idx_buyer_referrals_referrer on buyer_referrals(referrer_resident_id);
