-- =====================================================================
-- Gap fixes identified by comparing schema.json (an earlier Airtable-
-- based plan that assumed integration with Mighty Networks) against
-- the Supabase schema built from תכנון-בסיס-נתונים-קהילות.pdf.
--
-- Mighty Networks-specific concepts (external publish targets) are
-- deliberately excluded: the product is now being built in-house.
-- Every change below was confirmed item-by-item with the product owner.
-- =====================================================================

create extension if not exists btree_gist; -- needed for the booking-overlap exclusion constraint

-- =====================================================================
-- A. Field additions on existing tables
-- =====================================================================

alter table organizations add column contact_email text;
alter table organizations add column contact_phone text;

alter table buildings add column address text;
alter table buildings add column building_type text check (building_type in ('residential','office','mixed'));
alter table buildings add column total_units int;
alter table buildings add column timezone text;
alter table buildings add column calendar_system text not null default 'hebrew_gregorian'
  check (calendar_system in ('hebrew_gregorian','gregorian_only'));

alter table units add column unit_type text not null default 'residential'
  check (unit_type in ('residential','office','commercial'));
alter table units add column consent_given boolean not null default false;
alter table units add column marketing_consent boolean not null default false;
alter table units add column data_source text not null default 'admin_entered'
  check (data_source in ('self_reported','inferred','admin_entered'));
alter table units add column billing_responsibility text not null default 'owner_pays'
  check (billing_responsibility in ('owner_pays','tenant_pays','split'));

-- household-level interest tagging (distinct from the per-resident resident_interests) —
-- useful when you know a unit's profile before knowing which individual lives there
create table unit_interest_tags (
  unit_id uuid references units(id),
  interest_tag_id int references interest_tags(id),
  primary key (unit_id, interest_tag_id)
);

-- richer seasonal calendar: sensitivity level matters for auto-generated content tone
alter table seasonal_calendar add column holiday_key text unique;
alter table seasonal_calendar add column hebrew_date text;
alter table seasonal_calendar add column gregorian_date_this_year date; -- refreshed yearly by a scheduled job
alter table seasonal_calendar add column sensitivity_level text not null default 'neutral'
  check (sensitivity_level in ('celebratory','solemn','neutral'));

-- a manager can be assigned to specific buildings, not just a whole community/org
create table staff_building_assignments (
  staff_user_id uuid not null references staff_users(id),
  building_id uuid not null references buildings(id),
  primary key (staff_user_id, building_id)
);

-- =====================================================================
-- B. Building maintenance: separate vendor roster + service ticketing
-- (maintenance_vendors is a distinct concept from the consumer-club
-- `vendors` table — a plumber the management company dispatches is not
-- a paid marketplace listing residents browse for deals)
-- =====================================================================

