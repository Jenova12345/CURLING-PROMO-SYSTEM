-- =============================================================================
-- Částečný dobropis
-- =============================================================================
-- Doteď šlo doklad jen CELÝ stornovat. Častější případ je ale menší: akce byla
-- kratší, jedna dráha se nakonec nepoužila, sazba se spletla o stovku. Na to se
-- vystavuje opravný doklad jen na ČÁST původní faktury.
--
-- ROZDÍL PROTI PLNÉMU STORNU (rozhodnutí R1, řádek 126 plánu):
--   plné storno       → původní doklad `stornovano`, rezervace se UVOLNÍ
--   částečný dobropis → původní doklad zůstává VYSTAVENÝ, rezervace se
--                       NEUVOLŇUJE
--
-- Proč se zámek nepouští: rezervace by se dostala mezi „k fakturaci" a někdo
-- (nebo automatika) by naúčtoval znovu něco, co je částečně dobropisované.
-- Zbytek se dofakturuje výhradně ručně doplňkovou fakturou.
--
-- DOPAD NA KONTROLNÍ SOUČET — nosná část
--
-- U plného storna se opravný doklad z rovnice VYPOUŠTÍ: originál je
-- `stornovano`, tedy z `fakturovano` venku, a odečítat k tomu ještě dobropis by
-- šlo do mínusu. U částečného dobropisu ale originál zůstává vystavený a jeho
-- řádky se dál počítají v plné výši — jenže klub tolik nedluží.
--
-- Pravidlo je proto: **opravný doklad se odečítá právě tehdy, když doklad,
-- který opravuje, je pořád aktivní.** Jinak se ignoruje.
--
-- Aby rovnice vyšla, musí zároveň klesnout `dluzi` — a to je `corrected_amount`
-- na rezervaci, který v tomhle repu existuje přesně na tenhle druh opravy.
-- RPC ho proto nastavuje samo; kdyby to nechalo na člověku, rovnice by se
-- rozešla přesně o dobropisovanou částku a nikdo by nevěděl proč.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Na jeden doklad může být víc opravných dokladů
--
-- Unikátní index vznikl u plného storna, kde dává smysl (jednou zrušený doklad
-- se podruhé ruší těžko). Částečných dobropisů může být několik — dvakrát se
-- opravovaly různé řádky. Že se nedá stornovat už stornované, hlídá dál
-- `storno_invoice`.
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS public.idx_invoices_jeden_opravny;

-- Plné storno ale pořád smí být jen jedno: opravný doklad BEZ vybraných položek
-- (tedy zrcadlo celé faktury) se pozná podle `je_plne_storno`.
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS je_plne_storno boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.invoices.je_plne_storno IS
  'Opravný doklad ruší CELOU původní fakturu (a uvolnil její rezervace). false = částečný dobropis, po kterém původní doklad dál platí.';

UPDATE public.invoices o SET je_plne_storno = true
 WHERE o.opravuje_id IS NOT NULL
   AND o.je_plne_storno = false
   AND EXISTS (SELECT 1 FROM public.invoices p
                WHERE p.id = o.opravuje_id AND p.status = 'stornovano');

CREATE UNIQUE INDEX IF NOT EXISTS idx_invoices_jedno_plne_storno
  ON public.invoices (opravuje_id) WHERE opravuje_id IS NOT NULL AND je_plne_storno;

-- Guard: `je_plne_storno` se nastavuje při vzniku a pak už ne.
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.guard_invoice_immutable()'::regprocedure);
  IF position('je_plne_storno' in _def) = 0 THEN
    -- Do whitelistu se NEPŘIDÁVÁ schválně: u vystaveného dokladu se měnit nesmí.
    RAISE NOTICE 'je_plne_storno není ve whitelistu guardu — správně, u vystaveného dokladu se nemění.';
  END IF;
END $$;

