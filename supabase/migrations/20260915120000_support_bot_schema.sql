-- =====================================================================
-- Support bot schema (sections 30-33 of the extended planning doc:
-- support-bot-system-prompt.md / תכנון-בסיס-נתונים-קהילות.md).
--
-- Replaces the earlier, never-built-on WhatsApp-only chatbot design
-- from 20260906130000_gap_fixes_from_airtable_schema.sql with the
-- richer, channel-agnostic support_conversations/support_messages
-- design that also backs semantic knowledge-base search via pgvector.
--
-- Step 0 renames (not drops) the old tables — no UI was ever built
-- against them and they hold no data, but nothing is deleted.
-- =====================================================================

-- ------------------------------------------------------------
-- 0. Retire the old, unused knowledge-base/chatbot tables (rename only)
-- ------------------------------------------------------------
alter table if exists knowledge_base_entries rename to knowledge_base_entries_deprecated;
alter table if exists chatbot_conversations_log rename to chatbot_conversations_log_deprecated;

comment on table knowledge_base_entries_deprecated is
  'Deprecated 2026-09-15: superseded by support_knowledge_base (pgvector semantic search, sections 30-33 of the extended planning doc). Renamed, not dropped — no UI was ever built against this table, so it holds no real data.';
comment on table chatbot_conversations_log_deprecated is
  'Deprecated 2026-09-15: superseded by support_conversations/support_messages (multi-channel, full lifecycle). Renamed, not dropped.';

-- ------------------------------------------------------------
-- 1. pgvector, for semantic knowledge-base search
-- ------------------------------------------------------------
create extension if not exists vector;

-- ------------------------------------------------------------
-- 2. Support categories — an editable table, not a hardcoded list,
-- so the bot's escalate_to_staff tool can be given the current
-- category list dynamically at conversation time (section 33.2)
-- ------------------------------------------------------------
create table support_categories (
  id serial primary key,
  key text unique not null,
  label text not null,
  default_priority text not null default 'normal'
    check (default_priority in ('low','normal','high','urgent'))
);

-- ------------------------------------------------------------
-- 3. Conversations — one row per support thread, whichever way it
-- started (bot escalation or a direct "open a ticket" button; section 32.1)
-- ------------------------------------------------------------
create table support_conversations (
  id uuid primary key default gen_random_uuid(),
  community_id uuid references communities(id),
  requester_type text not null check (requester_type in ('resident','staff')),
  requester_id uuid not null,
  channel text not null default 'in_app' check (channel in ('in_app','whatsapp','email')),
  status text not null default 'open'
    check (status in ('open','escalated','in_progress','resolved','resolved_by_bot','closed')),
  category_id int references support_categories(id),
  priority text not null default 'normal'
    check (priority in ('low','normal','high','urgent')),
  summary text,
  escalated_to uuid references staff_users(id),
  assigned_to uuid references staff_users(id),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

-- ------------------------------------------------------------
-- 4. Messages — the single thread the resident, the bot and staff
-- all post into (section 32.4: "no hand-off between systems")
-- ------------------------------------------------------------
create table support_messages (
  id bigserial primary key,
  conversation_id uuid not null references support_conversations(id),
  sender_type text not null check (sender_type in ('user','bot','staff')),
  body text not null,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 5. Knowledge base — content the bot searches semantically
-- (section 31.3). community_id null = platform-wide entry.
-- ------------------------------------------------------------
create table support_knowledge_base (
  id uuid primary key default gen_random_uuid(),
  community_id uuid references communities(id),
  title text not null,
  content text not null,
  embedding vector(1536),
  updated_at timestamptz not null default now()
);
-- Note: an ivfflat/hnsw ANN index on `embedding` is deliberately not
-- created yet — those index types build best (and Supabase's own docs
-- recommend building them) once there's real content to sample from.
-- Add one once the knowledge base has a meaningful number of rows, e.g.:
--   create index idx_support_kb_embedding on support_knowledge_base
--     using hnsw (embedding vector_cosine_ops);

-- ------------------------------------------------------------
-- 6. Indexes
-- ------------------------------------------------------------
create index idx_support_conversations_community_status
  on support_conversations (community_id, status);

create index idx_support_messages_conversation
  on support_messages (conversation_id, created_at);

create index idx_support_kb_community
  on support_knowledge_base (community_id);

-- ------------------------------------------------------------
-- 7. Row-Level Security
--
-- Uses current_resident_id()/current_community_id() — the
-- SECURITY DEFINER helper functions from the app's own
-- supabase/external/001_app_access.sql (already applied to the
-- live project), so residents can read/write only their own
-- conversation via the resident app's normal Supabase Auth session.
-- Staff access (Retool) goes through a service-role connection,
-- which bypasses RLS entirely — same pattern as the other
-- staff-only tables in this schema.
-- ------------------------------------------------------------
alter table support_conversations enable row level security;
alter table support_messages enable row level security;
alter table support_knowledge_base enable row level security;
alter table support_categories enable row level security;

drop policy if exists app_read_own_conversations on support_conversations;
create policy app_read_own_conversations on support_conversations for select to authenticated
using (requester_type = 'resident' and requester_id = public.current_resident_id());

drop policy if exists app_create_own_conversation on support_conversations;
create policy app_create_own_conversation on support_conversations for insert to authenticated
with check (
  requester_type = 'resident'
  and requester_id = public.current_resident_id()
  and community_id = public.current_community_id()
);

drop policy if exists app_update_own_conversation on support_conversations;
create policy app_update_own_conversation on support_conversations for update to authenticated
using (requester_type = 'resident' and requester_id = public.current_resident_id())
with check (requester_type = 'resident' and requester_id = public.current_resident_id());

drop policy if exists app_read_own_messages on support_messages;
create policy app_read_own_messages on support_messages for select to authenticated
using (conversation_id in (
  select id from support_conversations
  where requester_type = 'resident' and requester_id = public.current_resident_id()
));

drop policy if exists app_create_own_message on support_messages;
create policy app_create_own_message on support_messages for insert to authenticated
with check (
  sender_type = 'user'
  and conversation_id in (
    select id from support_conversations
    where requester_type = 'resident' and requester_id = public.current_resident_id()
  )
);

drop policy if exists app_read_knowledge_base on support_knowledge_base;
create policy app_read_knowledge_base on support_knowledge_base for select to authenticated
using (community_id is null or community_id = public.current_community_id());

drop policy if exists app_read_categories on support_categories;
create policy app_read_categories on support_categories for select to authenticated
using (true);

grant select, insert, update on support_conversations to authenticated;
grant select, insert on support_messages to authenticated;
grant select on support_knowledge_base to authenticated;
grant select on support_categories to authenticated;

-- ------------------------------------------------------------
-- 8. עידן — the support bot's own staff_users row (is_ai_agent=true,
-- role='support', platform-wide since it serves every community).
-- Placeholder email; update it later if a real inbox is wired up.
-- ------------------------------------------------------------
insert into staff_users (email, full_name, scope_level, role, is_ai_agent)
values ('idan-bot@upper.internal', 'עידן', 'platform', 'support', true)
on conflict (email) do nothing;
