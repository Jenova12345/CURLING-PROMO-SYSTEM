-- =============================================================================
-- Zrušená směna zruší i přihlášky, které na ní visí
-- Bug #7 od Jakuba (2. 9. 2026)
-- =============================================================================
-- KROK 0 — CO UŽ EXISTUJE:
--
-- Zrušení rezervace ruší SMĚNY (`cancel_open_shifts_on_reservation_cancel`,
-- od 20260902120000 včetně obsazených). Na `shift_applications` ale nesahá
-- NIC — grep přes `pg_proc` nenašel jedinou funkci, která by je zmiňovala,
-- a `shifts` nemá trigger, který by je táhl s sebou.
--
-- Změřeno na zrušené komerční akci:
--     směna → cancelled   |   přihláška na ni → pending
--
-- Brigádník tak má v přehledu žádost o směnu, která se nekoná, a čeká na
-- vyřízení, které nikdy nepřijde. Admin ji nevidí jako problém, protože
-- v jeho frontě je to pořád „čeká na schválení".
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ
-- -----------------------------------------------------------------------------
-- Trigger na `shifts`: jakmile směna přejde do `cancelled`, její ŽIVÉ přihlášky
-- (`pending`, `approved`) se zruší taky. `rejected` a `cancelled` se nesahá —
-- ty už jsou vyřízené a přepisovat je by mazalo, jak to dopadlo.
--
-- Věší se to na SMĚNU, ne na rezervaci: směnu ruší víc cest (zrušení akce,
-- `odeber_trenera`, `dorovnej_stab` u přebytku, admin ručně) a přihlášky mají
-- viset na osudu směny, ne na tom, kudy se ta směna zrušila.
--
-- `completed` směny se netýká: ta do `cancelled` nepřejde (hlídá to #6),
-- takže trigger nad ní nikdy nespustí a odpracované zůstává odpracované.
--
-- VRATNOST:
--   DROP TRIGGER IF EXISTS trg_shifts_zrus_prihlasky ON public.shifts;
--   DROP FUNCTION IF EXISTS public.zrus_prihlasky_zrusene_smeny();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.zrus_prihlasky_zrusene_smeny()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
    UPDATE public.shift_applications
       SET status = 'cancelled', updated_at = now()
     WHERE shift_id = NEW.id
       AND status IN ('pending', 'approved');
  END IF;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.zrus_prihlasky_zrusene_smeny() IS
  'Zrušená směna s sebou vezme i živé přihlášky (pending, approved). Bez toho zůstal brigádníkovi v přehledu požadavek na směnu, která se nekoná, a adminovi ve frontě položka „čeká na schválení", kterou nešlo vyřídit. Vyřízené přihlášky (rejected) se nepřepisují.';

DROP TRIGGER IF EXISTS trg_shifts_zrus_prihlasky ON public.shifts;
CREATE TRIGGER trg_shifts_zrus_prihlasky
  AFTER UPDATE OF status ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.zrus_prihlasky_zrusene_smeny();

DO $kontrola$
DECLARE _n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname='trg_shifts_zrus_prihlasky' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Trigger na rušení přihlášek se nevytvořil.';
  END IF;

  -- Co už viselo na zrušených směnách, uklidíme jednorázově — jinak by
  -- oprava platila jen pro budoucí zrušení a staré požadavky by v přehledu
  -- zůstaly navždy.
  UPDATE public.shift_applications a
     SET status = 'cancelled', updated_at = now()
    FROM public.shifts s
   WHERE s.id = a.shift_id
     AND s.status = 'cancelled'
     AND a.status IN ('pending', 'approved');
  GET DIAGNOSTICS _n = ROW_COUNT;
  IF _n > 0 THEN
    RAISE NOTICE 'Uklizeno % přihlášek, které visely na už zrušených směnách.', _n;
  END IF;

  RAISE NOTICE 'Zrušená směna bere přihlášky s sebou.';
END $kontrola$;
