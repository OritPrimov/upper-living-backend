-- =====================================================================
-- UPPER LIVING — Initial schema
-- Source: תכנון-בסיס-נתונים-קהילות.pdf (sections 1-22)
-- Corrections from later sections (15-19) are folded directly into the
-- base CREATE TABLE statements below (not applied as separate ALTERs),
-- so this file reflects the final, corrected design in one pass.
-- =====================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists pg_trgm;    -- fuzzy vendor search (12.2)

-- =====================================================================
-- 2.1 — Organizational layering
-- =====================================================================

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table communities ( -- tenant = one residential complex
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id),
  name text not null,
  timezone text not null default 'Asia/Jerusalem',
  created_at timestamptz not null default now(),
  archived_at timestamptz -- soft delete
);

create table buildings (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  name text not null -- "בניין א'"
);

create table units ( -- physical apartment
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references buildings(id),
  floor int,
  unit_number text not null
);

-- =====================================================================
-- 2.2 — Residents & permissions
-- (status check includes 'pending_approval' per 15.3;
--  show_online_status per 15.1; occupancy_type per 18.3)
-- =====================================================================

create table residents (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  unit_id uuid references units(id), -- nullable: supports co-residents & future "virtual" residents
  full_name text not null,
  phone text,
  email text,
  avatar_url text,
  moved_in_at date,
  status text not null default 'pending_approval'
    check (status in ('pending_approval','active','inactive','moved_out')),
  occupancy_type text not null default 'tenant'
    check (occupancy_type in ('owner_occupier','tenant','family_member','guest')),
  show_online_status boolean not null default true, -- privacy opt-in for "who's online" (6, 15.1)
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

create table roles ( -- regular resident / vaad member / community manager / super-admin
  id serial primary key,
  name text unique not null
);

create table resident_roles (
  resident_id uuid references residents(id),
  role_id int references roles(id),
  primary key (resident_id, role_id)
);

-- =====================================================================
-- 2.3 — Interests & groups
-- =====================================================================

create table interest_tags (
  id serial primary key,
  name text unique not null -- "cooking", "dogs", "running"
);

create table resident_interests (
  resident_id uuid references residents(id),
  interest_tag_id int references interest_tags(id),
  primary key (resident_id, interest_tag_id)
);

create table groups (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  name text not null,
  interest_tag_id int references interest_tags(id),
  visibility text not null default 'open' check (visibility in ('open','closed','private')),
  created_by uuid references residents(id),
  created_at timestamptz not null default now()
);

create table group_members (
  group_id uuid references groups(id),
  resident_id uuid references residents(id),
  joined_at timestamptz not null default now(),
  primary key (group_id, resident_id)
);

-- unread-tracking so a "new" badge is real, not decorative (15.2)
create table group_read_receipts (
  group_id uuid not null references groups(id),
  resident_id uuid not null references residents(id),
  last_read_at timestamptz not null default now(),
  primary key (group_id, resident_id)
);

-- =====================================================================
-- 2.4 — Events
-- =====================================================================

create table events (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  group_id uuid references groups(id), -- NULL if general community event
  title text not null,
  description text,
  location text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  category text, -- "families" / "sports" / "vaad"
  created_by uuid references residents(id),
  created_at timestamptz not null default now()
);

create table event_rsvps (
  event_id uuid references events(id),
  resident_id uuid references residents(id),
  status text not null default 'going' check (status in ('going','maybe','declined')),
  responded_at timestamptz not null default now(),
  primary key (event_id, resident_id)
);

-- =====================================================================
-- 2.5 — Posts, comments, reactions
-- =====================================================================

create table posts (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  group_id uuid references groups(id),
  author_id uuid not null references residents(id),
  body text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz -- soft delete, kept for audit
);

create table comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id),
  author_id uuid not null references residents(id),
  body text not null,
  created_at timestamptz not null default now()
);

-- polymorphic table instead of 3 separate like-tables (post/comment/event)
create table reactions (
  id bigserial primary key,
  target_type text not null check (target_type in ('post','comment','event')),
  target_id uuid not null,
  resident_id uuid not null references residents(id),
  reaction_type text not null default 'like',
  created_at timestamptz not null default now(),
  unique (target_type, target_id, resident_id)
);

