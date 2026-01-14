-- Odstranit sloupec avatar_url z profiles
ALTER TABLE public.profiles DROP COLUMN IF EXISTS avatar_url;

-- Smazat storage objekty a policies pro avatary
DELETE FROM storage.objects WHERE bucket_id = 'avatars';
DELETE FROM storage.buckets WHERE id = 'avatars';