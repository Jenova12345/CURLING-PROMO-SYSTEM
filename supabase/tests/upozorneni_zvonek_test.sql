-- =============================================================================
-- TEST: zvonek je osobní schránka a jde v něm uklidit (Jakubův nález)
-- Migrace 20260902266000_upozorneni_vlastni_a_odkliditelna.sql
-- =============================================================================
-- ⚠️ BĚŽÍ POD `SET LOCAL ROLE authenticated`. Celý nález je o tom, co RLS
-- pouští ven — jako `postgres` by byl soubor zelený s libovolnou politikou.
--
-- MUTAČNÍ ZKOUŠKY:
--   a) vrať do `notifications_select_own` větev `OR has_role(auth.uid(),'admin')`
--      → musí zčervenat na scénářích 1 a 2;
--   b) přidej do `_allowed` v `guard_notification_update()` sloupec `id`
--      (nebo vrať guard na blacklist) → musí zčervenat na scénáři 4.
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

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): mělo to skončit chybou, ale prošlo', _popis;
END $$;

-- PŘÍPRAVA: přesně Jakubova situace — pár vlastních, víc cizích.
DELETE FROM public.notifications;
-- Vlastní upozornění mají vazby VYPLNĚNÉ schválně: scénář 4 je pak nuluje
-- a to je skutečná změna. S NULLem už v řádku by guard neměl na co reagovat
-- a test by tvrdil „nesmí" o něčem, co se ani nezměnilo.
INSERT INTO public.notifications (user_id, type, title, body, link, reservation_id, subject_id, created_by) VALUES
  ('11111111-1111-1111-1111-111111111111','reservation_cancelled','Moje 1','x','/calendar',
    (SELECT id FROM public.reservations WHERE deleted_at IS NULL LIMIT 1),
    (SELECT id FROM public.subjects LIMIT 1),
    '11111111-1111-1111-1111-111111111111'),
  ('11111111-1111-1111-1111-111111111111','reservation_changed','Moje 2','x','/calendar',
    (SELECT id FROM public.reservations WHERE deleted_at IS NULL LIMIT 1),
    (SELECT id FROM public.subjects LIMIT 1),
    '11111111-1111-1111-1111-111111111111'),
  ('11111111-1111-1111-1111-111111111111','reservation_approved','Moje 3','x','/calendar',
    (SELECT id FROM public.reservations WHERE deleted_at IS NULL LIMIT 1),
    (SELECT id FROM public.subjects LIMIT 1),
    '11111111-1111-1111-1111-111111111111'),
  ('33333333-3333-3333-3333-333333333333','reservation_cancelled','Cizí 1','x',NULL,NULL,NULL,NULL),
  ('33333333-3333-3333-3333-333333333333','reservation_changed','Cizí 2','x',NULL,NULL,NULL,NULL),
  ('44444444-4444-4444-4444-444444444444','reservation_cancelled','Cizí 3','x',NULL,NULL,NULL,NULL);

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1) ADMIN VIDÍ VE ZVONKU JEN SVOJE (jádro — a příčina obou dalších symptomů)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.notifications) = 3,
    'admin vidí ve zvonku jen svoje 3 upozornění, ne cizích 6');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.notifications WHERE title LIKE 'Cizí%') = 0,
    '… a do cizích těl nevidí vůbec');
END $$;

-- ---------------------------------------------------------------------------
-- 2) „OZNAČIT VŠE JAKO PŘEČTENÉ" SKUTEČNĚ VYNULUJE ODZNAK
--    Přesně ten dotaz, který posílá `useNotifications.markAllRead`.
-- ---------------------------------------------------------------------------
DO $$
DECLARE _pred int; _po int;
BEGIN
  SELECT count(*) INTO _pred FROM public.notifications WHERE read_at IS NULL;
  PERFORM pg_temp.tvrd(_pred = 3, 'odznak před kliknutím ukazuje 3');

  UPDATE public.notifications SET read_at = now()
   WHERE id IN (SELECT id FROM public.notifications WHERE read_at IS NULL);

  SELECT count(*) INTO _po FROM public.notifications WHERE read_at IS NULL;
  PERFORM pg_temp.tvrd(_po = 0,
    format('po kliknutí je odznak na nule (bylo %s, zůstalo %s)', _pred, _po));
END $$;

