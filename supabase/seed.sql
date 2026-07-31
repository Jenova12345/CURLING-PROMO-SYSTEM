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
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '55555555-5555-5555-5555-555555555555',
   'authenticated', 'authenticated', 'clen2@test.local',
   extensions.crypt('Heslo1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Test Clen2 (člen)"}',
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
   now(), now(), now()),
  ('55555555-5555-5555-5555-555555555555', '55555555-5555-5555-5555-555555555555',
   '{"sub":"55555555-5555-5555-5555-555555555555","email":"clen2@test.local"}', 'email',
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

-- =============================================================================
-- Etapa 1 — FIKTIVNÍ rezervační data (jen lokál)
-- =============================================================================

-- Placeholder ceník JEN pro lokál (v produkci sazby nastaví admin; migrace je nechá NULL)
UPDATE public.settings SET club_default_rate = 500, commercial_default_rate = 1000;

-- Subjekty: 2 kluby + 1 komerční (IČO/DIČ fiktivní)
INSERT INTO public.subjects (id, type, name, ico, dic, address, default_rate) VALUES
  ('aaaa1111-0000-0000-0000-000000000001', 'club', 'Curling Promo Ostrava', NULL, NULL, NULL, NULL),
  ('aaaa1111-0000-0000-0000-000000000002', 'club', 'Curling Ostrava', NULL, NULL, NULL, 450),
  ('bbbb2222-0000-0000-0000-000000000001', 'commercial', 'Testovací Firma s.r.o.',
   '00000019', 'CZ00000019', 'Testovací 1, 700 30 Ostrava', NULL);

-- Zástupci klubů (napojení na testovací uživatele z části výše)
--   clen@test.local (4444…)  → Curling Promo Ostrava
--   instruktor@test.local (2222…) → Curling Ostrava (pro test izolace mezi kluby)
--   clen  = ZÁSTUPCE (rep) CPO, instruktor = zástupce Curling Ostrava, clen2 = ČLEN (member) CPO
INSERT INTO public.subject_reps (subject_id, user_id, level) VALUES
  ('aaaa1111-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'rep'),
  ('aaaa1111-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'rep'),
  ('aaaa1111-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555', 'member');

-- Rezervace (rate_per_hour necháme na triggeru — vezme default_rate subjektu ?? ceník).
-- Dráhy referencujeme podle jména (jejich UUID generuje migrace).
INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, status, note) VALUES
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 1'),
   'aaaa1111-0000-0000-0000-000000000001', '2026-07-20 10:00+02', '2026-07-20 11:00+02', 'confirmed', 'CPO trénink'),
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 2'),
   'aaaa1111-0000-0000-0000-000000000002', '2026-07-20 10:00+02', '2026-07-20 11:00+02', 'confirmed', 'Curling Ostrava trénink'),
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 1'),
   'bbbb2222-0000-0000-0000-000000000001', '2026-07-20 14:00+02', '2026-07-20 15:00+02', 'confirmed', 'Firemní akce'),
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 1'),
   'aaaa1111-0000-0000-0000-000000000001', '2026-07-20 12:00+02', '2026-07-20 13:00+02', 'cancelled', 'Zrušený test');

-- Sjednocený kalendář: akce navázané na rezervaci ledu (test event_id vazby)
--   interní trénink (bez fakturačního subjektu) + komerční akce (trigger vygeneruje směnu)
INSERT INTO public.events (id, title, event_type, start_time, end_time, required_staff, role_reqs) VALUES
  ('cccc3333-0000-0000-0000-000000000001', 'Trénink CPO', 'training',
   '2026-07-21 16:00+02', '2026-07-21 17:00+02', 0, '{}'::jsonb),
  ('cccc3333-0000-0000-0000-000000000002', 'Firemní teambuilding', 'commercial',
   '2026-07-21 09:00+02', '2026-07-21 11:00+02', 1, '{"instructor": 1}'::jsonb);

-- Navázané rezervace ledu. Seed běží jako postgres (ne-admin kontext) → guard by event_id
-- vynuloval; pro tyto důvěryhodné seed řádky ho dočasně vypneme (pricing dál běží).
ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_a_guard;
INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note) VALUES
  -- interní rezervace ledu pro trénink (subject NULL = neúčtuje se)
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 2'), NULL,
   'cccc3333-0000-0000-0000-000000000001', '2026-07-21 16:00+02', '2026-07-21 17:00+02', 'Trénink (interní)'),
  -- komerční rezervace ledu navázaná na akci se štábem
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 1'), 'bbbb2222-0000-0000-0000-000000000001',
   'cccc3333-0000-0000-0000-000000000002', '2026-07-21 09:00+02', '2026-07-21 11:00+02', 'Komerční akce vč. štábu');
-- Klubová rezervace vytvořená ČLENEM (clen2) — test „člen edituje jen svou"; created_by explicitně.
INSERT INTO public.reservations (sheet_id, subject_id, created_by, start_at, end_at, note) VALUES
  ((SELECT id FROM public.sheets WHERE name = 'Dráha 1'), 'aaaa1111-0000-0000-0000-000000000001',
   '55555555-5555-5555-5555-555555555555', '2026-07-23 09:00+02', '2026-07-23 10:00+02', 'rezervace člena CPO');
ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_a_guard;

