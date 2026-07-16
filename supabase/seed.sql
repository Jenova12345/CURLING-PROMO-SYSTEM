-- =============================================================================
-- SEED — FIKTIVNÍ testovací data pro LOKÁLNÍ vývoj
-- =============================================================================
-- ⚠️ Žádná reálná osoba, žádné reálné číslo účtu. Slouží jen pro lokální Supabase
-- (supabase db reset ho aplikuje po migracích). NIKDY nepouštět proti produkci.
--
-- Testovací účty (heslo pro všechny: Heslo1234):
--   admin@test.local       → role: admin      (+ hobby_player z triggeru)
--   instruktor@test.local  → role: instructor (+ hobby_player)
--   brigadnik@test.local   → role: part_time_staff (+ hobby_player)
--   clen@test.local        → role: hobby_player (běžný člen)
--
-- Uživatele vkládáme přímo do auth.users; trigger on_auth_user_created
-- (migrace 20260716120000) jim založí profil + výchozí roli hobby_player.
-- =============================================================================

-- 1) Auth uživatelé (heslo přes pgcrypto v schématu extensions)
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new, email_change
) VALUES
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
   'authenticated', 'authenticated', 'admin@test.local',
   extensions.crypt('Heslo1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Test Admin"}',
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
   'authenticated', 'authenticated', 'instruktor@test.local',
   extensions.crypt('Heslo1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Test Instruktor"}',
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333',
   'authenticated', 'authenticated', 'brigadnik@test.local',
   extensions.crypt('Heslo1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Test Brigadnik"}',
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444',
   'authenticated', 'authenticated', 'clen@test.local',
   extensions.crypt('Heslo1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Test Clen"}',
   '', '', '', '');

-- 2) Auth identities (potřebné pro e-mail/heslo login v GoTrue)
INSERT INTO auth.identities (
  provider_id, user_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
) VALUES
  ('11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   '{"sub":"11111111-1111-1111-1111-111111111111","email":"admin@test.local"}', 'email',
   now(), now(), now()),
  ('22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222',
   '{"sub":"22222222-2222-2222-2222-222222222222","email":"instruktor@test.local"}', 'email',
   now(), now(), now()),
  ('33333333-3333-3333-3333-333333333333', '33333333-3333-3333-3333-333333333333',
   '{"sub":"33333333-3333-3333-3333-333333333333","email":"brigadnik@test.local"}', 'email',
   now(), now(), now()),
  ('44444444-4444-4444-4444-444444444444', '44444444-4444-4444-4444-444444444444',
   '{"sub":"44444444-4444-4444-4444-444444444444","email":"clen@test.local"}', 'email',
   now(), now(), now());

-- 3) Doplňkové role (trigger už každému dal hobby_player)
INSERT INTO public.user_roles (user_id, role) VALUES
  ('11111111-1111-1111-1111-111111111111', 'admin'),
  ('22222222-2222-2222-2222-222222222222', 'instructor'),
  ('33333333-3333-3333-3333-333333333333', 'part_time_staff')
ON CONFLICT (user_id, role) DO NOTHING;

-- 4) Fiktivní kontaktní údaje v profilech (čísla účtů jsou vymyšlená)
UPDATE public.profiles SET phone = '+420700000001', bank_account = '1000000001/0800'
  WHERE user_id = '11111111-1111-1111-1111-111111111111';
UPDATE public.profiles SET phone = '+420700000002', bank_account = '1000000002/0800'
  WHERE user_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET phone = '+420700000003', bank_account = '1000000003/0800'
  WHERE user_id = '33333333-3333-3333-3333-333333333333';
UPDATE public.profiles SET phone = '+420700000004'
  WHERE user_id = '44444444-4444-4444-4444-444444444444';

-- 5) Jeden fiktivní testovací „klub" (chat_groups; prázdné authorized_roles = veřejné)
INSERT INTO public.chat_groups (name, description, whatsapp_url, authorized_roles)
VALUES ('Test Klub', 'Fiktivní testovací klub (seed)', 'https://example.com/test-klub', '{}');
