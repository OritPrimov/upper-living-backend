-- =====================================================================
-- Soft delete for the support bot's knowledge base (support_knowledge_base).
-- Requested by Orit after Retool flagged that the KB admin screen's
-- "delete article" was a hard DELETE with no recovery, against the
-- "soft delete everywhere" governance principle from the planning doc
-- (section 5, data governance). Same rename-not-drop philosophy used
-- throughout this schema, applied here as archive-not-delete.
-- =====================================================================

alter table support_knowledge_base add column if not exists archived_at timestamptz;

-- Bot search (search_knowledge_base tool) and any resident-facing read
-- must never surface an archived article.
drop policy if exists app_read_knowledge_base on support_knowledge_base;
create policy app_read_knowledge_base on support_knowledge_base for select to authenticated
using (
  (community_id is null or community_id = public.current_community_id())
  and archived_at is null
);
