-- =====================================================================
-- Jobs Platform: DEMO data (fake companies, candidates, requests, payments)
-- Purpose: see the admin pages with numbers. Safe to delete: run demo_cleanup.sql.
-- Run AFTER 001, 002 and 003. Run ONCE (it stops with a message if demo data already exists).
-- All demo companies end with "(demo)" and all demo candidates have phones starting +9627990000.
-- =====================================================================

begin;

do $$ begin
  if exists (select 1 from public.companies where name like '% (demo)') then
    raise exception 'Demo data already exists. Run demo_cleanup.sql first.';
  end if;
end $$;

-- lookup helpers (they disappear when this run ends)
create function pg_temp.t(n text) returns uuid language sql as $$ select id from public.job_titles where name_en = n order by created_at limit 1 $$;
create function pg_temp.s(n text) returns uuid language sql as $$ select id from public.sectors where name_en = n $$;
create function pg_temp.c(n text) returns uuid language sql as $$ select id from public.companies where name = n $$;
create function pg_temp.k(p text) returns uuid language sql as $$ select id from public.candidates where phone = p $$;
create function pg_temp.r(co text, ti text) returns uuid language sql as $$
  select r.id from public.hiring_requests r join public.job_titles j on j.id = r.job_title_id
  join public.companies c on c.id = r.company_id where c.name = co and j.name_en = ti limit 1 $$;
create function pg_temp.n(co text, ti text, p text) returns uuid language sql as $$
  select id from public.nominations where request_id = pg_temp.r(co, ti) and candidate_id = pg_temp.k(p) $$;
create function pg_temp.adm() returns uuid language sql as $$ select id from public.profiles where role = 'admin' order by created_at limit 1 $$;

-- give the admin a display name so the "coordinator" column is readable
update public.profiles set full_name = 'Admin' where id = pg_temp.adm() and coalesce(full_name, '') = '';

-- ---------- Companies ----------
insert into public.companies (name, sector_id, status, reg_check, commercial_reg_file, rejection_reason, departments, employees_count, established_year) values
 ('Arab National Bank (demo)',  pg_temp.s('Banking & Insurance'), 'approved','verified','demo/anb.pdf', null, '{Finance,Operations}', 900, 1990),
 ('Zain Jordan (demo)',         pg_temp.s('IT'),                  'approved','verified','demo/zain.pdf', null, '{IT,Sales}', 1200, 1999),
 ('Aramex Jordan (demo)',       pg_temp.s('Logistics, Transport & Warehousing'), 'approved','verified','demo/aramex.pdf', null, '{Logistics}', 600, 1982),
 ('Orange Jordan (demo)',       pg_temp.s('Sales & Marketing'),   'approved','verified','demo/orange.pdf', null, '{Sales,Design}', 800, 2000),
 ('Jordan Hospital (demo)',     pg_temp.s('Healthcare'),          'approved','verified','demo/hospital.pdf', null, '{Nursing,Admin}', 700, 1982),
 ('Al-Safwa Group (demo)',      pg_temp.s('Construction'),        'approved','verified','demo/safwa.pdf', null, '{Projects}', 350, 2005),
 ('Talabat Jordan (demo)',      pg_temp.s('Logistics, Transport & Warehousing'), 'approved','verified','demo/talabat.pdf', null, '{Delivery}', 400, 2015),
 ('Petra Hotels (demo)',        pg_temp.s('Tourism, Hospitality & Restaurants'), 'approved','verified','demo/petra.pdf', null, '{Hospitality}', 250, 1998),
 ('Delta Trading (demo)',       pg_temp.s('Retail'),              'suspended','verified','demo/delta.pdf', null, '{Sales}', 60, 2010),
 ('Makani Real Estate (demo)',  pg_temp.s('Retail'),              'pending','to_review','demo/makani.pdf', null, '{Sales}', 40, 2018),
 ('Al-Noor Clinic (demo)',      pg_temp.s('Healthcare'),          'pending','verified','demo/noor.pdf', null, '{Nursing}', 25, 2016),
 ('Sunrise Factory (demo)',     pg_temp.s('Manufacturing & Production'), 'pending','missing', null, null, '{Production}', 120, 2012),
 ('Unreadable Co (demo)',       pg_temp.s('Retail'),              'rejected','missing', null, 'Commercial registration file is unreadable', '{}', 10, 2020);

