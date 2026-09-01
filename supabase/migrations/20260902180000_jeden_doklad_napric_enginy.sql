-- =============================================================================
-- Tvrdý zámek proti druhému dokladu za tytéž rezervace + slušné odmítnutí
-- Nálezy 5 a „prázdné claims" z ultra review · příprava na cutover Fakturoidu
-- =============================================================================
-- KROK 0 — JAK TO DRŽÍ DNES:
--
-- Interní engine si rezervaci zamyká přes `reservations.invoice_id`
-- (`create_invoice_draft_club` filtruje `f.invoice_id IS NULL`).
-- Fakturoid si ji zamyká přes `fakturoid_invoice_reservations`
-- (UNIQUE na `reservation_id`).
--
-- ⚠️ ANI JEDEN O TOM DRUHÉM NEVÍ. `fakturovatelne_rezervace` `invoice_id`
-- nefiltruje (jen ho vrací jako sloupec) a `fakturoid_podklady_*` se ho
-- neptají vůbec. Dvojí faktuře za tytéž hodiny tedy dnes brání JEDINÁ věc:
-- guard „interní engine neumí plátce" (20260830160000). Ten ale s duplicitou
-- nijak nesouvisí a visí na `billing_settings.vat_mode`, což je přepínač
-- v Nastavení. Přepnutí na `neplatce` — třeba omylem nebo při zkoušení —
-- otevře obě cesty naráz.
--
-- Ověřeno dřív v souběžném testu: po `vat_mode='neplatce'` vznikl interní
-- doklad na 29 600 Kč vedle fakturoidího a 10 rezervací viselo na obou.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ: ZÁMEK NA ZÁPISU, NE VE VÝBĚRU
-- -----------------------------------------------------------------------------
-- Dvě zrcadlová pravidla, obě jako trigger:
--
--   1. `reservations.invoice_id` nejde nastavit rezervaci, kterou už drží
--      fakturoidí doklad.
--   2. Fakturoidí vazba nejde vytvořit rezervaci, kterou už drží interní
--      doklad.
--
-- Schválně na ZÁPISU: filtr ve výběru („neber to, co už má doklad") ochrání
-- jen tu cestu, do které ho někdo napsal — a těch cest je pět a přibývají.
-- Trigger platí pro všechny, i pro ty, které vzniknou příště, a nedá se
-- obejít přímým zápisem přes PostgREST.
--
-- NEVISÍ NA `vat_mode`. To je celý smysl: zámek proti dvojí faktuře nemá co
-- dělat na daňovém přepínači.
--
-- -----------------------------------------------------------------------------
-- A DRUHÁ VĚC: `fakturoid_smi_volat` PADALA NA PRÁZDNÝCH CLAIMS
-- -----------------------------------------------------------------------------
-- Funkce dělá `current_setting('request.jwt.claims', true)::jsonb`. Když je
-- ta proměnná PRÁZDNÝ ŘETĚZEC (ne NULL), cast skončí tvrdou chybou
-- `invalid input syntax for type json` — a celá fakturační cesta spadne
-- místo slušného „nemáte oprávnění".
--
-- Nastane to spolehlivě přes POOLER: spojení se recyklují mezi relacemi a GUC
-- po předchozí relaci zůstane nastavený na prázdno. Narazil jsem na to při
-- ověřování na produkci — claim vrátil `invalid input syntax for type json`
-- a vypadalo to jako chyba migrace, ne prostředí.
--
-- Řeší to `NULLIF(..., '')`: prázdno se čte jako „žádné claims", tedy stejně
-- jako když proměnná není nastavená vůbec.
--
-- VRATNOST:
--   DROP TRIGGER IF EXISTS trg_reservations_jeden_doklad ON public.reservations;
--   DROP TRIGGER IF EXISTS trg_fakturoid_vazba_jeden_doklad ON public.fakturoid_invoice_reservations;
--   DROP FUNCTION IF EXISTS public.hlidej_jeden_doklad_rezervace();
--   DROP FUNCTION IF EXISTS public.hlidej_jeden_doklad_vazba();
--   -- fakturoid_smi_volat zpátky ze ŽIVÉHO schématu (pg_get_functiondef).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Prázdné claims = žádná oprávnění, ne pád
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_smi_volat()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(has_role(auth.uid(), 'admin'), false)
      -- `NULLIF(..., '')`: přes pooler zůstane po předchozí relaci prázdný
      -- řetězec, a `''::jsonb` je tvrdá chyba, ne false. Prázdno se proto čte
      -- jako „žádné claims" — tedy totéž co nenastavená proměnná.
      OR COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
                  = 'service_role', false)
      OR COALESCE(auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'), false);
$function$;

-- -----------------------------------------------------------------------------
-- 2) Zámek: interní doklad nesmí zabrat, co drží Fakturoid
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hlidej_jeden_doklad_rezervace()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.invoice_id IS NOT NULL
     AND NEW.invoice_id IS DISTINCT FROM OLD.invoice_id
     AND EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations fr
                  WHERE fr.reservation_id = NEW.id) THEN
    RAISE EXCEPTION 'Rezervace už je na dokladu z Fakturoidu, druhý doklad na ni vystavit nejde.'
      USING HINT = 'Nejdřív uvolni fakturoidí doklad (storno nebo dobropis).';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reservations_jeden_doklad ON public.reservations;
CREATE TRIGGER trg_reservations_jeden_doklad
  BEFORE UPDATE OF invoice_id ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.hlidej_jeden_doklad_rezervace();

-- -----------------------------------------------------------------------------
-- 3) Zámek zrcadlově: Fakturoid nesmí zabrat, co drží interní doklad
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hlidej_jeden_doklad_vazba()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.reservations r
              WHERE r.id = NEW.reservation_id AND r.invoice_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Rezervace už je na interním dokladu, do Fakturoidu ji poslat nejde.'
      USING HINT = 'Nejdřív uvolni interní doklad (storno nebo dobropis).';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fakturoid_vazba_jeden_doklad ON public.fakturoid_invoice_reservations;
CREATE TRIGGER trg_fakturoid_vazba_jeden_doklad
  BEFORE INSERT ON public.fakturoid_invoice_reservations
  FOR EACH ROW EXECUTE FUNCTION public.hlidej_jeden_doklad_vazba();

-- -----------------------------------------------------------------------------
-- 4) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_reservations_jeden_doklad' AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_fakturoid_vazba_jeden_doklad' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Zámek proti dvojí faktuře není kompletní — musí být na OBOU stranách.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid='public.fakturoid_smi_volat()'::regprocedure)
     NOT LIKE '%NULLIF%' THEN
    RAISE EXCEPTION 'fakturoid_smi_volat pořád padá na prázdných claims.';
  END IF;

  -- Existující data nesmí být už teď na obou dokladech.
  SELECT count(*) INTO _n
    FROM public.reservations r
    JOIN public.fakturoid_invoice_reservations fr ON fr.reservation_id = r.id
   WHERE r.invoice_id IS NOT NULL;
  IF _n > 0 THEN
    RAISE EXCEPTION '% rezervací už visí na interním i fakturoidím dokladu — nutno rozplést ručně.', _n;
  END IF;

  RAISE NOTICE 'Jedna rezervace, jeden doklad — napříč oběma enginy.';
END $kontrola$;
