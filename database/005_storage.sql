-- =====================================================================
-- Jobs Platform (Jordan) - migration 005: private file storage
-- Creates the private bucket for candidate and company files, with permissions.
-- Run ONCE in Supabase SQL Editor, AFTER 004. It is separate so a storage permission problem cannot block 004.
-- =====================================================================

-- Folder layout inside the bucket:  candidates/<candidate_id>/...   (photo, CV, payment proof)
--                                   companies/<company_id>/...      (commercial registration)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('private-files', 'private-files', false, 5242880,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create or replace function public.storage_path_ok(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if parts[2] is null or parts[2] !~ '^[0-9a-fA-F-]{36}$' then return false; end if;
  if parts[1] = 'candidates' then
    return public.my_candidate_id() = parts[2]::uuid or public.registrar_owns_candidate(parts[2]::uuid);
  elsif parts[1] = 'companies' then
    return parts[2]::uuid in (select public.my_company_ids());
  end if;
  return false;
end $$;

drop policy if exists pf_staff_all on storage.objects;
create policy pf_staff_all on storage.objects for all to authenticated
  using (bucket_id = 'private-files' and public.is_staff())
  with check (bucket_id = 'private-files' and public.is_staff());
drop policy if exists pf_owner_read on storage.objects;
create policy pf_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'private-files' and public.storage_path_ok(name));
drop policy if exists pf_owner_upload on storage.objects;
create policy pf_owner_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'private-files' and public.storage_path_ok(name));
-- No update/delete for owners: uploaded proofs cannot be swapped afterwards. Only staff can remove files.
