-- =============================================================================
-- TESTY PÁSMOVÉHO CENÍKU LEDU (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/cenik_pasma_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE:
-- Pásmový ceník rozbíjí pravidlo, na kterém stála celá peněžní vrstva —
-- `amount = hodiny × rate_per_hour`. U rezervace přes dvě pásma je
-- `rate_per_hour` odvozený průměr (3 400 / 3 h = 1 133,33) a součin dá
-- 3 399,99. Autoritativní je nově `amount` a `cenove_pasma`.
--
-- Nejcennější tvrzení jsou proto ta, která hlídají, že se ten rozdíl NIKDE
-- neprojeví jako tichá ztráta haléře: součet rozpisu == částka, hodiny
-- v rozpisu == hodiny rezervace, a UPDATE rezervace částku nepřepočítá.
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

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

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

-- Klubová rezervace v daném čase; vrací id.
CREATE OR REPLACE FUNCTION pg_temp.rez(_od timestamptz, _do timestamptz, _klub text DEFAULT 'CK Ostravské kameny')
 RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _id uuid;
BEGIN
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name = _klub), _od, _do)
  RETURNING id INTO _id;
  RETURN _id;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Sazby od PM
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record;
BEGIN
  FOR _r IN
    SELECT * FROM (VALUES
      ('vsedni',  6, 14,  800), ('vsedni', 14, 17, 1000),
      ('vsedni', 17, 22, 1200), ('vikend',  0, 24, 1000)
    ) AS t(den, od, do_, sazba)
  LOOP
    PERFORM pg_temp.tvrd(EXISTS (
      SELECT 1 FROM public.cenik_pasma
       WHERE den_typ = _r.den::public.den_typ
         AND od_hodina = _r.od AND do_hodina = _r.do_ AND sazba = _r.sazba),
      format('pásmo %s %s–%s = %s Kč/h', _r.den, _r.od, _r.do_, _r.sazba));
  END LOOP;

  -- Odstupňování po 200 je zadání klienta, ne náhoda. Kdyby někdo zadal 1100,
  -- ceník přestane být „po dvoustovkách" a nikdo si toho nevšimne.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.cenik_pasma WHERE sazba::int % 200 <> 0) = 0,
    'všechny sazby jsou násobky 200 (odstupňování ze zadání)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Pásma se nesmí překrývat ani mít nesmyslné hodnoty
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis)
       VALUES ('vsedni', 16, 18, 900, 'překryv')$q$,
    'cenik_pasma_bez_prekryvu', 'překrývající se pásmo neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis)
       VALUES ('vsedni', 22, 22, 900, 'nulová délka')$q$,
    'cenik_pasma_rozsah', 'pásmo nulové délky neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis)
       VALUES ('vsedni', 22, 23, 1000.50, 'haléře')$q$,
    'cenik_pasma_cele', 'haléřová sazba v ceníku neprojde (sazba je VSTUP)');

  -- Ale navazující pásmo projít MUSÍ — interval je polootevřený.
  INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis)
  VALUES ('vsedni', 22, 23, 1400, 'TEST navazující');
  PERFORM pg_temp.tvrd(true, 'navazující pásmo 22–23 projde (interval je [od, do))');
  DELETE FROM public.cenik_pasma WHERE popis = 'TEST navazující';
END $$;

