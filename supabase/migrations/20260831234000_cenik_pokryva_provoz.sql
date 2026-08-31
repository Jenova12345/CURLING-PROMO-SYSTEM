-- =============================================================================
-- Ceník ledu musí pokrýt otevírací dobu — a chybová hláška nesmí posílat
-- na obrazovku, která neexistuje
-- Nález z brány (ultra review, 31. 8. 2026) — zabezpečení, ne stavba editoru
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- `cena_ledu` na hodinu bez pásma vyhodí výjimku — to je správně („radši
-- nevystavit než ocenit naprázdno"). Jenže:
--
--   1. Hláška posílala „doplň to v Nastavení". Editor pásmového ceníku ale
--      v `src/` NENÍ (grep na `cenik_pasma` vrátí jen generované typy), takže
--      rada vedla na obrazovku, která neexistuje. Admin, který rozšíří
--      otevírací dobu z 7:00 na 5:00, tím shodí KAŽDOU klubovou rezervaci
--      v té hodině a nemá jak to spravit.
--
--   2. Mezera vůbec neměla vznikat. Otevírací doba se edituje v Nastavení,
--      ceník ne — takže díru mezi nimi umí vyrobit jedno uložení formuláře,
--      a projeví se až tomu, kdo si zkusí zarezervovat led.
--
-- CO SE MĚNÍ:
--
--   1. HLÁŠKA MLUVÍ PRAVDU: řekne, o kterou hodinu jde, a pošle za správcem
--      haly (dokud editor ceníku není).
--   2. DÍRA NEVZNIKNE: dvě odložené (`DEFERRABLE INITIALLY DEFERRED`)
--      constraint triggery hlídají, že se otevírací doba a živá pásma
--      neroze­jdou — ani při změně otevírací doby, ani při zásahu do ceníku.
--      Odložené schválně: admin může v jedné transakci pásmo zúžit a jiné
--      rozšířit, a mezistav nemá být důvod k odmítnutí.
--   3. PLACEHOLDER V DATECH: naseedované ranní pásmo se jmenovalo
--      „Ranní (čeká na potvrzení klienta)". Popisek je provozní údaj, ne
--      poznámkový blok — čeká-li se na potvrzení, patří to do dokumentace
--      a do ticketu, ne do řádku, podle kterého se fakturuje.
--
-- ⚠️ CO SE TÍM NEŘEŠÍ (vědomě): SAZBA ranního pásma (800 Kč/h) pořád čeká
--    na potvrzení klienta a EDITOR CENÍKU V UI POŘÁD NENÍ. Obojí je vlastní
--    follow-up; tahle migrace jen zabraňuje tomu, aby se z toho stal výpadek.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   DROP TRIGGER IF EXISTS trg_settings_cenik_pokryti ON public.settings;
--   DROP TRIGGER IF EXISTS trg_cenik_pasma_pokryti   ON public.cenik_pasma;
--   DROP FUNCTION IF EXISTS public.trg_cenik_pokryva_provoz();
--   DROP FUNCTION IF EXISTS public.hodiny_bez_pasma(jsonb);
--   -- cena_ledu zpátky ze ŽIVÉHO schématu (pg_get_functiondef).
--   -- Popisek pásma revert nevrací (je to text, ne cena).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Popisek pásma není poznámkový blok
--
-- Mění se JEN tehdy, když tam pořád stojí původní placeholder — kdyby si ho
-- admin mezitím přepsal, migrace mu to nesmí vzít.
-- -----------------------------------------------------------------------------
UPDATE public.cenik_pasma
   SET popis = 'Ranní (6–14)'
 WHERE popis = 'Ranní (čeká na potvrzení klienta)'
   AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 2) Které hodiny provozu ceník nepokrývá
