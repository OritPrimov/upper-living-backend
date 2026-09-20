-- =====================================================================
-- Fix for a real RLS bug in 20260920120000_parking_module.sql, found by
-- Lovable while wiring the resident-facing screen and verified directly:
-- a resident could only ever see listings for THEIR OWN spot, not their
-- neighbours' — meaning "available listings" only ever showed what the
-- viewer themselves posted.
--
-- Root cause: parking_listings' app_read_community_listings policy joins
-- through parking_spots to find the listing's community. But
-- parking_spots only had one resident-facing policy, app_read_own_spots,
-- scoped to the resident's own unit. Postgres RLS applies recursively —
-- a subquery against an RLS-protected table is itself filtered by that
-- table's policies for the querying role. So the "community-wide"
-- listings policy silently collapsed to "my own spot's listings only",
-- because the resident could never even read a neighbour's parking_spots
-- row to confirm it was in their community.
--
-- Fix: parking spot inventory (spot number, which unit/building it
-- belongs to) isn't sensitive — it's the same kind of browsable data as
-- community_resources — so residents get community-wide SELECT on
-- parking_spots, not just their own. Write access (via
-- app_create_own_listing, checked separately) still only allows listing
-- your own spot.
-- =====================================================================

drop policy if exists app_read_community_spots on parking_spots;
create policy app_read_community_spots on parking_spots
  for select to authenticated
  using (
    unit_id in (
      select u.id from units u
      join buildings b on b.id = u.building_id
      where b.community_id = current_community_id()
    )
  );

-- superseded by the community-wide policy above (which already includes
-- the resident's own unit) — dropping to avoid two overlapping SELECT
-- policies doing the same job
drop policy if exists app_read_own_spots on parking_spots;
