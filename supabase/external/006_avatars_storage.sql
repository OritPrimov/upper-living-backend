-- 006: public "avatars" bucket access.
-- The bucket itself was already created (public, 5MB, image/jpeg|png|webp).
-- This file only adds the storage.objects policies so a signed-in resident can
-- upload / replace their own profile photo. No schema changes.

-- Anyone may read avatars (bucket is public; this makes the API path explicit).
drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read"
on storage.objects for select
using (bucket_id = 'avatars');

-- A signed-in user may write only inside their own folder: avatars/<auth.uid()>/...
drop policy if exists "avatars own upload" on storage.objects;
create policy "avatars own upload"
on storage.objects for insert to authenticated
with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars own update" on storage.objects;
create policy "avatars own update"
on storage.objects for update to authenticated
using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars own delete" on storage.objects;
create policy "avatars own delete"
on storage.objects for delete to authenticated
using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
