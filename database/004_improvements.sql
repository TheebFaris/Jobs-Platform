-- =====================================================================
-- Jobs Platform (Jordan) - migration 004
-- 1) faster lists  2) proof that the candidate accepted "no refund" and the terms
-- 3) automatic-filter results with reasons (and coordinator override)
-- 4) rule: two interview no-shows block the candidate for 14 days
-- 5) on hire: follow-ups at the end of probation + first-hire date for the company contract
-- 6) audit trail for sensitive changes (private file storage is in 005_storage.sql)
-- Run ONCE in Supabase SQL Editor, AFTER 001, 002 and 003. Safe on a project that already has data.
-- =====================================================================

-- ---------- 1) Indexes for the admin lists ----------
create index if not exists hiring_requests_status_created_idx on public.hiring_requests (status, created_at desc);
create index if not exists companies_status_created_idx on public.companies (status, created_at desc);
create index if not exists nominations_status_idx on public.nominations (status);
create index if not exists interviews_status_start_idx on public.interviews (status, starts_at);
create index if not exists candidates_created_idx on public.candidates (created_at desc);

-- ---------- 2) Evidence of consent ----------
alter table public.candidates add column if not exists terms_accepted_at timestamptz;
alter table public.payments add column if not exists ack_no_refund_at timestamptz;

-- A payment can only be created after the candidate acknowledged that the fee is non-refundable
drop policy if exists pay_own_insert on public.payments;
create policy pay_own_insert on public.payments for insert to authenticated
  with check (candidate_id = public.my_candidate_id() and status = 'pending'
              and confirmed_by is null and confirmed_at is null and ack_no_refund_at is not null);

create or replace function public.guard_payment_update() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not public.is_staff() then
    new.candidate_id := old.candidate_id;
    new.amount_jd := old.amount_jd;
    new.method := old.method;
    new.reference_code := old.reference_code;
    new.status := old.status;
    new.reject_reason := old.reject_reason;
    new.confirmed_by := old.confirmed_by;
    new.confirmed_at := old.confirmed_at;
    new.ack_no_refund_at := old.ack_no_refund_at;
  end if;
  if new.status = 'confirmed' and old.status <> 'confirmed' then
    new.confirmed_at := now();
    new.confirmed_by := coalesce(auth.uid(), new.confirmed_by);
  end if;
  return new;
end $$;

-- ---------- 3) Automatic filter results (why a candidate was approved / sent to review / not suitable) ----------
create table if not exists public.match_results (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hiring_requests(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  decision text not null check (decision in ('approved','review','not_suitable')),
  score int check (score between 0 and 100),
  reasons jsonb not null default '[]'::jsonb,       -- e.g. [{"rule":"min_experience","need":5,"has":4.5}]
  overridden_by uuid references public.profiles(id),
  overridden_at timestamptz,
  override_decision text check (override_decision in ('approved','review','not_suitable')),
  created_at timestamptz not null default now(),
  unique (request_id, candidate_id)
);
create index if not exists match_results_request_idx on public.match_results (request_id, decision);
alter table public.match_results enable row level security;
-- Staff only: companies and candidates never see these results
drop policy if exists staff_all on public.match_results;
create policy staff_all on public.match_results for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------- 4) Two no-shows = temporary block ----------
create or replace function public.interview_no_show() returns trigger
language plpgsql security definer set search_path = public as $$
declare cand uuid;
begin
  if new.status = 'candidate_no_show' and old.status is distinct from 'candidate_no_show' then
    select candidate_id into cand from public.nominations where id = new.nomination_id;
    update public.candidates set
      no_show_count = no_show_count + 1,
      blocked_until = case when no_show_count + 1 >= 2 then now() + interval '14 days' else blocked_until end,
      blocked_reason = case when no_show_count + 1 >= 2 then 'Two interview no-shows' else blocked_reason end
    where id = cand;
  end if;
  return new;
end $$;
drop trigger if exists interviews_no_show on public.interviews;
create trigger interviews_no_show after update of status on public.interviews
  for each row execute function public.interview_no_show();

-- ---------- 5) On hire: follow-ups + first-hire date ----------
create or replace function public.nomination_hired() returns trigger
language plpgsql security definer set search_path = public as $$
declare due date;
begin
  if new.status = 'hired' and old.status is distinct from 'hired' then
    due := (coalesce(new.start_date, current_date) + make_interval(months => coalesce(new.probation_months, 3)))::date;
    insert into public.followups (nomination_id, role, due_date)
      values (new.id, 'company', due), (new.id, 'candidate', due)
      on conflict (nomination_id, role) do nothing;
    update public.subscriptions set first_hire_at = now()
      where first_hire_at is null
        and company_id = (select company_id from public.hiring_requests where id = new.request_id);
  end if;
  return new;
end $$;
drop trigger if exists nominations_hired on public.nominations;
create trigger nominations_hired after update of status on public.nominations
  for each row execute function public.nomination_hired();

-- ---------- 6) Audit trail for sensitive changes ----------
create or replace function public.audit_sensitive_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare col text;
begin
  if tg_table_name = 'candidates' then
    foreach col in array array['verified_badge','blocked_until','paid_at','is_active'] loop
      if to_jsonb(new) -> col is distinct from to_jsonb(old) -> col then
        insert into public.audit_log (actor_id, action, entity, entity_id, details)
        values (auth.uid(), 'change_' || col, 'candidates', new.id::text,
                jsonb_build_object('from', to_jsonb(old) -> col, 'to', to_jsonb(new) -> col));
      end if;
    end loop;
  elsif tg_table_name = 'companies' then
    if new.reg_check is distinct from old.reg_check then
      insert into public.audit_log (actor_id, action, entity, entity_id, details)
      values (auth.uid(), 'change_reg_check', 'companies', new.id::text,
              jsonb_build_object('from', old.reg_check, 'to', new.reg_check));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists audit_candidates_sensitive on public.candidates;
create trigger audit_candidates_sensitive after update on public.candidates
  for each row execute function public.audit_sensitive_change();
drop trigger if exists audit_companies_sensitive on public.companies;
create trigger audit_companies_sensitive after update on public.companies
  for each row execute function public.audit_sensitive_change();
