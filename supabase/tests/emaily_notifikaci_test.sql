-- =============================================================================
-- TESTY: e-mailové notifikace (migrace 20260911160000_emaily_notifikaci.sql)
-- =============================================================================
-- CO TENHLE SOUBOR HLÍDÁ. Pět tvrzení, každé ověřené mutací (vypnout opravu
-- v migraci → tenhle soubor zčervená):
--
--   1) matice: zakladatel dostane „čeká na potvrzení", správce „máš k potvrzení"
--   2) allowlist: typ mimo matici e-mail NEDOSTANE (žádný spam)
--   3) jedno upozornění = nejvýš jeden e-mail (pojistka proti dvojímu odeslání)
--   4) neplatná adresa se tiše přeskočí, není to chyba
--   5) `email_outbox_prevzit` je nedosažitelné z API (měřeno POD ROLÍ, ne jen
--      podle grantu) a převzatý řádek se podruhé nenabídne
--   6) rozpočet pokusů a úklid uvíznutých řádků
--   7) uživatelem nastavené jméno nepropašuje do e-mailu vlastní odstavec
--
-- POZOR NA PAST, KTERÁ UŽ JEDNOU UDĚLALA SOUSEDNÍ TEST FALEŠNĚ ZELENÝM:
-- upozornění na akci se posílá JEDNOU NA AKCI. Každý scénář má proto vlastní
-- rezervaci a vlastní termín.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_p boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_p, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

-- 55555555 = řadový člen CK Ostravské kameny (jeho rezervace čeká na potvrzení)
-- 44444444 = zástupce téhož klubu (potvrzuje)
CREATE OR REPLACE FUNCTION pg_temp.pocet(_kdo uuid, _typ text) RETURNS int
 LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.notifications WHERE user_id = _kdo AND type = _typ;
$$;

CREATE OR REPLACE FUNCTION pg_temp.posta(_kdo uuid) RETURNS int
 LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.email_outbox WHERE user_id = _kdo;
$$;

-- E-mail se hledá PŘES TYP UPOZORNĚNÍ, ne podle „posledního podle created_at".
-- `created_at` je čas ZAČÁTKU transakce, takže uvnitř jednoho testu mají
-- všechny řádky totéž razítko a „poslední" je náhodný.
CREATE OR REPLACE FUNCTION pg_temp.mail(_kdo uuid, _typ text)
 RETURNS TABLE (predmet text, telo text)
 LANGUAGE sql AS $$
  SELECT o.subject, o.body
    FROM public.email_outbox o
    JOIN public.notifications n ON n.id = o.notification_id
   WHERE o.user_id = _kdo AND n.type = _typ
   ORDER BY n.id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.rezervuj(_den date) RETURNS uuid
 LANGUAGE plpgsql AS $$
DECLARE _r jsonb;
BEGIN
  _r := public.create_booking(
    (SELECT array_agg(id) FROM (SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1) q),
    'training', 'TEST e-mail ' || _den,
    (_den + time '17:00') AT TIME ZONE 'Europe/Prague',
    (_den + time '19:00') AT TIME ZONE 'Europe/Prague',
    (SELECT id FROM public.subjects WHERE name = 'CK Ostravské kameny'));
  RETURN (_r -> 'reservation_ids' ->> 0)::uuid;
END $$;

-- Odesílání e-mailů zapínáme JEN uvnitř téhle transakce (končí ROLLBACKem).
UPDATE public.settings SET email_notifications_enabled = true;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota uuid);

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: akce vytvořena → zakladateli „čeká", správci „máš k potvrzení"
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _clen uuid := '55555555-5555-5555-5555-555555555555';
        _rep  uuid := '44444444-4444-4444-4444-444444444444';
        -- Seed uz nejake upozorneni obsahuje, takze se meri PRIRUSTEK.
        -- Absolutni cislo by tenhle test udelalo falesne zelenym i cervenym.
        _ceka_pred  int := pg_temp.pocet(_clen, 'reservation_pending');
        _rep_pred   int := pg_temp.pocet(_rep, 'reservation_needs_approval');
        _predmet text;
        _telo    text;
