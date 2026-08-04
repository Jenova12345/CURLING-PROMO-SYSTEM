-- =============================================================================
-- Rezervace na obě dráhy = jedna akce + podklady pro fakturu
-- =============================================================================
-- 1) Potvrzení rezervace platí pro celou akci, ne pro jednu dráhu. Rezervace na obě
--    dráhy vzniká jako dva záznamy (každá dráha se obsazuje zvlášť), ale logicky je
--    to jedna akce — půl potvrzené akce nedává smysl. Storno už celou akci umí
--    (cancel_booking se scope = 'event'), potvrzení mu teď odpovídá.
--    Skupinou je AKCE (event_id), ne série: série sdružuje opakované termíny v jiných
--    dnech a ty se musí potvrzovat každý zvlášť.
-- 2) Fakturační view dostává jméno objednatele — faktura má u řádku ukázat, kdo
--    rezervaci zadal.
-- Forward-only, žádná ztráta dat, RLS beze změny.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) POTVRZENÍ CELÉ AKCE (obě dráhy naráz, v jedné transakci)
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.approve_reservation(uuid);

CREATE OR REPLACE FUNCTION public.approve_reservation(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _res      public.reservations%ROWTYPE;
  _ids      uuid[];
  _potvrzeno int;
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;

  IF NOT (has_role(auth.uid(), 'admin')
          OR (_res.subject_id IS NOT NULL AND public.is_subject_rep(_res.subject_id))) THEN
    RAISE EXCEPTION 'Rezervaci může potvrdit jen zástupce klubu nebo správce.';
  END IF;

  -- Celá akce = všechny živé rezervace se stejným event_id (typicky obě dráhy).
  -- Klubová rezervace bez akce zůstává sama za sebe.
  -- Skupina se drží JEDNOHO subjektu: kdyby někdo ručně pověsil na akci rezervaci
  -- jiného klubu, nesmí ji zástupce potvrdit jedním kliknutím s tou svou.
  SELECT array_agg(r.id) INTO _ids
    FROM public.reservations r
   WHERE r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND r.approved_at IS NULL
     AND r.subject_id IS NOT DISTINCT FROM _res.subject_id
     AND (
       (_res.event_id IS NOT NULL AND r.event_id = _res.event_id)
       OR (_res.event_id IS NULL AND r.id = _res.id)
     );

  IF _ids IS NULL OR array_length(_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('approved', 0);   -- už potvrzeno, není co dělat
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET approved_at = now(), approved_by = auth.uid()
   WHERE id = ANY (_ids);
  GET DIAGNOSTICS _potvrzeno = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('approved', _potvrzeno);
END;
$$;

REVOKE ALL ON FUNCTION public.approve_reservation(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_reservation(uuid) TO authenticated;

COMMENT ON FUNCTION public.approve_reservation(uuid) IS
  'Potvrdí celou akci — u rezervace na obě dráhy obě rezervace najednou. Vrací počet potvrzených.';

-- -----------------------------------------------------------------------------
-- 2) Jedno upozornění na akci, ne na každou dráhu
-- -----------------------------------------------------------------------------
-- Zakládání už jednu zprávu na akci posílá; potvrzení ji dosud posílalo za každou
-- dráhu zvlášť, takže autor rezervace na obě dráhy dostal dvě stejné.
CREATE OR REPLACE FUNCTION public.notify_reservation_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _rep         record;
  _subject     text;
  _author      text;
  _when        text;
  _sheet       text;
BEGIN
  IF NEW.subject_id IS NULL OR NEW.status <> 'confirmed' OR NEW.deleted_at IS NOT NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.name INTO _subject FROM public.subjects s WHERE s.id = NEW.subject_id;
  SELECT sh.name INTO _sheet   FROM public.sheets sh WHERE sh.id = NEW.sheet_id;
  _when := to_char(NEW.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
           || '–' || to_char(NEW.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI');

  -- (a) nová nepotvrzená rezervace člena → upozorni všechny zástupce klubu
  IF TG_OP = 'INSERT' AND NEW.approved_at IS NULL THEN
    -- Jedna zpráva na akci, ne na každý slot: rezervace na obě dráhy ani série
    -- opakovaných tréninků nesmí zástupci zaplavit schránku.
    IF EXISTS (
      SELECT 1 FROM public.reservations r
       WHERE r.id <> NEW.id
         AND ((NEW.event_id  IS NOT NULL AND r.event_id  = NEW.event_id)
           OR (NEW.series_id IS NOT NULL AND r.series_id = NEW.series_id))
    ) THEN
      RETURN NULL;
    END IF;

    SELECT p.full_name INTO _author FROM public.profiles p WHERE p.user_id = NEW.created_by;
    FOR _rep IN
      SELECT sr.user_id FROM public.subject_reps sr
       WHERE sr.subject_id = NEW.subject_id AND sr.level = 'rep' AND sr.user_id <> NEW.created_by
    LOOP
      PERFORM public.notify_user(
        _rep.user_id, 'reservation_needs_approval',
        'Rezervace čeká na potvrzení',
        COALESCE(_author, 'Člen klubu') || ' zadal(a) rezervaci za ' || COALESCE(_subject, 'klub')
          || ': ' || COALESCE(_sheet, 'dráha') || ', ' || _when || '. Potvrďte ji v kalendáři.',
        '/calendar', NEW.id, NEW.subject_id);
    END LOOP;
    RETURN NULL;
  END IF;

  -- (b) zástupce potvrdil → dej vědět autorovi (u akce na obou drahách jen jednou)
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NULL AND NEW.approved_at IS NOT NULL
     AND NEW.created_by IS NOT NULL AND NEW.created_by <> COALESCE(NEW.approved_by, NEW.created_by) THEN
    -- Umlčet smí jen sourozenec potvrzený TOUŽ operací (stejné razítko — now() je
    -- v rámci příkazu konstantní). Jinak by zprávu spolkla dráha, která byla
    -- mezitím stornovaná nebo potvrzená dřív, a autor by se nedozvěděl nic.
    IF NEW.event_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.reservations r
       WHERE r.event_id = NEW.event_id AND r.id < NEW.id AND r.deleted_at IS NULL
         AND r.approved_at = NEW.approved_at
    ) THEN
      RETURN NULL;   -- zprávu pošle první rezervace ze stejného potvrzení
    END IF;

    PERFORM public.notify_user(
      NEW.created_by, 'reservation_approved',
      'Rezervace potvrzena',
      'Vaši rezervaci za ' || COALESCE(_subject, 'klub') || ' (' || COALESCE(_sheet, 'dráha')
        || ', ' || _when || ') potvrdil zástupce klubu.',
      '/calendar', NEW.id, NEW.subject_id);
  END IF;

  RETURN NULL;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) FAKTURAČNÍ PODKLADY — kdo rezervaci objednal
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
    r.created_by, cp.full_name AS created_by_name
  FROM public.reservations r
  JOIN public.subjects s    ON s.id  = r.subject_id
  JOIN public.sheets   sh   ON sh.id = r.sheet_id
  LEFT JOIN public.events   e  ON e.id = r.event_id
  LEFT JOIN public.profiles cp ON cp.user_id = r.created_by
  WHERE r.status = 'confirmed'
    AND r.deleted_at IS NULL
    AND has_role(auth.uid(), 'admin');

REVOKE ALL ON public.reservations_billing FROM anon, authenticated, public;
GRANT SELECT ON public.reservations_billing TO authenticated;
