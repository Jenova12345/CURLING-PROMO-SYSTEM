-- =============================================================================
-- „Kdo kolik dluží" má ukazovat SKUTEČNÝ dluh, ne základ daně
-- Blok ceníku ledu
-- =============================================================================
-- CO JE ŠPATNĚ:
--
-- `reservations.amount` je `hodiny × rate_per_hour` — a od přechodu na plátce
-- (blok B) znamená u každého typu subjektu NĚCO JINÉHO:
--
--   • KLUB     — klubový ceník je vedený VČETNĚ DPH → `amount` je částka s daní
--   • KOMERCE  — komerční ceník je vedený BEZ DPH   → `amount` je ZÁKLAD
--
-- „Kdo kolik dluží" ale sčítá `amount` pro obojí stejně, takže u komerčních
-- zákazníků PODHODNOTÍ dluh přesně o sazbu daně. U akce za 5 000 Kč ukáže
-- 5 000, zatímco faktura zní na 5 600 — a rozdíl 600 Kč není vidět nikde.
--
-- Není to kosmetika: „Kdo dluží" je podklad, podle kterého se rozhoduje, komu
-- se volá kvůli nezaplacené faktuře, a je to jedna strana povinné rovnice
-- z CLAUDE.md („suma vystavených faktur == Kdo kolik dluží").
--
-- -----------------------------------------------------------------------------
-- CO MIGRACE DĚLÁ
-- -----------------------------------------------------------------------------
--   1. `billing_settings.vat_rate_ice` — sazba DPH za led v jednom místě,
--   2. `reservations_billing.dluh` — částka, kterou zákazník SKUTEČNĚ dluží,
--   3. `reservations_billing.dluh_zaklad` — týž údaj bez daně, ať jde poznat,
--      z čeho `dluh` vznikl (a ať se dá porovnat s tím, co jde na doklad).
--
-- `amount` ZŮSTÁVÁ beze změny. Je to snapshot, ze kterého se počítají doklady
-- i kontrolní součet; přepsat mu význam by rozešlo obě strany rovnice naráz.
-- Nový sloupec je odvozený, ne uložený.
--
-- -----------------------------------------------------------------------------
-- PROČ SAZBA DO DATABÁZE, KDYŽ JE UŽ V `billing/mapping.ts`
-- -----------------------------------------------------------------------------
-- Protože „Kdo dluží" je stránka v `src/`, a ta si `billing/` naimportovat
-- NESMÍ — hlídá to `billing/hranice.test.ts` (klíč k Fakturoidu nesmí mít ani
-- teoretickou cestu do prohlížeče). Sazbu tedy musí dodat databáze.
--
-- Vznikají tím dvě místa s týmž číslem, což je přesně ta situace, na kterou
-- v tomhle repu doplatily `iban_je_platny` a `overIban`. Proto obě strany
-- PŘIŠPENDLENÉ NA TOTÉŽ ČÍSLO, každá ve svém testu:
--   • `supabase/tests/billing_settings_test.sql` → `vat_rate_ice = 12`
--   • `billing/mapping.test.ts`                  → `SAZBA_DPH_LED === 12`
-- Změnit jedno bez druhého tedy nejde tiše — jeden z těch dvou testů zčervená.
--
-- Do budoucna je správnější směr, aby `billing/` četlo sazbu odsud a konstanta
-- zmizela — ale to je zásah do mapovací vrstvy a patří k vyřazení interního
-- enginu, ne sem.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- pohled zpátky do znění z 20260804090000_group_actions_and_billing.sql
--   ALTER TABLE public.billing_settings DROP COLUMN IF EXISTS vat_rate_ice;
-- Data se neztrácejí: `dluh` je dopočet, nic se neukládá.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Sazba DPH za led
-- -----------------------------------------------------------------------------
ALTER TABLE public.billing_settings
  ADD COLUMN IF NOT EXISTS vat_rate_ice numeric(5,2) NOT NULL DEFAULT 12;

-- Rozsah, ne konkrétní hodnota: sazbu mění zákon, ne provoz, ale zapsat
-- omylem 120 místo 12 se dá kdykoli. Nula je legitimní (osvobozeno).
ALTER TABLE public.billing_settings DROP CONSTRAINT IF EXISTS billing_settings_vat_rate_ice;
ALTER TABLE public.billing_settings ADD CONSTRAINT billing_settings_vat_rate_ice
  CHECK (vat_rate_ice >= 0 AND vat_rate_ice <= 100);

COMMENT ON COLUMN public.billing_settings.vat_rate_ice IS
  'Sazba DPH za pronájem ledu v PROCENTECH (12 = snížená sazba za sportovní služby). Zrcadlí SAZBA_DPH_LED v billing/mapping.ts — `src/` si billing/ importovat nesmí, takže sazbu pro „Kdo dluží" musí dodat databáze. Že se ta dvě čísla nerozejdou, hlídá billing_settings_test.sql (SQL strana) a mapping.test.ts (JS strana).';

-- Sloupec je součástí fakturačního nastavení, takže ho admin smí měnit stejně
-- jako zbytek. Bez tohohle grantu by ho formulář neuložil (grant je sloupcový,
-- viz 20260812160000 — tabulkový by pustil i `id` a `created_at`).
GRANT UPDATE (vat_rate_ice) ON public.billing_settings TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) Pohled: skutečný dluh
--
-- DROP + CREATE, ne REPLACE: přibývají sloupce a `REPLACE` to neumí.
-- Znění je převzaté z `20260804090000_group_actions_and_billing.sql` a rozšířené
-- jen o dva sloupce na konci — `security_invoker = off` i filtr na admina
-- zůstávají, protože je to pohled, který pouští ČÁSTKY.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.reservations_billing;
CREATE VIEW public.reservations_billing
  WITH (security_invoker = off) AS
  SELECT
    r.id, r.subject_id, s.name AS subject_name, s.type AS subject_type,
    r.sheet_id, sh.name AS sheet_name,
    r.start_at, r.end_at,
    r.hours, r.rate_per_hour, r.amount,
    r.corrected_hours, r.corrected_amount, r.correction_reason,
    r.note, e.title AS event_title, e.event_type,
    r.created_by, cp.full_name AS created_by_name,

    -- Částka po korekci — to, z čeho se dluh počítá. Vytažené zvlášť, ať se
    -- `coalesce` neopisuje ve dvou dalších výrazech a nerozejde se.
    COALESCE(r.corrected_amount, r.amount) AS dluh_zaklad,

    -- SKUTEČNÝ DLUH.
    --
    -- Klubový ceník je vedený VČETNĚ DPH, komerční BEZ ní — takže u komerčního
    -- subjektu je `amount` jen základ a doplatit se musí i daň. U neplátce se
    -- nepřipočítává nic; tam je `amount` konečná částka pro obojí.
    --
    -- Zaokrouhluje se NA HALÉŘE a po řádcích, ne až na součtu: je to kanonické
    -- pravidlo R3 („řádek → kvantizace na haléře, mezisoučet → přesný součet
    -- už kvantizovaných řádků"). Na celé koruny se zaokrouhluje až částka
    -- k úhradě na dokladu, ne tady.
    CASE
      WHEN s.type = 'commercial'
       AND COALESCE((SELECT bs.vat_mode FROM public.billing_settings bs WHERE bs.singleton),
                    'neplatce') <> 'neplatce'
        THEN round(COALESCE(r.corrected_amount, r.amount)
                   * (1 + COALESCE((SELECT bs.vat_rate_ice FROM public.billing_settings bs
                                     WHERE bs.singleton), 0) / 100), 2)
      ELSE COALESCE(r.corrected_amount, r.amount)
    END AS dluh

  FROM public.reservations r
  JOIN public.subjects s    ON s.id  = r.subject_id
  JOIN public.sheets   sh   ON sh.id = r.sheet_id
  LEFT JOIN public.events   e  ON e.id = r.event_id
  LEFT JOIN public.profiles cp ON cp.user_id = r.created_by
  WHERE r.status = 'confirmed'
    AND r.deleted_at IS NULL
    AND has_role(auth.uid(), 'admin');

REVOKE ALL ON public.reservations_billing FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.reservations_billing TO authenticated;

COMMENT ON VIEW public.reservations_billing IS
  'Podklad pro „Kdo kolik dluží". `amount` je snapshot z rezervace a pod DPH znamená u klubu částku S DANÍ, u komerce ZÁKLAD — sčítat ho napříč typy tedy míchá jablka s hruškami. Na to je `dluh`: skutečná částka, kterou zákazník dluží. `dluh_zaklad` je totéž bez daně.';

-- -----------------------------------------------------------------------------
-- 3) Kontrola
-- -----------------------------------------------------------------------------
DO $$
DECLARE _anon int; _sazba numeric;
BEGIN
  SELECT count(*) INTO _anon FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'reservations_billing'
     AND grantee IN ('anon', 'PUBLIC', 'service_role');
  IF _anon > 0 THEN
    RAISE EXCEPTION 'reservations_billing má granty, které mít nemá (%) — pouští ČÁSTKY.', _anon;
  END IF;

  -- Pohled po DROP+CREATE ztrácí `security_invoker`, kdyby ho někdo zapomněl.
  -- Tady je `off` schválně (filtr na admina je v těle), ale musí to tak zůstat
  -- vědomě, ne náhodou.
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relname = 'reservations_billing'
                AND c.reloptions @> ARRAY['security_invoker=on']) THEN
    RAISE EXCEPTION 'reservations_billing má security_invoker=on — filtr na admina v těle by pak byl druhá vrstva nad RLS, ne jediná.';
  END IF;

  SELECT vat_rate_ice INTO _sazba FROM public.billing_settings WHERE singleton;
  IF _sazba <> 12 THEN
    RAISE WARNING 'Sazba DPH za led je %, ne 12 — zkontroluj, že to tak má být (a že sedí se SAZBA_DPH_LED v billing/mapping.ts).', _sazba;
  END IF;

  RAISE NOTICE 'Kdo kolik dluží počítá u komerčních subjektů i DPH (sazba % %%).', _sazba;
END $$;