-- =====================================================================
-- 2.6 — Polls (eligible_voters per 18.4)
-- =====================================================================

create table polls (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  question text not null,
  created_by uuid references residents(id),
  eligible_voters text not null default 'all_residents'
    check (eligible_voters in ('all_residents','owners_only')),
  closes_at timestamptz,
  created_at timestamptz not null default now()
);

create table poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references polls(id),
  label text not null,
  display_order int not null default 0
);

create table poll_votes (
  poll_option_id uuid references poll_options(id),
  resident_id uuid references residents(id),
  voted_at timestamptz not null default now(),
  primary key (poll_option_id, resident_id)
);

-- =====================================================================
-- 3 — Activity event sourcing (critical analytics backbone)
-- =====================================================================

create table activity_events (
  id bigserial primary key,
  community_id uuid not null,
  resident_id uuid,
  event_type text not null, -- 'post_created' | 'event_rsvp' | 'group_joined' |
                             -- 'login' | 'poll_voted' | 'comment_created' |
                             -- 'vendor_viewed' | 'vendor_contacted' | 'deal_viewed' |
                             -- 'deal_redeemed' | 'vendor_search' | ...
  metadata jsonb not null default '{}',
  occurred_at timestamptz not null default now()
) partition by range (occurred_at);

-- monthly partitions — a scheduled job (pg_cron) should create future ones
create table activity_events_2026_09 partition of activity_events
  for values from ('2026-09-01') to ('2026-10-01');
create table activity_events_2026_10 partition of activity_events
  for values from ('2026-10-01') to ('2026-11-01');
create table activity_events_2026_11 partition of activity_events
  for values from ('2026-11-01') to ('2026-12-01');
create table activity_events_2026_12 partition of activity_events
  for values from ('2026-12-01') to ('2027-01-01');

create index idx_activity_events_community_type on activity_events (community_id, event_type, occurred_at);
create index idx_activity_events_resident on activity_events (resident_id, occurred_at);

-- =====================================================================
-- 4 — Analytics star schema (separate schema, read layer only)
-- =====================================================================

create schema if not exists analytics;

create table analytics.dim_date (
  date_key date primary key,
  day_of_week text,
  is_weekend boolean,
  month int,
  year int
);

create table analytics.dim_resident (
  resident_id uuid primary key,
  community_id uuid,
  building_id uuid,
  moved_in_at date,
  status text
);

create table analytics.fact_daily_engagement (
  community_id uuid,
  date_key date references analytics.dim_date(date_key),
  resident_id uuid,
  posts_created int default 0,
  comments_created int default 0,
  reactions_given int default 0,
  events_rsvpd int default 0,
  logins int default 0,
  primary key (community_id, date_key, resident_id)
);

create table analytics.fact_event_attendance (
  event_id uuid,
  community_id uuid,
  date_key date,
  invited_count int,
  going_count int,
  attendance_rate numeric(5,2)
);

-- =====================================================================
-- 9 — Consumer club: vendors, deals, subscriptions
-- =====================================================================

create table vendor_categories (
  id serial primary key,
  parent_category_id int references vendor_categories(id),
  name text not null -- tree: "home professionals" > "electricians"
);

