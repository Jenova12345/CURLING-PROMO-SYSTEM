-- =============================================================================
-- Úprava schválené rezervace ji vrací na „čeká na schválení"
-- Bug #5 od Jakuba (2. 9. 2026)
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- `approved_at` nastavuje `create_booking` a `approve_reservation`. Žádná
-- editační cesta se ho ale nedotýkala — ani `move_booking`, ani
-- `update_booking`, ani `uprav_sazbu_akce`, `zmen_typ_akce`, `uprav_drahy_akce`.
-- Schválená rezervace tedy šla libovolně přecenit a razítko zůstalo.
--
-- Změřeno na klubové rezervaci (pásmový ceník):
--
--     17–19 (večerní pásmo)   2 400 Kč   schválená
--     → move_booking na 9–11  1 600 Kč   POŘÁD SCHVÁLENÁ
--
-- Kdo podepsal 2 400, má pod sebou 1 600 — a `fakturovatelne_rezervace` bere
-- `approved_at IS NOT NULL` jako „potvrzeno", takže se to vyfakturuje bez
-- toho, aby to někdo znovu viděl.
--
-- -----------------------------------------------------------------------------
-- PROČ TRIGGER, A NE ZÁSAH DO PĚTI FUNKCÍ
-- -----------------------------------------------------------------------------
-- Cest, které mění cenu, je dnes pět a zítra můžou být čtyři nebo šest.
-- Kdyby se razítko maskovalo v každé zvlášť, je to pět míst, kde se na to dá
-- zapomenout — a šesté, když někdo sáhne na `reservations` napřímo (admin to
-- přes PostgREST může). Trigger to řeší jednou a platí i pro cesty, které
-- ještě nevznikly.
--
-- -----------------------------------------------------------------------------
-- CO PŘESNĚ RUŠÍ SCHVÁLENÍ
-- -----------------------------------------------------------------------------
-- Vstupy, ze kterých se počítá cena, plus výsledek:
--   `start_at`, `end_at`   … čas, a s ním cenové pásmo
--   `sheet_id`             … dráha
--   `subject_id`           … komu se fakturuje
--   `rate_per_hour`, `amount`, `cenove_pasma` … cena sama
--
-- ⚠️ KOREKCE PO AKCI (`corrected_hours`, `corrected_amount`) schválně NEJSOU.
-- Ty zadává admin až po odehrání („nedorazili", „hráli o hodinu míň") a
-- vyžadovat po nich nové schválení by znamenalo posílat zástupce potvrzovat
-- něco, co se stalo minulý týden. Korekce má vlastní guard ve fakturaci.
--
-- ⚠️ Samotné schválení razítko neshazuje: když se ve stejném UPDATE mění
-- `approved_at`, trigger nedělá nic. Jinak by `approve_reservation` shodila,
-- co právě nastavila.
--
-- VRATNOST:
--   DROP TRIGGER IF EXISTS trg_reservations_zz_schvaleni ON public.reservations;
--   DROP FUNCTION IF EXISTS public.zrus_schvaleni_pri_uprave();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.zrus_schvaleni_pri_uprave()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  -- Nebylo co shodit.
  IF OLD.approved_at IS NULL THEN
    RETURN NEW;
  END IF;

  -- Ve stejném příkazu se hýbe schválením — to je `approve_reservation`
  -- (nebo admin, který razítko odebírá ručně), ne úprava rezervace.
  IF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    RETURN NEW;
  END IF;

  IF (NEW.start_at, NEW.end_at, NEW.sheet_id, NEW.subject_id,
      NEW.rate_per_hour, NEW.amount, NEW.cenove_pasma)
     IS DISTINCT FROM
     (OLD.start_at, OLD.end_at, OLD.sheet_id, OLD.subject_id,
      OLD.rate_per_hour, OLD.amount, OLD.cenove_pasma) THEN
    NEW.approved_at := NULL;
    NEW.approved_by := NULL;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.zrus_schvaleni_pri_uprave() IS
  'Úprava, která hýbe cenou (čas, dráha, subjekt, sazba, částka, pásma), shodí schválení — rezervace se vrací zástupci k potvrzení. Bez toho šlo schválenou rezervaci přesunout do levnějšího pásma a vyfakturovat částku, kterou nikdo neodkýval. Korekce po akci schválně nepočítá.';

-- `zz_` schválně: BEFORE triggery se spouštějí podle abecedy a tenhle musí být
-- POSLEDNÍ — až po `trg_reservations_pricing`, které přepočítá `amount`.
-- Kdyby běžel dřív, porovnával by částku, která se o řádek dál ještě změní.
DROP TRIGGER IF EXISTS trg_reservations_zz_schvaleni ON public.reservations;
CREATE TRIGGER trg_reservations_zz_schvaleni
  BEFORE UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.zrus_schvaleni_pri_uprave();

DO $kontrola$
DECLARE _poradi text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname='trg_reservations_zz_schvaleni' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Trigger na shození schválení se nevytvořil.';
  END IF;

  -- Musí běžet AŽ PO přecenění, jinak se ptá na starou částku.
  SELECT string_agg(tgname, ' < ' ORDER BY tgname) INTO _poradi
    FROM pg_trigger WHERE tgrelid='public.reservations'::regclass AND NOT tgisinternal
      AND tgname IN ('trg_reservations_pricing','trg_reservations_zz_schvaleni');
  IF _poradi <> 'trg_reservations_pricing < trg_reservations_zz_schvaleni' THEN
    RAISE EXCEPTION 'Pořadí triggerů je %, čekal jsem pricing PŘED schválením.', _poradi;
  END IF;

  RAISE NOTICE 'Úprava, která hýbe cenou, vrací rezervaci k potvrzení.';
END $kontrola$;
