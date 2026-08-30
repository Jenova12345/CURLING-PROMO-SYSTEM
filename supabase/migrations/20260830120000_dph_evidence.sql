-- =============================================================================
-- Evidence dokladů pod DPH: základ daně zvlášť, aby kontrolní součet nelhal
-- Blok B — přechod na plátce DPH (12 % za pronájem ledu)
-- =============================================================================
-- CO JE ŠPATNĚ BEZ TÉHLE MIGRACE:
--
-- `fakturoid_invoices.nas_soucet` drží `Σ hodiny × sazba` z našeho podkladu.
-- Pod DPH to znamená u KAŽDÉHO TYPU DOKLADU NĚCO JINÉHO:
--
--   • klubový doklad  — ceny jsou VČETNĚ daně → `nas_soucet` je částka s daní
--   • komerční doklad — ceny jsou BEZ daně    → `nas_soucet` je ZÁKLAD
--
-- Pohled `fakturoid_invoices_list` přitom počítal kontrolní součet jako
-- `provider_total - nas_soucet`, tedy vždycky proti částce S DANÍ. U komerčního
-- dokladu by z toho vycházel rozdíl PŘESNĚ VE VÝŠI DPH — u faktury za 5 000 Kč
-- tedy 600 Kč — a to na každé komerční faktuře, navždy.
--
-- Není to kosmetika: rovnice „suma vystavených faktur == Kdo kolik dluží" je
-- podle CLAUDE.md POVINNÁ BRÁNA. Sloupec, který u poloviny dokladů hlásí
-- neexistující rozdíl, tu bránu neposiluje, ale vypíná — protože si na červenou
-- všichni zvyknou. Kód v `billing/pipeline.ts` (`castkaKPorovnani`) tohle už
-- řeší; databáze o tom dosud nevěděla.
--
-- CO S TÍM MIGRACE DĚLÁ:
--   1. přidá `provider_subtotal` — základ daně tak, jak ho spočítal Fakturoid,
--   2. naučí `fakturoid_zapis_vazbu` ho ukládat,
--   3. přepíše `rozdil` v pohledu tak, aby porovnával LIKE S LIKE.
--
-- PROČ SE ZÁKLAD MUSÍ UKLÁDAT, A NE DOPOČÍTÁVAT: dopočet ze sazby je náš odhad,
-- kdežto na dokladu je číslo Fakturoidu. Kontrolní součet má porovnávat, co
-- jsme poslali, s tím, CO SKUTEČNĚ VYTISKL — ne s tím, co si myslíme, že
-- vytisknout měl. Zpětně už to nedohledáme, proto sloupec.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   ALTER TABLE public.fakturoid_invoices DROP COLUMN IF EXISTS provider_subtotal;
--   -- a `fakturoid_zapis_vazbu` i `fakturoid_invoices_list` zpátky do znění
--   -- z 20260824120000_fakturoid_vazba.sql (funkce má o parametr míň, takže
--   -- se musí DROPnout, ne jen nahradit).
-- Revert NEZTRATÍ data: `provider_subtotal` je přírůstkový sloupec, `nas_soucet`
-- ani `provider_total` se nemění.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Sloupec
-- -----------------------------------------------------------------------------
ALTER TABLE public.fakturoid_invoices
  ADD COLUMN IF NOT EXISTS provider_subtotal numeric(12,2);

COMMENT ON COLUMN public.fakturoid_invoices.provider_subtotal IS
  'Základ daně tak, jak ho spočítal provider (Fakturoid `subtotal`). U neplátce se rovná provider_total. Slouží ke kontrolnímu součtu u dokladů s cenami BEZ DPH — tam je náš nas_soucet taky základ, takže se porovnává s tímhle, ne s provider_total.';

COMMENT ON COLUMN public.fakturoid_invoices.nas_soucet IS
  'Σ hodiny × sazba z NAŠEHO podkladu. POZOR, pod DPH má podle typu dokladu jiný význam: u klubového (ceny včetně daně) je to částka S DANÍ, u komerčního (ceny bez daně) ZÁKLAD. Protějšek pro porovnání proto vybírá sloupec `druh` — viz pohled fakturoid_invoices_list.';