-- -----------------------------------------------------------------------------
-- 3) Výpočet ceny — JÁDRO
-- -----------------------------------------------------------------------------
DO $$
DECLARE _c numeric; _r jsonb;
BEGIN
  SELECT castka, rozpis INTO _c, _r FROM public.cena_ledu('2026-09-02 17:00+02','2026-09-02 19:00+02');
  PERFORM pg_temp.tvrd(_c = 2400, 'večer 17–19 = 2 × 1 200 = 2 400 Kč');

  SELECT castka INTO _c FROM public.cena_ledu('2026-09-02 09:00+02','2026-09-02 11:00+02');
  PERFORM pg_temp.tvrd(_c = 1600, 'ráno 9–11 = 2 × 800 = 1 600 Kč');

  SELECT castka INTO _c FROM public.cena_ledu('2026-09-02 14:00+02','2026-09-02 16:00+02');
  PERFORM pg_temp.tvrd(_c = 2000, 'odpoledne 14–16 = 2 × 1 000 = 2 000 Kč');

  -- HRANICE PÁSMA. Interval je [od, do), takže hodina 17:00 je už večerní.
  SELECT castka INTO _c FROM public.cena_ledu('2026-09-02 16:00+02','2026-09-02 17:00+02');
  PERFORM pg_temp.tvrd(_c = 1000, 'hodina 16–17 patří ještě do odpoledního pásma');
  SELECT castka INTO _c FROM public.cena_ledu('2026-09-02 17:00+02','2026-09-02 18:00+02');
  PERFORM pg_temp.tvrd(_c = 1200, '… a hodina 17–18 už do večerního');

  -- PŘES DVĚ PÁSMA — to, kvůli čemu celý blok vznikl.
  SELECT castka, rozpis INTO _c, _r FROM public.cena_ledu('2026-09-02 16:00+02','2026-09-02 19:00+02');
  PERFORM pg_temp.tvrd(_c = 3400, 'přes dvě pásma 16–19 = 1×1000 + 2×1200 = 3 400 Kč');
  PERFORM pg_temp.tvrd(jsonb_array_length(_r) = 2, '… a rozpis má dvě položky');
  PERFORM pg_temp.tvrd(
    (SELECT sum((p ->> 'hodin')::numeric) FROM jsonb_array_elements(_r) p) = 3,
    '… které dohromady pokrývají všechny 3 hodiny');
  PERFORM pg_temp.tvrd(
    (SELECT sum((p ->> 'sazba')::numeric * (p ->> 'hodin')::numeric) FROM jsonb_array_elements(_r) p) = _c,
    '… a jejichž součet je PŘESNĚ ta částka');

  -- VÍKEND je plochý bez ohledu na hodinu.
  SELECT castka INTO _c FROM public.cena_ledu('2026-09-05 16:00+02','2026-09-05 19:00+02');
  PERFORM pg_temp.tvrd(_c = 3000, 'sobota 16–19 = 3 × 1 000 (víkend je plochý)');
  SELECT castka INTO _c FROM public.cena_ledu('2026-09-06 08:00+02','2026-09-06 10:00+02');
  PERFORM pg_temp.tvrd(_c = 2000, 'neděle ráno taky 1 000, ne 800');

  -- LETNÍ ČAS. `start_at` je timestamptz; bez převodu do pražského pásma by se
  -- hranice posunula o hodinu a rezervace na 17:00 by se v zimě ocenila jako
  -- odpolední. Leden je zimní čas (+01), září letní (+02).
  SELECT castka INTO _c FROM public.cena_ledu('2027-01-06 17:00+01','2027-01-06 19:00+01');
  PERFORM pg_temp.tvrd(_c = 2400, 'v ZIMNÍM čase je 17–19 pořád večerní pásmo (2 400 Kč)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Hodina bez pásma je CHYBA, ne tichá nula
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  DELETE FROM public.cenik_pasma WHERE den_typ = 'vsedni' AND od_hodina = 6;
  PERFORM pg_temp.ocekavej_chybu(
    $q$SELECT public.cena_ledu('2026-09-02 09:00+02','2026-09-02 11:00+02')$q$,
    'nemá v ceníku pásmo', 'hodina bez pásma skončí chybou, ne nulou ani výchozí sazbou');
END $$;
ROLLBACK;
BEGIN;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 5) Rezervace: snapshot ceny a rozpisu
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
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

-- Každá testovací rezervace na JINÝ TÝDEN. Exclusion constraint
-- `reservations_no_overlap` jinak druhou odmítne — a test by padal na kolizi
-- místo na tom, co měří.
CREATE OR REPLACE FUNCTION pg_temp.rez(_od timestamptz, _do timestamptz, _klub text DEFAULT 'CK Ostravské kameny')
 RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _id uuid;
BEGIN
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name = _klub), _od, _do)
  RETURNING id INTO _id;
  RETURN _id;
END $$;