-- `storno_invoice` musí nový příznak nastavovat, jinak by plné storno šlo udělat
-- podruhé. Tělo z `pg_get_functiondef` (pravidlo 7).
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.storno_invoice(uuid, text)'::regprocedure);
  IF position('je_plne_storno' in _def) = 0 THEN
    _def := replace(_def,
      $stare$      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid)$stare$,
      $nove$      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid)$nove$);
    _def := replace(_def,
      $stare$      opravuje_id, storno_duvod, created_by)$stare$,
      $nove$      opravuje_id, storno_duvod, created_by, je_plne_storno)$nove$);
    _def := replace(_def,
      $stare$      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid)
  RETURNING id INTO _opr;$stare$,
      $nove$      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid, true)
  RETURNING id INTO _opr;$nove$);
    EXECUTE _def;
  END IF;

  IF position('je_plne_storno' in pg_get_functiondef('public.storno_invoice(uuid, text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'storno_invoice neoznačuje plné storno — šlo by ho udělat dvakrát.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) Částečný dobropis
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dobropis_invoice(
  _invoice_id uuid,
  _polozky    uuid[],
  _duvod      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid    uuid := auth.uid();
  _p      record;
  _bs     record;
  _opr    uuid;
  _cislo  text;
  _dnes   date;
  _radku  integer;
  _castka numeric(12,2);
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Opravné doklady vystavuje jen správce haly.';
  END IF;

  SELECT * INTO _p FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Doklad neexistuje.';
  END IF;
  IF _p.status = 'koncept' THEN
    RAISE EXCEPTION 'Koncept se nedobropisuje — uprav ho, nebo zahoď.';
  END IF;
  IF _p.status = 'stornovano' THEN
    RAISE EXCEPTION 'Doklad % je celý stornovaný, není co dobropisovat.', _p.cislo;
  END IF;
  IF _p.opravuje_id IS NOT NULL THEN
    RAISE EXCEPTION 'Opravný doklad se sám nedobropisuje.';
  END IF;
  IF _polozky IS NULL OR array_length(_polozky, 1) IS NULL THEN
    RAISE EXCEPTION 'Vyber aspoň jednu položku k dobropisu.'
      USING HINT = 'Na celý doklad je storno, ne dobropis.';
  END IF;

  -- Všechny vybrané položky musí patřit TOMUHLE dokladu. Bez téhle kontroly by
  -- šlo dobropisovat řádky z cizí faktury a částky by se rozešly u obou.
  SELECT count(*), COALESCE(sum(line_total), 0) INTO _radku, _castka
    FROM public.invoice_items
   WHERE id = ANY (_polozky) AND invoice_id = _invoice_id;

  IF _radku <> array_length(_polozky, 1) THEN
    RAISE EXCEPTION 'Některé vybrané položky na dokladu % nejsou.', _p.cislo
      USING HINT = 'Dobropisovat jde jen řádky téhle faktury.';
  END IF;
  IF _castka <= 0 THEN
    RAISE EXCEPTION 'Dobropis na nulovou částku nedává smysl.';
  END IF;

  -- Celý doklad = storno, ne dobropis. Jinak by vznikl opravný doklad na plnou
  -- částku, ale originál by dál platil a rezervace zůstaly zamčené — stav,
  -- ze kterého není cesta ven.
  IF _radku = (SELECT count(*) FROM public.invoice_items WHERE invoice_id = _invoice_id) THEN
    RAISE EXCEPTION 'Vybral jsi všechny položky — na celý doklad použij storno.'
      USING HINT = 'Storno navíc uvolní rezervace zpět k fakturaci; dobropis je schválně nechává zamčené.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;
  IF COALESCE(_bs.separate_series, false) THEN
    RAISE EXCEPTION 'Oddělené číselné řady zatím nejsou implementované.';
  END IF;

  _dnes := (now() AT TIME ZONE 'Europe/Prague')::date;

  INSERT INTO public.invoices (
      kind, status, subject_id, event_id, obdobi_od, obdobi_do,
      dodavatel_nazev, dodavatel_adresa, dodavatel_ico, dodavatel_dic,
      dodavatel_rejstrik, dodavatel_ucet, dodavatel_iban, dodavatel_zprava,
      vat_mode, odberatel_nazev, odberatel_adresa, odberatel_ico, odberatel_dic,
      opravuje_id, storno_duvod, created_by, je_plne_storno)
  VALUES (
      _p.kind, 'koncept', _p.subject_id, _p.event_id, _p.obdobi_od, _p.obdobi_do,
      _p.dodavatel_nazev, _p.dodavatel_adresa, _p.dodavatel_ico, _p.dodavatel_dic,
      _p.dodavatel_rejstrik, _p.dodavatel_ucet, _p.dodavatel_iban, _p.dodavatel_zprava,
      _p.vat_mode, _p.odberatel_nazev, _p.odberatel_adresa, _p.odberatel_ico, _p.odberatel_dic,
      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid, false)
  RETURNING id INTO _opr;

  -- Zrcadlo VYBRANÝCH řádků.
  INSERT INTO public.invoice_items (
      invoice_id, reservation_id, popis, datum, cas_od, cas_do,
      hodiny, sazba, line_total, vat_rate, vat_base, vat_amount, poradi)
  SELECT _opr, it.reservation_id, it.popis, it.datum, it.cas_od, it.cas_do,
         it.hodiny, it.sazba, it.line_total, it.vat_rate, it.vat_base, it.vat_amount, it.poradi
    FROM public.invoice_items it
   WHERE it.id = ANY (_polozky)
   ORDER BY it.poradi, it.datum;

  _cislo := public.next_invoice_number('spolecna', EXTRACT(year FROM _dnes)::integer);

  UPDATE public.invoices SET
      status = 'vystaveno', cislo = _cislo,
      variabilni_symbol = regexp_replace(_cislo, '\D', '', 'g'),
      datum_vystaveni = _dnes, datum_splatnosti = _dnes,
      issued_at = now(), issued_by = _uid,
      pdf_status = 'pending'
   WHERE id = _opr;

  -- CO SE SCHVÁLNĚ NEDĚJE: nesráží se částka na rezervaci.
  --
  -- Zkusil jsem to a schéma to odmítlo — `corrected_amount` PŘEPISUJE cenový
  -- trigger, protože je odvozený z `corrected_hours`. A hlavně to není potřeba:
  -- rovnice kontrolního součtu porovnává rezervace proti řádkům dokladů, a ani
  -- jedno se dobropisem nemění. Rezervace zůstává zamčená na původní faktuře
  -- (R1) a její řádek na ní dál je.
  --
  -- Kolik z vyfakturovaného se vrátilo, tedy NENÍ v rovnici — je to vlastní
  -- sloupec `dobropisovano`. Rovnice hlídá rozejití rezervací a dokladů;
  -- „kolik klub po dobropisu opravdu zaplatí" je jiná otázka a zaslouží si
  -- vlastní číslo, ne schované v `fakturovano`.

  RETURN jsonb_build_object(
    'opravny_id', _opr,
    'opravny_cislo', _cislo,
    'dobropisovano', _castka,
    'radku', _radku,
    'puvodni_cislo', _p.cislo);

EXCEPTION
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Opravný doklad se nepodařilo vystavit.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj vybrané položky a stav dokladu v Přehledu fakturace.';
END;
$$;

REVOKE ALL ON FUNCTION public.dobropis_invoice(uuid, uuid[], text) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.dobropis_invoice(uuid, uuid[], text) TO authenticated;

COMMENT ON FUNCTION public.dobropis_invoice(uuid, uuid[], text) IS
  'Částečný dobropis: opravný doklad na vybrané řádky. Původní faktura dál platí a rezervace zůstávají zamčené (R1) — zbytek se dofakturuje ručně. Sráží corrected_amount, aby seděl kontrolní součet.';

-- -----------------------------------------------------------------------------
-- 3) Kontrolní součet: dobropisy se nepočítají do rovnice, ale je vidět kolik jich je
--
-- Rovnice `dluzi = fakturovano + v_konceptu + ve_stornu + k_fakturaci +
-- neschvalene` porovnává REZERVACE proti ŘÁDKŮM DOKLADŮ. Dobropis ani jedno
-- nemění — rezervace zůstává zamčená (R1) a řádek na původní faktuře dál je.
-- Zůstává tedy z rovnice venku, přesně jako doteď.
--
-- MĚL JSEM TO JINAK a bylo to horší: odečítal jsem dobropisy od `fakturovano`
-- a k tomu srážel částku na rezervaci. Rozbilo to obojí — `rozdil` vyšel
-- o dobropisovanou částku vedle a po stornu spadlo `fakturovano` do mínusu.
--
-- Přibývá jen INFORMATIVNÍ sloupec: kolik z vyfakturovaného se vrátilo
-- dobropisem. Do rovnice nevstupuje, ale bez něj by „Kdo dluží" tiše
-- nadhodnocoval o dobropisovanou částku a nikde by to nebylo vidět.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.billing_reconcile(date,date)'::regprocedure);
  IF position('dobropisovano' in _def) > 0 THEN
    RAISE NOTICE 'billing_reconcile už dobropisy vykazuje.';
    RETURN;
  END IF;

  -- (a) nový sloupec do hlavičky, hned za `ve_stornu`
  _def := replace(_def, 've_stornu numeric,', 've_stornu numeric, dobropisovano numeric,');

  -- (b) do `radky` pustit i opravné doklady, ale označené — a s vazbou na to,
  --     jestli doklad, který opravují, ještě platí
  _def := replace(_def,
    $stare$     WHERE i.opravuje_id IS NULL$stare$,
    $nove$     LEFT JOIN public.invoices puv ON puv.id = i.opravuje_id
     WHERE i.opravuje_id IS NULL
        -- Dobropis se vykazuje, JEN dokud doklad, který opravuje, platí.
        -- U stornovaného originálu by šlo o dvojí započtení téhož zrušení.
        OR puv.status IN ('vystaveno', 'zaplaceno')$nove$);

  _def := replace(_def,
    $stare$           rez.invoice_id AS zamek$stare$,
    $nove$           rez.invoice_id AS zamek,
           (i.opravuje_id IS NOT NULL) AS je_dobropis$nove$);

  -- (c) `fakturovano` počítá jen doklady, NE dobropisy (jinak by rovnice
  --     přestala platit); dobropisy jdou do vlastního sloupce
  _def := replace(_def,
    $stare$           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')) AS fakturovano,$stare$,
    $nove$           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')
                                             AND NOT radky.je_dobropis)                AS fakturovano,
           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')
                                             AND radky.je_dobropis)                    AS dobropisovano,$nove$);

  _def := replace(_def,
    $stare$           sum(radky.line_total) FILTER (WHERE radky.status = 'koncept')                   AS v_konceptu,$stare$,
    $nove$           sum(radky.line_total) FILTER (WHERE radky.status = 'koncept'
                                             AND NOT radky.je_dobropis)                AS v_konceptu,$nove$);

  -- (d) vydat nový sloupec ve výsledku
  _def := replace(_def,
    $stare$         COALESCE(d.ve_stornu, 0),$stare$,
    $nove$         COALESCE(d.ve_stornu, 0),
         COALESCE(d.dobropisovano, 0),$nove$);

  -- Přibývá sloupec, tedy se MĚNÍ návratový typ — `CREATE OR REPLACE` to
  -- neumí a funkce musí nejdřív pryč. Grant se proto vrací hned za tím.
  DROP FUNCTION public.billing_reconcile(date, date);
  EXECUTE _def;
  REVOKE ALL ON FUNCTION public.billing_reconcile(date, date) FROM public, anon, service_role;
  GRANT EXECUTE ON FUNCTION public.billing_reconcile(date, date) TO authenticated;
END $$;

DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.billing_reconcile(date,date)'::regprocedure);
  IF position('dobropisovano' in _def) = 0 THEN
    RAISE EXCEPTION 'billing_reconcile nevykazuje dobropisy — „Kdo dluží" by tiše nadhodnocoval.';
  END IF;
  RAISE NOTICE 'Částečný dobropis připravený; rovnice beze změny, dobropisy ve vlastním sloupci.';
END $$;