insert into public.subscriptions (company_id, status, plan, starts_on, ends_on, fee_jd, first_hire_at)
select pg_temp.c(v.n), v.st::public.subscription_status, v.pl, current_date + v.s_off, case when v.e_off is null then null else current_date + v.e_off end, v.fee, now() - interval '30 days'
from (values
 ('Arab National Bank (demo)','active','yearly', -285, 80, 100),
 ('Zain Jordan (demo)','active','six_months', -60, 120, 50),
 ('Aramex Jordan (demo)','trial','trial', -20, null, null),
 ('Orange Jordan (demo)','active','six_months', -140, 40, 50),
 ('Jordan Hospital (demo)','active','yearly', -165, 200, 100),
 ('Al-Safwa Group (demo)','active','six_months', -120, 60, 50),
 ('Talabat Jordan (demo)','expired','six_months', -200, -15, 50),
 ('Petra Hotels (demo)','trial','trial', -10, null, null),
 ('Delta Trading (demo)','active','six_months', -90, 90, 50)
) as v(n, st, pl, s_off, e_off, fee);

-- ---------- Candidates (the newer the later in the list, so the CV queue shows the newest) ----------
insert into public.candidates
 (full_name, phone, nationality, is_jordanian, governorate, city, sector_id, job_title_id, level, years_experience, summary, skills,
  expected_salary_min, expected_salary_max, profile_completion, verified_badge, no_show_count, paid_at, blocked_until, blocked_reason,
  data_consent_at, phone_verified_at, created_at)
select v.name, v.phone, v.nat, v.nat = 'Jordanian', v.city, v.city, pg_temp.s(v.sec), pg_temp.t(v.title), v.lvl::public.level_type, v.yrs, v.summary, v.skills::text[],
  v.smin, v.smax, v.compl, v.badge, v.ns, case when v.paid then now() - interval '3 days' else null end,
  case when v.ns >= 2 then now() + interval '10 days' else null end, case when v.ns >= 2 then 'Two interview no-shows' else null end,
  now() - interval '5 days', now() - interval '5 days', now() - ((20 - v.i) || ' hours')::interval
from (values
 (1, 'Ahmad Al-Khaled','+962799000001','Jordanian','Amman','IT','Network Administrator','senior',6,'Network engineer with 6 years managing enterprise networks.','{Cisco,Firewalls,VPN,CCNA}',900,1100,95,true,0,true),
 (2, 'Samar Al-Ali','+962799000002','Egyptian','Zarqa','Accounting & Finance','Accountant','senior',6,'Senior accountant, IFRS and payroll.','{QuickBooks,Excel,IFRS}',650,750,92,true,0,true),
 (3, 'Khaled Al-Matar','+962799000003','Jordanian','Irbid','Sales & Marketing','Sales Representative','junior',2,'Field sales representative.','{CRM,B2B Sales}',450,550,70,false,1,false),
 (4, 'Nour Al-Hassan','+962799000004','Jordanian','Amman','Healthcare','Nurse','mid',3,'Registered nurse, ICU and pediatrics.','{ICU,Pediatrics,First Aid}',550,650,90,false,0,true),
 (5, 'Omar Al-Bakri','+962799000005','Jordanian','Aqaba','Engineering','Civil Engineer','senior',7,'Site civil engineer on large projects.','{AutoCAD,Project Management}',1000,1200,88,true,0,true),
 (6, 'Rania Abdallah','+962799000006','Jordanian','Amman','HR & Administration','HR Officer','mid',5,'HR officer: recruitment and payroll.','{Recruitment,Payroll}',700,800,75,false,0,false),
 (7, 'Yousef Nasser','+962799000007','Jordanian','Salt','Logistics, Transport & Warehousing','Delivery Driver','junior',1,'Delivery driver with own license.','{Driving}',330,380,60,false,2,false),
 (8, 'Lina Haddad','+962799000008','Jordanian','Amman','Design & Creative','Graphic Designer','mid',3,'Graphic designer for brands and social media.','{Photoshop,Illustrator}',500,600,90,false,1,true),
 (9, 'محمود عويس','+962799000009','Jordanian','Aqaba','Trades & Technicians','Electrician','mid',8,'كهربائي بخبرة ٨ سنوات في التمديدات المنزلية والصناعية.','{تمديدات,لوحات كهرباء,صيانة}',600,700,85,false,0,true),
 (10,'سامر الخطيب','+962799000010','Jordanian','Irbid','Trades & Technicians','Plumber','junior',3,'سباك صحي بخبرة ٣ سنوات.','{تمديدات صحية,صيانة}',400,500,70,false,0,false),
 (11,'رامي الحوراني','+962799000011','Jordanian','Zarqa','Construction','Mason','mid',5,'بنّاء بخبرة ٥ سنوات.','{بناء,لياسة}',450,550,65,false,0,false),
 (12,'Hala Mansour','+962799000012','Jordanian','Amman','Tourism, Hospitality & Restaurants','Hotel Receptionist','junior',2,'Front desk, English and Arabic.','{Opera,Customer Care}',400,480,72,false,0,false),
 (13,'Tariq Salameh','+962799000013','Jordanian','Amman','Retail','Cashier','fresh',0,'Fresh graduate, cashier.','{POS}',300,350,55,false,0,false),
 (14,'Dina Qasem','+962799000014','Jordanian','Amman','IT','Software Developer','mid',4,'Full-stack developer.','{JavaScript,React,Node.js}',900,1100,93,true,0,true),
 (15,'Basel Odeh','+962799000015','Jordanian','Zarqa','Logistics, Transport & Warehousing','Warehouse Worker','fresh',1,'Warehouse worker, forklift trained.','{Forklift,Inventory}',320,360,58,false,0,false),
 (16,'Maha Saleh','+962799000016','Jordanian','Irbid','Education & Training','Teacher','junior',2,'Primary school teacher.','{Teaching,Classroom Management}',380,450,66,false,0,false)
) as v(i, name, phone, nat, city, sec, title, lvl, yrs, summary, skills, smin, smax, compl, badge, ns, paid);