-- -----------------------------------------------------------------------------
-- 2) Zápis výsledku umí uložit i základ
--
-- Parametr je na KONCI a má DEFAULT NULL, takže starší volající (a rozepsaná
-- Edge funkce, která se nasazuje zvlášť) fungují dál — jen bez základu. To je
-- horší než s ním, ale pořád lepší než rozbité vystavení dokladu.
--
-- CELÉ TĚLO JE VYGENEROVANÉ Z `pg_get_functiondef` ŽIVÉHO SCHÉMATU a zasažené
-- jen na ČTYŘECH řádcích, kde přibývá `provider_subtotal` — pravidlo 7
-- z CLAUDE.md. Diff proti živé verzi byl kontrolovaný, aby se ověřilo, že
-- nezmizelo nic jiného.
--
-- ⚠️ NENÍ TO CEREMONIE. První pokus jsem psal podle znění v migraci
-- 20260824120000 a lišil se od živého stavu ve třech věcech: jinou hláškou
-- guardu, chybějící kontrolou `_provider_invoice_id IS NULL`, jiným pořadím
-- parametrů `_rezim`/`_rezervace` — a hlavně CELÝM VYNECHANÝM blokem, který
-- zapisuje do `fakturoid_invoice_reservations`, včetně jeho `EXCEPTION` větve
-- na `unique_violation`. Doklad by se zapsal, ale vazba na rezervace ne, takže
-- by se tytéž rezervace daly vyfakturovat znovu. Chytila to až kontrola na
-- konci téhle migrace. Přesně proto to pravidlo v CLAUDE.md je (87b1f78).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_zapis_vazbu(_klic text, _provider_invoice_id text, _provider_subject_id text, _cislo text, _vs text, _public_url text, _status text, _provider_total numeric, _varovani text DEFAULT NULL::text, _druh text DEFAULT NULL::text, _subject uuid DEFAULT NULL::uuid, _event uuid DEFAULT NULL::uuid, _od date DEFAULT NULL::date, _do date DEFAULT NULL::date, _nas_soucet numeric DEFAULT NULL::numeric, _radku integer DEFAULT NULL::integer, _rezim text DEFAULT NULL::text, _rezervace uuid[] DEFAULT NULL::uuid[], _provider_subtotal numeric DEFAULT NULL::numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění zapisovat fakturoidí doklady.';
  END IF;

  IF _provider_invoice_id IS NULL OR _cislo IS NULL THEN
    RAISE EXCEPTION 'Doklad bez id nebo čísla se zapsat nedá.';
  END IF;

  -- ---- A) dorovnání živého claimu ------------------------------------------
  UPDATE public.fakturoid_invoices
     SET provider_invoice_id = _provider_invoice_id,
         provider_subject_id = _provider_subject_id,
         cislo = _cislo,
         variabilni_symbol = _vs,
         public_url = _public_url,
         status = _status,
         provider_total = _provider_total,
         provider_subtotal = _provider_subtotal,
         varovani = _varovani,
         vystaveno_at = now(),
         updated_at = now(),
         updated_by = auth.uid()
   WHERE idempotency_key = _klic
     AND uvolneno_at IS NULL
     AND deleted_at IS NULL
     -- Přepsat už zapsaný doklad by zahodilo stopu po tom prvním.
     AND provider_invoice_id IS NULL
  RETURNING id INTO _id;

  IF _id IS NOT NULL THEN RETURN true; END IF;

  -- ---- B) zápis nálezu -----------------------------------------------------
  -- Bez kontextu to nejde: sloupce `druh`, `subject_id`, `nas_soucet`, `radku`
  -- a `rezervace` jsou NOT NULL. Volající ho má, protože právě sestavil draft.
  IF _druh IS NULL OR _subject IS NULL OR _rezervace IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    INSERT INTO public.fakturoid_invoices
      (idempotency_key, druh, subject_id, event_id, obdobi_od, obdobi_do,
       nas_soucet, radku, rezervace, rezim, created_by,
       provider_invoice_id, provider_subject_id, cislo, variabilni_symbol,
       public_url, status, provider_total, provider_subtotal, varovani, vystaveno_at)
    VALUES
      (_klic, _druh, _subject, _event, _od, _do,
       coalesce(_nas_soucet, 0), coalesce(_radku, cardinality(_rezervace)),
       _rezervace, coalesce(_rezim, 'koncept'), auth.uid(),
       _provider_invoice_id, _provider_subject_id, _cislo, _vs,
       _public_url, _status, _provider_total, _provider_subtotal, _varovani, now())
    ON CONFLICT (idempotency_key) WHERE uvolneno_at IS NULL AND deleted_at IS NULL
    DO NOTHING
    RETURNING id INTO _id;

    -- Někdo jiný nález zapsal dřív. Není to chyba: doklad je zaevidovaný,
    -- jen ne námi.
    IF _id IS NULL THEN RETURN false; END IF;

    INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
    SELECT _id, r FROM unnest(_rezervace) AS r;

  EXCEPTION WHEN unique_violation THEN
    -- Rezervace už visí na jiném dokladu. Subtransakce se odroluje celá.
    RETURN false;
  END;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.fakturoid_zapis_vazbu(
  text, text, text, text, text, text, text, numeric, text,
  text, uuid, uuid, date, date, numeric, integer, text, uuid[], numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fakturoid_zapis_vazbu(
  text, text, text, text, text, text, text, numeric, text,
  text, uuid, uuid, date, date, numeric, integer, text, uuid[], numeric
) TO authenticated, service_role;

-- Starý osmnáctiparametrový podpis pryč. Kdyby zůstal, PostgREST by měl dvě
-- přetížení téhož jména a volání bez `_provider_subtotal` by mohlo skončit
-- v tom starém — tedy tiše bez základu daně, což je přesně to, co migrace řeší.
DROP FUNCTION IF EXISTS public.fakturoid_zapis_vazbu(
  text, text, text, text, text, text, text, numeric, text,
  text, uuid, uuid, date, date, numeric, integer, text, uuid[]
);

-- -----------------------------------------------------------------------------
-- 3) Pohled porovnává LIKE S LIKE
--
-- `druh` nese typ dokladu (`club_monthly` / `commercial_event`) — je to týž
-- řetězec, jaký nese `InvoiceDraft.type`, takže se z něj dá odvodit, co
-- `nas_soucet` znamená. Kdyby se do `druh` někdy dostala neznámá hodnota,
-- padne to do větve „celkem", tedy do dosavadního chování.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.fakturoid_invoices_list;
CREATE VIEW public.fakturoid_invoices_list
WITH (security_invoker = on) AS
  SELECT fi.id, fi.idempotency_key, fi.druh, fi.cislo, fi.variabilni_symbol,
         fi.status, fi.rezim, fi.public_url,
         fi.nas_soucet, fi.provider_total, fi.provider_subtotal,

         -- Se kterým číslem od providera se náš součet vůbec smí porovnávat.
         -- Je to sloupec, ne jen mezivýpočet: admin, který se dívá na `rozdil`,
         -- musí vidět i to, PROTI ČEMU se počítal — jinak se nedá poznat,
         -- jestli je nula pravda, nebo shoda náhod.
         CASE WHEN fi.druh = 'commercial_event' THEN 'základ bez DPH'
              ELSE 'celkem' END AS soucet_proti,

         -- Kontrolní součet. U komerčního dokladu má náš podklad ceny BEZ daně,
         -- takže se porovnává se ZÁKLADEM; u klubového jsou ceny s daní, takže
         -- s celkovou částkou. Do 0,50 Kč je to rozdíl zaokrouhlovacích
         -- pravidel, nad to jiný podklad.
         --
         -- `provider_subtotal` je NULL u dokladů vystavených před touhle migrací.
         -- Padá se tedy zpátky na `provider_total` — u neplátce je to totéž
         -- číslo, takže se pro historii nic nemění.
         (CASE WHEN fi.druh = 'commercial_event'
               THEN coalesce(fi.provider_subtotal, fi.provider_total)
               ELSE fi.provider_total
          END - fi.nas_soucet) AS rozdil,

         fi.varovani,
         fi.obdobi_od, fi.obdobi_do,
         fi.vystaveno_at, fi.odeslano_at, fi.pdf_path,
         s.name AS subjekt,
         cardinality(fi.rezervace) AS rezervaci
    FROM public.fakturoid_invoices fi
    JOIN public.subjects s ON s.id = fi.subject_id
   WHERE fi.deleted_at IS NULL
     AND fi.uvolneno_at IS NULL
     AND fi.provider_invoice_id IS NOT NULL;