DO $$
DECLARE _id uuid; _r record; _puvodni numeric;
BEGIN
  _id := pg_temp.rez('2026-09-02 16:00+02','2026-09-02 19:00+02');
  SELECT hours, rate_per_hour, amount, cenove_pasma INTO _r
    FROM public.reservations WHERE id = _id;

  PERFORM pg_temp.tvrd(_r.amount = 3400, 'klubová rezervace 16–19 stojí 3 400 Kč');
  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NOT NULL, 'a nese rozpis po pásmech');
  PERFORM pg_temp.tvrd(_r.rate_per_hour = 1133.33,
    'rate_per_hour je ODVOZENÝ průměr s haléři (3 400 / 3 = 1 133,33)');

  -- To je celý smysl uvolnění pravidla o celých korunách.
  PERFORM pg_temp.tvrd(_r.rate_per_hour <> round(_r.rate_per_hour),
    '… tedy NENÍ celá koruna — a projde to, protože je to dopočet, ne zadání');
  PERFORM pg_temp.tvrd(round(_r.hours * _r.rate_per_hour, 2) <> _r.amount,
    '… a součin hodin a sazby vědomě NEDÁ částku (3 399,99 ≠ 3 400)');

  -- ÚPRAVA REZERVACE NESMÍ ČÁSTKU POSUNOUT. Bez téhle zábrany by každý UPDATE
  -- přepočítal amount na hodiny × průměr, tedy o haléř dolů — a to na dokladu,
  -- který už mohl odejít.
  _puvodni := _r.amount;
  UPDATE public.reservations SET note = 'úprava poznámky' WHERE id = _id;
  PERFORM pg_temp.tvrd((SELECT amount FROM public.reservations WHERE id = _id) = _puvodni,
    'úprava rezervace NEPŘEPOČÍTALA částku (jinak by ujel haléř)');
END $$;

-- -----------------------------------------------------------------------------
-- 5b) PŘESUN A PRODLOUŽENÍ — cena musí jít s časem
--
-- Snapshot platí pro čas, na který vznikl. Bez přecenění by rezervace přesunutá
-- z večera na ráno zůstala na večerní ceně (klub přeplatí) a prodloužená by
-- měla rozpis kratší než hodiny — takovou `mapping.ts` odmítne a doklad by se
-- nedal vystavit vůbec.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _r record;
BEGIN
  _id := pg_temp.rez('2026-09-23 16:00+02','2026-09-23 19:00+02');
  PERFORM pg_temp.tvrd((SELECT amount FROM public.reservations WHERE id = _id) = 3400,
    'výchozí stav: 16–19 přes dvě pásma = 3 400 Kč');

  -- PŘESUN na ráno: 3 × 800 = 2 400 Kč.
  UPDATE public.reservations
     SET start_at = '2026-09-23 09:00+02', end_at = '2026-09-23 12:00+02'
   WHERE id = _id;
  SELECT hours, rate_per_hour, amount, cenove_pasma INTO _r
    FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.amount = 2400,
    'přesun z večera na ráno rezervaci PŘECENÍ (3 400 → 2 400 Kč, jinak klub přeplatí)');
  PERFORM pg_temp.tvrd(_r.rate_per_hour = 800 AND jsonb_array_length(_r.cenove_pasma) = 1,
    '… a rozpis se přepíše na jedno ranní pásmo');

  -- PRODLOUŽENÍ o hodinu, pořád ráno: 4 × 800 = 3 200 Kč.
  UPDATE public.reservations SET end_at = '2026-09-23 13:00+02' WHERE id = _id;
  SELECT hours, amount, cenove_pasma INTO _r FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.amount = 3200 AND _r.hours = 4,
    'prodloužení o hodinu cenu dopočítá (4 × 800 = 3 200 Kč)');
  PERFORM pg_temp.tvrd(
    (SELECT sum((p ->> 'hodin')::numeric) FROM jsonb_array_elements(_r.cenove_pasma) p) = _r.hours,
    '… a rozpis pokrývá VŠECHNY hodiny (jinak by doklad neprošel kontrolou)');

  -- Prodloužení PŘES hranici pásma: 9–15 = 5×800 + 1×1000 = 5 000 Kč.
  UPDATE public.reservations SET end_at = '2026-09-23 15:00+02' WHERE id = _id;
  SELECT amount, cenove_pasma INTO _r FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.amount = 5000 AND jsonb_array_length(_r.cenove_pasma) = 2,
    'prodloužení přes hranici pásma přidá do rozpisu druhou sazbu (9–15 = 5 000 Kč)');
END $$;