insert into public.candidate_documents (candidate_id, kind, language, file_path)
select pg_temp.k(p), 'generated_cv', l, 'demo/cv-' || right(p, 2) || '.pdf'
from (values ('+962799000001','en'),('+962799000002','en'),('+962799000004','en'),('+962799000005','en'),('+962799000008','en'),('+962799000009','ar'),('+962799000014','en')) as d(p, l);

-- ---------- Hiring requests ----------
insert into public.hiring_requests (company_id, job_title_id, level, positions_count, status, is_urgent, assigned_to, location, created_at, submitted_at)
select pg_temp.c(v.co), pg_temp.t(v.ti), v.lvl::public.level_type, v.pos, v.st::public.request_status, v.urg,
       case when v.assigned then pg_temp.adm() else null end, 'Amman',
       now() - (v.d || ' days')::interval, now() - (v.d || ' days')::interval
from (values
 ('Arab National Bank (demo)','Accountant','senior',1,'submitted',true,false,0),
 ('Zain Jordan (demo)','Network Administrator','mid',2,'submitted',false,false,1),
 ('Orange Jordan (demo)','Sales Representative','junior',3,'submitted',false,false,2),
 ('Aramex Jordan (demo)','Delivery Driver','junior',5,'matching',false,true,3),
 ('Al-Safwa Group (demo)','Civil Engineer','senior',1,'matching',true,true,4),
 ('Petra Hotels (demo)','Chef','mid',2,'matching',false,true,5),
 ('Jordan Hospital (demo)','Nurse','mid',5,'shortlist_sent',false,true,6),
 ('Zain Jordan (demo)','Software Developer','senior',1,'shortlist_sent',false,true,7),
 ('Arab National Bank (demo)','Cashier','fresh',2,'interviews',false,true,9),
 ('Jordan Hospital (demo)','Receptionist','junior',1,'interviews',false,true,10),
 ('Talabat Jordan (demo)','Delivery Driver','junior',4,'closed',false,true,40),
 ('Petra Hotels (demo)','Hotel Receptionist','junior',1,'closed',false,true,45)
) as v(co, ti, lvl, pos, st, urg, assigned, d);

-- three hired requests: the hire happens this month so the dashboard shows hires and average time
insert into public.hiring_requests (company_id, job_title_id, level, positions_count, status, assigned_to, location, created_at, submitted_at)
select pg_temp.c(v.co), pg_temp.t(v.ti), v.lvl::public.level_type, v.pos, 'hired', pg_temp.adm(), 'Amman',
       h.at - (v.span + 1 || ' days')::interval, h.at - (v.span || ' days')::interval
from (values ('Orange Jordan (demo)','Graphic Designer','mid',1,11, interval '2 days'),
             ('Al-Safwa Group (demo)','Electrician','mid',2,9, interval '5 days'),
             ('Aramex Jordan (demo)','Warehouse Worker','fresh',3,14, interval '1 day')) as v(co, ti, lvl, pos, span, back)
cross join lateral (select greatest(now() - v.back, date_trunc('month', now()) + interval '2 hours') as at) h;