BEGIN
  INSERT INTO _s VALUES ('ceka', pg_temp.rezervuj(DATE '2028-12-04'));

  -- Tohle je ta část matice, která v systému CHYBĚLA: člen zadal rezervaci
  -- a nedozvěděl se, že do potvrzení neplatí.
  PERFORM pg_temp.tvrd(pg_temp.pocet(_clen, 'reservation_pending') = _ceka_pred + 1,
    'JÁDRO: zakladatel dostal „čeká na potvrzení správce"');
  PERFORM pg_temp.tvrd(pg_temp.pocet(_rep, 'reservation_needs_approval') = _rep_pred + 1,
    'JÁDRO: správce klubu dostal „máte rezervaci k potvrzení"');

  -- A oba dostali i e-mail, se šablonou (ne jen holý titulek upozornění).
  SELECT m.predmet, m.telo INTO _predmet, _telo
    FROM pg_temp.mail(_clen, 'reservation_pending') m;
  PERFORM pg_temp.tvrd(_predmet = 'Rezervace čeká na potvrzení správce klubu',
    'e-mail zakladatele má vlastní předmět ze šablony');
  -- Adresa se od 14. 9. 2026 bere z `settings.web_base_url`, ne z kódu, takže
  -- se sem nepíše natvrdo — jinak by test zčervenal při každé změně domény,
  -- a to z falešného důvodu.
  --
  -- `strpos`, NE `LIKE`: adresa je DATA, a v LIKE vzoru by z `_` a `%` byly
  -- divoké karty. Dnes to drží jen proto, že CHECK na `web_base_url` ani jeden
  -- z těch znaků nepustí — tedy náhodou, ne konstrukcí. Až se allowlist jednou
  -- rozšíří, tvrzení by tiše změklo. (Nález brány pro migrace.)
  PERFORM pg_temp.tvrd(_telo LIKE 'Dobrý den,%'
                   AND _telo LIKE '%04.12.2028 17:00%'
                   AND _telo LIKE '%Curling Promo Ostrava%'
                   AND strpos(_telo, (SELECT s.web_base_url FROM public.settings s
                                       WHERE s.singleton LIMIT 1) || '/calendar') > 0,
    'tělo e-mailu má oslovení, termín, odkaz i podpis');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: správce potvrdil → zakladateli „akce potvrzena"
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
DECLARE _clen uuid := '55555555-5555-5555-5555-555555555555';
        _pred int := pg_temp.pocet('55555555-5555-5555-5555-555555555555', 'reservation_approved');
        _predmet text;
BEGIN
  PERFORM public.approve_reservation((SELECT hodnota FROM _s WHERE klic='ceka'));

  PERFORM pg_temp.tvrd(pg_temp.pocet(_clen, 'reservation_approved') = _pred + 1,
    'JÁDRO: zakladatel dostal „rezervace je potvrzena"');

  SELECT m.predmet INTO _predmet FROM pg_temp.mail(_clen, 'reservation_approved') m;
  PERFORM pg_temp.tvrd(_predmet = 'Rezervace je potvrzena',
    'potvrzení jde i do pošty, s vlastním předmětem');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: allowlist — typ mimo matici e-mail NEDOSTANE
-- -----------------------------------------------------------------------------
-- Bez allowlistu by zapnutí e-mailů poslalo ven každou notifikaci v systému,
-- tedy i schválení žádosti o klub a cokoli, co vznikne příště.
DO $$
DECLARE _clen uuid := '55555555-5555-5555-5555-555555555555';
        _posta_pred int := pg_temp.posta(_clen);
        _notif_pred int := pg_temp.pocet(_clen, 'subject_request_approved');