-- -----------------------------------------------------------------------------
-- 5c) Stropy z `strop_sazby` platí DÁL
--
-- `check_reservation_money` se kvůli pásmům přepisovala. Tyhle dvě hlášky z ní
-- při přepisu jednou vypadly (CHECK constraint držel, ale uživatel dostal místo
-- vysvětlení hlášku o porušení constraintu) — proto tu na ně je regresní test.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid;
BEGIN
  _id := pg_temp.rez('2026-09-30 17:00+02','2026-09-30 19:00+02');
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations SET rate_per_hour = 50001, cenove_pasma = NULL
               WHERE id = %L$q$, _id),
    'nejvýš 50 000', 'strop sazby 50 000 Kč/h pořád mluví česky');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations
                 SET corrected_hours = 25, correction_reason = 'test'
               WHERE id = %L$q$, _id),
    'nejvýš 24', 'strop korekce 24 h pořád mluví česky');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations SET corrected_hours = 2 WHERE id = %L$q$, _id),
    'potřeba důvod', 'korekce bez důvodu pořád mluví česky');
END $$;

DO $$
DECLARE _r record; _id uuid;
BEGIN
  -- Rezervace v JEDNOM pásmu se chová jako dřív: sazba je celá koruna
  -- a součin sedí.
  -- ČTE SE PODLE ID, ne „poslední podle created_at“. Uvnitř transakce je
  -- `now()` zmrazené, takže všechny zdejší rezervace mají TOTOŽNÝ `created_at`
  -- a „poslední“ z nich je losování — test pak měřil cizí řádek.
  _id := pg_temp.rez('2026-09-09 17:00+02','2026-09-09 19:00+02');
  SELECT hours, rate_per_hour, amount INTO _r
    FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.amount = 2400 AND _r.rate_per_hour = 1200,
    'rezervace v jednom pásmu má celou korunu a součin sedí');
END $$;

DO $$
DECLARE _r record; _id uuid;
BEGIN
  -- KOMERČNÍ ZÁKAZNÍK pásem NEPOUŽÍVÁ — má jednu sazbu 5 000 Kč/h bez DPH.
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name = 'Demo Firma s.r.o.'),
          '2026-09-03 16:00+02','2026-09-03 18:00+02')
  RETURNING id INTO _id;
  SELECT rate_per_hour, amount, cenove_pasma INTO _r
    FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.rate_per_hour = 5000 AND _r.amount = 10000,
    'komerční zákazník má 5 000 Kč/h bez ohledu na denní dobu');
  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NULL,
    '… a žádný rozpis po pásmech nedostane');
END $$;

DO $$
DECLARE _r record; _sub uuid; _id uuid;
BEGIN
  -- VLASTNÍ SAZBA SUBJEKTU má přednost před ceníkem — individuálně dohodnutá
  -- cena je dohoda, ne ceník.
  SELECT id INTO _sub FROM public.subjects WHERE name = 'HC Ostrava';
  UPDATE public.subjects SET default_rate = 750 WHERE id = _sub;
  _id := pg_temp.rez('2026-09-16 16:00+02','2026-09-16 19:00+02', 'HC Ostrava');
  SELECT rate_per_hour, amount, cenove_pasma INTO _r
    FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.rate_per_hour = 750 AND _r.amount = 2250,
    'vlastní sazba subjektu přebije pásmový ceník');
  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NULL, '… a rozpis se nevyplní');
END $$;

