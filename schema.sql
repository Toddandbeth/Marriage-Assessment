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

-- Door #2: a class leader viewing anonymous group results.
-- Returns only category scores and a timestamp for a given class code.
-- Never returns retrieval_code, email, or per-question answers, so an
-- individual's specific responses can never be reconstructed from this.
-- Now requires an authenticated, allowlisted leader (see leader section
-- below) -- no longer callable by anyone who just knows a class code.
create or replace function public.get_class_aggregate(p_class_code text)
returns table (
  scores jsonb,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_current_user_allowlisted_leader() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
    select s.scores, s.created_at
    from public.submissions s
    where s.class_code = upper(trim(p_class_code));
end;
$$;

revoke all on function public.get_class_aggregate(text) from anon;
grant execute on function public.get_class_aggregate(text) to authenticated;

-- ============================================================================
-- Groups + leader login
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

-- Nobody -- not even a signed-in leader -- reads this table directly.
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
  select exists(select 1 from public.groups where code = upper(trim(p_code)));
$$;

grant execute on function public.check_group_exists(text) to anon;

-- The leader allowlist: only emails in this table can ever be treated as a
-- leader, no matter who successfully signs in via magic link. RLS is on
-- with no policies, so this table cannot be read directly by anyone --
-- only checked internally by is_current_user_allowlisted_leader() below.
-- Add/remove leaders any time with, e.g.:
--   insert into public.leader_allowlist (email) values ('someone@example.com');
create table if not exists public.leader_allowlist (
  email text primary key
);

alter table public.leader_allowlist enable row level security;

-- The one real gate every leader-only function below checks first. Matching
-- is case-insensitive since email addresses aren't case sensitive in practice.
create or replace function public.is_current_user_allowlisted_leader()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.leader_allowlist
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.is_current_user_allowlisted_leader() to authenticated;

-- Lists every known group (including ones with zero submissions so far,
-- like a group a leader just created ahead of a class) with a live count.
create or replace function public.leader_list_groups()
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
  if not public.is_current_user_allowlisted_leader() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
    select g.code, g.label, g.exclude_from_summary, count(s.id) as submission_count, g.created_at
    from public.groups g
    left join public.submissions s on s.class_code = g.code
    group by g.code, g.label, g.exclude_from_summary, g.created_at
    order by g.created_at asc;
end;
$$;

grant execute on function public.leader_list_groups() to authenticated;

-- Creates a new group with a leader-chosen code. Fails clearly if the code
-- is already taken so the frontend can ask for a different one.
create or replace function public.leader_create_group(p_code text, p_label text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(trim(p_code));
begin
  if not public.is_current_user_allowlisted_leader() then
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

grant execute on function public.leader_create_group(text, text) to authenticated;

-- Combined aggregate across every group that isn't flagged excluded
-- (e.g. the internal TEST bucket, see the migration file for this project).
-- Same shape as get_class_aggregate so the frontend can reuse one report view.
create or replace function public.leader_get_all_groups_aggregate()
returns table (scores jsonb, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_current_user_allowlisted_leader() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
    select s.scores, s.created_at
    from public.submissions s
    join public.groups g on g.code = s.class_code
    where g.exclude_from_summary = false;
end;
$$;

grant execute on function public.leader_get_all_groups_aggregate() to authenticated;