BEGIN
  PERFORM public.notify_user(_clen, 'subject_request_approved',
    'Žádost o klub schválena', 'Vaše žádost byla schválena.', '/profile');

  PERFORM pg_temp.tvrd(pg_temp.pocet(_clen, 'subject_request_approved') = _notif_pred + 1,
    'typ mimo matici upozornění V APLIKACI pořád vyrobí');
  PERFORM pg_temp.tvrd(pg_temp.posta(_clen) = _posta_pred,
    'JÁDRO: typ mimo matici se do pošty NEDOSTANE (žádný spam)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) JÁDRO: jedno upozornění = nejvýš jeden e-mail
-- -----------------------------------------------------------------------------
DO $$
DECLARE _n uuid;
        _pred int;
BEGIN
  SELECT notification_id INTO _n FROM public.email_outbox
   WHERE notification_id IS NOT NULL LIMIT 1;
  PERFORM pg_temp.tvrd(_n IS NOT NULL, 'příprava: ve frontě je e-mail s upozorněním');

  SELECT count(*)::int INTO _pred FROM public.email_outbox;

  BEGIN
    INSERT INTO public.email_outbox (notification_id, user_id, email, subject, body)
    VALUES (_n, '55555555-5555-5555-5555-555555555555', 'a@b.cz', 'Kopie', 'Kopie');
    PERFORM pg_temp.tvrd(false, 'druhý e-mail k témuž upozornění NESMÍ projít');
  EXCEPTION WHEN unique_violation THEN
    NULL;  -- přesně tohle chceme
  END;

  PERFORM pg_temp.tvrd((SELECT count(*)::int FROM public.email_outbox) = _pred,
    'JÁDRO: jedno upozornění = nejvýš jeden e-mail');
END $$;

-- -----------------------------------------------------------------------------
-- 5) JÁDRO: neplatná / prázdná adresa se tiše přeskočí
-- -----------------------------------------------------------------------------
-- Dosud se hlídalo jen NULL a prázdno. „jan.novak" došla až k Resendu, ten ji
-- odmítl, a řádek se pak pětkrát marně opakoval a skončil jako `failed`,
-- tedy jako by šlo o poruchu pošty.
DO $$
DECLARE _bez uuid := '33333333-3333-3333-3333-333333333333';
        _pred int := pg_temp.posta(_bez);
        _id  uuid;
BEGIN
  UPDATE auth.users SET email = 'jan.novak' WHERE id = _bez;

  _id := public.notify_user(_bez, 'reservation_cancelled',
    'Rezervace byla zrušena', 'Vaši rezervaci zrušil správce haly.', '/calendar');

  PERFORM pg_temp.tvrd(_id IS NOT NULL,
    'upozornění v aplikaci vzniklo i s nesmyslnou adresou');
  PERFORM pg_temp.tvrd(pg_temp.posta(_bez) = _pred,
    'JÁDRO: nesmyslná adresa se do fronty nedostane a nic nespadne');

  UPDATE auth.users SET email = NULL WHERE id = _bez;
  PERFORM public.notify_user(_bez, 'reservation_cancelled',
    'Rezervace byla zrušena', 'Vaši rezervaci zrušil správce haly.', '/calendar');
  PERFORM pg_temp.tvrd(pg_temp.posta(_bez) = _pred,
    'prázdná adresa se do fronty nedostane a nic nespadne');
END $$;

-- -----------------------------------------------------------------------------
-- 6) JÁDRO: frontu smí převzít jen server
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  -- Granty. `anon` tu chybět nesmí: PostgREST volá RPC i nepřihlášeně.
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('authenticated', 'public.email_outbox_prevzit(int)', 'EXECUTE'),
    'JÁDRO: `authenticated` frontu převzít nesmí');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.email_outbox_prevzit(int)', 'EXECUTE'),
    '`anon` frontu převzít nesmí');
  PERFORM pg_temp.tvrd(
    has_function_privilege('service_role', 'public.email_outbox_prevzit(int)', 'EXECUTE'),
    'servisní role frontu převzít smí');
END $$;

-- Grant je jen papír. CLAUDE.md pravidlo 9: práva se měří POD TOU ROLÍ, která
-- jde z API. Jako `postgres` projde všechno, takže test tvrdí zavřeno o dveřích,
-- vedle kterých je otevřené okno.
DO $$
DECLARE _pusteno boolean := false;
BEGIN
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM * FROM public.email_outbox_prevzit(1);
    _pusteno := true;
  EXCEPTION WHEN insufficient_privilege THEN
    _pusteno := false;
  END;
  RESET ROLE;
  PERFORM pg_temp.tvrd(NOT _pusteno,
    'JÁDRO: pod rolí `authenticated` frontu převzít NELZE (ne jen podle grantu)');
END $$;

