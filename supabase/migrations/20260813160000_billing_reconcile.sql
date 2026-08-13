-- =============================================================================
-- B6 — Kontrolní součet fakturace
-- =============================================================================
-- Akceptační kritérium Etapy 2 zní doslova:
--
--     suma vystavených faktur za období == „Kdo kolik dluží" za totéž období
--
-- Tahle funkce je JEDINÝ způsob, jak to poznat. Bez ní je fakturační modul jen
-- hezky vypadající obrazovka, o které nikdo neví, jestli počítá správně — proto
-- B6 přichází hned po B5 a ne až nakonec.
--
-- ROVNICE, KTERÁ MUSÍ PLATIT VŽDYCKY:
--
--     dluzi = fakturovano + v_konceptu + k_fakturaci + neschvalene
--
-- Prosté „faktury == dluží" totiž platí až v okamžiku, kdy je vyfakturované
-- všechno. Rozpad na čtyři sloupce říká i to, PROČ se to zrovna nerovná —
-- a rozdíl mimo tyhle čtyři důvody je skutečná vada. Právě proto se počítá
-- `rozdil`: nula znamená „sedí to", cokoli jiného je nález.
--
-- ČTYŘI ROZHODNUTÍ, KTERÁ V TOM JSOU ZADRÁTOVANÁ:
--
-- 1) **Porovnává se `total`, ne `total_rounded`** (R3). Zaokrouhlení na koruny je
--    per doklad; sečtením zaokrouhlených částek by se nasčítal drift ±N/2 Kč
--    a kontrolní součet by hlásil rozdíl, který v datech není.
--
-- 2) **Fakturovaná částka se bere z `invoice_items`, ne z hlavičky faktury**
--    (R1). Období faktury nemusí sedět na období dotazu — doklad může přesahovat
--    přes přelom měsíce. Řádek je vázaný na rezervaci, a ta má datum.
--
-- 3) **„Kdo dluží" se počítá z AKTUÁLNÍ částky rezervace**, kdežto fakturovaná
--    částka z ULOŽENÉHO řádku dokladu. To je schválně: kdyby se obě strany braly
--    ze stejného místa, kontrolní součet by seděl vždycky a nezjistil by nic.
--    Takhle odhalí i nález N1 — dodatečnou změnu už vyfakturované rezervace.
--
-- 4) **Koncepty se do „vyfakturováno" nepočítají**, ale nemizí — mají vlastní
--    sloupec. Koncept doklad ještě není (nemá číslo), ale rezervace už drží,
--    takže bez toho sloupce by se jevily jako ztracené peníze.
--
-- CO ROVNICE NEVIDÍ (a proto to hlídá `billing_health`): vyfakturovanou rezervaci,
-- která se potom zrušila. Vypadne z „dluží" i z „fakturováno" naráz, takže
-- `rozdil` vyjde 0, i když vystavený doklad pořád účtuje led, který se nekonal.
-- „rozdil = 0" se proto nesmí číst jako „všechno sedí" — je to jedna ze dvou
-- kontrol, ne obě.
--
-- ČTE ZE ZÁKLADNÍCH TABULEK, ne z `reservations_billing` (nález N4): ten pohled
-- končí `AND has_role(auth.uid(), 'admin')` a pod cronem by vrátil nula řádků —
-- kontrolní součet by pak seděl nula proti nule a ohlásil úspěch.
--
-- VRATNOST:
--   DROP VIEW IF EXISTS public.billing_health;
--   DROP FUNCTION IF EXISTS public.billing_reconcile(date, date);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.billing_reconcile(_od date, _do date)
RETURNS TABLE (
  subject_id   uuid,
  subjekt      text,
  -- Σ řádků dokladů, které JSOU dokladem (mají číslo). Stornované se nepočítají.
  fakturovano  numeric,
  -- Σ řádků konceptů — rezervace jsou zabrané, doklad ještě nevznikl.
  v_konceptu   numeric,
  -- Σ částek rezervací, které čekají na fakturaci.
  k_fakturaci  numeric,
  -- Σ částek rezervací, které se podle nastavení fakturovat nesmí (Q4: jen schválené).
  neschvalene  numeric,
  -- „Kdo kolik dluží" — to, co ukazuje obrazovka.
  dluzi        numeric,
  -- Musí být 0. Cokoli jiného je vada, ne stav.
  rozdil       numeric,
  rezervaci    bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
    SELECT rez.subject_id,
           i.status,
           it.line_total
      FROM rez
      JOIN public.invoice_items it ON it.reservation_id = rez.id
      JOIN public.invoices i       ON i.id = it.invoice_id
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
           sum(radky.line_total) FILTER (WHERE radky.status = 'koncept')                   AS v_konceptu
      FROM radky GROUP BY radky.subject_id
  )
  SELECT s.subject_id,
         sub.name,
         COALESCE(d.fakturovano, 0),
         COALESCE(d.v_konceptu, 0),
         COALESCE(s.k_fakturaci, 0),
         COALESCE(s.neschvalene, 0),
         COALESCE(s.dluzi, 0),
         COALESCE(s.dluzi, 0)
           - (COALESCE(d.fakturovano, 0) + COALESCE(d.v_konceptu, 0)
              + COALESCE(s.k_fakturaci, 0) + COALESCE(s.neschvalene, 0)),
         s.rezervaci
    FROM souhrn s
    LEFT JOIN doklady d ON d.subject_id = s.subject_id
    LEFT JOIN public.subjects sub ON sub.id = s.subject_id
   ORDER BY sub.name;
