-- =============================================================================
-- Zrušená akce uvolní i OBSAZENÉ směny (trenér, instruktor)
-- Bug #6 od Jakuba (2. 9. 2026)
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- `cancel_open_shifts_on_reservation_cancel` rušila jen směny ve stavu
-- `open` a `pending`. `claimed` a `completed` zůstávaly schválně, s komentářem
-- „historie výplat; admin je řeší ručně".
--
-- U `completed` to sedí — práce se odvedla. U `claimed` ne: akce se nekoná,
-- takže potvrzená směna je závazek bez práce. Změřeno na zrušeném tréninku:
--
--     bar_staff   open     →  cancelled   ✓
--     instructor  claimed  →  claimed     ✗ zůstal
--     trainer     claimed  →  claimed     ✗ zůstal (600 Kč/h)
--
-- Trenérská směna přitom vzniká rovnou jako `claimed` (`prirad_trenera`,
-- rozhodnutí P1), takže se jí tenhle úklid MINUL VŽDYCKY — nešlo o okrajový
-- případ, ale o výchozí stav každého tréninku s přiřazeným trenérem.
--
-- CO SE MĚNÍ: do výčtu přibývá `claimed`. `completed` zůstává nedotčené —
-- táž hranice, jakou drží `odeber_trenera` („uzavřenou směnu odebrat nejde,
-- je to podklad pro výplatu").
--
-- Rušení je dál SOFT: `status = 'cancelled'` plus razítka, řádek nikam nemizí.
--
-- VRATNOST: funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.cancel_open_shifts_on_reservation_cancel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.event_id IS NOT NULL
     AND (
       (OLD.status = 'confirmed' AND NEW.status = 'cancelled')
       OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.reservations r
        WHERE r.event_id = NEW.event_id
          AND r.id <> NEW.id
          AND r.status = 'confirmed'
          AND r.deleted_at IS NULL
     ) THEN
    UPDATE public.shifts
       SET status = 'cancelled',
           cancelled_at = now(),
           cancelled_by = auth.uid()
     WHERE event_id = NEW.event_id
       AND status IN ('open', 'pending', 'claimed');
    -- `claimed` SE NOVĚ RUŠÍ TAKY. Dřív tu bylo jen `open, pending` s tím, že
    -- obsazené směny jsou „historie výplat" — jenže to platí až pro odpracované.
    -- Zrušený trénink s `claimed` trenérem znamenal potvrzenou směnu za
    -- 600 Kč/h na akci, která se nekoná: v rozpisu svítí, do výplat vstupuje
    -- a odklidit ji musel admin ručně, o čemž se nikde nedozvěděl.
    --
    -- `completed` se NERUŠÍ a nikdy rušit nebude — tam se práce odvedla a je
    -- to podklad pro výplatu (táž hranice, jakou drží `odeber_trenera`).
    -- Rušení je SOFT: `cancelled` + razítka, řádek nikam nemizí (zásada 2).
  END IF;
  RETURN NULL;
END;
$function$

;

DO $kontrola$
BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.cancel_open_shifts_on_reservation_cancel()'::regprocedure)
     NOT LIKE '%''open'', ''pending'', ''claimed''%' THEN
    RAISE EXCEPTION 'Úklid směn pořád nesahá na obsazené — trenér by na zrušené akci zůstal.';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.cancel_open_shifts_on_reservation_cancel()'::regprocedure)
     LIKE '%''completed''%' THEN
    RAISE EXCEPTION 'Úklid sahá i na completed — to je podklad pro výplatu a rušit se nesmí.';
  END IF;
  RAISE NOTICE 'Zrušená akce uvolní i obsazené směny; odpracované zůstávají.';
END $kontrola$;