--
-- Vrací (den, hodina) pro každou hodinu otevírací doby, na kterou není živé
-- pásmo. Prázdný výsledek = ceník a provoz sedí.
--
-- `_oh` se předává schválně jako parametr, ne čte z `settings`: trigger na
-- `settings` potřebuje ověřit NOVOU hodnotu ještě předtím, než je uložená.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hodiny_bez_pasma(_oh jsonb)
 RETURNS TABLE (den int, hodina int)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT d.den, h.hodina
    FROM (SELECT generate_series(1, 7) AS den) d
    CROSS JOIN LATERAL (
      SELECT generate_series(
               extract(hour FROM (_oh -> d.den::text ->> 'open')::time)::int,
               -- Polootevřený interval: zavírá-li se ve 22:00, poslední
               -- placená hodina je 21:00–22:00.
               extract(hour FROM (_oh -> d.den::text ->> 'close')::time)::int - 1
             ) AS hodina
    ) h
   WHERE _oh -> d.den::text ->> 'open' IS NOT NULL
     AND _oh -> d.den::text ->> 'close' IS NOT NULL
     AND NOT EXISTS (
           SELECT 1 FROM public.cenik_pasma p
            WHERE p.deleted_at IS NULL
              AND p.den_typ = (CASE WHEN d.den >= 6 THEN 'vikend' ELSE 'vsedni' END)::public.den_typ
              AND h.hodina >= p.od_hodina AND h.hodina < p.do_hodina
         )
   ORDER BY d.den, h.hodina;
$$;

COMMENT ON FUNCTION public.hodiny_bez_pasma(jsonb) IS
  'Hodiny otevírací doby, na které není v cenik_pasma živé pásmo. Prázdný výsledek = klubový led jde ocenit v celé provozní době. Používají to oba hlídací triggery i test; cena_ledu na takovou hodinu vyhodí výjimku, takže bez tohohle by se mezera projevila až padající rezervací.';