-- -----------------------------------------------------------------------------
-- 5d) ROZPIS SE MUSÍ DOSTAT AŽ K DOKLADU
--
-- Nejdražší tvrzení v souboru. `mapping.ts` umí složit doklad po pásmech, ale
-- dokud ho `fakturoid_podklady_klub` nevracela, byla to slepá ulička: řádek by
-- se složil z `hodiny × průměr` = 3 399,99 proti částce 3 400 a mapovací vrstva
-- by klubový doklad ODMÍTLA. Nešel by vystavit vůbec — a v testech DB by to
-- nebylo vidět, protože každá vrstva zvlášť funguje.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _sub uuid; _r record;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  _id := pg_temp.rez('2026-10-07 16:00+02','2026-10-07 19:00+02');
  UPDATE public.reservations
     SET status = 'confirmed', approved_at = now(), approved_by = auth.uid()
   WHERE id = _id;

  SELECT hodiny, sazba, castka, cenove_pasma INTO _r
    FROM public.fakturoid_podklady_klub(_sub, '2026-10-01', '2026-10-31')
   WHERE id = _id;

  PERFORM pg_temp.tvrd(_r.castka = 3400, 'podklady vracejí částku 3 400 Kč');
  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NOT NULL,
    'PODKLADY PRO DOKLAD NESOU ROZPIS (bez něj by klubová faktura nešla vystavit)');
  PERFORM pg_temp.tvrd(
    (SELECT sum((p ->> 'sazba')::numeric * (p ->> 'hodin')::numeric)
       FROM jsonb_array_elements(_r.cenove_pasma) p) = _r.castka,
    '… a součet rozpisu je PŘESNĚ ta částka (řádky dokladu tím sednou na haléř)');
  PERFORM pg_temp.tvrd(
    (SELECT sum((p ->> 'hodin')::numeric) FROM jsonb_array_elements(_r.cenove_pasma) p) = _r.hodiny,
    '… a pokrývá přesně ty hodiny, které se fakturují');

  -- KOREKCE ROZPIS VYPÍNÁ. Opravená částka se počítá z průměru, takže původní
  -- rozpis (3 h / 3 400 Kč) na ni nesedí — a kdyby přišel s ní, doklad by
  -- neprošel kontrolou. Bez rozpisu vyjde `hodiny × sazba` přesně.
  UPDATE public.reservations
     SET corrected_hours = 2, correction_reason = 'test korekce'
   WHERE id = _id;

  SELECT hodiny, sazba, castka, cenove_pasma INTO _r
    FROM public.fakturoid_podklady_klub(_sub, '2026-10-01', '2026-10-31')
   WHERE id = _id;

  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NULL,
    'u KOREKCE se rozpis nevrací (nesedl by na opravenou částku)');
  PERFORM pg_temp.tvrd(round(_r.hodiny * _r.sazba, 2) = _r.castka,
    format('… a tam zas přesně sedí hodiny × sazba (%s × %s = %s)',
           _r.hodiny, _r.sazba, _r.castka));
END $$;

-- -----------------------------------------------------------------------------
-- 5f) RUČNÍ SAZBA PŘEBÍJÍ PÁSMA
--
-- Nález brány: bez tohohle se `amount` u pásmové rezervace nepřepočítalo NIKDY,
-- takže admin nastavil 900 Kč/h, UI ukázalo 900 — a systém vyfakturoval starou
-- částku 3 400 Kč místo 2 700. Tichý rozdíl mezi zobrazenou a fakturovanou
-- cenou je u peněz to nejhorší, co se může stát.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _r record;
BEGIN
  _id := pg_temp.rez('2026-10-14 16:00+02','2026-10-14 19:00+02');
  PERFORM pg_temp.tvrd((SELECT amount FROM public.reservations WHERE id = _id) = 3400,
    'výchozí stav: pásmová rezervace za 3 400 Kč');

  UPDATE public.reservations SET rate_per_hour = 900 WHERE id = _id;
  SELECT rate_per_hour, hours, amount, cenove_pasma INTO _r
    FROM public.reservations WHERE id = _id;

  PERFORM pg_temp.tvrd(_r.amount = 2700,
    'ruční sazba 900 Kč/h PŘEPOČÍTÁ částku (3 × 900 = 2 700, ne stará 3 400)');
  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NULL,
    '… a zahodí rozpis, protože ten už cenu nepopisuje');

  -- A tím se vrací i pravidlo o celých korunách — ruční sazba je zase VSTUP.
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations SET rate_per_hour = 900.50 WHERE id = %L$q$, _id),
    'celých korunách', '… a ruční sazba zase musí být v celých korunách');
END $$;

-- -----------------------------------------------------------------------------
-- 5g) ROZPIS SE NEDÁ PODSTRČIT
--
-- `cenove_pasma` je odvozená hodnota, ale sloupec je pro `authenticated`
-- zapisovatelný (tabulkové granty na `reservations`). Nález brány: `'null'::jsonb
-- NENÍ SQL NULL`, takže podstrčením téhle hodnoty šlo vypnout pravidlo o celých
-- korunách i dopočet `amount` — vznikla rezervace se sazbou 1 234,56 Kč/h
-- a `amount = NULL`.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _r record;
BEGIN
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, cenove_pasma)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name = 'CK Ostravské kameny'),
          '2026-10-21 16:00+02','2026-10-21 19:00+02', '[{"sazba":1,"hodin":3}]'::jsonb)
  RETURNING id INTO _id;

  SELECT amount, cenove_pasma INTO _r FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_r.amount = 3400,
    'podstrčený rozpis se při vzniku zahodí a cena se spočítá z ceníku');
  PERFORM pg_temp.tvrd(
    (SELECT sum((p ->> 'sazba')::numeric * (p ->> 'hodin')::numeric)
       FROM jsonb_array_elements(_r.cenove_pasma) p) = 3400,
    '… a uložený rozpis je ten pravý, ne ten podstrčený');

  -- `'null'::jsonb` musí skončit jako SQL NULL, ne jako „mám rozpis".
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations
                 SET rate_per_hour = 1234.56, cenove_pasma = 'null'::jsonb
               WHERE id = %L$q$, _id),
    'celých korunách',
    '„null“ jako jsonb NEVYPNE pravidlo o celých korunách (past: není to SQL NULL)');