create table vendors (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  phone text,
  email text,
  website text,
  logo_url text,
  vendor_type text not null default 'community_recommendation'
    check (vendor_type in ('community_recommendation','official_partner')),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','archived')),
  submitted_by uuid references residents(id),
  approved_by uuid references residents(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  -- generated search column for fuzzy text search (12.2)
  search_text text generated always as (coalesce(name,'') || ' ' || coalesce(description,'')) stored
);

create index idx_vendors_search_trgm on vendors using gin (search_text gin_trgm_ops);

create table vendor_category_links (
  vendor_id uuid references vendors(id),
  category_id int references vendor_categories(id),
  primary key (vendor_id, category_id)
);

create table vendor_category_synonyms (
  id serial primary key,
  category_id int not null references vendor_categories(id),
  synonym text not null -- "electrician" -> category "electricians"
);

-- recommendation scope: one row = "recommended in this context"
create table vendor_scopes (
  id bigserial primary key,
  vendor_id uuid not null references vendors(id),
  organization_id uuid references organizations(id), -- NULL = platform-wide
  community_id uuid references communities(id),       -- NULL = all communities in org
  building_id uuid references buildings(id),           -- NULL = all buildings in community
  constraint scope_hierarchy_valid check (
    building_id is null or community_id is not null -- can't have building without community
  )
);

-- deals: temporary, has its own scope, independent from the vendor's own scope
create table deals (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  title text not null, -- "15% off electrical work"
  description text,
  discount_type text not null check (discount_type in ('percentage','fixed_amount','other')),
  discount_value numeric(10,2),
  applies_to text not null default 'general' check (applies_to in ('general','specific_product')),
  product_name text, -- only relevant if applies_to = specific_product
  promo_code text,
  terms text,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  status text not null default 'pending' check (status in ('pending','approved','rejected','expired')),
  created_by uuid references residents(id),
  created_at timestamptz not null default now()
);

create index idx_deals_vendor_ends_at on deals (vendor_id, ends_at);

create table deal_scopes (
  id bigserial primary key,
  deal_id uuid not null references deals(id),
  organization_id uuid references organizations(id),
  community_id uuid references communities(id),
  building_id uuid references buildings(id)
);

create table deal_redemptions (
  id bigserial primary key,
  deal_id uuid not null references deals(id),
  resident_id uuid not null references residents(id),
  redeemed_at timestamptz not null default now(),
  unique (deal_id, resident_id) -- prevent double redemption; drop if allowing repeats
);

create table vendor_reviews (
  id bigserial primary key,
  vendor_id uuid not null references vendors(id),
  resident_id uuid not null references residents(id),
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  unique (vendor_id, resident_id)
);

create table vendor_favorites (
  vendor_id uuid references vendors(id),
  resident_id uuid references residents(id),
  primary key (vendor_id, resident_id)
);

-- materialized, refreshed periodically (pg_cron) — not computed per search
create materialized view vendor_ratings_agg as
select vendor_id, avg(rating)::numeric(3,2) as avg_rating, count(*) as review_count
from vendor_reviews
group by vendor_id;

create unique index on vendor_ratings_agg (vendor_id);

-- =====================================================================
-- 11 — Vendor listing plans, subscriptions, payments
-- =====================================================================

create table listing_plans (
  id serial primary key,
  name text not null, -- "basic", "community", "national"
  max_scope_level text not null check (max_scope_level in ('building','community','organization','platform')),
  price_amount numeric(10,2) not null,
  currency text not null default 'ILS',
  billing_interval text not null check (billing_interval in ('monthly','yearly','one_time')),
  is_active boolean not null default true
);

create table vendor_subscriptions (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  plan_id int not null references listing_plans(id),
  status text not null default 'trialing'
    check (status in ('trialing','active','past_due','canceled','expired')),
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null,
  auto_renew boolean not null default true,
  canceled_at timestamptz,
  created_at timestamptz not null default now()
);

create table vendor_payments (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  subscription_id uuid references vendor_subscriptions(id),
  payment_type text not null default 'subscription'
    check (payment_type in ('subscription','featured_placement','other')),
  amount numeric(10,2) not null,
  currency text not null default 'ILS',
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded')),
  payment_provider text, -- 'tranzila' / 'cardcom' / 'stripe'
  external_transaction_id text,
  external_invoice_id text, -- if using an external invoicing system (Green Invoice etc.)
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 13 — Signed documents for residents
-- =====================================================================

create table documents (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  building_id uuid references buildings(id), -- NULL = whole community
  category text not null check (category in ('vaad_minutes','contract','notice','insurance','other')),
  title text not null,
  requires_signature boolean not null default false,
  signature_level text not null default 'acknowledge'
    check (signature_level in ('acknowledge','internal_signature','certified_esignature')),
  target_audience text not null default 'all_residents'
    check (target_audience in ('all_residents','owners_only','tenants_only')),
  created_by uuid references residents(id),
  created_at timestamptz not null default now()
);

-- always sign a concrete version, never the abstract "document"
create table document_versions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id),
  version_number int not null,
  file_url text not null,
  file_hash text not null, -- SHA-256 of the file, proves it wasn't altered post-signature
  uploaded_at timestamptz not null default now(),
  unique (document_id, version_number)
);

-- per-resident distribution: who it's for and their status
create table document_recipients (
  id bigserial primary key,
  document_version_id uuid not null references document_versions(id),
  resident_id uuid not null references residents(id),
  status text not null default 'pending' check (status in ('pending','viewed','signed','declined')),
  viewed_at timestamptz,
  unique (document_version_id, resident_id)
);

