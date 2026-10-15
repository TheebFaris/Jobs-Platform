-- =====================================================================
-- Jobs Platform (Jordan) - Phase 1 database schema
-- How to run: Supabase dashboard > SQL Editor > New query > paste > Run
-- Run it ONCE on an empty project.
-- Architecture rule: sensitive changes (status transitions, approvals,
-- exam results, badges) are made by server code or by staff accounts.
-- Normal users only get the few write permissions listed in the policies.
-- =====================================================================

-- ---------- Enums ----------
create type public.user_role as enum ('admin','coordinator','registrar','candidate','company_user','institution_user');
create type public.org_status as enum ('pending','approved','rejected','suspended');
create type public.level_type as enum ('fresh','junior','mid','senior');
create type public.opportunity_type as enum ('full_time','part_time','temporary','hourly','training');
create type public.title_status as enum ('approved','pending');
create type public.request_status as enum ('draft','submitted','matching','shortlist_sent','interviews','hired','closed');
create type public.nomination_status as enum ('proposed','candidate_accepted','candidate_declined','company_accepted','company_declined','interview_scheduled','interview_done','hired','not_hired','withdrawn');
create type public.interview_status as enum ('scheduled','confirmed','done','candidate_no_show','company_no_show','cancelled');
create type public.party_role as enum ('company','candidate');
create type public.eval_outcome as enum ('accepted','second_interview','rejected','undecided');
create type public.subscription_status as enum ('trial','active','expired','cancelled');
create type public.replacement_status as enum ('reported','under_review','approved','rejected','fulfilled');
create type public.leave_party as enum ('employee','company');
create type public.idea_status as enum ('new','reviewed','winner','archived');
create type public.ticket_status as enum ('open','answered','closed');

-- ---------- Generic helpers ----------
create function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ---------- Users ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.user_role not null default 'candidate',
  full_name text,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Every new sign-up gets a profile with the lowest role (candidate).
-- The role is NEVER taken from client-supplied data.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, phone, full_name)
  values (new.id, new.phone, coalesce(new.raw_user_meta_data->>'full_name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Sectors and job titles (fixed lists managed by the team) ----------
create table public.sectors (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null,
  name_en text not null unique,
  exam_required boolean not null default false,
  cv_language text not null default 'en' check (cv_language in ('ar','en')),
  sort_order int not null default 0
);

create table public.job_titles (
  id uuid primary key default gen_random_uuid(),
  sector_id uuid references public.sectors(id),
  name_ar text,
  name_en text,
  synonyms text[] not null default '{}',
  status public.title_status not null default 'approved',
  suggested_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  check (name_ar is not null or name_en is not null)
);
create unique index job_titles_unique_approved
  on public.job_titles (sector_id, lower(coalesce(name_en, name_ar)))
  where status = 'approved';

-- ---------- Companies and institutions ----------
create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  commercial_reg_no text,
  commercial_reg_file text,            -- path in PRIVATE storage
  business_nature text,
  established_year int check (established_year between 1900 and 2100),
  services text,
  departments text[] not null default '{}',
  employees_count int check (employees_count >= 0),
  status public.org_status not null default 'pending',
  rejection_reason text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.company_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  is_owner boolean not null default false,
  job_position text,
  created_at timestamptz not null default now(),
  primary key (company_id, profile_id)
);

-- Phase 2 (universities and training centers): table exists now so the model is ready
create table public.institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null default 'university' check (kind in ('university','training_center','other')),
  status public.org_status not null default 'pending',
  created_at timestamptz not null default now()
);
create table public.institution_members (
  institution_id uuid not null references public.institutions(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  primary key (institution_id, profile_id)
);

-- ---------- Candidates ----------
-- profile_id is NULL for candidates registered by our team who have no login yet.
create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null,
  registered_by uuid references public.profiles(id),
  full_name text not null,
  phone text not null unique,
  nationality text,
  is_jordanian boolean not null default true,
  work_permit_valid boolean,
  birth_year int check (birth_year between 1940 and 2100),
  governorate text,
  city text,
  sector_id uuid references public.sectors(id),
  job_title_id uuid references public.job_titles(id),
  other_title_text text,
  level public.level_type,
  years_experience numeric(4,1) check (years_experience >= 0),
  summary text,
  skills text[] not null default '{}',          -- English only (enforced in app)
  photo_path text,                              -- optional
  expected_salary_min numeric(8,2),             -- PRIVATE: never shown to companies
  expected_salary_max numeric(8,2),             -- PRIVATE
  currently_employed boolean,
  profile_completion int not null default 0 check (profile_completion between 0 and 100),
  verified_badge boolean not null default false,
  no_show_count int not null default 0 check (no_show_count >= 0),
  data_consent_at timestamptz,
  ai_consent_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expected_salary_max is null or expected_salary_min is null or expected_salary_max >= expected_salary_min)
);
create index candidates_sector_idx on public.candidates (sector_id, job_title_id, level);
create index candidates_skills_idx on public.candidates using gin (skills);

