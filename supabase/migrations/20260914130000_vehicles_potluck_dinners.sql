-- =====================================================================
-- Sections 24-28 of the extended planning doc (docs/database-plan-extended.md):
--   24-25. Shared vehicles (extends community_resources from section 23)
--   26.    Potluck meal coordination (extends events)
--   27.    Resident-hosted "get to know your neighbours" dinners (extends events)
--   28.    Search/filter view for open dinner gatherings
--
-- Depends on 20260914120000_community_resources_booking.sql (community_resources,
-- resource_bookings) — must run after it. Purely additive: new tables, one new
-- column, one new storage bucket, and two existing CHECK constraints widened
-- (event_rsvps.status, reactions.target_type) to accept new values — no
-- existing rows are touched, and the constraint names below are Postgres's own
-- default auto-generated names for the unnamed column-level checks in
-- 20260906120000_initial_schema.sql (verified against that file).
-- =====================================================================

-- =====================================================================
-- 24-25. Shared vehicles
-- =====================================================================

create table if not exists vehicle_details (
  resource_id uuid primary key references community_resources(id),
  license_plate text not null,
  make_model text,
  fuel_type text not null default 'electric'
    check (fuel_type in ('electric','gasoline','diesel','hybrid')),
  current_charge_percent int check (current_charge_percent between 0 and 100),
  current_fuel_percent int check (current_fuel_percent between 0 and 100),
  current_odometer_km int,
  parking_spot text,
  live_status text not null default 'available'
    check (live_status in ('available','in_use','maintenance','out_of_service')),
  last_service_at date,
  next_service_due_km int,
  updated_at timestamptz not null default now()
);

create table if not exists vehicle_trip_logs (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references resource_bookings(id),
  checkout_at timestamptz,
  checkout_odometer_km int,
  checkout_charge_percent int,
  checkout_photo_url text,
  checkin_at timestamptz,
  checkin_odometer_km int,
  checkin_charge_percent int,
  checkin_photo_url text,
  damage_reported boolean not null default false,
  damage_notes text,
  created_at timestamptz not null default now(),
  -- 25.1: block an obviously wrong return-odometer reading (typo, or hiding a trip)
  constraint checkin_odometer_after_checkout
    check (checkin_odometer_km is null or checkout_odometer_km is null
           or checkin_odometer_km >= checkout_odometer_km)
);

-- 24.4: the trip log (checkout/checkin) is the single source of truth for the
-- vehicle's live status — nothing else should write to vehicle_details directly.
create or replace function sync_vehicle_status() returns trigger as $$
declare
  v_resource_id uuid;
begin
  select resource_id into v_resource_id from resource_bookings where id = new.booking_id;

  if new.checkin_at is not null then
    update vehicle_details set
      live_status = 'available',
      current_odometer_km = new.checkin_odometer_km,
      current_charge_percent = new.checkin_charge_percent,
      updated_at = now()
    where resource_id = v_resource_id;
  elsif new.checkout_at is not null then
    update vehicle_details set
      live_status = 'in_use',
      current_odometer_km = new.checkout_odometer_km,
      current_charge_percent = new.checkout_charge_percent,
      updated_at = now()
    where resource_id = v_resource_id;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_sync_vehicle_status on vehicle_trip_logs;
create trigger trg_sync_vehicle_status
  after insert or update on vehicle_trip_logs
  for each row execute function sync_vehicle_status();

