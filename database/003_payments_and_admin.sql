-- =====================================================================
-- Jobs Platform (Jordan) - migration 003
-- Adds: manual payments (CliQ / bank transfer), candidate blocking after no-shows,
-- request assignment to a coordinator, company sector and registration check,
-- craftsman certificates, interview rescheduling.
-- Run ONCE in Supabase SQL Editor, AFTER 001 and 002. Safe on an existing project with data.
-- =====================================================================

-- ---------- Interview rescheduling ----------
alter type public.interview_status add value if not exists 'rescheduling';
alter table public.interviews add column if not exists reschedule_reason text;

-- ---------- Companies: business sector + commercial registration check ----------
alter table public.companies
  add column if not exists sector_id uuid references public.sectors(id),
  add column if not exists reg_check text not null default 'missing'
    check (reg_check in ('missing','to_review','verified'));

-- ---------- Requests: who is handling it ----------
alter table public.hiring_requests
  add column if not exists assigned_to uuid references public.profiles(id);
create index if not exists hiring_requests_assigned_idx on public.hiring_requests (assigned_to);

-- ---------- Candidates: phone check, payment date, temporary block ----------
alter table public.candidates
  add column if not exists phone_verified_at timestamptz,
  add column if not exists paid_at timestamptz,
  add column if not exists blocked_until timestamptz,
  add column if not exists blocked_reason text;

-- Candidates must not be able to set these themselves (extends the guard from 001)
create or replace function public.guard_candidate_write() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not public.is_staff() then
    if tg_op = 'INSERT' then
      new.verified_badge := false;
      new.no_show_count := 0;
      new.phone_verified_at := null;
      new.paid_at := null;
      new.blocked_until := null;
      new.blocked_reason := null;
    else
      new.verified_badge := old.verified_badge;
      new.no_show_count := old.no_show_count;
      new.registered_by := old.registered_by;
      new.profile_id := old.profile_id;
      new.phone_verified_at := old.phone_verified_at;
      new.paid_at := old.paid_at;
      new.blocked_until := old.blocked_until;
      new.blocked_reason := old.blocked_reason;
    end if;
  end if;
  return new;
end $$;

-- ---------- Craftsman certificates ----------
create table if not exists public.candidate_certificates (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  title text not null,
  issuer text,
  year int,
  file_path text
);
alter table public.candidate_certificates enable row level security;
create policy staff_all on public.candidate_certificates for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy own_all on public.candidate_certificates for all to authenticated
  using (candidate_id = public.my_candidate_id()) with check (candidate_id = public.my_candidate_id());
create policy registrar_all on public.candidate_certificates for all to authenticated
  using (public.registrar_owns_candidate(candidate_id)) with check (public.registrar_owns_candidate(candidate_id));
create policy certs_company_read on public.candidate_certificates for select to authenticated
  using (public.company_can_see_candidate(candidate_id));

-- ---------- Payments (manual: CliQ or bank transfer, confirmed by staff) ----------
create sequence if not exists public.payment_ref_seq start 1000;
-- The default value goes through a function so it works for any logged-in user without direct sequence rights
create or replace function public.next_payment_reference() returns text
language sql security definer set search_path = public as $$ select 'WZ-' || nextval('public.payment_ref_seq') $$;

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  amount_jd numeric(8,2) not null default 5 check (amount_jd > 0),
  method text not null check (method in ('cliq','bank')),
  reference_code text not null unique default public.next_payment_reference(),
  transfer_ref text,                         -- transfer number written by the candidate
  proof_path text,                           -- screenshot in PRIVATE storage
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  reject_reason text,
  confirmed_by uuid references public.profiles(id),
  confirmed_at timestamptz,
  created_at timestamptz not null default now()
);
create index payments_status_idx on public.payments (status, created_at);
create index payments_candidate_idx on public.payments (candidate_id);
alter table public.payments enable row level security;

create policy staff_all on public.payments for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy pay_own_select on public.payments for select to authenticated
  using (candidate_id = public.my_candidate_id());
create policy pay_own_insert on public.payments for insert to authenticated
  with check (candidate_id = public.my_candidate_id() and status = 'pending' and confirmed_by is null and confirmed_at is null);
create policy pay_own_proof on public.payments for update to authenticated
  using (candidate_id = public.my_candidate_id() and status = 'pending')
  with check (candidate_id = public.my_candidate_id() and status = 'pending');

-- A candidate may only add proof / transfer number to a pending payment, never change anything else
create function public.guard_payment_update() returns trigger language plpgsql as $$
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
  end if;
  if new.status = 'confirmed' and old.status <> 'confirmed' then
    new.confirmed_at := now();
    new.confirmed_by := coalesce(auth.uid(), new.confirmed_by);
  end if;
  return new;
end $$;
create trigger guard_payments before update on public.payments
  for each row execute function public.guard_payment_update();

-- When a payment is confirmed, the candidate is marked as paid
create function public.payment_confirmed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'confirmed' and old.status <> 'confirmed' then
    update public.candidates set paid_at = coalesce(paid_at, now()) where id = new.candidate_id;
  end if;
  return new;
end $$;
create trigger payments_after_update after update on public.payments
  for each row execute function public.payment_confirmed();

create trigger audit_payments after update on public.payments
  for each row execute function public.audit_status_change();
