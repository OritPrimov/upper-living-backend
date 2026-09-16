-- Run this ONCE in the SQL editor of the external Supabase project.
-- Additive only: grants + RLS policies for the new "ארוחות משותפות" screen
-- (potluck + neighbour dinners). No tables or columns are created or altered.
-- Reviewed by Claude before running — safe, community-scoped, resident-owned.

grant select on public.dinner_gathering_availability to authenticated;
grant select, insert, update on public.dinner_gatherings to authenticated;
grant select, insert, update on public.potluck_items to authenticated;
grant insert on public.events to authenticated;

alter table public.dinner_gatherings enable row level security;
alter table public.potluck_items enable row level security;

-- Defensive hardening: make sure the view respects the RLS of the tables
-- it selects from, regardless of which role owns it.
alter view public.dinner_gathering_availability set (security_invoker = true);

drop policy if exists app_read_dinners on public.dinner_gatherings;
create policy app_read_dinners on public.dinner_gatherings for select to authenticated
using (event_id in (select id from public.events where community_id = public.current_community_id()));

drop policy if exists app_read_potluck on public.potluck_items;
create policy app_read_potluck on public.potluck_items for select to authenticated
using (event_id in (select id from public.events where community_id = public.current_community_id()));

drop policy if exists app_create_event on public.events;
create policy app_create_event on public.events for insert to authenticated
with check (community_id = public.current_community_id()
and created_by = public.current_resident_id());

drop policy if exists app_create_dinner on public.dinner_gatherings;
create policy app_create_dinner on public.dinner_gatherings for insert to authenticated
with check (host_resident_id = public.current_resident_id()
and event_id in (select id from public.events where community_id = public.current_community_id()));

drop policy if exists app_update_own_dinner on public.dinner_gatherings;
create policy app_update_own_dinner on public.dinner_gatherings for update to authenticated
using (host_resident_id = public.current_resident_id())
with check (host_resident_id = public.current_resident_id());

drop policy if exists app_create_potluck_item on public.potluck_items;
create policy app_create_potluck_item on public.potluck_items for insert to authenticated
with check (event_id in (select id from public.events where community_id = public.current_community_id())
and (resident_id is null or resident_id = public.current_resident_id()));

drop policy if exists app_update_potluck_item on public.potluck_items;
create policy app_update_potluck_item on public.potluck_items for update to authenticated
using (event_id in (select id from public.events where community_id = public.current_community_id())
and (resident_id is null or resident_id = public.current_resident_id()))
with check (resident_id = public.current_resident_id());
