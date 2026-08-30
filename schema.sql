-- Intentional Marriage Assessment — Supabase schema
-- Run this once in your Supabase project's SQL editor (Database > SQL Editor > New query).

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  class_code text,
  retrieval_code text not null unique,
  email text,
  created_at timestamptz not null default now(),
  answers jsonb not null,
  scores jsonb not null
);

create index if not exists submissions_class_code_idx on public.submissions (class_code);
create index if not exists submissions_retrieval_code_idx on public.submissions (retrieval_code);

-- Row Level Security is turned on, and no SELECT policy is granted to anyone.
-- That means nobody — including you, using the public anon key — can list or
-- browse the raw table. The only two doors in are the functions below, and
-- each one only ever returns exactly what it's designed to return.
alter table public.submissions enable row level security;

drop policy if exists "anyone can submit an assessment" on public.submissions;
create policy "anyone can submit an assessment"
  on public.submissions
  for insert
  to anon
  with check (true);

-- Door #1: a person retrieving their own results.
-- Requires knowing the exact private retrieval code. Returns one row, never a list.
-- Deliberately does NOT return retrieval_code or email, so even this can't leak them back out.
create or replace function public.get_submission_by_code(p_code text)
returns table (
  class_code text,
  created_at timestamptz,
  answers jsonb,
  scores jsonb
)
language sql
security definer
set search_path = public
as $$
  select class_code, created_at, answers, scores
  from public.submissions
  where retrieval_code = p_code
  limit 1;
$$;

grant execute on function public.get_submission_by_code(text) to anon;

-- Normalizes a class/group code for matching and storage: case-insensitive,
-- leading/trailing whitespace trimmed, and internal runs of whitespace
-- collapsed to a single space (so "Full Count 2026" == "full  count 2026"
-- but a space still distinguishes "Full Count 2026" from "FullCount2026").
create or replace function public.normalize_code(p_code text)
returns text
language sql
immutable
as $$
  select upper(trim(regexp_replace(coalesce(p_code, ''), '\s+', ' ', 'g')));
$$;

-- Door #2: a class leader viewing anonymous group results.
-- Returns only category scores and a timestamp for a given class code.
-- Never returns retrieval_code, email, or per-question answers, so an
-- individual's specific responses can never be reconstructed from this.
-- Now requires the shared leader access code (see leader section below)
-- on every call -- no longer callable by anyone who just knows a class code.
create or replace function public.get_class_aggregate(p_class_code text, p_access_code text)
returns table (
  scores jsonb,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.verify_leader_code(p_access_code) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
    select s.scores, s.created_at
    from public.submissions s
    where s.class_code = public.normalize_code(p_class_code);
end;
$$;

-- ============================================================================
-- Groups + leader access
-- ============================================================================
-- A "group" is a named bucket submissions can belong to: a real class code a
-- leader created ahead of time, or the always-existing "GENERAL" bucket for
-- people taking the assessment on their own (not part of any class).
create table if not exists public.groups (
  code text primary key,
  label text,
  exclude_from_summary boolean not null default false,
  created_at timestamptz not null default now()
);

insert into public.groups (code, label)
values ('GENERAL', 'General (no class)')
on conflict (code) do nothing;

-- Nobody -- not even a leader -- reads this table directly.
-- All access goes through the narrow functions below, same philosophy as
-- the submissions table above.
alter table public.groups enable row level security;

-- Lets the assessment flow confirm a typed class code is real before
-- letting someone proceed, without exposing the full list of groups.
create or replace function public.check_group_exists(p_code text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(select 1 from public.groups where code = public.normalize_code(p_code));
$$;

grant execute on function public.check_group_exists(text) to anon;

-- Leader access is a single shared 8-digit code -- no email, no accounts,
-- no waiting on a login link. The code itself lives in Supabase Vault
-- (never in this file, never in the frontend); this function is the only
-- thing in the whole database allowed to read it, and it never returns
-- the code itself, only whether a guess matched.
-- This replaces the earlier email-allowlist approach entirely.
drop function if exists public.get_class_aggregate(text);
drop function if exists public.leader_list_groups();
drop function if exists public.leader_create_group(text, text);
drop function if exists public.leader_get_all_groups_aggregate();
drop function if exists public.is_current_user_allowlisted_leader();
drop table if exists public.leader_allowlist;

create or replace function public.verify_leader_code(p_access_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'leader_access_code'
  limit 1;

  return v_secret is not null and v_secret <> '' and p_access_code = v_secret;
end;
$$;

grant execute on function public.verify_leader_code(text) to anon;
grant execute on function public.get_class_aggregate(text, text) to anon;

-- Lists every known group (including ones with zero submissions so far,
-- like a group a leader just created ahead of a class) with a live count.
create or replace function public.leader_list_groups(p_access_code text)
returns table (
  code text,
  label text,
  exclude_from_summary boolean,
  submission_count bigint,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.verify_leader_code(p_access_code) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
    select g.code, g.label, g.exclude_from_summary, count(s.id) as submission_count, g.created_at
    from public.groups g
    left join public.submissions s on s.class_code = g.code
    group by g.code, g.label, g.exclude_from_summary, g.created_at
    order by g.created_at desc;
end;
$$;

grant execute on function public.leader_list_groups(text) to anon;

-- Creates a new group with a leader-chosen code. Fails clearly if the code
-- is already taken so the frontend can ask for a different one.
create or replace function public.leader_create_group(p_code text, p_label text, p_access_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := public.normalize_code(p_code);
begin
  if not public.verify_leader_code(p_access_code) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if v_code is null or v_code = '' then
    raise exception 'code_required';
  end if;

  if exists (select 1 from public.groups where code = v_code) then
    raise exception 'code_taken';
  end if;

  insert into public.groups (code, label) values (v_code, nullif(trim(p_label), ''));
end;
$$;

grant execute on function public.leader_create_group(text, text, text) to anon;

-- Combined aggregate across every group that isn't flagged excluded
-- (e.g. the internal TEST bucket, see the migration file for this project).
-- Same shape as get_class_aggregate so the frontend can reuse one report view.
create or replace function public.leader_get_all_groups_aggregate(p_access_code text)
returns table (scores jsonb, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.verify_leader_code(p_access_code) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
    select s.scores, s.created_at
    from public.submissions s
    join public.groups g on g.code = s.class_code
    where g.exclude_from_summary = false;
end;
$$;

grant execute on function public.leader_get_all_groups_aggregate(text) to anon;
