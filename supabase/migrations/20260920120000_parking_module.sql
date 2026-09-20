-- =====================================================================
-- Section 41 of the extended planning doc (docs/database-plan-extended.md):
-- parking rental between neighbours.
--
-- Key differences from the community_resources booking module (section 23):
--   - A parking spot belongs to a UNIT/resident, not the HOA — so residents
--     manage their own listings, not staff.
--   - A "listing" is a one-off opportunity ("my spot is free tonight
--     18:00-23:00"), not a recurring resource with a calendar — so there's
--     no blackout/capacity concept here, just open -> booked -> expired.
--   - Double-booking prevention is UNIQUE(listing_id) at the DB level
--     (matches the pattern's own stated design), with a trigger only for
--     the UX-convenience "mark as booked" step.
--   - Payment is informational only in this MVP (no processor integration),
--     matching vendor/resource billing being kept out of the DB layer too.
-- =====================================================================

-- ------------------------------------------------------------
-- 1. Parking spot inventory (tied to a unit, not to the HOA)
-- ------------------------------------------------------------
create table if not exists parking_spots (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  building_id uuid references buildings(id),
  spot_number text,                          -- e.g. "Spot 14", "Level -2 Spot 7"
  is_active boolean not null default true,   -- disable without deleting (e.g. spot sold)
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. One-off listings: "my spot is free from X to Y, at this price"
-- ------------------------------------------------------------
create table if not exists parking_listings (
  id uuid primary key default gen_random_uuid(),
  parking_spot_id uuid not null references parking_spots(id),
  listed_by_resident_id uuid not null references residents(id),
  available_start timestamptz not null,
  available_end timestamptz not null,
  price_per_hour numeric(10,2) not null default 0,   -- 0 = free
  notes text,                                         -- e.g. "limited entry height"
  status text not null default 'open'
    check (status in ('open','booked','cancelled','expired')),
  created_at timestamptz not null default now(),
  check (available_end > available_start)
);

-- ------------------------------------------------------------
-- 3. Bookings — UNIQUE(listing_id) is the real single-booking guarantee,
-- enforced at the DB level so a race between two residents can't both win.
-- ------------------------------------------------------------
create table if not exists parking_bookings (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null unique references parking_listings(id),
  booked_by_resident_id uuid not null references residents(id),
  total_price numeric(10,2) not null default 0,
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','paid','waived')),
  status text not null default 'confirmed'
    check (status in ('confirmed','cancelled','completed')),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 4. Business rules that a plain CHECK can't express
-- ------------------------------------------------------------

-- 4a. can't book your own listing (Postgres CHECK constraints can't subquery
-- another table, so this has to be a trigger)
create or replace function check_parking_booking_not_own_listing() returns trigger as $$
declare
  v_listed_by uuid;
begin
  select listed_by_resident_id into v_listed_by
  from parking_listings where id = new.listing_id;

  if v_listed_by = new.booked_by_resident_id then
    raise exception 'לא ניתן לתפוס חניה שפרסמת בעצמך';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_parking_booking_not_own_listing on parking_bookings;
create trigger trg_check_parking_booking_not_own_listing
  before insert on parking_bookings
  for each row execute function check_parking_booking_not_own_listing();

-- 4b. once a booking exists, hide the listing from the "available now" list.
-- This is a UX convenience only — the UNIQUE(listing_id) constraint above is
-- what actually prevents double-booking, not this trigger.
create or replace function mark_parking_listing_booked() returns trigger as $$
begin
  update parking_listings set status = 'booked' where id = new.listing_id;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_mark_parking_listing_booked on parking_bookings;
create trigger trg_mark_parking_listing_booked
  after insert on parking_bookings
  for each row execute function mark_parking_listing_booked();

-- ------------------------------------------------------------
-- 5. Effective status is derived from time, not a stored flag that a job
-- has to remember to flip (same principle as deals' active-window in
-- section 10 of the planning doc).
-- ------------------------------------------------------------
create or replace view parking_listings_live as
select
  pl.*,
  case
    when pl.status = 'open' and pl.available_end < now() then 'expired'
    else pl.status
  end as effective_status
from parking_listings pl;

-- ------------------------------------------------------------
-- 6. Row-Level Security — staff (Retool) side
-- ------------------------------------------------------------
alter table parking_spots enable row level security;
drop policy if exists tenant_isolation on parking_spots;
create policy tenant_isolation on parking_spots
  using (
    unit_id in (
      select u.id from units u
      join buildings b on b.id = u.building_id
      where b.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

alter table parking_listings enable row level security;
drop policy if exists tenant_isolation on parking_listings;
create policy tenant_isolation on parking_listings
  using (
    parking_spot_id in (
      select ps.id from parking_spots ps
      join units u on u.id = ps.unit_id
      join buildings b on b.id = u.building_id
      where b.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

alter table parking_bookings enable row level security;
drop policy if exists tenant_isolation on parking_bookings;
create policy tenant_isolation on parking_bookings
  using (
    listing_id in (
      select pl.id from parking_listings pl
      join parking_spots ps on ps.id = pl.parking_spot_id
      join units u on u.id = ps.unit_id
      join buildings b on b.id = u.building_id
      where b.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

-- ------------------------------------------------------------
-- 7. Row-Level Security — resident (Lovable app) side
-- ------------------------------------------------------------

-- a resident can see their own spot(s), to pick "my spot" when publishing a listing
drop policy if exists app_read_own_spots on parking_spots;
create policy app_read_own_spots on parking_spots
  for select to authenticated
  using (unit_id = (select unit_id from residents where id = current_resident_id()));

-- everyone in the community can browse open listings — it's a neighbour
-- marketplace, not a private record (mirrors community_resources.app_read_resources)
drop policy if exists app_read_community_listings on parking_listings;
create policy app_read_community_listings on parking_listings
  for select to authenticated
  using (
    parking_spot_id in (
      select ps.id from parking_spots ps
      join units u on u.id = ps.unit_id
      join buildings b on b.id = u.building_id
      where b.community_id = current_community_id()
    )
  );

-- a resident may only publish a listing for their own spot
drop policy if exists app_create_own_listing on parking_listings;
create policy app_create_own_listing on parking_listings
  for insert to authenticated
  with check (
    listed_by_resident_id = current_resident_id()
    and parking_spot_id in (
      select id from parking_spots
      where unit_id = (select unit_id from residents where id = current_resident_id())
    )
  );

-- a resident may cancel their own listing
drop policy if exists app_update_own_listing on parking_listings;
create policy app_update_own_listing on parking_listings
  for update to authenticated
  using (listed_by_resident_id = current_resident_id())
  with check (listed_by_resident_id = current_resident_id());

-- both sides of a booking (who booked it, and who listed the spot) can see
-- it, so they can coordinate payment off-platform
drop policy if exists app_read_own_or_listed_bookings on parking_bookings;
create policy app_read_own_or_listed_bookings on parking_bookings
  for select to authenticated
  using (
    booked_by_resident_id = current_resident_id()
    or listing_id in (
      select id from parking_listings where listed_by_resident_id = current_resident_id()
    )
  );

-- a resident may book any listing visible to them (the "not your own
-- listing" rule is enforced by the trigger above, at the DB level)
drop policy if exists app_create_own_booking on parking_bookings;
create policy app_create_own_booking on parking_bookings
  for insert to authenticated
  with check (booked_by_resident_id = current_resident_id());

-- either side may update a booking they're party to (e.g. mark paid/cancelled)
drop policy if exists app_update_own_or_listed_bookings on parking_bookings;
create policy app_update_own_or_listed_bookings on parking_bookings
  for update to authenticated
  using (
    booked_by_resident_id = current_resident_id()
    or listing_id in (
      select id from parking_listings where listed_by_resident_id = current_resident_id()
    )
  )
  with check (
    booked_by_resident_id = current_resident_id()
    or listing_id in (
      select id from parking_listings where listed_by_resident_id = current_resident_id()
    )
  );

-- ------------------------------------------------------------
-- 8. Indexes
-- ------------------------------------------------------------
create index if not exists idx_parking_spots_unit on parking_spots(unit_id);
create index if not exists idx_parking_listings_spot on parking_listings(parking_spot_id);
create index if not exists idx_parking_listings_status_time on parking_listings(status, available_start, available_end);
create index if not exists idx_parking_listings_listed_by on parking_listings(listed_by_resident_id);
create index if not exists idx_parking_bookings_booked_by on parking_bookings(booked_by_resident_id);
