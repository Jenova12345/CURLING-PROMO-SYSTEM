-- =============================================================================
-- Storno vystaveného dokladu opravným dokladem (Etapa 2, fáze B)
--
-- Rozhodnutí PM (17. 8. 2026):
--   * doklad se jmenuje „Opravný doklad" (režim neplátce DPH)
--   * stornovat jde i ZAPLACENOU fakturu, nejen nezaplacenou
--   * kontrolní součet musí po stornu sedět; nesedící opravné doklady se počítají
--
-- CO SE DĚJE PŘI STORNU
--   1. vznikne opravný doklad — samostatný dokument s vlastním číslem z téže
--      řady, zrcadlí řádky originálu a odkazuje na něj přes `opravuje_id`
--   2. původní doklad přejde do stavu `stornovano` (položky zůstávají, je to
--      historie — vystavený doklad se nemaže, to hlídá `guard_invoice_immutable`)
--   3. rezervace se uvolní (`invoice_id = NULL`), takže se vrátí mezi
--      „k fakturaci" a dají se vyfakturovat znovu
--
-- PROČ KLADNÉ ČÁSTKY: schéma záporný doklad nepustí — `invoice_items` má
-- `hodiny > 0`, `sazba >= 0` a `line_total = round(hodiny*sazba,2)`, hlavička má
-- `invoices_castky_nezaporne`. Opravný doklad proto nese TYTÉŽ kladné částky
-- jako originál a jeho význam („tohle se ruší") drží `opravuje_id`, ne znaménko.
--
-- DOPAD NA KONTROLNÍ SOUČET — nosná část téhle migrace
--
-- Rovnice `dluzi = fakturovano + v_konceptu + ve_stornu + k_fakturaci +
-- neschvalene` se stornem sama od sebe ROZBIJE: uvolněná rezervace se počítá
-- jednou jako `ve_stornu` (řádek stornovaného dokladu) a podruhé jako
-- `k_fakturaci` (prázdný zámek). Změřeno před opravou: `rozdil = -22 600`.
-- Proto se tady mění i `billing_reconcile`:
--   * opravné doklady se do rovnice nezapočítávají (zrcadlí originál)
--   * `ve_stornu` počítá jen rezervace, které na stornovaném dokladu VISÍ
--     (částečný dobropis) — po plném stornu je nese `k_fakturaci`
--
-- Obě funkce jsou vygenerované z `pg_get_functiondef` živého schématu
-- (pravidlo 7) a vložený je do nich jen tenhle zásah.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Vazba opravného dokladu na původní
-- -----------------------------------------------------------------------------
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS opravuje_id  uuid REFERENCES public.invoices(id),
  ADD COLUMN IF NOT EXISTS storno_duvod text;

COMMENT ON COLUMN public.invoices.opravuje_id IS
  'Vyplněné = tenhle doklad je OPRAVNÝ DOKLAD a ruší doklad, na který ukazuje. Vyřazuje ho to z rovnice billing_reconcile (jinak by se rezervace počítala dvakrát); že sedí s originálem, hlídá billing_health.opravne_nesedi.';
COMMENT ON COLUMN public.invoices.storno_duvod IS
  'Proč se doklad stornoval. Píše se na opravný doklad, ne na originál — originál je neměnný.';

DO $$
BEGIN
  -- Sám sebe opravovat nemůže.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_opravny_ne_sam_sebe') THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_opravny_ne_sam_sebe CHECK (opravuje_id IS NULL OR opravuje_id <> id);
  END IF;
  -- Důvod storna dává smysl jen na opravném dokladu.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_duvod_jen_na_opravnem') THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_duvod_jen_na_opravnem CHECK (storno_duvod IS NULL OR opravuje_id IS NOT NULL);
  END IF;
END $$;

-- Jeden opravný doklad na jeden originál. Dnes umíme jen PLNÉ storno, takže dva
-- opravné doklady na tutéž fakturu by znamenaly, že se něco vrátilo dvakrát.
-- (Až přijde částečný dobropis, tenhle index se cíleně uvolní — a bude to
-- vědomá změna pravidla, ne přehlédnutí.)
CREATE UNIQUE INDEX IF NOT EXISTS idx_invoices_jeden_opravny
  ON public.invoices (opravuje_id) WHERE opravuje_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2) Storno: opravný doklad + uvolnění rezervací
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.storno_invoice(_invoice_id uuid, _duvod text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid    uuid := auth.uid();
  _p      record;      -- původní doklad
  _bs     record;
  _opr    uuid;        -- opravný doklad
  _cislo  text;
  _dnes   date;
  _uvolneno integer;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Doklady stornuje jen správce haly.';
  END IF;

  -- Zámek: dvě souběžná kliknutí na „Stornovat" by jinak vyrobila dva opravné
  -- doklady, tedy dvě čísla v řadě a dvojí vrácení téže částky.
  SELECT * INTO _p FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Doklad neexistuje.';
  END IF;

  -- Koncept se stornovat nedá, protože ještě není dokladem — ten se zahazuje
  -- (`delete_invoice_draft`). Kdyby se na něj vystavil opravný doklad, vzniklo by
  -- číslo v řadě k dokladu, který nikdy neexistoval.
  IF _p.status = 'koncept' THEN
    RAISE EXCEPTION 'Koncept se nestornuje — zahoď ho.'
      USING HINT = 'Storno je na vystavené doklady; koncept ještě dokladem není.';
  END IF;
  IF _p.status = 'stornovano' THEN
    RAISE EXCEPTION 'Doklad % je už stornovaný.', _p.cislo;
  END IF;
  IF _p.opravuje_id IS NOT NULL THEN
    RAISE EXCEPTION 'Opravný doklad se sám nestornuje.'
      USING HINT = 'Ruší se jím původní faktura; další opravný doklad na něj nepatří.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;
  IF COALESCE(_bs.separate_series, false) THEN
    RAISE EXCEPTION 'Oddělené číselné řady zatím nejsou implementované.'
      USING HINT = 'V Nastavení → Fakturace nech „jedna společná řada" (rozhodnutí PM k otázce Q6).';
  END IF;

  -- Pražské datum, ne `current_date`: databáze běží v UTC, takže 1. ledna po
  -- půlnoci by doklad dostal loňský rok v čísle (týž důvod jako v `issue_invoice`).
  _dnes := (now() AT TIME ZONE 'Europe/Prague')::date;

  -- Opravný doklad vzniká jako KONCEPT, protože do vystaveného dokladu už
  -- `guard_invoice_item_immutable` položky nepustí. Číslo dostane až na konci.
  INSERT INTO public.invoices (
      kind, status, subject_id, event_id, obdobi_od, obdobi_do,
      dodavatel_nazev, dodavatel_adresa, dodavatel_ico, dodavatel_dic,
      dodavatel_rejstrik, dodavatel_ucet, dodavatel_iban, dodavatel_zprava,
      vat_mode, odberatel_nazev, odberatel_adresa, odberatel_ico, odberatel_dic,
      opravuje_id, storno_duvod, created_by)
  VALUES (
      _p.kind, 'koncept', _p.subject_id, _p.event_id, _p.obdobi_od, _p.obdobi_do,
      _p.dodavatel_nazev, _p.dodavatel_adresa, _p.dodavatel_ico, _p.dodavatel_dic,
      _p.dodavatel_rejstrik, _p.dodavatel_ucet, _p.dodavatel_iban, _p.dodavatel_zprava,
      _p.vat_mode, _p.odberatel_nazev, _p.odberatel_adresa, _p.odberatel_ico, _p.odberatel_dic,
      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid)
  RETURNING id INTO _opr;

  -- Zrcadlo řádků. Snapshot údajů se přebírá z ORIGINÁLU, ne z dnešních rezervací:
  -- opravný doklad musí ukazovat totéž, co se rušilo, i když se rezervace mezitím
  -- změnila nebo zrušila (což je jeden z hlavních důvodů, proč se storno dělá).
  INSERT INTO public.invoice_items (
      invoice_id, reservation_id, popis, datum, cas_od, cas_do,
      hodiny, sazba, line_total, vat_rate, vat_base, vat_amount, poradi)
  SELECT _opr, it.reservation_id, it.popis, it.datum, it.cas_od, it.cas_do,
         it.hodiny, it.sazba, it.line_total, it.vat_rate, it.vat_base, it.vat_amount, it.poradi
    FROM public.invoice_items it
   WHERE it.invoice_id = _invoice_id
   ORDER BY it.poradi, it.datum;

  -- Součty dopočítal trigger `recalc_invoice_totals` z položek; ručně se nepíšou.
  _cislo := public.next_invoice_number('spolecna', EXTRACT(year FROM _dnes)::integer);

  UPDATE public.invoices SET
      status            = 'vystaveno',
      cislo             = _cislo,
      variabilni_symbol = regexp_replace(_cislo, '\D', '', 'g'),
      datum_vystaveni   = _dnes,
      -- Splatnost = datum vystavení: opravným dokladem se nic neplatí, ale
      -- `invoices_cislo_dle_stavu` ji u vystaveného dokladu vyžaduje.
      datum_splatnosti  = _dnes,
      issued_at         = now(),
      issued_by         = _uid
   WHERE id = _opr;

  -- Původní doklad do storna. `status` je ve whitelistu guardu, takže tohle
  -- immutabilitu neporušuje — částky, strany ani číslo se nemění.
  UPDATE public.invoices SET status = 'stornovano' WHERE id = _invoice_id;

  -- Uvolnění rezervací. `app.trusted_booking` je jediná cesta, jak zámek pustit:
  -- `guard_reservation_rep_changes` ho jinak brání i adminovi právě proto, aby
  -- se rezervace nedala odpojit od neměnného dokladu jinudy než stornem.
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET invoice_id = NULL, invoiced_at = NULL
   WHERE invoice_id = _invoice_id;
  GET DIAGNOSTICS _uvolneno = ROW_COUNT;
  -- Vypnout hned: zvýšené oprávnění nesmí platit pro zbytek transakce.
  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object(
    'opravny_id',    _opr,
    'opravny_cislo', _cislo,
    'stornovana_id', _invoice_id,
    'stornovane_cislo', _p.cislo,
    'castka',        (SELECT total_rounded FROM public.invoices WHERE id = _opr),
    'uvolneno_rezervaci', _uvolneno);

EXCEPTION
  -- R11: uvnitř SECURITY DEFINER neplatí RLS, takže by Postgres do chyby doplnil
  -- celý řádek dokladu — včetně IBANu dodavatele a jména odběratele.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Doklad se nepodařilo stornovat.'
      USING ERRCODE = '22023',
            HINT = 'Zkus to znovu; když to potrvá, zkontroluj stav dokladu v Přehledu fakturace.';
END;
$$;

REVOKE ALL ON FUNCTION public.storno_invoice(uuid, text) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.storno_invoice(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.storno_invoice(uuid, text) IS
  'Stornuje vystavený (i zaplacený) doklad: vystaví opravný doklad se zrcadlenými řádky, převede originál do stavu stornovano a uvolní rezervace zpět k fakturaci. Koncept nestornuje — ten se zahazuje.';

-- -----------------------------------------------------------------------------
-- 3) Kontrolní součet: opravné doklady ven, `ve_stornu` jen na visící rezervace
--
-- Tělo je vygenerované z `pg_get_functiondef` (pravidlo 7); vložený je jen zásah
-- popsaný v hlavičce migrace.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_reconcile(_od date, _do date)
 RETURNS TABLE(subject_id uuid, subjekt text, fakturovano numeric, v_konceptu numeric, ve_stornu numeric, k_fakturaci numeric, neschvalene numeric, dluzi numeric, rozdil numeric, rezervaci bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _zacatek timestamptz;
  _konec   timestamptz;
  _jen_schvalene boolean;
BEGIN
  -- Kontrolní součet ukazuje peníze všech subjektů — tedy adminská věc.
  --
  -- Výjimka je JEN pro běh pod databázovou rolí (pg_cron ve fázi D poběží jako
  -- `postgres`, kde `auth.uid()` je NULL). Podmínka schválně NESTOJÍ jen na
  -- „auth.uid() IS NULL": to by z chybějícího `sub` v tokenu udělalo klíč
  -- k obratům všech klubů. Že se takový token přes PostgREST dnes nesloží, je
  -- shoda okolností v konfiguraci, ne vlastnost téhle funkce — a `session_user`
  -- je totéž kritérium, jaké používá guard v rezervacích (booking_core.sql).
  IF NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Kontrolní součet fakturace vidí jen správce haly.';
  END IF;
  IF _od IS NULL OR _do IS NULL OR _do < _od THEN
    RAISE EXCEPTION 'Neplatné období (od % do %).', _od, _do;
  END IF;

  SELECT zacatek, konec INTO _zacatek, _konec FROM public.obdobi_hranice(_od, _do);
  SELECT COALESCE(bs.invoice_only_approved, true) INTO _jen_schvalene
    FROM public.billing_settings bs LIMIT 1;
  _jen_schvalene := COALESCE(_jen_schvalene, true);

  RETURN QUERY
  WITH rez AS (
    -- Jedna definice „co je zpoplatněné" pro obě strany rovnice.
    SELECT r.id, r.subject_id,
           COALESCE(r.corrected_amount, r.amount) AS castka,
           r.invoice_id,
           (r.approved_at IS NOT NULL) AS schvalena
      FROM public.reservations r
     WHERE r.status = 'confirmed'
       AND r.deleted_at IS NULL
       AND r.subject_id IS NOT NULL
       AND r.start_at >= _zacatek
       AND r.start_at <  _konec
  ),
  radky AS (
    -- Řádky dokladů patřící rezervacím v období. `LEFT JOIN` schválně NE:
    -- řádek bez rezervace (sleva, storno poplatek) do porovnání s „Kdo dluží"
    -- nepatří, protože na druhé straně rovnice žádnou rezervaci nemá.
    -- (Že je pak nepočítá vůbec nikdo, hlídá `billing_health.radky_bez_rezervace`.)
    --
    -- SESKUPUJE SE PODLE `i.subject_id`, ne podle subjektu rezervace. Admin smí
    -- rezervaci přepsat subjekt i po vyfakturování (guard mu brání jen v `invoice_id`),
    -- a pak se peníze na dokladu a dnešní příslušnost rezervace rozejdou. S
    -- `rez.subject_id` vyšla rovnice OBĚMA klubům: jednomu se „vyfakturovalo" to,
    -- co má na dokladu druhý, a `rozdil` byl u obou nula. Doklad ví, komu je
    -- vystavený — tak ať rozhoduje on.
    SELECT i.subject_id,
           i.status,
           it.line_total,
           -- Zámek rezervace. Rozhoduje o tom, jestli řádek stornovaného dokladu
           -- ještě někoho zavazuje, nebo je to už jen historie (viz `ve_stornu`).
           rez.invoice_id AS zamek
      FROM rez
      JOIN public.invoice_items it ON it.reservation_id = rez.id
      JOIN public.invoices i       ON i.id = it.invoice_id
     -- OPRAVNÉ DOKLADY SE NEPOČÍTAJÍ. Zrcadlí řádky původní faktury, takže by
     -- tutéž rezervaci naúčtovaly podruhé. Že opravný doklad sedí s originálem,
     -- hlídá `billing_health.opravne_nesedi` — ať ta výjimka není slepé místo.
     WHERE i.opravuje_id IS NULL
  ),
  souhrn AS (
    SELECT rez.subject_id,
           count(*)                                                    AS rezervaci,
           sum(rez.castka)                                             AS dluzi,
           sum(rez.castka) FILTER (WHERE rez.invoice_id IS NULL
                                     AND (rez.schvalena OR NOT _jen_schvalene)) AS k_fakturaci,
           sum(rez.castka) FILTER (WHERE rez.invoice_id IS NULL
                                     AND NOT rez.schvalena AND _jen_schvalene)  AS neschvalene
      FROM rez GROUP BY rez.subject_id
  ),
  doklady AS (
    SELECT radky.subject_id,
           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')) AS fakturovano,
           sum(radky.line_total) FILTER (WHERE radky.status = 'koncept')                   AS v_konceptu,
           sum(radky.line_total) FILTER (WHERE radky.status = 'stornovano'
                                     -- Jen dokud rezervace na stornovaném dokladu VISÍ
                                     -- (částečný dobropis). Po plném stornu se zámek
                                     -- uvolní a rezervace se vrací do `k_fakturaci`;
                                     -- bez téhle podmínky by se počítala dvakrát
                                     -- a `rozdil` vyšel o celou fakturu vedle.
                                     AND radky.zamek IS NOT NULL)                AS ve_stornu
      FROM radky GROUP BY radky.subject_id
  )
  SELECT s.subject_id,
         sub.name,
         COALESCE(d.fakturovano, 0),
         COALESCE(d.v_konceptu, 0),
         COALESCE(d.ve_stornu, 0),
         COALESCE(s.k_fakturaci, 0),
         COALESCE(s.neschvalene, 0),
         COALESCE(s.dluzi, 0),
         COALESCE(s.dluzi, 0)
           - (COALESCE(d.fakturovano, 0) + COALESCE(d.v_konceptu, 0) + COALESCE(d.ve_stornu, 0)
              + COALESCE(s.k_fakturaci, 0) + COALESCE(s.neschvalene, 0)),
         s.rezervaci
    FROM souhrn s
    LEFT JOIN doklady d ON d.subject_id = s.subject_id
    LEFT JOIN public.subjects sub ON sub.id = s.subject_id
   ORDER BY sub.name;
END;
$function$

;

-- -----------------------------------------------------------------------------
-- 4) billing_health: počítadlo nesedících opravných dokladů
--
-- Mění se návratový typ (nový sloupec), takže funkce musí nejdřív pryč —
-- `CREATE OR REPLACE` by na změnu `RETURNS TABLE` narazil.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.billing_health();
CREATE OR REPLACE FUNCTION public.billing_health()
 RETURNS TABLE(rozesle_castky bigint, zamek_bez_radku bigint, vyfakturovane_zrusene bigint, radky_bez_rezervace bigint, polozky_mimo_obdobi bigint, spatna_cisla bigint, rozesle_soucty bigint, stare_koncepty bigint, opravne_nesedi bigint, posledni_vystaveni timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Táž podmínka jako u `billing_reconcile`: výjimka jen pro běh pod databázovou
  -- rolí (pg_cron ve fázi D), ne pro chybějící `sub` v tokenu.
  IF NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Stav fakturace vidí jen správce haly.';
  END IF;

  RETURN QUERY
  SELECT
    -- Rezervace, jejíž částka se rozešla s řádkem už vystaveného dokladu.
    -- Tohle je nález N1 v přímém přenosu: doklad tvrdí jedno, rezervace druhé.
    (SELECT count(*) FROM (
       SELECT it.reservation_id
         FROM public.invoice_items it
         JOIN public.invoices i ON i.id = it.invoice_id AND i.status IN ('vystaveno', 'zaplaceno')
                                AND i.opravuje_id IS NULL
         JOIN public.reservations r ON r.id = it.reservation_id
        GROUP BY it.reservation_id
       HAVING sum(it.line_total) <> max(COALESCE(r.corrected_amount, r.amount))
     ) x) AS rozesle_castky,

    -- Rezervace zabraná fakturou, která na ní ale nemá řádek (a naopak).
    -- Zámek a pravda se rozešly — R1 říká, že autoritou je `invoice_items`.
    (SELECT count(*) FROM public.reservations r
      WHERE r.invoice_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM public.invoice_items it
                         WHERE it.invoice_id = r.invoice_id AND it.reservation_id = r.id)) AS zamek_bez_radku,

    -- VYFAKTUROVANÁ REZERVACE, KTERÁ SE PAK ZRUŠILA.
    --
    -- Tohle je jediná známá díra v kontrolním součtu: `billing_reconcile` počítá
    -- obě strany rovnice jen z rezervací se `status = 'confirmed'` a bez
    -- `deleted_at`, takže když se UŽ VYFAKTUROVANÁ rezervace zruší, vypadne
    -- z „dluží" i z „fakturováno" zároveň — a `rozdil` vyjde 0, přestože
    -- vystavený doklad pořád účtuje led, který se nekonal.
    --
    -- Chytit se to musí tady, ne tam: v rovnici za období to není peněžní rozdíl,
    -- ale stavová vada. Spec ji má jako vlastní případ (bod 10: „když se zruší
    -- už vyfakturovaná rezervace → nabídnout dobropis").
    (SELECT count(*) FROM public.invoice_items it
       JOIN public.invoices i ON i.id = it.invoice_id AND i.status IN ('vystaveno', 'zaplaceno')
                              -- Opravný doklad na zrušenou rezervaci je NÁPRAVA téhle
                              -- vady, ne další její výskyt. Bez téhle podmínky by
                              -- počítadlo po stornu hlásilo pořád totéž.
                              AND i.opravuje_id IS NULL
       JOIN public.reservations r ON r.id = it.reservation_id
      WHERE r.deleted_at IS NOT NULL OR r.status <> 'confirmed') AS vyfakturovane_zrusene,

    -- Řádek dokladu, který nevisí na žádné rezervaci (sleva, storno poplatek,
    -- budoucí dobropis). Z porovnání s „Kdo dluží" je vyloučený schválně — na
    -- druhé straně rovnice nemá protějšek — jenže tím ho nepočítá vůbec nikdo.
    -- Dnes ho nemá kdo založit; až přijde E2 nebo dobropisy, tohle počítadlo
    -- řekne, že akceptační kritérium přestalo pokrývat část dokladu.
    (SELECT count(*) FROM public.invoice_items it
       JOIN public.invoices i ON i.id = it.invoice_id AND i.status <> 'stornovano'
      WHERE it.reservation_id IS NULL) AS radky_bez_rezervace,

    -- Položka mimo období, na které doklad zní. Peněžně to sedí v obou obdobích
    -- (rovnice porovnává řádky proti rezervacím, hlavičku nečte), ale doklad pak
    -- tvrdí „srpen" a účtuje červencový led. Trefí se do toho přesun rezervace
    -- přes hranici měsíce a měsíční ZIP export (E3), který staví na hlavičce.
    (SELECT count(*) FROM public.invoice_items it
       JOIN public.invoices i ON i.id = it.invoice_id AND i.status <> 'stornovano'
      WHERE it.datum IS NOT NULL
        AND (it.datum < i.obdobi_od OR it.datum > i.obdobi_do)) AS polozky_mimo_obdobi,

    -- Vystavený doklad bez čísla nebo koncept s číslem: obojí by znamenalo díru
    -- nebo duplicitu v číselné řadě. CHECK to nepustí, tohle je kontrola kontroly.
    (SELECT count(*) FROM public.invoices
      WHERE (status <> 'koncept' AND cislo IS NULL)
         OR (status =  'koncept' AND cislo IS NOT NULL)) AS spatna_cisla,

    -- Doklad, jehož hlavička nesedí na součet vlastních řádků.
    (SELECT count(*) FROM public.invoices i
      WHERE i.subtotal <> COALESCE((SELECT sum(it.line_total) FROM public.invoice_items it
                                     WHERE it.invoice_id = i.id), 0)) AS rozesle_soucty,

    -- Koncepty starší než 7 dní. Nejsou vadou, ale drží rezervace mimo fakturaci,
    -- takže „zapomenutý koncept" se pozná dřív než na konci měsíce.
    (SELECT count(*) FROM public.invoices
      WHERE status = 'koncept' AND created_at < now() - interval '7 days') AS stare_koncepty,

    -- Poslední vystavený doklad — nejlevnější „tiká to vůbec?" pro fázi D.
    -- OPRAVNÝ DOKLAD, KTERÝ NESEDÍ S ORIGINÁLEM.
    --
    -- `billing_reconcile` opravné doklady z rovnice vyřazuje, aby nepočítala
    -- rezervaci dvakrát. Tím se ale stávají místem, kam rovnice nevidí — a přesně
    -- tam patří vlastní kontrola. Hlásí tři věci: opravný doklad na dokladu, který
    -- není stornovaný; jiná částka než originál; a originál, který zmizel.
    (SELECT count(*) FROM public.invoices o
       LEFT JOIN public.invoices p ON p.id = o.opravuje_id
      WHERE o.opravuje_id IS NOT NULL
        AND (p.id IS NULL
             OR p.status <> 'stornovano'
             OR o.total IS DISTINCT FROM p.total)) AS opravne_nesedi,

    (SELECT max(issued_at) FROM public.invoices WHERE status <> 'koncept') AS posledni_vystaveni;
END;
$function$

;

REVOKE ALL ON FUNCTION public.billing_health() FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.billing_health() TO authenticated;

COMMENT ON FUNCTION public.billing_health() IS
  'Počítadla vad, které kontrolní součet neuvidí. `opravne_nesedi` hlídá opravné doklady, které billing_reconcile z rovnice vyřazuje — aby ta výjimka nebyla slepé místo.';

-- -----------------------------------------------------------------------------
-- 5) Seznam dokladů: ať je poznat opravný doklad
--
-- Bez tohohle vypadá opravný doklad v seznamu i na tisku jako obyčejná faktura
-- — tedy jako druhá výzva k zaplacení téže částky. `opravuje_cislo` se veze
-- s sebou schválně: „opravný doklad k faktuře 20260001" je informace, kterou
-- odběratel na dokladu potřebuje, a dohledávat ji druhým dotazem je zbytečné.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.invoices_list;
CREATE VIEW public.invoices_list WITH (security_invoker = on) AS
  SELECT i.id,
         i.cislo,
         i.variabilni_symbol,
         i.kind,
         i.status,
         i.subject_id,
         COALESCE(i.odberatel_nazev, s.name) AS odberatel,
         i.obdobi_od,
         i.obdobi_do,
         i.datum_vystaveni,
         i.datum_splatnosti,
         i.datum_uhrady,
         i.subtotal,
         i.total,
         i.total_rounded,
         i.pdf_path,
         (SELECT count(*) FROM public.invoice_items it WHERE it.invoice_id = i.id) AS polozek,
         i.status = 'vystaveno'::invoice_status
           AND i.datum_splatnosti < (now() AT TIME ZONE 'Europe/Prague')::date AS po_splatnosti,
         i.created_at,
         i.issued_at,
         i.opravuje_id,
         i.storno_duvod,
         -- Číslo opravovaného dokladu. `security_invoker = on` znamená, že se
         -- na `invoices` uplatní RLS volajícího — ta je admin-only, tedy táž
         -- jako na řádku samotném; nic se tím neodkrývá.
         (SELECT p.cislo FROM public.invoices p WHERE p.id = i.opravuje_id) AS opravuje_cislo,
         -- Byl tenhle doklad stornovaný? (Pohled na tutéž vazbu z druhé strany.)
         (SELECT o.cislo FROM public.invoices o WHERE o.opravuje_id = i.id)  AS stornovan_dokladem
    FROM public.invoices i
    LEFT JOIN public.subjects s ON s.id = i.subject_id;

REVOKE ALL ON public.invoices_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.invoices_list TO authenticated;
