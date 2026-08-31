-- =============================================================================
-- TESTY: zástupce vidí členy svého klubu (blok A)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/zastupce_klub_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Rozšíření viditelnosti je vždycky ta nebezpečnější strana změny RLS. Tvrzení
-- jsou proto párová: co zástupce vidět MÁ, a hlavně co vidět NESMÍ — cizí klub
-- a jakýkoli zápis.
--
-- ⚠️ POVINNĚ POD `SET LOCAL ROLE authenticated` (pravidlo 8 z CLAUDE.md).
-- Jako `postgres` se politiky neuplatňují vůbec a test by neměřil nic.
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

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale prošla', _popis;
END $$;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);
GRANT ALL ON _s TO authenticated;

-- -----------------------------------------------------------------------------
-- Příprava: `clen` je zástupce CK Ostravské kameny (ze seedu),
-- `clen2` je řadový člen téhož klubu, `instruktor` je zástupce JINÉHO klubu.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _cizi uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  SELECT id INTO _cizi FROM public.subjects WHERE name = 'Curling Ostrava';
  INSERT INTO _s VALUES ('klub', _klub::text), ('cizi', _cizi::text);

  PERFORM pg_temp.tvrd(
    (SELECT level FROM public.subject_reps
      WHERE subject_id = _klub AND user_id = '44444444-4444-4444-4444-444444444444') = 'rep',
    'příprava: clen@test.local je zástupce CK Ostravské kameny');
  PERFORM pg_temp.tvrd(
    (SELECT level FROM public.subject_reps
      WHERE subject_id = _klub AND user_id = '55555555-5555-5555-5555-555555555555') = 'member',
    'příprava: clen2@test.local je řadový člen téhož klubu');
  PERFORM pg_temp.tvrd(
    (SELECT level FROM public.subject_reps
      WHERE subject_id = _cizi AND user_id = '22222222-2222-2222-2222-222222222222') = 'rep',
    'příprava: instruktor@test.local je zástupce JINÉHO klubu');
END $$;

-- -----------------------------------------------------------------------------
-- 1) ZÁSTUPCE vidí svůj klub — a nevidí cizí
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}';

DO $$
DECLARE _klub uuid; _cizi uuid;
BEGIN
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'test běží jako authenticated, ne jako postgres');
  PERFORM pg_temp.tvrd(NOT COALESCE(has_role(auth.uid(), 'admin'), false),
    '… a pod NEadminem (jinak by to neměřilo nic)');

  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  SELECT hodnota::uuid INTO _cizi FROM _s WHERE klic = 'cizi';

  -- Tohle je ten dotaz, který by spustil rekurzi, kdyby politika volala
  -- funkci bez SECURITY DEFINER. Když projde, rekurze není.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps WHERE subject_id = _klub) >= 2,
    'zástupce vidí VÍC než jen sebe (celý svůj klub)');

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.subject_reps
             WHERE subject_id = _klub
               AND user_id = '55555555-5555-5555-5555-555555555555'),
    '… konkrétně i řádek řadového člena');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps WHERE subject_id = _cizi) = 0,
    'ale do CIZÍHO klubu nevidí ani řádek');
END $$;

-- Jména k tomu musí být taky vidět, jinak by seznam členů byl k ničemu.
DO $$
DECLARE _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps sr
       JOIN public.profiles_public p ON p.user_id = sr.user_id
      WHERE sr.subject_id = _klub AND p.full_name IS NOT NULL) >= 2,
    'a ke členům se dá dohledat jméno (profiles_public)');

  -- Cizí telefon ani číslo účtu zástupce vidět NESMÍ — to zůstává vlastníkovi
  -- a adminovi, rozšíření viditelnosti členství na tom nic nemění.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.profiles_public
      WHERE user_id <> auth.uid() AND (phone IS NOT NULL OR bank_account IS NOT NULL)) = 0,
    '… ale cizí telefon a číslo účtu pořád ne');
END $$;