create table public.candidate_experiences (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  employer text,
  job_title text,
  start_date date,
  end_date date,
  is_current boolean not null default false,
  description text
);
create table public.candidate_education (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  institution text,
  degree text,
  field text,
  start_year int,
  end_year int,
  gpa numeric(4,2),
  gpa_verified boolean not null default false
);
create table public.candidate_references (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  referee_name text not null,
  referee_phone text,
  relation text,
  permission_confirmed boolean not null default false
);
-- Sensitive and confidential: visible to the team only, and to a company only with the candidate's consent
create table public.candidate_support (
  candidate_id uuid primary key references public.candidates(id) on delete cascade,
  needs_note text,
  share_with_company boolean not null default false,
  consent_at timestamptz
);
create table public.candidate_documents (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  kind text not null check (kind in ('old_cv','generated_cv')),
  language text check (language in ('ar','en')),
  file_path text not null,
  parsed jsonb,
  created_at timestamptz not null default now()
);
-- One attempt per candidate (unique). Reopening = staff deletes the row after a technical failure.
create table public.exam_attempts (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null unique references public.candidates(id) on delete cascade,
  sector_id uuid references public.sectors(id),
  score int check (score between 0 and 100),
  passed boolean not null default false,
  taken_at timestamptz not null default now()
);

-- ---------- Hiring requests and subscriptions ----------
create table public.hiring_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  created_by uuid references public.profiles(id),
  job_title_id uuid references public.job_titles(id),
  other_title_text text,
  level public.level_type,
  opportunity public.opportunity_type not null default 'full_time',
  positions_count int not null default 1 check (positions_count > 0),
  must_skills text[] not null default '{}',
  nice_skills text[] not null default '{}',
  salary_min numeric(8,2),
  salary_max numeric(8,2),
  location text,
  schedule text,
  contract_type text,
  accepted_nationalities text[],               -- NULL = any nationality
  is_urgent boolean not null default false,
  status public.request_status not null default 'draft',
  notes text,
  submitted_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (salary_max is null or salary_min is null or salary_max >= salary_min)
);
create index hiring_requests_company_idx on public.hiring_requests (company_id, status);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  status public.subscription_status not null default 'trial',
  plan text not null default 'trial' check (plan in ('trial','six_months','yearly')),
  starts_on date,
  ends_on date,
  fee_jd numeric(8,2),
  free_requests_limit int,
  first_hire_at timestamptz,
  contract_signed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Nominations, interviews, evaluations ----------
