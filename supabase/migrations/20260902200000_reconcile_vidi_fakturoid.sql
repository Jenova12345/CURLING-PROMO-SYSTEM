-- =============================================================================
-- Kontrolní součet vidí i doklady z Fakturoidu
-- Nález 6 z ultra review · příprava na cutover
-- =============================================================================
-- KROK 0 — CO POČÍTAL DOSUD:
--
--     rozdil = dluzi − (fakturovano + v_konceptu + ve_stornu
--                       + k_fakturaci + neschvalene)
--
-- kde `fakturovano`, `v_konceptu` i `ve_stornu` pocházejí VÝHRADNĚ z interních
-- `invoices` / `invoice_items`, a `k_fakturaci` je „co má `invoice_id IS NULL`".
--
-- Fakturoidí cesta do `reservations.invoice_id` schválně nezapisuje (zámek je
-- vazební tabulka), takže vyfakturovaná rezervace zůstala napořád
-- v `k_fakturaci`. Rovnice přitom VYCHÁZELA — každá rezervace se počítala
-- právě jednou — takže `rozdil = 0` vypadal jako zdraví, ale měřil jen
-- vyřazovaný engine.
--
-- Změřeno dřív: před vystavením fakturoidího dokladu `k_fakturaci = 29 600`,
-- po vystavení naprosto totéž. Admin by tak po měsíci upomínal klub o částku,
-- kterou už zaplatil.
--
-- -----------------------------------------------------------------------------
-- CO PŘIBÝVÁ
-- -----------------------------------------------------------------------------
--   `fakturoid`        … Σ částek rezervací, které drží fakturoidí doklad.
--                        Zároveň se odečítají z `k_fakturaci` — co je zabrané,
--                        není k fakturaci.
--   `fakturoid_rozdil` … Σ `nas_soucet` dokladů − Σ částek rezervací na nich.
--                        MUSÍ být 0. Tohle je ta skutečná kontrola fakturoidí
--                        strany: `rozdil` sám o sobě by u ní vycházel vždycky,
--                        protože obě strany bere z týchž částek rezervací.
--
-- Zámkem je VAZBA, ne stav dokladu u poskytovatele: jakmile je rezervace
-- zabraná, není k fakturaci, ani kdyby doklad zůstal konceptem. Kdyby se
-- claim uvolnil (`fakturoid_uvolni_zabrani`), rezervace se vrátí do
-- `k_fakturaci` sama.
--
-- `nas_soucet` je zaokrouhlený na celé koruny (`roundCzk` v pipeline), proto
-- se porovnává se zaokrouhleným součtem — ne kvůli toleranci, ale aby se
-- srovnávalo totéž.
--
-- -----------------------------------------------------------------------------
-- ⚠️ DROP + CREATE ZAHAZUJE GRANTY
-- -----------------------------------------------------------------------------
-- Mění se návratový typ, takže `CREATE OR REPLACE` nestačí. Po `DROP` se ale
-- ACL vrátí na výchozí — ověřeno: funkce byla rázem volatelná i pro `anon`
-- a `PUBLIC`, přestože „Kdo kolik dluží" jsou peníze všech klubů. REVOKE/GRANT
-- ze `20260813160000` se proto opakuje NÍŽ a hlídá ho kontrola.
--
-- VRATNOST: funkce zpátky z 20260813160000_billing_reconcile.sql
--   (v revertu nezapomeň na REVOKE/GRANT).
-- =============================================================================