-- -----------------------------------------------------------------------------
-- 2) ČTENÍ ANO, ZÁPIS NE
--
-- Nejdůležitější půlka téhle migrace. Rozšířila se viditelnost, ne pravomoc.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';

  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.subject_reps (subject_id, user_id, level)
              VALUES (%L, '33333333-3333-3333-3333-333333333333', 'member')$q$, _klub),
    'row-level security',
    'zástupce NESMÍ přidat člena do klubu (zůstává adminovi, P3)');

  -- ⚠️ U UPDATE A DELETE SE NETESTUJE VÝJIMKA, ALE STAV ŘÁDKU.
  --
  -- RLS u `UPDATE`/`DELETE` nevyhazuje chybu — nevyhovující řádky prostě
  -- ODFILTRUJE, takže příkaz projde a změní NULA řádků. Chybu hodí jen
  -- `INSERT`, kterému neprojde `WITH CHECK` (viz tvrzení výš).
  --
  -- Test, který by tu čekal výjimku, by tedy selhal na správně zabezpečené
  -- databázi. A co hůř, kdyby si to někdo „opravil" tím, že tvrzení zahodí,
  -- přestala by se ta pravomoc kontrolovat úplně. Proto se ptáme na to, na
  -- čem doopravdy záleží: zůstal ten řádek nedotčený?
  UPDATE public.subject_reps SET level = 'rep'
   WHERE subject_id = _klub AND user_id = '55555555-5555-5555-5555-555555555555';
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps
      WHERE user_id = '55555555-5555-5555-5555-555555555555' AND level = 'rep') = 0,
    'zástupce NEPOVÝŠÍ člena na zástupce (UPDATE projde, ale změní 0 řádků)');

  DELETE FROM public.subject_reps
   WHERE subject_id = _klub AND user_id = '55555555-5555-5555-5555-555555555555';
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.subject_reps
             WHERE subject_id = _klub AND user_id = '55555555-5555-5555-5555-555555555555'),
    'zástupce NEODEBERE člena (DELETE projde, ale nesmaže nic)');
END $$;

-- -----------------------------------------------------------------------------
-- 2b) PRÁVO NAVÍC jen do svého klubu (blok B)
--
-- `nastav_pravo_navic` je SECURITY DEFINER, takže RLS ji neomezuje — kontrolu
-- si dělá sama. Tohle tvrzení v testech dosud chybělo a je to ta podstatná
-- půlka: zástupce jednoho klubu nesmí rozdávat práva v cizím.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _cizi uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  SELECT hodnota::uuid INTO _cizi FROM _s WHERE klic = 'cizi';

  -- Ve svém klubu ano.
  PERFORM public.nastav_pravo_navic(_klub, '55555555-5555-5555-5555-555555555555', true);
  PERFORM pg_temp.tvrd(
    (SELECT muze_potvrzovat FROM public.subject_reps
      WHERE subject_id = _klub AND user_id = '55555555-5555-5555-5555-555555555555'),
    'zástupce udělí právo navíc členovi SVÉHO klubu');

  -- V cizím ne — a to ani členovi, který tam je.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.nastav_pravo_navic(%L, %L, true)', _cizi,
           '22222222-2222-2222-2222-222222222222'),
    'uděluje zástupce klubu nebo správce',
    'zástupce NEUDĚLÍ právo navíc v CIZÍM klubu');

  -- A zpátky, ať se stav nepřenáší do dalších sekcí.
  PERFORM public.nastav_pravo_navic(_klub, '55555555-5555-5555-5555-555555555555', false);
END $$;

-- -----------------------------------------------------------------------------
-- 3) ŘADOVÝ ČLEN vidí pořád jen sebe
-- -----------------------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

DO $$
DECLARE _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps WHERE user_id <> auth.uid()) = 0,
    'řadový člen nevidí NIKOHO kromě sebe — rozšíření platí jen pro zástupce');
END $$;

-- -----------------------------------------------------------------------------
-- 4) DEAKTIVOVANÝ zástupce nevidí nic
--
-- Brána `ucet_aktivni()` z bloku C je uvnitř `is_subject_rep`, takže tuhle
-- politiku zavírá zadarmo. Ověřujeme, že to opravdu platí.
-- -----------------------------------------------------------------------------
RESET ROLE;
UPDATE public.profiles SET stav = 'deaktivovan'
 WHERE user_id = '44444444-4444-4444-4444-444444444444';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}';

DO $$
DECLARE _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps WHERE subject_id = _klub AND user_id <> auth.uid()) = 0,
    'DEAKTIVOVANÝ zástupce ztrácí i výhled na klub (brána ucet_aktivni)');
END $$;

RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