REVOKE ALL ON FUNCTION public.hodiny_bez_pasma(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hodiny_bez_pasma(jsonb) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Hlídací trigger pro obě strany
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_cenik_pokryva_provoz()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _oh jsonb; _chybi text;
BEGIN
  SELECT opening_hours INTO _oh FROM public.settings LIMIT 1;
  IF _oh IS NULL THEN
    RETURN NULL;   -- bez otevírací doby není co pokrývat
  END IF;

  SELECT string_agg(format('%s %s:00', 
           CASE den WHEN 1 THEN 'Po' WHEN 2 THEN 'Út' WHEN 3 THEN 'St' WHEN 4 THEN 'Čt'
                    WHEN 5 THEN 'Pá' WHEN 6 THEN 'So' ELSE 'Ne' END, hodina), ', ')
    INTO _chybi
    FROM public.hodiny_bez_pasma(_oh);

  IF _chybi IS NOT NULL THEN
    RAISE EXCEPTION 'Ceník ledu nepokrývá celou otevírací dobu — chybí pásmo na: %.', _chybi
      USING HINT = 'Buď zkrať otevírací dobu, nebo doplň pásmo do ceníku (cenik_pasma). Bez toho by klubová rezervace v té hodině skončila chybou.';
  END IF;

  RETURN NULL;   -- AFTER trigger, návratová hodnota se nepoužije
END;
$$;

COMMENT ON FUNCTION public.trg_cenik_pokryva_provoz() IS
  'Odložená kontrola, že se otevírací doba a pásmový ceník nerozejdou. Visí na settings i cenik_pasma, protože díru umí vyrobit obě strany — a projevila by se až tím, že členovi klubu spadne rezervace na hlášku, která ho posílá na neexistující obrazovku.';

-- CONSTRAINT TRIGGER + DEFERRABLE INITIALLY DEFERRED: kontroluje se až
-- na konci transakce. Bez toho by neprošla úprava ceníku po částech (zúžit
-- jedno pásmo, rozšířit druhé), přestože výsledek je v pořádku.
DROP TRIGGER IF EXISTS trg_settings_cenik_pokryti ON public.settings;
CREATE CONSTRAINT TRIGGER trg_settings_cenik_pokryti
  AFTER UPDATE OF opening_hours ON public.settings
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.trg_cenik_pokryva_provoz();

DROP TRIGGER IF EXISTS trg_cenik_pasma_pokryti ON public.cenik_pasma;
CREATE CONSTRAINT TRIGGER trg_cenik_pasma_pokryti
  AFTER INSERT OR UPDATE OR DELETE ON public.cenik_pasma
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.trg_cenik_pokryva_provoz();

-- -----------------------------------------------------------------------------
-- 3b) Hláška, která nelže
--
-- Tělo z `pg_get_functiondef` živého schématu (pravidlo 7); zásah je jediný
-- `RAISE EXCEPTION`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cena_ledu(_start timestamp with time zone, _end timestamp with time zone)
 RETURNS TABLE(castka numeric, rozpis jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _h        timestamptz;
  _hodina   int;
  _je_vikend boolean;
  _sazba    numeric;
  _po_sazbach jsonb := '{}'::jsonb;
  _klic     text;
BEGIN
  IF _start IS NULL OR _end IS NULL OR _end <= _start THEN
    RAISE EXCEPTION 'Neplatný časový rozsah pro výpočet ceny.';
  END IF;

  -- Po hodinách. Rezervace jsou od `validate_reservation_slot` celé hodiny,
  -- takže smyčka vždycky vyjde přesně; kdyby se to někdy uvolnilo, poslední
  -- neúplná hodina by se sem nedostala a bylo by to vidět na součtu.
  _h := _start;
  WHILE _h < _end LOOP
    _hodina := extract(hour FROM (_h AT TIME ZONE 'Europe/Prague'))::int;
    _je_vikend := extract(isodow FROM (_h AT TIME ZONE 'Europe/Prague')) >= 6;

    SELECT p.sazba INTO _sazba
      FROM public.cenik_pasma p
     WHERE p.den_typ = (CASE WHEN _je_vikend THEN 'vikend' ELSE 'vsedni' END)::public.den_typ
       AND _hodina >= p.od_hodina AND _hodina < p.do_hodina
       AND p.deleted_at IS NULL;

    IF _sazba IS NULL THEN
      -- RADŠI NEVYSTAVIT NEŽ OCENIT NAPRÁZDNO. Hodina bez pásma znamená, že
      -- se rozešla otevírací doba s ceníkem — a tichá nula nebo pád na výchozí
      -- sazbu by se projevily až na faktuře.
      --
      -- HLÁŠKA UŽ NEPOSÍLÁ „DO NASTAVENÍ": editor pásmového ceníku v aplikaci
      -- není, takže ta rada vedla na obrazovku, která neexistuje — a dostal ji
      -- člen klubu, který s ní stejně nic nezmůže. Že mezera vůbec vznikne,
      -- hlídají od 20260831234000 dva odložené triggery; tohle je poslední
      -- záchrana pro data, která se sem dostala jinudy.
      RAISE EXCEPTION 'Led na % v % h nemá v ceníku cenu, tak ho zatím nejde zarezervovat.',
        CASE WHEN _je_vikend THEN 'víkend' ELSE 'všední den' END, _hodina
        USING HINT = 'Řekněte to správci haly — musí doplnit pásmo do ceníku ledu, nebo upravit otevírací dobu.';
    END IF;

    -- Sčítá se PO SAZBÁCH, ne po hodinách: doklad má mít jeden řádek na sazbu
    -- („2 h × 1 200"), ne řádek na každou hodinu.
    _klic := _sazba::text;
    _po_sazbach := jsonb_set(_po_sazbach, ARRAY[_klic],
      to_jsonb(COALESCE((_po_sazbach ->> _klic)::numeric, 0) + 1));

    _h := _h + interval '1 hour';
  END LOOP;

  SELECT
    -- Přesný součet, nic se průběžně nezaokrouhluje (pravidlo R3).
    COALESCE(sum((k.key)::numeric * (k.value)::numeric), 0),
    COALESCE(jsonb_agg(jsonb_build_object('sazba', (k.key)::numeric, 'hodin', (k.value)::numeric)
                       ORDER BY (k.key)::numeric), '[]'::jsonb)
    INTO castka, rozpis
    FROM jsonb_each_text(_po_sazbach) AS k;

  RETURN NEXT;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _oh jsonb; _n int;
BEGIN
  SELECT opening_hours INTO _oh FROM public.settings LIMIT 1;
  SELECT count(*) INTO _n FROM public.hodiny_bez_pasma(_oh);
  IF _n > 0 THEN
    RAISE EXCEPTION 'Ceník už teď nepokrývá % hodin provozu — oprav data, než se zapne hlídání.', _n;
  END IF;

  IF EXISTS (SELECT 1 FROM public.cenik_pasma
              WHERE deleted_at IS NULL AND popis LIKE '%čeká na potvrzení%') THEN
    RAISE EXCEPTION 'V ceníku pořád stojí placeholder v popisu pásma.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_settings_cenik_pokryti' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Hlídání otevírací doby se nevytvořilo.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.cena_ledu(timestamptz,timestamptz)'::regprocedure)
     LIKE '%Doplň ho v Nastavení%' THEN
    RAISE EXCEPTION 'cena_ledu pořád posílá na neexistující obrazovku.';
  END IF;

  RAISE NOTICE 'Ceník pokrývá provoz a hlídá se to z obou stran.';
END $kontrola$;
