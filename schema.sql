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
create or replace function public.get_class_aggregate(p_class_code text)
returns table (
  scores jsonb,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select scores, created_at
  from public.submissions
  where class_code = p_class_code;
$$;

grant execute on function public.get_class_aggregate(text) to anon;
