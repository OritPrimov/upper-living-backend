-- =====================================================================
-- On-screen signature drawing for the "internal signature" level (2).
-- Requested by Orit as a UX addition — the drawn image itself carries no
-- extra legal weight (that already comes from the password re-verification
-- + IP/timestamp in document-sign/index.ts), it just makes signing feel
-- like signing. Stored in the same private 'documents' bucket as the
-- underlying files, under signatures/, referenced by path (not a public
-- URL) — consistent with how the file itself is handled.
-- =====================================================================

alter table document_signatures add column if not exists signature_image_path text;
