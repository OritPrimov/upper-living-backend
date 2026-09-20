-- =====================================================================
-- Section 52 of the extended planning doc (docs/database-plan-extended.md):
-- the digital apartment folder — a static reference library (plans,
-- spec sheets, warranty certificates, manuals), deliberately NOT built on
-- the existing `documents` table since that one is designed around
-- distribution that needs tracking (who read it, who signed, a deadline)
-- — none of which applies to "here's the electrical plan."
-- =====================================================================

create table if not exists unit_documents (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  category text not null check (category in (
    'electrical_plan','plumbing_plan','structural_plan',
    'spec_sheet','warranty_certificate','manual','other'
  )),
  system_name text,               -- 'AC', 'smart home system', 'solar water heater' — null for general plans/specs
  title text not null,
  file_url text not null,
  vendor_name text,               -- manufacturer/supplier of the system (free text — often a national brand, not a local vendor)
  warranty_expires_at date,
  -- optional link back to the original finish selection (section 42.5) —
  -- if the buyer picked a specific flooring, its warranty cert can load
  -- from that same selection instead of being entered twice
  finish_selection_category_id uuid references finish_selection_categories(id),
  uploaded_by_staff_id uuid references staff_users(id),
  uploaded_at timestamptz not null default now()
);

-- 52.3: RLS at the unit level, not just the community — same principle as
-- resident_personal_tasks (section 46): a resident must see only their
-- own unit's documents, not the whole building's.
alter table unit_documents enable row level security;

drop policy if exists tenant_isolation on unit_documents;
create policy tenant_isolation on unit_documents
  using (
    unit_id in (
      select u.id from units u
      join buildings b on b.id = u.building_id
      where b.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

drop policy if exists app_read_own_unit_documents on unit_documents;
create policy app_read_own_unit_documents on unit_documents
  for select to authenticated
  using (unit_id = (select unit_id from residents where id = current_resident_id()));

create index if not exists idx_unit_documents_unit on unit_documents(unit_id);
create index if not exists idx_unit_documents_warranty_expires on unit_documents(warranty_expires_at) where warranty_expires_at is not null;
