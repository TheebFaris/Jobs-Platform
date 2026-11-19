-- Removes ONLY the demo data created by demo_data.sql (companies ending in "(demo)" and candidates with phone +9627990000..).
-- Related requests, nominations, interviews, payments, subscriptions and documents are removed automatically.
delete from public.companies where name like '% (demo)';
delete from public.candidates where phone like '+9627990000%';