-- ---------- Nominations and interviews ----------
insert into public.nominations (request_id, candidate_id, status, proposed_by, candidate_consent_at, candidate_currently_employed, candidate_available_from, hired_at, start_date, probation_months)
select pg_temp.r(v.co, v.ti), pg_temp.k(v.p), v.st::public.nomination_status, pg_temp.adm(), now() - interval '4 days', false, current_date + 14,
       case when v.st = 'hired' then greatest(now() - v.back, date_trunc('month', now()) + interval '2 hours') else null end,
       case when v.st = 'hired' then current_date + 14 else null end, case when v.st = 'hired' then 3 else null end
from (values
 ('Jordan Hospital (demo)','Nurse','+962799000004','candidate_accepted', interval '0 days'),
 ('Zain Jordan (demo)','Software Developer','+962799000014','candidate_accepted', interval '0 days'),
 ('Arab National Bank (demo)','Cashier','+962799000013','interview_scheduled', interval '0 days'),
 ('Jordan Hospital (demo)','Receptionist','+962799000012','interview_scheduled', interval '0 days'),
 ('Orange Jordan (demo)','Graphic Designer','+962799000008','hired', interval '2 days'),
 ('Al-Safwa Group (demo)','Electrician','+962799000009','hired', interval '5 days'),
 ('Aramex Jordan (demo)','Warehouse Worker','+962799000015','hired', interval '1 day'),
 ('Talabat Jordan (demo)','Delivery Driver','+962799000007','not_hired', interval '0 days')
) as v(co, ti, p, st, back);

insert into public.interviews (nomination_id, starts_at, ends_at, platform, meeting_url, status, candidate_confirmed_at, company_confirmed_at)
select pg_temp.n(v.co, v.ti, v.p), v.at, v.at + interval '45 minutes', 'google_meet', 'https://meet.google.com/demo-' || right(v.p, 2), v.st::public.interview_status,
       case when v.st in ('confirmed','done') then now() - interval '1 day' else null end, case when v.st in ('confirmed','done') then now() - interval '1 day' else null end
from (values
 ('Jordan Hospital (demo)','Receptionist','+962799000012', date_trunc('day', now()) + interval '11 hours', 'scheduled'),
 ('Arab National Bank (demo)','Cashier','+962799000013', date_trunc('day', now()) + interval '1 day 8 hours', 'confirmed'),
 ('Orange Jordan (demo)','Graphic Designer','+962799000008', now() - interval '12 days', 'done'),
 ('Al-Safwa Group (demo)','Electrician','+962799000009', now() - interval '14 days', 'done'),
 ('Aramex Jordan (demo)','Warehouse Worker','+962799000015', now() - interval '17 days', 'done'),
 ('Talabat Jordan (demo)','Delivery Driver','+962799000007', now() - interval '30 days', 'candidate_no_show')
) as v(co, ti, p, at, st);

-- ---------- Candidate payments (manual CliQ / bank transfers) ----------
insert into public.payments (candidate_id, amount_jd, method, transfer_ref, proof_path, status, reject_reason, confirmed_by, confirmed_at, created_at)
select pg_temp.k(v.p), 5, v.m, v.tr, v.pr, v.st, v.rr,
       case when v.st = 'confirmed' then pg_temp.adm() else null end, case when v.st = 'confirmed' then now() - interval '3 days' else null end,
       now() - (v.d || ' days')::interval
from (values
 ('+962799000001','cliq','CLQ-10001','demo/proof-01.png','confirmed',null,8), ('+962799000002','bank','TRF-20231','demo/proof-02.png','confirmed',null,8),
 ('+962799000004','cliq','CLQ-10042','demo/proof-04.png','confirmed',null,7), ('+962799000005','cliq','CLQ-10077','demo/proof-05.png','confirmed',null,7),
 ('+962799000008','bank','TRF-20310',null,'confirmed',null,6), ('+962799000009','cliq','CLQ-10102','demo/proof-09.png','confirmed',null,6),
 ('+962799000014','cliq','CLQ-10130','demo/proof-14.png','confirmed',null,5),
 ('+962799000003','cliq','CLQ-10188','demo/proof-03.png','pending',null,0), ('+962799000006','bank',null,null,'pending',null,1),
 ('+962799000010','cliq','CLQ-10190','demo/proof-10.png','pending',null,2),
 ('+962799000016','bank','TRF-20999',null,'rejected','Amount does not match the bank statement',4)
) as v(p, m, tr, pr, st, rr, d);

commit;