DO $$
DECLARE _pusteno boolean := false;
BEGIN
  SET LOCAL ROLE authenticated;
  BEGIN
    -- Fronta nese e-mailové adresy. Zápis do ní blokuje RLS i granty.
    INSERT INTO public.email_outbox (user_id, email, subject, body)
    VALUES ('55555555-5555-5555-5555-555555555555', 'utok@test.local', 'x', 'y');
    _pusteno := true;
  EXCEPTION WHEN insufficient_privilege OR sqlstate '42501' THEN
    _pusteno := false;
  END;
  RESET ROLE;
  PERFORM pg_temp.tvrd(NOT _pusteno,
    'JÁDRO: pod rolí `authenticated` do fronty ZAPSAT nelze');
END $$;

-- -----------------------------------------------------------------------------
-- 7) Převzatý řádek se podruhé nenabídne
-- -----------------------------------------------------------------------------
-- ⚠️ CO TENHLE TEST NEMĚŘÍ: skutečný SOUBĚH. Obě volání jedou v JEDNÉ session
-- a JEDNÉ transakci, takže `FOR UPDATE SKIP LOCKED` se tu nemá o co zaseknout.
-- Smaž `SKIP LOCKED` z `email_outbox_prevzit` a tenhle test zůstane zelený.
-- Měří jen to, co je v názvu: převzetí překlopí stav, takže druhý výběr
-- tytéž řádky nevidí.
--
-- Souběh dvou spojení se v jedné psql transakci zahrát nedá (druhá session by
-- nezakomitovaná data neviděla). Je na to `supabase/tests/emaily_fronta_zavod.sh`,
-- stejným vzorem jako ostatní `*_zavod.sh` v tomhle adresáři.
DO $$
DECLARE _prvni int;
        _druhy int;
BEGIN
  SELECT count(*)::int INTO _prvni FROM public.email_outbox_prevzit(50);
  PERFORM pg_temp.tvrd(_prvni > 0, 'příprava: první převzetí si vzalo dávku');

  SELECT count(*)::int INTO _druhy FROM public.email_outbox_prevzit(50);
  PERFORM pg_temp.tvrd(_druhy = 0,
    'JÁDRO: druhé převzetí už tytéž řádky nedostane');

  PERFORM pg_temp.tvrd(
    (SELECT count(*)::int FROM public.email_outbox WHERE status = 'sending') = _prvni
    AND (SELECT min(attempts) FROM public.email_outbox WHERE status = 'sending') = 1,
    'převzaté řádky mají stav `sending` a započítaný pokus');
END $$;

-- -----------------------------------------------------------------------------
-- 8) JÁDRO: rozpočet pokusů a úklid uvíznutých řádků
-- -----------------------------------------------------------------------------
-- Nejporuchovější část celé změny a dosud neměl jediné tvrzení.
DO $$
DECLARE _id uuid;
BEGIN
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, attempts)
  VALUES ('55555555-5555-5555-5555-555555555555', 'pokusy@test.local', 'x', 'y', 'pending', 4)
  RETURNING id INTO _id;

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.email_outbox_prevzit(200) p WHERE p.id = _id),
    'řádek se čtyřmi pokusy se ještě nabídne (pátý pokus)');

  UPDATE public.email_outbox SET status = 'pending' WHERE id = _id;   -- vrátil ho odesílač
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.email_outbox_prevzit(200) p WHERE p.id = _id),
    'JÁDRO: po pěti pokusech se řádek už nenabídne (fronta nebobtná donekonečna)');
END $$;

DO $$
DECLARE _uviznuty uuid;
        _cerstvy  uuid;
BEGIN
  -- Řádek, který zůstal v `sending` po spadlém běhu.
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, attempts, claimed_at)
  VALUES ('55555555-5555-5555-5555-555555555555', 'uviznuty@test.local', 'x', 'y',
          'sending', 1, now() - interval '30 minutes')
  RETURNING id INTO _uviznuty;

  -- A jeden, který si právě teď vzal běžící odesílač. Ten se sebrat NESMÍ,
  -- jinak by ho poslal druhý běh podruhé.
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, attempts, claimed_at)
  VALUES ('55555555-5555-5555-5555-555555555555', 'cerstvy@test.local', 'x', 'y',
          'sending', 1, now())
  RETURNING id INTO _cerstvy;

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.email_outbox_prevzit(200) p WHERE p.id = _uviznuty),
    'JÁDRO: řádek uvíznutý v `sending` se po 10 minutách vrátí do fronty');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.email_outbox WHERE id = _cerstvy AND attempts > 1),
    'JÁDRO: čerstvě převzatý řádek se druhému běhu nesebere');
