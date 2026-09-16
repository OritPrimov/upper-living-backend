-- =====================================================================
-- Resident announcements module (targeted broadcast) — section 34 of the
-- extended planning doc (תכנון-בסיס-נתונים-קהילות, section 34).
-- Generic resident-attribute system + announcements/segments/recipients,
-- matching the mockups (prototype-resident-app.html "s-announcements",
-- prototype-management-software.html "m-announcements").
--
-- This corrects two issues found in the migration Lovable/the planning
-- doc drafted (supabase/external/... proposal, not committed here):
--   1. RLS used current_setting('app.current_community_id')::uuid — the
--      unused session-variable convention from the doc's original
--      section 1 example. This app's real resident-facing tables all use
--      the SECURITY DEFINER helpers from supabase/external/001_app_access.sql
--      (current_resident_id()/current_community_id(), backed by real
--      Supabase Auth sessions) — every other module in this repo
--      (support bot, meals, resources) uses that convention, and this
--      one needs to match or residents get zero access.
--   2. No GRANT statements at all — RLS policies are never evaluated
--      without the underlying table grant to `authenticated` first, so
--      residents would hit permission-denied even with correct RLS.
--
-- It also scopes announcement_recipients more tightly than the draft did:
-- that table is more sensitive than the announcement content itself (it
-- shows exactly who received/read what, and when), so it's restricted to
-- the resident's own row rather than community-wide. Staff (Retool)
-- connects via service-role and bypasses RLS entirely either way.
-- =====================================================================

-- ------------------------------------------------------------
-- 1. Generic resident attributes — lets a community manager add a new
-- targeting attribute ("parent of a kindergartner", "60+") without a
-- future migration (section 34.1).
-- ------------------------------------------------------------
create table if not exists attribute_definitions (
  id serial primary key,
  key text unique not null,
  label text not null,
  value_type text not null default 'boolean'
    check (value_type in ('boolean','text','number','date')),
  created_at timestamptz not null default now()
);

create table if not exists resident_attributes (
  resident_id uuid not null references residents(id),
  attribute_id int not null references attribute_definitions(id),
  value_boolean boolean,
  value_text text,
  updated_at timestamptz not null default now(),
  primary key (resident_id, attribute_id)
);

-- ------------------------------------------------------------
-- 2. The announcement itself
-- ------------------------------------------------------------
create table if not exists announcements (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  title text,
  body text not null,
  priority text not null default 'normal' check (priority in ('normal','urgent')),
  created_by uuid references staff_users(id),
  status text not null default 'draft' check (status in ('draft','scheduled','sent')),
  scheduled_for timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 3. Target-audience definition — AND across rows (section 34.2-34.3)
-- ------------------------------------------------------------
create table if not exists announcement_segments (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references announcements(id),
  filter_type text not null
    check (filter_type in ('building','floor_range','occupancy_type','attribute')),
  building_id uuid references buildings(id),
  floor_min int,
  floor_max int,
  occupancy_type text,
  attribute_id int references attribute_definitions(id),
  attribute_value text
);

-- ------------------------------------------------------------
-- 4. Delivery/read log — "who got what, and did they read it"
-- ------------------------------------------------------------
create table if not exists announcement_recipients (
  id bigserial primary key,
  announcement_id uuid not null references announcements(id),
  resident_id uuid not null references residents(id),
  delivered_at timestamptz not null default now(),
  read_at timestamptz,
  unique (announcement_id, resident_id)
);

-- ------------------------------------------------------------
-- 5. Extend reactions to allow a "קיבלתי" acknowledgment on an
-- announcement (section 34.6.3) — same constraint 20260914130000
-- already extended for potluck_item, adding 'announcement' alongside it.
-- ------------------------------------------------------------
do $$
begin
  alter table reactions drop constraint if exists reactions_target_type_check;
  alter table reactions add constraint reactions_target_type_check
    check (target_type in ('post','comment','event','potluck_item','announcement'));
exception when undefined_table then
  raise notice 'reactions table not found — skipped';
end $$;

-- ------------------------------------------------------------
-- 6. Indexes
-- ------------------------------------------------------------
create index if not exists idx_announcement_recipients_resident
  on announcement_recipients (resident_id, delivered_at);
create index if not exists idx_announcement_recipients_announcement
  on announcement_recipients (announcement_id);
create index if not exists idx_resident_attributes_attribute
  on resident_attributes (attribute_id);

-- ------------------------------------------------------------
-- 7. Row-Level Security — current_resident_id()/current_community_id(),
-- the live helpers backed by real Supabase Auth sessions (see header).
-- ------------------------------------------------------------
alter table announcements enable row level security;
alter table announcement_recipients enable row level security;

drop policy if exists app_read_community_announcements on announcements;
create policy app_read_community_announcements on announcements for select to authenticated
using (community_id = public.current_community_id());

drop policy if exists app_read_own_receipt on announcement_recipients;
create policy app_read_own_receipt on announcement_recipients for select to authenticated
using (resident_id = public.current_resident_id());

drop policy if exists app_mark_own_receipt_read on announcement_recipients;
create policy app_mark_own_receipt_read on announcement_recipients for update to authenticated
using (resident_id = public.current_resident_id())
with check (resident_id = public.current_resident_id());

grant select on announcements to authenticated;
grant select, update on announcement_recipients to authenticated;