-- =============================================================================
-- BOHATÝ DEMO SEED (fiktivní) — ať kalendář i „kdo kolik dluží" vypadají živě
-- =============================================================================

-- Realistické výchozí sazby (ať výpočet nedává nuly)
UPDATE public.settings SET club_default_rate = 600, commercial_default_rate = 1500;

-- Další subjekty: 2 kluby + 1 komerční
INSERT INTO public.subjects (id, type, name, ico, dic, address, default_rate) VALUES
  ('aaaa1111-0000-0000-0000-000000000003', 'club', 'HC Ostrava', NULL, NULL, NULL, NULL),
  ('aaaa1111-0000-0000-0000-000000000004', 'club', 'TJ Poruba', NULL, NULL, NULL, 550),
  ('bbbb2222-0000-0000-0000-000000000002', 'commercial', 'Demo Firma s.r.o.', '12345678', 'CZ12345678', 'Hlavní 1, 700 30 Ostrava', NULL);

-- Týden klubových rezervací na obou dráhách (sazbu dopočítá trigger z ceníku/subjektu)
INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, note) VALUES
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'aaaa1111-0000-0000-0000-000000000001', '2026-07-27 08:00+02','2026-07-27 09:00+02','Trénink CPO'),
  ((SELECT id FROM public.sheets WHERE name='Dráha 2'), 'aaaa1111-0000-0000-0000-000000000002', '2026-07-27 08:00+02','2026-07-27 10:00+02','Curling Ostrava'),
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'aaaa1111-0000-0000-0000-000000000003', '2026-07-27 10:00+02','2026-07-27 11:00+02','HC Ostrava'),
  ((SELECT id FROM public.sheets WHERE name='Dráha 2'), 'aaaa1111-0000-0000-0000-000000000004', '2026-07-27 10:00+02','2026-07-27 12:00+02','TJ Poruba'),
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'aaaa1111-0000-0000-0000-000000000001', '2026-07-27 18:00+02','2026-07-27 19:00+02','CPO večer'),
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'aaaa1111-0000-0000-0000-000000000002', '2026-07-28 09:00+02','2026-07-28 10:00+02',''),
  ((SELECT id FROM public.sheets WHERE name='Dráha 2'), 'aaaa1111-0000-0000-0000-000000000003', '2026-07-28 17:00+02','2026-07-28 18:00+02',''),
  ((SELECT id FROM public.sheets WHERE name='Dráha 2'), 'aaaa1111-0000-0000-0000-000000000004', '2026-07-29 08:00+02','2026-07-29 09:00+02',''),
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'aaaa1111-0000-0000-0000-000000000001', '2026-07-30 16:00+02','2026-07-30 17:00+02',''),
  ((SELECT id FROM public.sheets WHERE name='Dráha 2'), 'aaaa1111-0000-0000-0000-000000000002', '2026-07-30 18:00+02','2026-07-30 19:00+02',''),
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'aaaa1111-0000-0000-0000-000000000003', '2026-07-31 09:00+02','2026-07-31 10:00+02',''),
  ((SELECT id FROM public.sheets WHERE name='Dráha 2'), 'aaaa1111-0000-0000-0000-000000000001', '2026-07-31 17:00+02','2026-07-31 18:00+02','CPO víkendová příprava');

-- Komerční akce s OBSAZENÍM (part filled) — event → trigger vytvoří 3 směny (2 instruktor, 1 bar)
INSERT INTO public.events (id, title, event_type, start_time, end_time, required_staff, role_reqs) VALUES
  ('cccc3333-0000-0000-0000-000000000003', 'Firemní teambuilding Demo', 'commercial',
   '2026-07-29 17:00+02', '2026-07-29 20:00+02', 3, '{"instructor": 2, "bar_staff": 1}');

ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_a_guard;
INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note) VALUES
  ((SELECT id FROM public.sheets WHERE name='Dráha 1'), 'bbbb2222-0000-0000-0000-000000000002',
   'cccc3333-0000-0000-0000-000000000003', '2026-07-29 17:00+02','2026-07-29 20:00+02','Demo Firma — akce se štábem');
ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_a_guard;

-- Obsazení: 1 instruktor potvrzen (instruktor@), 1 instruktor s čekající přihláškou (brigadnik@), bar volný
UPDATE public.shifts SET status='claimed', claimed_by='22222222-2222-2222-2222-222222222222', claimed_at=now()
  WHERE id = (SELECT id FROM public.shifts WHERE event_id='cccc3333-0000-0000-0000-000000000003' AND required_role='instructor' ORDER BY id LIMIT 1);
INSERT INTO public.shift_applications (shift_id, user_id, status) VALUES
  ((SELECT id FROM public.shifts WHERE event_id='cccc3333-0000-0000-0000-000000000003' AND required_role='instructor' AND status='claimed' LIMIT 1),
   '22222222-2222-2222-2222-222222222222', 'approved'),
  ((SELECT id FROM public.shifts WHERE event_id='cccc3333-0000-0000-0000-000000000003' AND required_role='instructor' AND status='open' ORDER BY id LIMIT 1),
   '33333333-3333-3333-3333-333333333333', 'pending');
