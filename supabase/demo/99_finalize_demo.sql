-- =============================================================================
-- DOKONČENÍ DEMA — běží jako poslední část demo_setup.sql
-- =============================================================================
-- Reset smazal schéma public (a s ním profily a role), ale účty v auth.users,
-- které si někdo v demu založil sám, zůstaly. Bez profilu a role by se sice
-- přihlásili, ale aplikace by je nikam nepustila — tak jim je doplníme.
-- =============================================================================

INSERT INTO public.profiles (user_id, full_name)
SELECT u.id, COALESCE(u.raw_user_meta_data ->> 'full_name', split_part(u.email, '@', 1))
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = u.id);

INSERT INTO public.user_roles (user_id, role)
SELECT u.id, 'hobby_player'
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = u.id)
ON CONFLICT (user_id, role) DO NOTHING;

DO $$
DECLARE _uzivatelu int; _rezervaci int; _drah int;
BEGIN
  SELECT count(*) INTO _uzivatelu FROM auth.users;
  SELECT count(*) INTO _rezervaci FROM public.reservations WHERE status = 'confirmed';
  SELECT count(*) INTO _drah FROM public.sheets;
  RAISE NOTICE 'DEMO připraveno: % uživatelů, % potvrzených rezervací, % dráhy.', _uzivatelu, _rezervaci, _drah;
END $$;