alter table vehicle_details enable row level security;
drop policy if exists tenant_isolation on vehicle_details;
create policy tenant_isolation on vehicle_details
  using (
    resource_id in (
      select id from community_resources
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

alter table vehicle_trip_logs enable row level security;
drop policy if exists tenant_isolation on vehicle_trip_logs;
create policy tenant_isolation on vehicle_trip_logs
  using (
    booking_id in (
      select rb.id from resource_bookings rb
      join community_resources cr on cr.id = rb.resource_id
      where cr.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- 25.3.1: dedicated private bucket for checkout/checkin vehicle photos.
-- Private (not public) since these are evidence photos tied to a specific
-- resident's booking, not public content — access via signed URLs.
insert into storage.buckets (id, name, public)
values ('vehicle-trip-photos', 'vehicle-trip-photos', false)
on conflict (id) do nothing;

-- =====================================================================
-- 26. Potluck meal coordination
-- =====================================================================

create table if not exists potluck_items (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id),
  category text not null
    check (category in ('starter','main','dessert','drink','disposables','other')),
  item_name text,                              -- null while it's an open slot with no specific name yet
  quantity_needed int not null default 1,
  resident_id uuid references residents(id),   -- null = not yet claimed
  status text not null default 'open'
    check (status in ('open','claimed','cancelled')),
  claimed_at timestamptz,
  cancelled_at timestamptz,
  created_by uuid references residents(id),    -- who added the row (organizer or the resident themself)
  created_at timestamptz not null default now()
);

alter table event_rsvps add column if not exists notes text;

-- allow reactions (e.g. a heart) on a potluck item, reusing the existing
-- polymorphic reactions table instead of a new one
alter table reactions drop constraint if exists reactions_target_type_check;
alter table reactions add constraint reactions_target_type_check
  check (target_type in ('post','comment','event','potluck_item'));

alter table potluck_items enable row level security;
drop policy if exists tenant_isolation on potluck_items;
create policy tenant_isolation on potluck_items
  using (
    event_id in (
      select id from events
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- =====================================================================
-- 27. Resident-hosted "get to know your neighbours" dinners
-- =====================================================================

create table if not exists dinner_gatherings (
  event_id uuid primary key references events(id),
  host_resident_id uuid not null references residents(id),
  min_participants int not null default 4,
  max_participants int not null default 8,
  meal_type text not null default 'host_provides'
    check (meal_type in ('host_provides','potluck_theme','potluck_free')),
  theme_description text,              -- mainly relevant for potluck_theme, e.g. "Italian night"
  status text not null default 'open'
    check (status in ('open','full','cancelled','completed')),
  created_at timestamptz not null default now()
);

-- widen event_rsvps.status to support an automatic waitlist (useful beyond
-- dinners too, for any capacity-limited event)
alter table event_rsvps drop constraint if exists event_rsvps_status_check;
alter table event_rsvps add constraint event_rsvps_status_check
  check (status in ('going','maybe','declined','waitlisted'));

-- capacity check only applies to events that actually have a dinner_gatherings
-- row; everything else is unaffected. Once max_participants is hit, a new
-- rsvp is moved to 'waitlisted' instead of being rejected.
create or replace function check_dinner_gathering_capacity() returns trigger as $$
declare
  v_max int;
  v_going_count int;
begin
  select max_participants into v_max from dinner_gatherings where event_id = new.event_id;
  if v_max is null then
    return new;
  end if;

  if new.status = 'going' then
    select count(*) into v_going_count
    from event_rsvps
    where event_id = new.event_id and status = 'going' and resident_id <> new.resident_id;

    if v_going_count >= v_max then
      new.status := 'waitlisted';
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_dinner_gathering_capacity on event_rsvps;
create trigger trg_check_dinner_gathering_capacity
  before insert or update on event_rsvps
  for each row execute function check_dinner_gathering_capacity();

alter table dinner_gatherings enable row level security;
drop policy if exists tenant_isolation on dinner_gatherings;
create policy tenant_isolation on dinner_gatherings
  using (
    event_id in (
      select id from events
      where community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- =====================================================================
-- 28. Search/filter view for open dinner gatherings
-- =====================================================================

create or replace view dinner_gathering_availability as
select
  e.id as event_id,
  e.community_id,
  e.title,
  e.starts_at,
  e.location,
  dg.host_resident_id,
  dg.meal_type,
  dg.theme_description,
  dg.min_participants,
  dg.max_participants,
  dg.status,
  dg.max_participants - coalesce(gc.going_count, 0) as spots_available
from events e
join dinner_gatherings dg on dg.event_id = e.id
left join lateral (
  select count(*) as going_count
  from event_rsvps er
  where er.event_id = e.id and er.status = 'going'
) gc on true;

-- 28.2: typo-tolerant theme search, same pg_trgm approach as vendor search (section 12)
create index if not exists idx_dinner_gatherings_theme_trgm
  on dinner_gatherings using gin (theme_description gin_trgm_ops);