-- ---------------------------------------------------------------------------
-- 3) UPOZORNĚNÍ KE ZRUŠENÉ REZERVACI JDE ODKLIDIT — a zmizí ze zvonku
-- ---------------------------------------------------------------------------
DO $$
DECLARE _id uuid;
BEGIN
  SELECT id INTO _id FROM public.notifications WHERE type='reservation_cancelled' LIMIT 1;

  UPDATE public.notifications SET dismissed_at = now() WHERE id = _id;
  PERFORM pg_temp.tvrd(
    (SELECT dismissed_at IS NOT NULL FROM public.notifications WHERE id=_id),
    'upozornění ke zrušené rezervaci jde odklidit');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.notifications WHERE dismissed_at IS NULL) = 2,
    '… a ze zvonku (moje, neodklizené) zmizí');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.notifications) = 3,
    '… ale v tabulce zůstane, nemaže se natvrdo');

  -- ODKLIZENÉ NESMÍ ZŮSTAT „NEPŘEČTENÉ".
  -- Křížek funguje i na nepřečtené položce; kdyby se `read_at` nedoplnilo,
  -- spadl by odznak, aniž si to kdo přečetl. Klient to dělá dvěma dotazy
  -- (`useNotifications.ts`), tady se ověřuje výsledek.
  UPDATE public.notifications SET read_at = now() WHERE id = _id AND read_at IS NULL;
  PERFORM pg_temp.tvrd(
    (SELECT read_at IS NOT NULL AND dismissed_at IS NOT NULL
       FROM public.notifications WHERE id=_id),
    '… a odklizené je zároveň přečtené (nevzniká matoucí mezistav)');
END $$;

-- ---------------------------------------------------------------------------
-- 4) ADRESÁT SMÍ MĚNIT JEN read_at A dismissed_at — nic víc
--
--    Guard je od 20260902280000 WHITELIST. Blacklist tady nestačil: `id`
--    v seznamu chybělo a šlo si ho přepsat, protože u blacklistu je každý
--    nedopsaný sloupec automaticky povolený. Scénáře níž projdou i všechny
--    sloupce, které teprve přibudou.
-- ---------------------------------------------------------------------------
DO $$
DECLARE _sl text; _sql text;
BEGIN
  -- Povolené dvě: musí projít.
  UPDATE public.notifications SET read_at = now()
   WHERE user_id='11111111-1111-1111-1111-111111111111';
  UPDATE public.notifications SET dismissed_at = NULL
   WHERE user_id='11111111-1111-1111-1111-111111111111';
  PERFORM pg_temp.tvrd(true, 'read_at i dismissed_at adresát měnit smí');

  -- A teď KAŽDÝ ostatní sloupec tabulky, ať se na nový zase nezapomene.
  FOR _sl IN
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='public' AND table_name='notifications'
       AND column_name <> ALL (ARRAY['read_at','dismissed_at'])
     ORDER BY ordinal_position
  LOOP
    _sql := format(
      $f$UPDATE public.notifications SET %I = %L
          WHERE user_id='11111111-1111-1111-1111-111111111111'$f$,
      _sl,
      CASE _sl
        WHEN 'id'             THEN 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
        WHEN 'user_id'        THEN '33333333-3333-3333-3333-333333333333'
        WHEN 'reservation_id' THEN NULL   -- vynulování vyplněné vazby = skutečná změna
        WHEN 'subject_id'     THEN NULL
        WHEN 'created_by'     THEN NULL
        WHEN 'link'           THEN NULL
        WHEN 'created_at'     THEN '2020-01-01 00:00+00'
        ELSE 'PŘEPSÁNO'
      END);
    PERFORM pg_temp.ocekavej_chybu(_sql, 'lze měnit jen přečtení a odklizení',
      format('sloupec „%s" adresát změnit nesmí', _sl));
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 5) CIZÍ UPOZORNĚNÍ NEJDE ANI ODKLIDIT
-- ---------------------------------------------------------------------------
DO $$
DECLARE _n int;
BEGIN
  UPDATE public.notifications SET dismissed_at = now()
   WHERE user_id='33333333-3333-3333-3333-333333333333';
  GET DIAGNOSTICS _n = ROW_COUNT;
  PERFORM pg_temp.tvrd(_n = 0, 'cizí upozornění nejde odklidit (0 řádků)');
END $$;

RESET ROLE;
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.notifications
      WHERE user_id='33333333-3333-3333-3333-333333333333' AND dismissed_at IS NULL) = 2,
    '… a opravdu zůstala nedotčená');
END $$;

ROLLBACK;