-- BEZ TOHOHLE REVOKE dostane nový objekt v `public` výchozí práva Supabase,
-- tedy plné `arwdDxtm` pro anon i authenticated (viz 20260824120000).
REVOKE ALL ON public.fakturoid_invoices_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.fakturoid_invoices_list TO authenticated;

COMMENT ON VIEW public.fakturoid_invoices_list IS
  'Přehled dokladů odeslaných do Fakturoidu. `rozdil` je kontrolní součet a pod DPH se počítá podle typu dokladu: u komerčního proti základu daně (naše ceny jsou bez ní), u klubového proti celkové částce. Proti čemu se počítalo, říká sloupec `soucet_proti`.';

-- -----------------------------------------------------------------------------
-- 4) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _anon int; _podpisu int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'fakturoid_invoices'
                    AND column_name = 'provider_subtotal') THEN
    RAISE EXCEPTION 'provider_subtotal nevznikl.';
  END IF;

  -- Dvě přetížení by znamenala, že se volání může tiše svézt tím starým.
  SELECT count(*) INTO _podpisu FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'fakturoid_zapis_vazbu';
  IF _podpisu <> 1 THEN
    RAISE EXCEPTION 'fakturoid_zapis_vazbu má % přetížení, má mít právě jedno.', _podpisu;
  END IF;

  SELECT count(*) INTO _anon FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'fakturoid_invoices_list'
     AND grantee IN ('anon', 'PUBLIC', 'service_role');
  IF _anon > 0 THEN
    RAISE EXCEPTION 'fakturoid_invoices_list má granty, které mít nemá (%).', _anon;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relname = 'fakturoid_invoices_list'
                    AND c.reloptions @> ARRAY['security_invoker=on']) THEN
    RAISE EXCEPTION 'fakturoid_invoices_list ztratil security_invoker.';
  END IF;
END $$;
