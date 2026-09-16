-- =====================================================================
-- Document signing module — completing section 13 with the section 35
-- upgrade (extended planning doc): unify document targeting with the
-- same flexible segment mechanism already built for announcements
-- (announcement_segments), instead of the old fixed-3-value
-- documents.target_audience column.
--
-- documents / document_versions / document_recipients / document_signatures
-- already exist (20260906120000_initial_schema.sql) and already have
-- extra columns from 20260906130000 (template_id, expires_at,
-- reminder_count, tenancy/ownership period links) — none of that is
-- touched here. This migration only adds document_segments, drops the
-- old target_audience column, adds RLS (previously had none), and adds
-- a private storage bucket for the underlying files.
-- =====================================================================

-- ------------------------------------------------------------
-- 1. Flexible audience targeting — identical shape to
-- announcement_segments (20260915150000), so the same "how many
-- recipients" preview logic can be reused as-is.
-- ------------------------------------------------------------
create table if not exists document_segments (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id),
  filter_type text not null
    check (filter_type in ('building','floor_range','occupancy_type','attribute')),
  building_id uuid references buildings(id),
  floor_min int,
  floor_max int,
  occupancy_type text,
  attribute_id int references attribute_definitions(id),
  attribute_value text
);

alter table documents drop column if exists target_audience;

-- ------------------------------------------------------------
-- 2. Storage — same private-bucket-plus-signed-URL pattern already
-- used for vehicle-trip-photos (20260914130000). Staff upload via
-- service role; residents get a short-lived signed URL, never public
-- access to the raw file.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('documents', 'documents', false)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 3. Row-Level Security.
--
-- documents: community-wide read for residents (same posture as
-- `announcements` — bulletin-style content, not per-recipient secret).
--
-- document_versions: readable exactly when its parent document is.
--
-- document_recipients: resident's own row only (read + update, e.g.
-- flipping status to 'viewed' for the "acknowledge" signature level) —
-- same posture as announcement_recipients.
--
-- document_signatures: NOT exposed to `authenticated` at all. Per the
-- planning doc's own privacy note (ip_address/user_agent are personal
-- data under Israeli privacy law, meant for staff-only legal-dispute
-- use, not shown even to the resident who signed). Only service role
-- (staff via Retool, or a dedicated Edge Function for internal
-- signatures) ever touches this table.
-- ------------------------------------------------------------
alter table documents enable row level security;
alter table document_versions enable row level security;
alter table document_segments enable row level security;
alter table document_recipients enable row level security;
alter table document_signatures enable row level security;

drop policy if exists app_read_community_documents on documents;
create policy app_read_community_documents on documents for select to authenticated
using (community_id = public.current_community_id());

drop policy if exists app_read_document_versions on document_versions;
create policy app_read_document_versions on document_versions for select to authenticated
using (
  document_id in (select id from documents where community_id = public.current_community_id())
);

drop policy if exists app_read_own_document_receipt on document_recipients;
create policy app_read_own_document_receipt on document_recipients for select to authenticated
using (resident_id = public.current_resident_id());

-- Client can only move itself to 'viewed'/'declined' directly — 'signed'
-- requires real identity re-verification and must go through the
-- internal-signature Edge Function (service role), never a raw table
-- write, so it's excluded here on purpose.
drop policy if exists app_update_own_document_receipt on document_recipients;
create policy app_update_own_document_receipt on document_recipients for update to authenticated
using (resident_id = public.current_resident_id())
with check (resident_id = public.current_resident_id() and status in ('viewed','declined'));

grant select on documents to authenticated;
grant select on document_versions to authenticated;
grant select, update on document_recipients to authenticated;
-- document_signatures: deliberately no grant to authenticated.