END $$;

DO $$
DECLARE _id uuid;
        _stav text;
BEGIN
  -- Uvíznutý A vyčerpaný: úklid ho musí zavřít, ne nabízet donekonečna.
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, attempts, claimed_at)
  VALUES ('55555555-5555-5555-5555-555555555555', 'vycerpany@test.local', 'x', 'y',
          'sending', 5, now() - interval '30 minutes')
  RETURNING id INTO _id;

  PERFORM * FROM public.email_outbox_prevzit(200);
  SELECT status INTO _stav FROM public.email_outbox WHERE id = _id;
  PERFORM pg_temp.tvrd(_stav = 'failed',
    'JÁDRO: uvíznutý řádek s vyčerpanými pokusy se zavře jako `failed`');
END $$;

DO $$
DECLARE _id uuid;
BEGIN
  -- Řádek v `sending` s PRÁZDNÝM razítkem. `NULL < cokoli` není pravda, takže
  -- bez COALESCE by z fronty zmizel navždy: ani se nenabídne, ani nezavře.
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, attempts, claimed_at, created_at)
  VALUES ('55555555-5555-5555-5555-555555555555', 'bezrazitka@test.local', 'x', 'y',
          'sending', 1, NULL, now() - interval '30 minutes')
  RETURNING id INTO _id;

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.email_outbox_prevzit(200) p WHERE p.id = _id),
    'JÁDRO: řádek v `sending` bez razítka se nesmí ve frontě ztratit');
END $$;

-- -----------------------------------------------------------------------------
-- 9) JÁDRO: uživatelem nastavené jméno nesmí do e-mailu propašovat odstavec
-- -----------------------------------------------------------------------------
-- `profiles.full_name` si mění každý přihlášený sám. Bez stripu řídicích znaků
-- by si člen klubu mohl do jména dát prázdný řádek a vlastní text, a ten by
-- zástupcům klubu dorazil z ověřené domény haly, pod naším podpisem.
DO $$
DECLARE _telo text;
BEGIN
  SELECT s.body INTO _telo FROM public.email_sablona(
    'reservation_needs_approval', 'Rezervace čeká na potvrzení',
    E'Jan Novák\n\nUpozornění správce: potvrďte účet na zly-web.cz zadal(a) rezervaci.',
    '/calendar') s;

  PERFORM pg_temp.tvrd(_telo NOT LIKE E'%Novák\n\nUpozornění%',
    'JÁDRO: cizí konce řádků se do e-mailu nedostanou');
  PERFORM pg_temp.tvrd(_telo LIKE '%Jan Novák Upozornění%',
    'text se nezahodí, jen se srovná na jeden řádek');
END $$;

DO $$
DECLARE _telo text;
BEGIN
  SELECT s.body INTO _telo FROM public.email_sablona(
    'reservation_approved', 'x', 'y', '.zly-web.cz/prihlaseni') s;
  -- Odkaz musí vést na adresu Z NASTAVENÍ — porovnávat se skutečnou hodnotou,
  -- ne s natvrdo napsanou doménou, jinak tvrzení měří starý stav kódu.
  -- `strpos` ze stejného důvodu jako výš: adresa do LIKE vzoru nepatří.
  PERFORM pg_temp.tvrd(strpos(_telo, (SELECT s.web_base_url FROM public.settings s
                                       WHERE s.singleton LIMIT 1) || '/calendar') > 0
                   AND _telo NOT LIKE '%zly-web%',
    'JÁDRO: odkaz v e-mailu zůstane na našem webu');
END $$;

-- -----------------------------------------------------------------------------
-- 10) `reservation_overridden` je v matici VĚDOMĚ
-- -----------------------------------------------------------------------------
-- Není v zadání vypsaný vlastním řádkem, ale je to „vaše rezervace byla
-- zrušena kvůli jiné akci", tedy podmnožina „akce zrušena → dotčeným".
-- Kdyby to PM chtěl jinak, tohle tvrzení je to místo, kde se to změní.
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT s.subject FROM public.email_sablona('reservation_overridden','x','y','/calendar') s) IS NOT NULL,
    'přebití rezervace jinou akcí jde e-mailem (vědomé rozhodnutí, viz komentář)');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
