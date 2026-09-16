-- =====================================================================
-- Add support_conversations/support_messages to the supabase_realtime
-- publication, so the resident chat screen gets live updates (bot/staff
-- replies appearing without a manual refresh) instead of relying on
-- reload-to-see-new-messages.
--
-- This was the one genuinely missing piece flagged by Lovable's proposed
-- supabase/external/005_support_access.sql. That file's RLS/grant
-- sections were checked directly against pg_policies on the live DB and
-- found to duplicate (under different policy names) what
-- 20260915120000_support_bot_schema.sql already created — resident-only
-- read/write is already correctly enforced, so only the realtime
-- publication membership needed adding here.
-- =====================================================================
alter publication supabase_realtime add table support_conversations;
alter publication supabase_realtime add table support_messages;
