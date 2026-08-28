-- One-time migration for the groups + leader-login feature.
--
-- Run this ONCE in the Supabase SQL editor, AFTER re-running the updated
-- schema.sql (which creates the groups table and seeds "GENERAL").
--
-- All submissions in this project so far are test data from building and
-- verifying the app (confirmed with the project owner, 2026-08-28), so this
-- moves every existing row into a dedicated "TEST" group. TEST is flagged
-- to be excluded from the "All Groups" leader summary, so this historical
-- data never mixes into real numbers, while still being visible/reviewable
-- as its own group in the leader dashboard if needed.

insert into public.groups (code, label, exclude_from_summary)
values ('TEST', 'Test data (pre-launch)', true)
on conflict (code) do nothing;

update public.submissions
set class_code = 'TEST';