DROP FUNCTION IF EXISTS public.billing_reconcile(date, date);
CREATE OR REPLACE FUNCTION public.billing_reconcile(_od date, _do date)
 RETURNS TABLE(subject_id uuid, subjekt text, fakturovano numeric, v_konceptu numeric, ve_stornu numeric, dobropisovano numeric, k_fakturaci numeric, neschvalene numeric, fakturoid numeric, fakturoid_rozdil numeric, dluzi numeric, rozdil numeric, rezervaci bigint)
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
           rez.invoice_id AS zamek,
           (i.opravuje_id IS NOT NULL) AS je_dobropis
      FROM rez
      JOIN public.invoice_items it ON it.reservation_id = rez.id
      JOIN public.invoices i       ON i.id = it.invoice_id
     -- OPRAVNÉ DOKLADY SE NEPOČÍTAJÍ. Zrcadlí řádky původní faktury, takže by
     -- tutéž rezervaci naúčtovaly podruhé. Že opravný doklad sedí s originálem,
     -- hlídá `billing_health.opravne_nesedi` — ať ta výjimka není slepé místo.
     LEFT JOIN public.invoices puv ON puv.id = i.opravuje_id
     WHERE i.opravuje_id IS NULL
        -- Dobropis se vykazuje, JEN dokud doklad, který opravuje, platí.
        -- U stornovaného originálu by šlo o dvojí započtení téhož zrušení.
        OR puv.status IN ('vystaveno', 'zaplaceno')
  ),
  -- REZERVACE ZABRANÉ FAKTUROIDEM.
  --
  -- Zámek je samotná VAZBA (`fakturoid_invoice_reservations`, UNIQUE na
  -- `reservation_id`), ne stav dokladu u poskytovatele: jakmile je rezervace
  -- zabraná, není „k fakturaci", ani kdyby doklad zůstal konceptem.
  fakt AS (
    SELECT rez.subject_id, rez.id, rez.castka, fr.fakturoid_invoice_id AS doklad_id
      FROM rez
      JOIN public.fakturoid_invoice_reservations fr ON fr.reservation_id = rez.id
  ),
  -- SEDÍ, CO JSME POSLALI, S TÍM, CO SI ÚČTUJEME?
  --
  -- `nas_soucet` je náš vlastní součet z okamžiku vystavení, zaokrouhlený na
  -- celé koruny (`roundCzk` v pipeline) — proto se porovnává se zaokrouhleným
  -- součtem částek, ne kvůli toleranci, ale aby se srovnávalo totéž.
  -- Kdyby se to rozešlo, je to přesně ten tichý rozjezd, kvůli kterému
  -- kontrolní součet existuje.
  fakt_doklady AS (
    SELECT f.subject_id,
           sum(fi.nas_soucet - round(f.suma, 0)) AS rozdil
      FROM (SELECT fakt.subject_id, fakt.doklad_id, sum(fakt.castka) AS suma
              FROM fakt GROUP BY fakt.subject_id, fakt.doklad_id) f
      JOIN public.fakturoid_invoices fi ON fi.id = f.doklad_id
     GROUP BY f.subject_id
  ),
  souhrn AS (
    SELECT rez.subject_id,
           count(*)                                                    AS rezervaci,
           sum(rez.castka)                                             AS dluzi,
           -- Co drží Fakturoid, NENÍ k fakturaci. Bez téhle podmínky tam
           -- rezervace visela napořád — fakturoidí cesta do `invoice_id`
           -- schválně nezapisuje, takže ji nic jiného neodečetlo.
           sum(rez.castka) FILTER (WHERE rez.invoice_id IS NULL
                                     AND NOT EXISTS (SELECT 1 FROM fakt WHERE fakt.id = rez.id)
                                     AND (rez.schvalena OR NOT _jen_schvalene)) AS k_fakturaci,
           sum(rez.castka) FILTER (WHERE rez.invoice_id IS NULL
                                     AND NOT EXISTS (SELECT 1 FROM fakt WHERE fakt.id = rez.id)
                                     AND NOT rez.schvalena AND _jen_schvalene)  AS neschvalene,
           sum(rez.castka) FILTER (WHERE EXISTS (SELECT 1 FROM fakt WHERE fakt.id = rez.id))
                                                                                AS fakturoid
      FROM rez GROUP BY rez.subject_id
  ),
  doklady AS (
    SELECT radky.subject_id,
           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')
                                             AND NOT radky.je_dobropis)                AS fakturovano,
           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')
                                             AND radky.je_dobropis)                    AS dobropisovano,
           sum(radky.line_total) FILTER (WHERE radky.status = 'koncept'
                                             AND NOT radky.je_dobropis)                AS v_konceptu,
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
         COALESCE(d.dobropisovano, 0),
         COALESCE(s.k_fakturaci, 0),
         COALESCE(s.neschvalene, 0),
         COALESCE(s.fakturoid, 0),
         COALESCE(fd.rozdil, 0),
         COALESCE(s.dluzi, 0),
         COALESCE(s.dluzi, 0)
           - (COALESCE(d.fakturovano, 0) + COALESCE(d.v_konceptu, 0) + COALESCE(d.ve_stornu, 0)
              + COALESCE(s.k_fakturaci, 0) + COALESCE(s.neschvalene, 0)
              + COALESCE(s.fakturoid, 0)),
         s.rezervaci
    FROM souhrn s
    LEFT JOIN doklady d ON d.subject_id = s.subject_id
    LEFT JOIN fakt_doklady fd ON fd.subject_id = s.subject_id
    LEFT JOIN public.subjects sub ON sub.id = s.subject_id
   ORDER BY sub.name;
END;
$function$

;

-- Práva se po DROPu nedědí — bez tohohle je „Kdo kolik dluží" otevřené i pro
-- nepřihlášené. Znění je převzaté z 20260813160000.
REVOKE ALL ON FUNCTION public.billing_reconcile(date, date) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.billing_reconcile(date, date) TO authenticated;

DO $kontrola$
DECLARE _acl text;
BEGIN
  SELECT coalesce(proacl::text, '') INTO _acl
    FROM pg_proc WHERE oid = 'public.billing_reconcile(date, date)'::regprocedure;
  IF _acl LIKE '%anon=X%' OR _acl LIKE '{=X%' THEN
    RAISE EXCEPTION 'billing_reconcile je volatelná pro anon/PUBLIC — peníze všech klubů.';
  END IF;
  IF _acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'billing_reconcile není volatelná pro authenticated — obrazovka „Kdo dluží" přestane fungovat.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid='public.billing_reconcile(date, date)'::regprocedure)
     NOT LIKE '%fakturoid_invoice_reservations%' THEN
    RAISE EXCEPTION 'Kontrolní součet pořád nevidí doklady z Fakturoidu.';
  END IF;

  RAISE NOTICE 'Kontrolní součet počítá i fakturoidí doklady (fakturoid, fakturoid_rozdil).';
END $kontrola$;