END $$;

-- Záruku má dávat CHECK, ne jen trigger — tenhle test to ověřuje s vypnutými
-- triggery, aby se nedalo splést „hlídá to constraint" s „hlídá to trigger".
DO $$
DECLARE _id uuid;
BEGIN
  _id := pg_temp.rez('2026-10-28 16:00+02','2026-10-28 19:00+02');
  ALTER TABLE public.reservations DISABLE TRIGGER USER;

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations
                 SET cenove_pasma = '[{"sazba":1,"hodin":3}]'::jsonb WHERE id = %L$q$, _id),
    'reservations_cenove_pasma_sedi',
    'rozpis, který nesedí na částku, ODMÍTNE CHECK i bez triggeru');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.reservations
                 SET cenove_pasma = '[{"sazba":1000,"hodin":-1}]'::jsonb WHERE id = %L$q$, _id),
    'reservations_cenove_pasma_sedi',
    'záporné hodiny v rozpisu ODMÍTNE CHECK i bez triggeru');

  ALTER TABLE public.reservations ENABLE TRIGGER USER;
END $$;

-- -----------------------------------------------------------------------------
-- 5e) CENÍK NEUNIKÁ OKNEM VEDLE ZAVŘENÝCH DVEŘÍ
--
-- Sazby jsou částky a ty vidí jen admin (rozhodnutí klienta 31. 7.). RLS na
-- `cenik_pasma` to drží, jenže `cena_ledu` je SECURITY DEFINER — čte tabulku
-- pod vlastníkem, takže s grantem pro `authenticated` by si člen klubu vyjel
-- cenu hodinu po hodině a ceník složil, aniž by z tabulky viděl jediný řádek.
--
-- POVINNĚ pod `SET LOCAL ROLE authenticated` (pravidlo 8 z CLAUDE.md): jako
-- `postgres` projde všechno a test by tvrdil zavřeno o dveřích, vedle kterých
-- je otevřené okno.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}';

DO $$
BEGIN
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'test práv OPRAVDU běží jako authenticated, ne jako postgres');
  PERFORM pg_temp.tvrd(NOT COALESCE(has_role(auth.uid(), 'admin'), false),
    '… a pod NEadminem (člen klubu)');

  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.cenik_pasma) = 0,
    'člen klubu nevidí z ceníku ani řádek (RLS)');

  PERFORM pg_temp.ocekavej_chybu(
    $q$SELECT castka FROM public.cena_ledu('2026-09-02 17:00+02','2026-09-02 18:00+02')$q$,
    'permission denied',
    '… a NEOBEJDE to přes cena_ledu (jinak by si ceník složil po hodinách)');
END $$;

RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 6) „Kdo kolik dluží" pod pásmovým ceníkem
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub numeric; _kom numeric; _kom_zaklad numeric;
BEGIN
  SELECT sum(dluh) INTO _klub FROM public.reservations_billing WHERE subject_type = 'club';
  SELECT sum(dluh), sum(dluh_zaklad) INTO _kom, _kom_zaklad
    FROM public.reservations_billing WHERE subject_type = 'commercial';

  -- Klubové ceny jsou VČETNĚ DPH → dluh se rovná částce.
  PERFORM pg_temp.tvrd(
    _klub = (SELECT sum(COALESCE(corrected_amount, amount)) FROM public.reservations_billing
              WHERE subject_type = 'club'),
    'u klubů se dluh rovná částce (ceny jsou včetně DPH)');

  -- Komerční jsou BEZ DPH → dluh je o daň vyšší.
  PERFORM pg_temp.tvrd(_kom > _kom_zaklad,
    'u komerce je dluh VYŠŠÍ než základ — o DPH, kterou dřív nebylo vidět');
  PERFORM pg_temp.tvrd(round(_kom_zaklad * 1.12, 2) = round(_kom, 2),
    format('… a přesně o 12 %% (%s → %s)', _kom_zaklad, _kom));
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
