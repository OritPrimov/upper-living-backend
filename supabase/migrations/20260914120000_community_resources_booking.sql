-- =====================================================================
-- Community resource booking (v2): replaces the never-built-out
-- "shared_resources" / "resource_bookings" feature from
-- 20260906130000_gap_fixes_from_airtable_schema.sql with a richer
-- design (exclusive vs. per-capacity booking, maintenance blackouts,
-- fuller cancellation/payment tracking) from section 23 of the
-- extended planning doc (see docs/database-plan-extended.md).
--
-- Step 0 renames (not drops) the old, UI-less tables so the new
-- "resource_bookings" name is free — no data is lost, and nothing in
-- Retool/Lovable ever referenced the old tables (no screens were built
-- against them).
-- =====================================================================

-- ------------------------------------------------------------
-- 0. Retire the old, unused shared-resource tables (rename only)
-- ------------------------------------------------------------
alter table if exists shared_resources rename to shared_resources_deprecated;
alter table if exists resource_bookings rename to resource_bookings_deprecated;

comment on table shared_resources_deprecated is
  'Deprecated 2026-09-14: superseded by community_resources. Renamed (not dropped) — no UI was ever built against this table, so it holds no real data, but nothing is deleted just in case.';
comment on table resource_bookings_deprecated is
  'Deprecated 2026-09-14: superseded by the new resource_bookings table (community_resources-based design). Renamed, not dropped.';

-- ------------------------------------------------------------
-- 1. Resource catalog
-- ------------------------------------------------------------
create table if not exists community_resources (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  building_id uuid references buildings(id), -- null = shared across the whole community
  name text not null,
  category text not null,
  description text,
  location_notes text,
  photo_url text,
  usage_rules text,
  capacity int,
  booking_mode text not null default 'exclusive'
    check (booking_mode in ('exclusive','concurrent')),
  is_paid boolean not null default false,
  price_amount numeric(10,2),
  price_unit text check (price_unit in ('per_hour','per_booking','per_day')),
  deposit_amount numeric(10,2),
  requires_approval boolean not null default false,
  min_booking_minutes int not null default 30,
  max_booking_minutes int,
  buffer_minutes int not null default 0,
  advance_booking_days int not null default 60,
  min_advance_notice_hours int not null default 0,
  max_bookings_per_resident_per_month int,
  available_hours jsonb,
  status text not null default 'active'
    check (status in ('active','maintenance','inactive')),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. Bookings
-- ------------------------------------------------------------
create table if not exists resource_bookings (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references community_resources(id),
  resident_id uuid not null references residents(id),
  created_by_staff_id uuid references staff_users(id), -- null if the resident booked it themself
  start_time timestamptz not null,
  end_time timestamptz not null,
  attendee_count int,
  status text not null default 'confirmed'
    check (status in ('pending_approval','confirmed','rejected','cancelled','completed','no_show')),
  is_charged boolean not null default false,
  charged_amount numeric(10,2),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','paid','waived','refunded')),
  notes text,
  cancelled_by_type text check (cancelled_by_type in ('resident','staff')),
  cancelled_by_id uuid,
  cancellation_reason text,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

-- ------------------------------------------------------------
-- 3. Maintenance blackouts (separate from real bookings)
-- ------------------------------------------------------------
create table if not exists resource_blackout_periods (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references community_resources(id),
  start_time timestamptz not null,
  end_time timestamptz not null,
  reason text,
  created_by uuid references staff_users(id),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 4. Conflict prevention — exclusive vs. per-capacity, via trigger
-- (a plain EXCLUDE constraint can't express "allow N overlaps")
-- ------------------------------------------------------------
create or replace function check_resource_booking_capacity() returns trigger as $$
declare
  v_mode text;
  v_capacity int;
  v_overlap_count int;
begin
  select booking_mode, capacity into v_mode, v_capacity
  from community_resources where id = new.resource_id;

  select count(*) into v_overlap_count
  from resource_bookings
  where resource_id = new.resource_id
    and status in ('pending_approval','confirmed')
    and id <> coalesce(new.id, gen_random_uuid())
    and tstzrange(start_time, end_time) && tstzrange(new.start_time, new.end_time);

  if v_mode = 'exclusive' and v_overlap_count > 0 then
    raise exception 'המשאב כבר תפוס בטווח הזמן הזה';
  elsif v_mode = 'concurrent' and v_overlap_count >= coalesce(v_capacity, 1) then
    raise exception 'המשאב הגיע לתפוסה המקסימלית בטווח הזמן הזה';
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_resource_booking_capacity on resource_bookings;
create trigger trg_check_resource_booking_capacity
  before insert or update on resource_bookings
  for each row execute function check_resource_booking_capacity();

-- ------------------------------------------------------------
-- 5. Row-Level Security
-- ------------------------------------------------------------
alter table community_resources enable row level security;
drop policy if exists tenant_isolation on community_resources;
create policy tenant_isolation on community_resources
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table resource_bookings enable row level security;
drop policy if exists tenant_isolation on resource_bookings;
create policy tenant_isolation on resource_bookings
  using (
    resource_id in (
      select id from community_resources
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

alter table resource_blackout_periods enable row level security;
drop policy if exists tenant_isolation on resource_blackout_periods;
create policy tenant_isolation on resource_blackout_periods
  using (
    resource_id in (
      select id from community_resources
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- ------------------------------------------------------------
-- 6. Indexes
-- ------------------------------------------------------------
create index if not exists idx_resource_bookings_resource_time
  on resource_bookings (resource_id, start_time);

create index if not exists idx_resource_bookings_resident
  on resource_bookings (resident_id);

create index if not exists idx_community_resources_community
  on community_resources (community_id);