-- the signature itself, with full evidentiary trail
create table document_signatures (
  id uuid primary key default gen_random_uuid(),
  document_recipient_id bigint not null references document_recipients(id),
  signed_at timestamptz not null default now(),
  ip_address inet,
  user_agent text,
  document_hash_at_signing text not null, -- copy of file_hash at signing time
  external_provider text, -- NULL if internal signature
  external_signature_id text
);

-- =====================================================================
-- 16 — Identity verification, staff separation, audit log
-- =====================================================================

create table unit_invitations (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  invite_code text not null unique,
  created_by uuid references residents(id),
  expires_at timestamptz not null,
  used_by uuid references residents(id),
  used_at timestamptz,
  created_at timestamptz not null default now()
);

-- separate identity plane from residents: staff / AI agents (is_ai_agent per 17.3)
create table staff_users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  full_name text not null,
  scope_level text not null check (scope_level in ('platform','organization','community')),
  organization_id uuid references organizations(id), -- NULL if scope_level='platform'
  community_id uuid references communities(id),       -- NULL if 'platform' or 'organization'
  role text not null default 'community_manager'
    check (role in ('super_admin','org_admin','community_manager','support')),
  is_ai_agent boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- dedicated, append-only security audit log (actor_type includes ai_agent per 17.4)
create table security_audit_log (
  id bigserial primary key,
  actor_type text not null check (actor_type in ('resident','staff','ai_agent','system')),
  actor_id uuid,
  action text not null, -- 'vendor_approved' / 'role_changed' / 'document_distributed' / ...
  target_table text,
  target_id uuid,
  metadata jsonb not null default '{}',
  ip_address inet,
  occurred_at timestamptz not null default now()
) partition by range (occurred_at);

create table security_audit_log_2026_09 partition of security_audit_log
  for values from ('2026-09-01') to ('2026-10-01');
create table security_audit_log_2026_10 partition of security_audit_log
  for values from ('2026-10-01') to ('2026-11-01');
create table security_audit_log_2026_11 partition of security_audit_log
  for values from ('2026-11-01') to ('2026-12-01');
create table security_audit_log_2026_12 partition of security_audit_log
  for values from ('2026-12-01') to ('2027-01-01');

-- =====================================================================
-- 15.4 — Platform's own billing engine (organizations paying Upper Living)
-- distinct from listing_plans/vendor_payments (section 11), which is
-- money flowing from vendors, not from communities.
-- =====================================================================

create table platform_plans (
  id serial primary key,
  name text not null, -- "basic", "premium"
  price_per_unit numeric(10,2) not null, -- usually price per unit/resident per month
  pricing_model text not null default 'per_unit' check (pricing_model in ('per_unit','flat_fee')),
  billing_interval text not null default 'monthly' check (billing_interval in ('monthly','yearly')),
  is_active boolean not null default true
);

create table organization_subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  plan_id int not null references platform_plans(id),
  status text not null default 'trialing' check (status in ('trialing','active','past_due','canceled')),
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null,
  canceled_at timestamptz,
  created_at timestamptz not null default now()
);

create table platform_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  subscription_id uuid references organization_subscriptions(id),
  amount numeric(10,2) not null,
  currency text not null default 'ILS',
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded')),
  payment_provider text,
  external_transaction_id text,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 15.5 — Feature flags
-- =====================================================================

create table feature_flags (
  id serial primary key,
  feature_key text not null, -- "consumer_club", "documents_v2"
  community_id uuid references communities(id), -- NULL = platform-wide default
  enabled boolean not null default false,
  unique (feature_key, community_id)
);

-- =====================================================================
-- 18 — Ownership registry (distinct from occupancy)
-- =====================================================================

create table unit_owners (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id),
  full_name text not null,
  phone text,
  email text,
  resident_id uuid references residents(id), -- NULL if owner doesn't use the app at all
  ownership_share numeric(5,2) not null default 100.00, -- supports co-ownership/inheritance
  is_primary_contact boolean not null default true,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 19 — Quarterly event proposals (AI agent capability)
-- =====================================================================