create table maintenance_vendors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id), -- the management company's own contractor roster
  name text not null,
  specialty text not null check (specialty in ('plumbing','electric','elevator','cleaning','general')),
  phone text,
  email text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table service_requests (
  id bigserial primary key,
  request_number text generated always as ('SR-' || id::text) stored,
  community_id uuid not null references communities(id),
  unit_id uuid references units(id),
  reported_by uuid references residents(id),
  category text not null check (category in ('plumbing','electric','elevator','cleaning','other')),
  description text,
  photo_urls text[] not null default '{}',
  source text not null default 'resident_form'
    check (source in ('whatsapp_chatbot','resident_form','phone_manual_entry','walk_in')),
  status text not null default 'new'
    check (status in ('new','triaged','assigned','scheduled','in_progress',
                       'waiting_on_parts','waiting_on_resident','resolved','closed','reopened')),
  priority text not null default 'medium' check (priority in ('low','medium','high','urgent')),
  assigned_vendor_id uuid references maintenance_vendors(id),
  scheduled_visit_at timestamptz,
  estimated_cost numeric(10,2),
  actual_cost numeric(10,2),
  is_recurring_issue boolean not null default false,
  satisfaction_rating int check (satisfaction_rating between 1 and 5),
  sla_target_at timestamptz, -- set by trigger below based on priority
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

-- SLA target is derived from priority at creation time, not left as a manual TODO
create or replace function set_service_request_sla() returns trigger as $$
begin
  new.sla_target_at := new.created_at + case new.priority
    when 'urgent' then interval '4 hours'
    when 'high'   then interval '1 day'
    when 'medium' then interval '3 days'
    else               interval '7 days'
  end;
  return new;
end;
$$ language plpgsql;

create trigger trg_service_request_sla
  before insert on service_requests
  for each row execute function set_service_request_sla();

-- "SLA breached" is a query-time derivation, not a stored column — same
-- principle as "is deal active" (section 10 of the original spec):
--   select * from service_requests
--   where sla_target_at < now() and status not in ('resolved','closed');

create index idx_service_requests_community_status on service_requests (community_id, status);

create table service_request_updates (
  id bigserial primary key,
  service_request_id bigint not null references service_requests(id),
  update_text text not null,
  update_source text not null check (update_source in ('community_manager','vendor','resident','system_automation')),
  updated_by uuid references staff_users(id),
  visible_to_resident boolean not null default true,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- C. Shared resource booking (event room, BBQ, sports court, parking...)
-- =====================================================================

create table shared_resources (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  building_id uuid references buildings(id), -- NULL = shared across the whole community
  name text not null,
  resource_type text not null check (resource_type in ('event_room','bbq_area','sports_court','guest_parking','rooftop','other')),
  capacity int,
  booking_fee numeric(10,2) not null default 0,
  requires_approval boolean not null default false,
  max_booking_duration_hours numeric(5,2),
  min_advance_booking_hours numeric(6,2),
  max_advance_booking_days int,
  buffer_time_minutes int not null default 0,
  cancellation_deadline_hours numeric(6,2),
  usage_rules text,
  photo_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table resource_bookings (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references shared_resources(id),
  unit_id uuid references units(id),
  booked_by uuid not null references residents(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  guest_count int,
  status text not null default 'requested'
    check (status in ('requested','approved','rejected','cancelled','completed')),
  approved_by uuid references staff_users(id),
  fee_amount numeric(10,2),
  payment_status text not null default 'not_applicable'
    check (payment_status in ('not_applicable','pending','paid','refunded')),
  stripe_payment_link_url text,
  stripe_payment_id text,
  notes text,
  created_at timestamptz not null default now(),
  constraint valid_time_range check (ends_at > starts_at),
  -- real conflict prevention at the DB level, not a manual "Conflict Detected" checkbox
  exclude using gist (
    resource_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (status in ('requested','approved'))
);

-- =====================================================================
-- D. Resident billing — distinct from platform_payments (org -> platform)
-- and vendor_payments (vendor -> platform): this is unit/resident -> HOA
-- =====================================================================

create table resident_charges (
  id bigserial primary key,
  community_id uuid not null references communities(id),
  unit_id uuid not null references units(id),
  payer_id uuid references residents(id),
  charge_type text not null default 'monthly_maintenance'
    check (charge_type in ('monthly_maintenance','special_assessment','resource_booking_fee','other')),
  amount numeric(10,2) not null,
  currency text not null default 'ILS',
  due_date date not null,
  paid_date date,
  status text not null default 'pending' check (status in ('pending','paid','overdue','waived')),
  related_booking_id uuid references resource_bookings(id),
  created_at timestamptz not null default now()
);

create index idx_resident_charges_unit_status on resident_charges (unit_id, status);

-- =====================================================================
-- E. Knowledge base + WhatsApp chatbot conversation log
-- =====================================================================

create table knowledge_base_entries (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  building_id uuid references buildings(id),
  topic text not null,
  category text not null check (category in ('wifi_access','waste_recycling','house_rules','contacts','amenities_booking','payments','other')),
  answer_content text not null,
  quick_link_url text,
  is_sensitive boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- staff-only: contains phone numbers + raw resident questions (privacy, per 16.5's
-- principle of restricting IP/user-agent-adjacent evidentiary data to staff)
create table chatbot_conversations_log (
  id bigserial primary key,
  resident_id uuid references residents(id),
  phone_number text,
  question_text text not null,
  matched_kb_entry_id uuid references knowledge_base_entries(id),
  answer_given text,
  was_escalated boolean not null default false,
  escalation_reason text check (escalation_reason in
    ('no_kb_match','sensitive_info_unverified_number','complaint_or_urgent_issue','explicit_human_request')),
  escalated_to uuid references staff_users(id),
  linked_service_request_id bigint references service_requests(id),
  is_resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- F. Ownership/tenancy as historical PERIODS, replacing the
-- current-state-only unit_owners table from the original migration
-- (no data exists yet, so a clean replacement is safe)
-- =====================================================================

drop table if exists unit_owners cascade;

create table ownership_periods (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  resident_id uuid references residents(id), -- NULL if the owner doesn't use the app at all
  full_name text not null,
  phone text,
  email text,
  ownership_share numeric(5,2) not null default 100.00, -- supports co-ownership/inheritance
  is_primary_contact boolean not null default true,
  start_date date not null default current_date,
  end_date date, -- NULL = current owner; "is current" is derived, not stored
  transfer_reason text check (transfer_reason in ('purchase','inheritance','sale')),
  created_at timestamptz not null default now()
);

create table tenancy_periods (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  resident_id uuid not null references residents(id),
  lease_start date not null,
  lease_end date, -- NULL = current tenancy
  lease_reference text,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- G. Document templates as a layer separate from document instances
-- =====================================================================

create table document_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id), -- NULL = usable platform-wide
  name text not null,
  category text not null check (category in
    ('lease_agreement','house_rules_acknowledgment','marketing_consent','pet_policy',
     'parking_agreement','renovation_request','key_deposit','insurance_declaration','other')),
  applies_to text not null default 'both' check (applies_to in ('owner','tenant','both')),
  required_signature_level text not null default 'basic' check (required_signature_level in ('basic','secure','certified')),
  template_file_url text,
  version_number int not null default 1,
  renewal_trigger text not null default 'one_time'
    check (renewal_trigger in ('one_time','annual','on_lease_renewal','on_policy_change')),
  retention_period_years int,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table documents add column template_id uuid references document_templates(id);

alter table document_recipients add column expires_at timestamptz;
alter table document_recipients add column reminder_count int not null default 0;
alter table document_recipients add column tenancy_period_id uuid references tenancy_periods(id);
alter table document_recipients add column ownership_period_id uuid references ownership_periods(id);

-- =====================================================================
-- H. Content templates + generalized content proposals — replaces
-- event_proposals/event_proposal_tags (events-only) with a version that
-- can also propose posts and polls, and targets OUR OWN tables instead
-- of an external platform.
-- =====================================================================

drop table if exists event_proposal_tags cascade;
drop table if exists event_proposals cascade;

create table content_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  content_type text not null check (content_type in ('event','post','poll')),
  category text not null check (category in ('holiday','recurring_activity','seasonal','civic')),
  trigger_type text not null check (trigger_type in ('fixed_date','hebrew_calendar_date','recurring_rule')),
  trigger_fixed_date date,
  trigger_holiday_id int references seasonal_calendar(id),
  trigger_offset_days int not null default 0,
  trigger_recurrence_rule text,
  content_prompt_template text not null,
  requires_approval boolean not null default true,
  priority text not null default 'medium' check (priority in ('low','medium','high')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table content_template_segments (
  template_id uuid references content_templates(id),
  interest_tag_id int references interest_tags(id),
  primary key (template_id, interest_tag_id)
);

create table content_proposals (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  template_id uuid references content_templates(id),
  proposed_by uuid references staff_users(id), -- the agent's row in staff_users
  content_type text not null check (content_type in ('event','post','poll')),
  title text not null,
  description text,
  category text,
  suggested_start_date date,
  suggested_end_date date,
  estimated_cost numeric(10,2),
  rationale text not null, -- mandatory: no proposal without data-backed reasoning
  confidence_score numeric(3,2),
  status text not null default 'proposed'
    check (status in ('proposed','approved','rejected','needs_revision')),
  reviewed_by uuid references staff_users(id),
  reviewed_at timestamptz,
  -- exactly one of these is filled, matching content_type, once approved
  resulting_event_id uuid references events(id),
  resulting_post_id uuid references posts(id),
  resulting_poll_id uuid references polls(id),
  created_at timestamptz not null default now()
);

create table content_proposal_tags (
  proposal_id uuid references content_proposals(id),
  interest_tag_id int references interest_tags(id),
  primary key (proposal_id, interest_tag_id)
);

-- =====================================================================
-- Row-Level Security for all new tables
-- (same app.current_community_id model as the initial migration)
-- =====================================================================

alter table unit_interest_tags enable row level security;
create policy tenant_isolation on unit_interest_tags
  using (unit_id in (
    select u.id from units u join buildings b on b.id = u.building_id
    where b.community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table service_requests enable row level security;
create policy tenant_isolation on service_requests
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table service_request_updates enable row level security;
create policy tenant_isolation on service_request_updates
  using (service_request_id in (
    select id from service_requests where community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table resident_charges enable row level security;
create policy tenant_isolation on resident_charges
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table shared_resources enable row level security;
create policy tenant_isolation on shared_resources
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table resource_bookings enable row level security;
create policy tenant_isolation on resource_bookings
  using (resource_id in (
    select id from shared_resources where community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table knowledge_base_entries enable row level security;
create policy tenant_isolation on knowledge_base_entries
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table ownership_periods enable row level security;
create policy tenant_isolation on ownership_periods
  using (unit_id in (
    select u.id from units u join buildings b on b.id = u.building_id
    where b.community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table tenancy_periods enable row level security;
create policy tenant_isolation on tenancy_periods
  using (unit_id in (
    select u.id from units u join buildings b on b.id = u.building_id
    where b.community_id = current_setting('app.current_community_id', true)::uuid
  ));

-- staff-only (service_role bypasses RLS; no permissive policy for anon/authenticated),
-- consistent with the "Super Admin / staff-only" tables from the initial migration
alter table maintenance_vendors enable row level security;
alter table chatbot_conversations_log enable row level security;
alter table document_templates enable row level security;
alter table content_templates enable row level security;
alter table content_template_segments enable row level security;
alter table content_proposals enable row level security;
alter table content_proposal_tags enable row level security;
alter table staff_building_assignments enable row level security;
