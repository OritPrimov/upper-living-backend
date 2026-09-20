-- =====================================================================
-- Section 49 of the extended planning doc (docs/database-plan-extended.md):
-- a minor flag on residents, to block legally/financially binding actions
-- (poll votes, signing binding documents) without touching normal app
-- use (posts, events, personal tasks, community projects).
--
-- Deliberately a single boolean, not a table or a date_of_birth column:
-- staff sets/updates it manually when creating the account, no
-- "turns 18" logic needed. The "household members" screen (49.3) needs
-- no schema at all — it's a query grouping residents + external owners
-- by unit_id, both of which already exist.
-- =====================================================================

alter table residents add column if not exists is_minor boolean not null default false;