create table seasonal_calendar (
  id serial primary key,
  name text not null, -- "Sukkot", "Hanukkah", "Independence Day"
  month int not null,
  typical_day_range text, -- approximate range (Hebrew calendar holidays move)
  suggested_category text
);

create table event_proposals (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id),
  proposed_by uuid references staff_users(id), -- the agent's row in staff_users
  title text not null,
  description text,
  category text,
  suggested_start_date date,
  suggested_end_date date,
  estimated_cost numeric(10,2),
  rationale text not null, -- mandatory: no proposal without data-backed reasoning
  confidence_score numeric(3,2), -- 0.00-1.00
  status text not null default 'proposed'
    check (status in ('proposed','approved','rejected','needs_revision')),
  reviewed_by uuid references staff_users(id),
  reviewed_at timestamptz,
  resulting_event_id uuid references events(id), -- filled only after real approval
  created_at timestamptz not null default now()
);

create table event_proposal_tags (
  proposal_id uuid references event_proposals(id),
  interest_tag_id int references interest_tags(id),
  primary key (proposal_id, interest_tag_id)
);

-- =====================================================================
-- 17 — AI agent governance (single approval queue for all agent actions)
-- =====================================================================

create table ai_agent_actions (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references staff_users(id),
  community_id uuid references communities(id),
  action_type text not null, -- 'vendor_review' / 'deal_review' / 'content_flag' /
                              -- 'nudge_draft' / 'weekly_digest' / 'outreach_draft' / ...
  risk_level text not null check (risk_level in ('low','medium','high')),
  target_table text,
  target_id uuid,
  proposed_payload jsonb not null default '{}',
  status text not null default 'proposed'
    check (status in ('proposed','auto_executed','approved','rejected','executed')),
  reviewed_by uuid references staff_users(id),
  reviewed_at timestamptz,
  executed_at timestamptz,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- Row-Level Security (section 1, 16.3, 16.4)
--
-- Model: every tenant-scoped table is isolated by
--   community_id = current_setting('app.current_community_id')::uuid
-- The APPLICATION (server-side, using a role that is NOT the anon key)
-- is responsible for issuing `SET app.current_community_id = '...'` at
-- the start of every request. Tables below with no policy are reachable
-- only via the Supabase service_role connection (which bypasses RLS),
-- matching the "Super Admin / staff-only" design in 16.3-16.4.
-- =====================================================================

alter table communities enable row level security;
create policy tenant_isolation on communities
  using (id = current_setting('app.current_community_id', true)::uuid);

alter table buildings enable row level security;
create policy tenant_isolation on buildings
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table units enable row level security;
create policy tenant_isolation on units
  using (building_id in (select id from buildings where community_id = current_setting('app.current_community_id', true)::uuid));

alter table residents enable row level security;
create policy tenant_isolation on residents
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table resident_roles enable row level security;
create policy tenant_isolation on resident_roles
  using (resident_id in (select id from residents where community_id = current_setting('app.current_community_id', true)::uuid));

alter table resident_interests enable row level security;
create policy tenant_isolation on resident_interests
  using (resident_id in (select id from residents where community_id = current_setting('app.current_community_id', true)::uuid));

alter table groups enable row level security;
create policy tenant_isolation on groups
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table group_members enable row level security;
create policy tenant_isolation on group_members
  using (group_id in (select id from groups where community_id = current_setting('app.current_community_id', true)::uuid));

alter table group_read_receipts enable row level security;
create policy tenant_isolation on group_read_receipts
  using (group_id in (select id from groups where community_id = current_setting('app.current_community_id', true)::uuid));

alter table events enable row level security;
create policy tenant_isolation on events
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table event_rsvps enable row level security;
create policy tenant_isolation on event_rsvps
  using (event_id in (select id from events where community_id = current_setting('app.current_community_id', true)::uuid));

alter table posts enable row level security;
create policy tenant_isolation on posts
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table comments enable row level security;
create policy tenant_isolation on comments
  using (post_id in (select id from posts where community_id = current_setting('app.current_community_id', true)::uuid));

alter table polls enable row level security;
create policy tenant_isolation on polls
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table poll_options enable row level security;
create policy tenant_isolation on poll_options
  using (poll_id in (select id from polls where community_id = current_setting('app.current_community_id', true)::uuid));

alter table poll_votes enable row level security;
create policy tenant_isolation on poll_votes
  using (poll_option_id in (
    select po.id from poll_options po
    join polls p on p.id = po.poll_id
    where p.community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table documents enable row level security;
create policy tenant_isolation on documents
  using (community_id = current_setting('app.current_community_id', true)::uuid);

alter table document_versions enable row level security;
create policy tenant_isolation on document_versions
  using (document_id in (select id from documents where community_id = current_setting('app.current_community_id', true)::uuid));

alter table document_recipients enable row level security;
create policy tenant_isolation on document_recipients
  using (document_version_id in (
    select dv.id from document_versions dv
    join documents d on d.id = dv.document_id
    where d.community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table document_signatures enable row level security;
create policy tenant_isolation on document_signatures
  using (document_recipient_id in (
    select dr.id from document_recipients dr
    join document_versions dv on dv.id = dr.document_version_id
    join documents d on d.id = dv.document_id
    where d.community_id = current_setting('app.current_community_id', true)::uuid
  ));

alter table unit_owners enable row level security;
create policy tenant_isolation on unit_owners
  using (unit_id in (
    select u.id from units u
    join buildings b on b.id = u.building_id
    where b.community_id = current_setting('app.current_community_id', true)::uuid
  ));

-- Vendor directory: visibility follows the scope-fallback pattern from
-- section 9.3 (NULL at any level = visible to everyone at that level and below),
-- not a strict community_id match — this is a shared, cross-tenant catalog.
alter table vendors enable row level security;
create policy scoped_visibility on vendors
  using (
    status = 'approved'
    and exists (
      select 1 from vendor_scopes vs
      where vs.vendor_id = vendors.id
        and (vs.community_id is null or vs.community_id = current_setting('app.current_community_id', true)::uuid)
    )
  );

alter table vendor_scopes enable row level security;
create policy scoped_visibility on vendor_scopes
  using (community_id is null or community_id = current_setting('app.current_community_id', true)::uuid);

alter table deals enable row level security;
create policy scoped_visibility on deals
  using (
    status = 'approved'
    and exists (
      select 1 from deal_scopes ds
      where ds.deal_id = deals.id
        and (ds.community_id is null or ds.community_id = current_setting('app.current_community_id', true)::uuid)
    )
  );

alter table deal_scopes enable row level security;
create policy scoped_visibility on deal_scopes
  using (community_id is null or community_id = current_setting('app.current_community_id', true)::uuid);

-- Tables intentionally left WITHOUT a permissive policy — RLS is enabled
-- (default-deny for anon/authenticated), reachable only via service_role:
--   staff_users, unit_invitations, ai_agent_actions, event_proposals,
--   event_proposal_tags, security_audit_log, platform_plans,
--   organization_subscriptions, platform_payments, vendor_payments,
--   listing_plans, vendor_subscriptions, feature_flags,
--   document data already isolated above but signature evidentiary
--   fields (ip_address/user_agent) should additionally be excluded from
--   any client-facing view per 16.5.
alter table staff_users enable row level security;
alter table unit_invitations enable row level security;
alter table ai_agent_actions enable row level security;
alter table event_proposals enable row level security;
alter table event_proposal_tags enable row level security;
alter table security_audit_log enable row level security;
alter table platform_plans enable row level security;
alter table organization_subscriptions enable row level security;
alter table platform_payments enable row level security;
alter table vendor_payments enable row level security;
alter table listing_plans enable row level security;
alter table vendor_subscriptions enable row level security;
alter table feature_flags enable row level security;
alter table vendor_reviews enable row level security;
alter table vendor_favorites enable row level security;
alter table vendor_category_links enable row level security;
alter table vendor_categories enable row level security;
alter table vendor_category_synonyms enable row level security;
alter table interest_tags enable row level security;
alter table roles enable row level security;
alter table reactions enable row level security;
alter table organizations enable row level security;
alter table seasonal_calendar enable row level security;

-- NOTE: reactions/vendor_reviews/vendor_favorites/interest_tags/roles/
-- vendor_categories/organizations/seasonal_calendar are reference or
-- cross-tenant tables without a natural community_id — access to these
-- from client code should go through a security-definer function or a
-- view scoped by the calling resident's community, added when the
-- backend auth model (how a resident's session maps to community_id) is
-- finalized. Left service_role-only for now to avoid an insecure default.