create table public.nominations (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hiring_requests(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  status public.nomination_status not null default 'proposed',
  proposed_by uuid references public.profiles(id),
  candidate_consent_at timestamptz,
  candidate_currently_employed boolean,
  candidate_available_from date,
  company_decided_at timestamptz,
  hired_at timestamptz,
  start_date date,
  probation_months int check (probation_months between 0 and 12),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (request_id, candidate_id)
);
create index nominations_candidate_idx on public.nominations (candidate_id);

-- Staff-only notes (salary gap etc.). Separate table because RLS works per row, not per column.
create table public.nomination_internal (
  nomination_id uuid primary key references public.nominations(id) on delete cascade,
  salary_gap_jd numeric(8,2),
  coordinator_note text
);

create table public.interview_slots (
  id uuid primary key default gen_random_uuid(),
  nomination_id uuid not null references public.nominations(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  proposed_by uuid references public.profiles(id),
  chosen boolean not null default false,
  check (ends_at > starts_at)
);
create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  nomination_id uuid not null references public.nominations(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz,
  platform text not null default 'google_meet' check (platform in ('zoom','google_meet')),
  meeting_url text,
  status public.interview_status not null default 'scheduled',
  candidate_confirmed_at timestamptz,
  company_confirmed_at timestamptz,
  cancelled_by uuid references public.profiles(id),
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index interviews_nomination_idx on public.interviews (nomination_id, starts_at);

create table public.evaluations (
  id uuid primary key default gen_random_uuid(),
  interview_id uuid not null references public.interviews(id) on delete cascade,
  evaluator_role public.party_role not null,
  evaluator_id uuid not null references public.profiles(id),
  outcome public.eval_outcome,
  rating_technical int check (rating_technical between 1 and 5),
  rating_communication int check (rating_communication between 1 and 5),
  rating_commitment int check (rating_commitment between 1 and 5),
  rating_fit int check (rating_fit between 1 and 5),
  reason text,
  comment text,
  created_at timestamptz not null default now(),
  unique (interview_id, evaluator_role),
  check (outcome is distinct from 'rejected' or reason is not null)
);

create table public.followups (
  id uuid primary key default gen_random_uuid(),
  nomination_id uuid not null references public.nominations(id) on delete cascade,
  role public.party_role not null,
  due_date date not null,
  answered_by uuid references public.profiles(id),
  answered_at timestamptz,
  still_employed boolean,
  satisfaction int check (satisfaction between 1 and 5),
  note text,
  created_at timestamptz not null default now(),
  unique (nomination_id, role)
);

create table public.replacement_requests (
  id uuid primary key default gen_random_uuid(),
  nomination_id uuid not null references public.nominations(id) on delete cascade,
  subscription_id uuid references public.subscriptions(id),
  reported_by uuid references public.profiles(id),
  left_by public.leave_party,
  company_reason text,
  employee_reason text,
  status public.replacement_status not null default 'reported',
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  new_request_id uuid references public.hiring_requests(id),
  created_at timestamptz not null default now()
);

-- ---------- Chat, community, support ----------
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  nomination_id uuid not null references public.nominations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  body text not null check (char_length(body) between 1 and 4000),
  flagged boolean not null default false,       -- phone number / link detected
  created_at timestamptz not null default now()
);
create index messages_nomination_idx on public.messages (nomination_id, created_at);

create function public.flag_contact_info() returns trigger language plpgsql as $$
begin
  if new.body ~* '([0-9٠-٩][ .-]?){8,}' or new.body ~* '(https?://|www\.|@[a-z0-9_]{3,})' then
    new.flagged := true;
  end if;
  return new;
end $$;
create trigger messages_flag before insert on public.messages
  for each row execute function public.flag_contact_info();

create table public.ideas (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  contest_month date not null default (date_trunc('month', now()))::date,
  status public.idea_status not null default 'new',
  created_at timestamptz not null default now()
);
create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject text,
  body text not null,
  status public.ticket_status not null default 'open',
  staff_reply text,
  replied_by uuid references public.profiles(id),
  replied_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.stories (
  id uuid primary key default gen_random_uuid(),
  nomination_id uuid references public.nominations(id) on delete set null,
  title_ar text,
  body_ar text,
  title_en text,
  body_en text,
  candidate_consent boolean not null default false,
  company_consent boolean not null default false,
  published boolean not null default false,
  published_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  check (not published or (candidate_consent and company_consent))   -- never publish without both consents
);

-- ---------- Notifications and audit ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  title text,
  body text,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications (profile_id, created_at desc);
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null check (platform in ('web','android','ios')),
  token text not null,
  created_at timestamptz not null default now(),
  unique (profile_id, token)
);
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  entity text,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_entity_idx on public.audit_log (entity, entity_id, created_at desc);

-- ---------- Access helper functions (security definer, read-only) ----------
create function public.current_user_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and is_active
$$;
create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_user_role() = 'admin', false)
$$;
create function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_user_role() in ('admin','coordinator'), false)
$$;
create function public.my_company_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.company_members where profile_id = auth.uid()
$$;
create function public.my_candidate_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.candidates where profile_id = auth.uid()
$$;
create function public.registrar_owns_candidate(p_cand uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_user_role() = 'registrar', false)
     and exists (select 1 from public.candidates where id = p_cand and registered_by = auth.uid())