END;
$$;

REVOKE ALL ON FUNCTION public.billing_reconcile(date, date) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.billing_reconcile(date, date) TO authenticated;

COMMENT ON FUNCTION public.billing_reconcile(date, date) IS
  'Kontrolní součet Etapy 2: dluzi = fakturovano + v_konceptu + k_fakturaci + neschvalene. Sloupec `rozdil` musí být 0 — cokoli jiného je vada. Porovnává `total` (přesné), nikdy `total_rounded`. POZOR: „rozdil = 0" NEZNAMENÁ „všechno sedí" — vyfakturovanou rezervaci, která se pak zrušila, tahle rovnice nevidí (vypadne z obou stran). Tu třídu hlídá billing_health.vyfakturovane_zrusene.';

-- -----------------------------------------------------------------------------
-- `billing_health` — mrtvý muž pro věci, které kontrolní součet za období nevidí
--
-- Kontrolní součet se ptá „sedí tohle období?". Tenhle pohled se ptá „není
-- někde něco shnilého?" napříč vším — a odpovídá čísly, která mají být nulová.
--
-- `security_invoker = on`: pohled ukazuje peníze, takže musí platit RLS volajícího
-- (`invoices_select_admin`). S `off` by ho přečetl každý přihlášený, což je přesně
-- díra, kterou měl drift 8f u `profiles_public`.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.billing_health;
CREATE VIEW public.billing_health WITH (security_invoker = on) AS
  SELECT
    -- Rezervace, jejíž částka se rozešla s řádkem už vystaveného dokladu.
    -- Tohle je nález N1 v přímém přenosu: doklad tvrdí jedno, rezervace druhé.
    (SELECT count(*) FROM (
       SELECT it.reservation_id
         FROM public.invoice_items it
         JOIN public.invoices i ON i.id = it.invoice_id AND i.status IN ('vystaveno', 'zaplaceno')
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
       JOIN public.reservations r ON r.id = it.reservation_id
      WHERE r.deleted_at IS NOT NULL OR r.status <> 'confirmed') AS vyfakturovane_zrusene,

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
    (SELECT max(issued_at) FROM public.invoices WHERE status <> 'koncept') AS posledni_vystaveni;

-- `authenticated` patří do REVOKE ze stejného důvodu jako u `invoices_list`:
-- výchozí práva Supabase dávají na nový objekt plné `arwdDxtm`. Hlídá to
-- security_hardening_test.sql (drift 8d).
REVOKE ALL ON public.billing_health FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.billing_health TO authenticated;

COMMENT ON VIEW public.billing_health IS
  'Mrtvý muž fakturace: všechny počty musí být 0. rozesle_castky = nález N1 (rezervace se po vyfakturování změnila), zamek_bez_radku = rozpor mezi zámkem a pravdou (R1), vyfakturovane_zrusene = zrušená rezervace na vystaveném dokladu (čeká na dobropis) — tuhle třídu billing_reconcile nevidí.';

-- -----------------------------------------------------------------------------
-- Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _h record;
BEGIN
  SELECT * INTO _h FROM public.billing_health;
  IF _h.rozesle_castky <> 0 OR _h.zamek_bez_radku <> 0 OR _h.vyfakturovane_zrusene <> 0
     OR _h.spatna_cisla <> 0 OR _h.rozesle_soucty <> 0 THEN
    RAISE EXCEPTION 'B6: fakturační data nejsou v pořádku hned po nasazení (%).', row_to_json(_h);
  END IF;
  RAISE NOTICE 'B6: kontrolní součet nasazen, billing_health čistý.';
END $$;
