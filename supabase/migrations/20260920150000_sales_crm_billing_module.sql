-- =====================================================================
-- Sections 36-40 of the extended planning doc (docs/database-plan-extended.md):
-- the sales pipeline (leads before they're a paying customer) and
-- recurring billing for organizations (credit-card tokenization via
-- Tranzila/Cardcom, never storing a real card number).
--
-- Per section 38.1.c: sales_leads has no community_id at all (it's
-- pre-customer data) — access is "are you a staff_user", not tenant
-- isolation. Same for organization_payment_methods (billing is per
-- organization, not per community, and only staff ever touches it). Both
-- follow the same enabled-RLS-but-no-policies pattern already used for
-- venture_relationships/platform_payments: default-denied to every role
-- except the Retool/staff connection.
-- =====================================================================

-- ------------------------------------------------------------
-- 36.3 — the sales pipeline itself
-- 40.3 — log_email_alias added directly here (not as a later ALTER)
-- since this table is new in this migration
-- ------------------------------------------------------------
create table if not exists sales_leads (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  contact_name text,
  contact_phone text,
  contact_email text,
  stage text not null default 'new'
    check (stage in ('new','demo_scheduled','negotiation','won','lost')),
  estimated_communities int,
  estimated_mrr numeric(10,2),
  notes text,
  assigned_to uuid references staff_users(id),
  converted_organization_id uuid references organizations(id),  -- filled in once stage='won'
  log_email_alias text unique,  -- 40.3: BCC target for cheap email logging automation
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 38.2 — contacts and notes on a lead (a sale process usually involves
-- more than one person, and "when it happened" is tracked separately
-- from "when it was logged")
-- ------------------------------------------------------------
create table if not exists sales_lead_contacts (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references sales_leads(id),
  full_name text not null,
  role text,                 -- e.g. "board chair", "CEO", "COO"
  phone text,
  email text,
  created_at timestamptz not null default now()
);

create table if not exists sales_lead_notes (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references sales_leads(id),
  created_by uuid references staff_users(id),
  body text not null,
  occurred_at timestamptz not null default now(),  -- when the interaction actually happened
  created_at timestamptz not null default now(),   -- when it was logged
  -- 40.2: email is a channel on the existing note, not a parallel table
  channel text not null default 'other' check (channel in ('call','email','meeting','whatsapp','other')),
  email_subject text,
  email_direction text check (email_direction in ('sent','received'))
);

create table if not exists sales_lead_note_contacts (
  note_id uuid not null references sales_lead_notes(id),
  contact_id uuid not null references sales_lead_contacts(id),
  primary key (note_id, contact_id)
);

-- ------------------------------------------------------------
-- 39.2 — quotes/contracts attached to the sale process, versioned
-- ------------------------------------------------------------
create table if not exists sales_lead_attachments (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references sales_leads(id),
  note_id uuid references sales_lead_notes(id),   -- optional link to the note it was sent in
  file_name text not null,
  file_url text not null,
  file_type text default 'quote' check (file_type in ('quote','contract','other')),
  version_number int not null default 1,
  status text not null default 'sent'
    check (status in ('draft','sent','accepted','rejected','superseded')),
  uploaded_by uuid references staff_users(id),
  uploaded_at timestamptz not null default now()
);

-- 39.3: uploading a new quote automatically supersedes the previous
-- active one of the same file_type, so there's never two "active" quotes
create or replace function supersede_previous_quote() returns trigger as $$
begin
  update sales_lead_attachments
  set status = 'superseded'
  where lead_id = new.lead_id and file_type = new.file_type
    and id <> new.id and status in ('sent','draft');
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_supersede_previous_quote on sales_lead_attachments;
create trigger trg_supersede_previous_quote
  after insert on sales_lead_attachments
  for each row execute function supersede_previous_quote();

-- ------------------------------------------------------------
-- 43.3 — sales_lead_tasks, deferred from 20260920140000 (that migration's
-- resident/owner/venture tasks module) until sales_leads existed. Same
-- shape as resident_tasks/venture_relationship_tasks. Also serves the
-- customer relationship after they've converted (via
-- converted_organization_id on sales_leads), not just the pre-sale phase.
-- ------------------------------------------------------------
create table if not exists sales_lead_tasks (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references sales_leads(id),
  title text not null,
  description text,
  planned_date date,
  actual_completed_at timestamptz,
  status text not null default 'open' check (status in ('open','done','cancelled')),
  assigned_to_staff_id uuid references staff_users(id),
  created_by_staff_id uuid not null references staff_users(id),
  created_at timestamptz not null default now()
);

create or replace view sales_lead_tasks_overdue as
select * from sales_lead_tasks where status = 'open' and planned_date < current_date;

alter table sales_lead_tasks enable row level security;

-- ------------------------------------------------------------
-- 37.3 — recurring billing: tokenized card only, never a real card
-- number (same "never build your own processor" principle as vendor
-- payments, section 11.3)
-- ------------------------------------------------------------
create table if not exists organization_payment_methods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  method_type text not null check (method_type in ('credit_card','bank_direct_debit')),
  provider text not null,                  -- 'tranzila' / 'cardcom'
  token text,                               -- card token only, never a real number
  card_last4 text,                          -- display only
  bank_account_last4 text,                  -- display only, bank_direct_debit only
  authorization_document_id uuid references documents(id),  -- signed authorization, bank_direct_debit only
  status text not null default 'pending' check (status in ('pending','active','failed','cancelled')),
  created_at timestamptz not null default now()
);

alter table platform_payments add column if not exists payment_method_id uuid references organization_payment_methods(id);
alter table platform_payments add column if not exists retry_count int not null default 0;
alter table platform_payments add column if not exists next_retry_at timestamptz;

-- ------------------------------------------------------------
-- Row-Level Security — platform-level data, staff/Retool only
-- ------------------------------------------------------------
alter table sales_leads enable row level security;
alter table sales_lead_contacts enable row level security;
alter table sales_lead_notes enable row level security;
alter table sales_lead_note_contacts enable row level security;
alter table sales_lead_attachments enable row level security;
alter table organization_payment_methods enable row level security;

-- ------------------------------------------------------------
-- Indexes
-- ------------------------------------------------------------
create index if not exists idx_sales_lead_contacts_lead on sales_lead_contacts(lead_id);
create index if not exists idx_sales_lead_notes_lead on sales_lead_notes(lead_id);
create index if not exists idx_sales_lead_attachments_lead on sales_lead_attachments(lead_id);
create index if not exists idx_organization_payment_methods_org on organization_payment_methods(organization_id);
create index if not exists idx_sales_lead_tasks_lead on sales_lead_tasks(lead_id);
create index if not exists idx_sales_lead_tasks_planned_date on sales_lead_tasks(planned_date) where status = 'open';
