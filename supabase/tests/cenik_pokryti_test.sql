-- =============================================================================
-- TESTY: ceník ledu musí pokrýt otevírací dobu
-- Migrace 20260831234000_cenik_pokryva_provoz.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/cenik_pokryti_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Hodina provozu bez pásma není kosmetická vada — `cena_ledu` na ni vyhodí
-- výjimku, takže KAŽDÁ klubová rezervace v té hodině spadne. A vyrobit ji
-- uměl jeden uložený formulář otevírací doby. Nejcennější tvrzení jsou proto
-- ta dvě o triggerech: díru neudělá ani úprava provozní doby, ani úprava
-- ceníku.
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
  IF NOT COALESCE(_podminka, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 1) Placeholder v datech
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.cenik_pasma
                 WHERE deleted_at IS NULL AND popis LIKE '%čeká na potvrzení%'),
    'v ceníku nestojí poznámka „čeká na potvrzení" — popisek je provozní údaj, ne ticket');
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.cenik_pasma
             WHERE deleted_at IS NULL AND den_typ = 'vsedni' AND od_hodina = 6 AND sazba = 800),
    'ranní pásmo 6–14 pořád stojí 800 Kč/h (sazbu migrace NEMĚNÍ, čeká na klienta)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Dnešní stav sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _oh jsonb; _n int;
BEGIN
  SELECT opening_hours INTO _oh FROM public.settings LIMIT 1;
  SELECT count(*) INTO _n FROM public.hodiny_bez_pasma(_oh);
  PERFORM pg_temp.tvrd(_n = 0, 'ceník pokrývá celou dnešní otevírací dobu');
END $$;

-- -----------------------------------------------------------------------------
-- 3) ROZŠÍŘENÍ OTEVÍRACÍ DOBY MIMO CENÍK NEPROJDE
--
-- Tohle je ta cesta z nálezu: admin posune otevírání na 5:00, ceník začíná
-- v 6:00 — a od té chvíle padá každá klubová rezervace na 5:00.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _chyba text;
BEGIN
  BEGIN
    UPDATE public.settings
       SET opening_hours = jsonb_set(opening_hours, '{1,open}', '"05:00"');
    -- Kontrola je ODLOŽENÁ na konec transakce, takže si ji vynutíme tady.
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST SELHAL: otevírací doba se rozšířila mimo ceník a prošlo to';
  EXCEPTION WHEN OTHERS THEN
    _chyba := SQLERRM;
    IF position('nepokrývá celou otevírací dobu' in _chyba) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL: čekal jsem hlášku o nepokryté době, přišlo: %', _chyba;
    END IF;
    RAISE NOTICE 'OK  rozšíření otevírací doby mimo ceník NEPROJDE (%)', left(_chyba, 60);
  END;
END $$;

-- -----------------------------------------------------------------------------
-- 4) VYŘAZENÍ PÁSMA, KTERÉ PROVOZ POTŘEBUJE, TAKY NEPROJDE
-- -----------------------------------------------------------------------------
DO $$
DECLARE _chyba text;
BEGIN
  BEGIN
    UPDATE public.cenik_pasma SET deleted_at = now()
     WHERE den_typ = 'vsedni' AND od_hodina = 17 AND deleted_at IS NULL;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST SELHAL: večerní pásmo se vyřadilo a provoz zůstal bez ceny';
  EXCEPTION WHEN OTHERS THEN
    _chyba := SQLERRM;
    IF position('nepokrývá celou otevírací dobu' in _chyba) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL: čekal jsem hlášku o nepokryté době, přišlo: %', _chyba;
    END IF;
    RAISE NOTICE 'OK  vyřazení potřebného pásma NEPROJDE';
  END;
END $$;

-- -----------------------------------------------------------------------------
-- 5) LEGITIMNÍ ÚPRAVA PO ČÁSTECH PROJÍT MUSÍ
--
-- Kvůli tomuhle je kontrola odložená: mezistav („zúžil jsem jedno pásmo,
-- druhé ještě nerozšířil") není důvod k odmítnutí.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE public.cenik_pasma SET do_hodina = 16
   WHERE den_typ = 'vsedni' AND od_hodina = 14 AND deleted_at IS NULL;   -- díra 16–17
  UPDATE public.cenik_pasma SET od_hodina = 16
   WHERE den_typ = 'vsedni' AND od_hodina = 17 AND deleted_at IS NULL;   -- díra zase zacelená
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM pg_temp.tvrd(true, 'posun hranice mezi dvěma pásmy (přes mezistav s dírou) PROJDE');
END $$;

-- -----------------------------------------------------------------------------
-- 6) Hláška z cena_ledu neposílá na neexistující obrazovku
-- -----------------------------------------------------------------------------
DO $$
DECLARE _src text;
BEGIN
  SELECT prosrc INTO _src FROM pg_proc
   WHERE oid = 'public.cena_ledu(timestamptz,timestamptz)'::regprocedure;
  PERFORM pg_temp.tvrd(_src NOT LIKE '%Doplň ho v Nastavení%',
    'cena_ledu už neposílá „doplň to v Nastavení" (editor ceníku tam není)');
  PERFORM pg_temp.tvrd(_src LIKE '%správci haly%',
    '… posílá za správcem haly, což je dnes jediná fungující cesta');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