$$;
-- A company may see a candidate only after the candidate accepted a nomination to that company's request
create function public.company_can_see_candidate(p_cand uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.nominations n
    join public.hiring_requests r on r.id = n.request_id
    where n.candidate_id = p_cand
      and r.company_id in (select public.my_company_ids())
      and n.status not in ('proposed','candidate_declined'))
$$;
create function public.can_access_nomination(p_nom uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_staff() or exists (
    select 1 from public.nominations n
    join public.hiring_requests r on r.id = n.request_id
    where n.id = p_nom and (
      n.candidate_id = public.my_candidate_id()
      or (r.company_id in (select public.my_company_ids())
          and n.status not in ('proposed','candidate_declined'))))
$$;
create function public.can_access_interview(p_int uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.interviews i
                 where i.id = p_int and public.can_access_nomination(i.nomination_id))
$$;
create function public.is_my_followup(p_nom uuid, p_role public.party_role) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_role = 'candidate' then
    exists (select 1 from public.nominations n where n.id = p_nom and n.candidate_id = public.my_candidate_id())
  else
    exists (select 1 from public.nominations n join public.hiring_requests r on r.id = n.request_id
            where n.id = p_nom and r.company_id in (select public.my_company_ids()))
  end
$$;

-- Application-level audit: call from server code, e.g. when staff or a company opens a candidate file
create function public.log_event(p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.audit_log (actor_id, action, entity, entity_id, details)
  values (auth.uid(), p_action, p_entity, p_entity_id, coalesce(p_details, '{}'::jsonb));
end $$;

-- ---------- Triggers ----------
create function public.audit_status_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    insert into public.audit_log (actor_id, action, entity, entity_id, details)
    values (auth.uid(), 'status_change', tg_table_name, new.id::text,
            jsonb_build_object('from', old.status::text, 'to', new.status::text));
  end if;
  return new;
end $$;
create trigger audit_companies after update on public.companies for each row execute function public.audit_status_change();
create trigger audit_requests after update on public.hiring_requests for each row execute function public.audit_status_change();
create trigger audit_nominations after update on public.nominations for each row execute function public.audit_status_change();
create trigger audit_interviews after update on public.interviews for each row execute function public.audit_status_change();
create trigger audit_replacements after update on public.replacement_requests for each row execute function public.audit_status_change();
create trigger audit_subscriptions after update on public.subscriptions for each row execute function public.audit_status_change();

-- Users cannot promote themselves or reactivate themselves
create function public.guard_profile_update() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.is_active := old.is_active;
  end if;
  return new;
end $$;
create trigger guard_profiles before update on public.profiles for each row execute function public.guard_profile_update();

-- Candidates cannot award themselves a badge or erase their no-show record
create function public.guard_candidate_write() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not public.is_staff() then
    if tg_op = 'INSERT' then
      new.verified_badge := false;
      new.no_show_count := 0;
    else
      new.verified_badge := old.verified_badge;
      new.no_show_count := old.no_show_count;
      new.registered_by := old.registered_by;
      new.profile_id := old.profile_id;
    end if;
  end if;
  return new;
end $$;
create trigger guard_candidates before insert or update on public.candidates
  for each row execute function public.guard_candidate_write();

create trigger t_upd_profiles before update on public.profiles for each row execute function public.set_updated_at();
create trigger t_upd_companies before update on public.companies for each row execute function public.set_updated_at();
create trigger t_upd_candidates before update on public.candidates for each row execute function public.set_updated_at();
create trigger t_upd_requests before update on public.hiring_requests for each row execute function public.set_updated_at();
create trigger t_upd_subscriptions before update on public.subscriptions for each row execute function public.set_updated_at();
create trigger t_upd_nominations before update on public.nominations for each row execute function public.set_updated_at();
create trigger t_upd_interviews before update on public.interviews for each row execute function public.set_updated_at();

-- ---------- Safe view for companies (no salary, no phone, no private data) ----------
create view public.company_candidate_cards as
select n.id as nomination_id, n.request_id, c.id as candidate_id,
       c.full_name, c.photo_path, c.nationality, c.is_jordanian, c.governorate, c.city,
       s.name_ar as sector_ar, s.name_en as sector_en,
       jt.name_ar as title_ar, jt.name_en as title_en, c.other_title_text,
       c.level, c.years_experience, c.summary, c.skills, c.verified_badge,
       n.status, n.candidate_currently_employed, n.candidate_available_from
from public.nominations n
join public.hiring_requests r on r.id = n.request_id
join public.candidates c on c.id = n.candidate_id
left join public.sectors s on s.id = c.sector_id
left join public.job_titles jt on jt.id = c.job_title_id
where n.status not in ('proposed','candidate_declined')
  and r.company_id in (select public.my_company_ids());

-- ---------- Row Level Security ----------
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;

revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
revoke all on public.company_candidate_cards from anon;
grant select on public.company_candidate_cards to authenticated;

-- Staff (admin + coordinator) can do everything on operational tables
do $$
declare t text;
begin
  foreach t in array array[
    'sectors','job_titles','companies','company_members','institutions','institution_members',
    'candidates','candidate_experiences','candidate_education','candidate_references','candidate_support',
    'candidate_documents','exam_attempts','hiring_requests','subscriptions','nominations','nomination_internal',
    'interview_slots','interviews','evaluations','followups','replacement_requests','messages','ideas',
    'support_tickets','stories','notifications']
  loop
    execute format('create policy staff_all on public.%I for all to authenticated using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
end $$;

-- profiles
create policy profiles_select_self on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_select_staff on public.profiles for select to authenticated using (public.is_staff());
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_admin_all on public.profiles for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- lists
create policy sectors_read on public.sectors for select to authenticated using (true);
create policy titles_read on public.job_titles for select to authenticated using (status = 'approved' or suggested_by = auth.uid());
create policy titles_suggest on public.job_titles for insert to authenticated with check (status = 'pending' and suggested_by = auth.uid());

-- companies (writes go through staff or server code)
create policy companies_read on public.companies for select to authenticated using (id in (select public.my_company_ids()));
create policy members_read on public.company_members for select to authenticated using (profile_id = auth.uid());

-- candidates: self
create policy cand_self_select on public.candidates for select to authenticated using (profile_id = auth.uid());
create policy cand_self_insert on public.candidates for insert to authenticated
  with check (profile_id = auth.uid() and public.current_user_role() = 'candidate');
create policy cand_self_update on public.candidates for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
-- candidates: registrar (assisted registration of people without a login)
create policy cand_reg_select on public.candidates for select to authenticated
  using (registered_by = auth.uid() and public.current_user_role() = 'registrar');
create policy cand_reg_insert on public.candidates for insert to authenticated
  with check (registered_by = auth.uid() and public.current_user_role() = 'registrar');
create policy cand_reg_update on public.candidates for update to authenticated
  using (registered_by = auth.uid() and public.current_user_role() = 'registrar')
  with check (registered_by = auth.uid() and public.current_user_role() = 'registrar');

-- candidate child tables: owner and registrar can manage; companies can read only what is safe
do $$
declare t text;
begin
  foreach t in array array['candidate_experiences','candidate_education','candidate_references','candidate_support','candidate_documents']
  loop
    execute format('create policy own_all on public.%I for all to authenticated using (candidate_id = public.my_candidate_id()) with check (candidate_id = public.my_candidate_id())', t);
    execute format('create policy registrar_all on public.%I for all to authenticated using (public.registrar_owns_candidate(candidate_id)) with check (public.registrar_owns_candidate(candidate_id))', t);
  end loop;
end $$;
create policy exp_company_read on public.candidate_experiences for select to authenticated using (public.company_can_see_candidate(candidate_id));
create policy edu_company_read on public.candidate_education for select to authenticated using (public.company_can_see_candidate(candidate_id));
create policy ref_company_read on public.candidate_references for select to authenticated
  using (permission_confirmed and public.company_can_see_candidate(candidate_id));
create policy support_company_read on public.candidate_support for select to authenticated
  using (share_with_company and public.company_can_see_candidate(candidate_id));
create policy exam_self_read on public.exam_attempts for select to authenticated using (candidate_id = public.my_candidate_id());

-- hiring requests and subscriptions (company side)
create policy req_select on public.hiring_requests for select to authenticated using (company_id in (select public.my_company_ids()));
create policy req_insert on public.hiring_requests for insert to authenticated with check (
  company_id in (select public.my_company_ids()) and status in ('draft','submitted')
  and exists (select 1 from public.companies c where c.id = company_id and c.status = 'approved'));
create policy req_update_draft on public.hiring_requests for update to authenticated
  using (company_id in (select public.my_company_ids()) and status = 'draft')
  with check (company_id in (select public.my_company_ids()) and status in ('draft','submitted'));
create policy req_delete_draft on public.hiring_requests for delete to authenticated
  using (company_id in (select public.my_company_ids()) and status = 'draft');
create policy subs_select on public.subscriptions for select to authenticated using (company_id in (select public.my_company_ids()));

-- nominations and interviews (status changes are made by server code or staff)
create policy nom_select on public.nominations for select to authenticated using (public.can_access_nomination(id));
create policy slots_select on public.interview_slots for select to authenticated using (public.can_access_nomination(nomination_id));
create policy slots_insert on public.interview_slots for insert to authenticated
  with check (proposed_by = auth.uid() and public.can_access_nomination(nomination_id));
create policy interviews_select on public.interviews for select to authenticated using (public.can_access_nomination(nomination_id));

-- evaluations: each side sees only its own evaluation
create policy eval_select_own on public.evaluations for select to authenticated using (evaluator_id = auth.uid());
create policy eval_insert_own on public.evaluations for insert to authenticated
  with check (evaluator_id = auth.uid() and public.can_access_interview(interview_id));

-- follow-ups: each side sees only its own row
create policy followups_select on public.followups for select to authenticated using (public.is_my_followup(nomination_id, role));

-- replacement requests: company side only
create policy repl_select on public.replacement_requests for select to authenticated using (
  exists (select 1 from public.subscriptions s where s.id = subscription_id and s.company_id in (select public.my_company_ids())));

-- chat: only after the company accepted the candidate
create policy msg_select on public.messages for select to authenticated using (public.can_access_nomination(nomination_id));
create policy msg_insert on public.messages for insert to authenticated with check (
  sender_id = auth.uid() and public.can_access_nomination(nomination_id)
  and exists (select 1 from public.nominations n where n.id = nomination_id
              and n.status in ('company_accepted','interview_scheduled','interview_done')));

-- community and support
create policy ideas_select on public.ideas for select to authenticated using (profile_id = auth.uid());
create policy ideas_insert on public.ideas for insert to authenticated with check (profile_id = auth.uid());
create policy tickets_select on public.support_tickets for select to authenticated using (profile_id = auth.uid());
create policy tickets_insert on public.support_tickets for insert to authenticated with check (profile_id = auth.uid());
create policy stories_read on public.stories for select to authenticated using (published);

-- notifications and push tokens
create policy notif_select on public.notifications for select to authenticated using (profile_id = auth.uid());
create policy notif_update on public.notifications for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy push_own on public.push_subscriptions for all to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- audit log: admin read only; writes happen only through triggers and log_event()
create policy audit_admin_read on public.audit_log for select to authenticated using (public.is_admin());
