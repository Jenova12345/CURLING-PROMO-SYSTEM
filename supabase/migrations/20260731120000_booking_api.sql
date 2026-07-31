-- =============================================================================
-- Rezervace 2. kolo — serverové API (RPC) + maskování ceny
-- =============================================================================
-- PROČ RPC: rezervace na obě dráhy, série opakovaných tréninků a přebití tréninku
-- komerční akcí musí proběhnout v JEDNÉ transakci (akce + N rezervací + storna +
-- notifikace). Přes PostgREST to jde jen po jednom insertu bez možnosti vrátit zpět.
-- Funkce jsou SECURITY DEFINER a práva si ověřují samy; guard trigger je pouštějí
-- přes transakčně lokální GUC app.trusted_booking.
--
-- MASKOVÁNÍ CENY: název klubu/akce vidí všichni přihlášení, částku jen admin a autor
-- rezervace. Vynuceno v DB — role authenticated nemá na cenové sloupce tabulky
-- reservations právo SELECT, čte se přes view (které maskuje) nebo přes RPC.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) VIEW PRO KALENDÁŘ — jména všem, částky jen adminovi a autorovi
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.reservations_calendar;

CREATE VIEW public.reservations_calendar
  WITH (security_invoker = off) AS
  SELECT
    r.id,
    r.sheet_id,
    r.subject_id,
    r.event_id,
    r.series_id,
    r.start_at,
    r.end_at,
    r.status,
    -- identita akce: vidí ji každý přihlášený (požadavek klienta)
    s.name  AS subject_name,
    s.type  AS subject_type,
    e.title AS event_title,
    COALESCE(
      e.event_type,
      CASE WHEN s.type = 'commercial' THEN 'commercial'::public.event_type
           ELSE 'training'::public.event_type END
    ) AS event_type,
    -- poznámka je interní informace klubu → jen klub a admin
    CASE WHEN has_role(auth.uid(), 'admin') OR public.is_subject_member(r.subject_id)
         THEN r.note END AS note,
    r.approved_at,
    r.created_by,
    cp.full_name AS created_by_name,
    r.created_at,
    r.cancelled_at,
    r.cancelled_by,
    xp.full_name AS cancelled_by_name,
    r.cancel_reason,
    -- ČÁSTKY: jen admin a autor rezervace
    CASE WHEN has_role(auth.uid(), 'admin') OR r.created_by = auth.uid() THEN r.hours END            AS hours,
    CASE WHEN has_role(auth.uid(), 'admin') OR r.created_by = auth.uid() THEN r.rate_per_hour END    AS rate_per_hour,
    CASE WHEN has_role(auth.uid(), 'admin') OR r.created_by = auth.uid() THEN r.amount END           AS amount,
    CASE WHEN has_role(auth.uid(), 'admin') OR r.created_by = auth.uid() THEN r.corrected_hours END  AS corrected_hours,
    CASE WHEN has_role(auth.uid(), 'admin') OR r.created_by = auth.uid() THEN r.corrected_amount END AS corrected_amount,
    (has_role(auth.uid(), 'admin') OR r.created_by = auth.uid()) AS can_see_amount,
    -- co smí přihlášený s rezervací dělat (aby to FE nemusel dopočítávat z rolí)
    (has_role(auth.uid(), 'admin')
     OR (r.subject_id IS NOT NULL AND public.is_subject_rep(r.subject_id))
     OR (r.subject_id IS NOT NULL AND public.is_subject_member(r.subject_id) AND r.created_by = auth.uid())
    ) AS can_manage,
    (has_role(auth.uid(), 'admin')
     OR (r.subject_id IS NOT NULL AND public.is_subject_rep(r.subject_id))
    ) AS can_approve
  FROM public.reservations r
  LEFT JOIN public.subjects s  ON s.id  = r.subject_id
  LEFT JOIN public.events   e  ON e.id  = r.event_id
  LEFT JOIN public.profiles cp ON cp.user_id = r.created_by
  LEFT JOIN public.profiles xp ON xp.user_id = r.cancelled_by
  WHERE r.deleted_at IS NULL;

REVOKE ALL ON public.reservations_calendar FROM anon, public;
GRANT SELECT ON public.reservations_calendar TO authenticated;

COMMENT ON VIEW public.reservations_calendar IS
  'Kalendář ledu pro přihlášené: obsazenost + název klubu/akce vidí všichni, částku jen admin a autor rezervace. Obsahuje i stornované (kvůli auditu „kdo zrušil"); kalendář si filtruje status = confirmed.';

-- -----------------------------------------------------------------------------
-- 2) PODKLADY PRO FAKTURACI („kdo kolik dluží") — jen admin
-- -----------------------------------------------------------------------------
CREATE VIEW public.reservations_billing
  WITH (security_invoker = off) AS
  SELECT
    r.id, r.subject_id, s.name AS subject_name, s.type AS subject_type,
    r.sheet_id, sh.name AS sheet_name,
    r.start_at, r.end_at,
    r.hours, r.rate_per_hour, r.amount,
    r.corrected_hours, r.corrected_amount, r.correction_reason,
    r.note, e.title AS event_title, e.event_type
  FROM public.reservations r
  JOIN public.subjects s   ON s.id  = r.subject_id
  JOIN public.sheets   sh  ON sh.id = r.sheet_id
  LEFT JOIN public.events e ON e.id = r.event_id
  WHERE r.status = 'confirmed'
    AND r.deleted_at IS NULL
    AND has_role(auth.uid(), 'admin');

REVOKE ALL ON public.reservations_billing FROM anon, public;
GRANT SELECT ON public.reservations_billing TO authenticated;

-- -----------------------------------------------------------------------------
-- 3) CENOVÉ SLOUPCE NEJDOU ČÍST PŘÍMO Z TABULKY
-- -----------------------------------------------------------------------------
-- Sloupcová práva jsou rolová (ne řádková), takže tabulku uzavřeme úplně a čtení
-- částek jde jen přes view výše, které maskuje podle uživatele.
REVOKE SELECT ON public.reservations FROM authenticated;
GRANT SELECT (
  id, sheet_id, subject_id, event_id, series_id,
  start_at, end_at, status, note,
  created_by, created_at, updated_by, updated_at, deleted_at,
  approved_at, approved_by, cancelled_at, cancelled_by, cancel_reason
) ON public.reservations TO authenticated;

-- -----------------------------------------------------------------------------
-- 4) POMOCNÉ FUNKCE
-- -----------------------------------------------------------------------------

-- Typ akce → priorita rezervace bez akce se odvodí z typu subjektu.
CREATE OR REPLACE FUNCTION public.reservation_priority(_event_type public.event_type, _subject_type public.subject_type)
 RETURNS int
 LANGUAGE sql IMMUTABLE
AS $$
  SELECT public.booking_priority(
    COALESCE(_event_type,
             CASE WHEN _subject_type = 'commercial' THEN 'commercial'::public.event_type
                  ELSE 'training'::public.event_type END)
  );
$$;

-- Kolize na zadaných dráhách v daném čase. Vrací i to, jestli je smí nová akce přebít.
CREATE OR REPLACE FUNCTION public.check_booking_conflicts(
  p_sheet_ids   uuid[],
  p_start       timestamptz,
  p_end         timestamptz,
  p_kind        text DEFAULT 'training',
  p_ignore_event uuid DEFAULT NULL,
  p_ignore_reservation uuid DEFAULT NULL
) RETURNS TABLE (
  reservation_id uuid,
  sheet_id       uuid,
  sheet_name     text,
  subject_name   text,
  event_title    text,
  event_type     public.event_type,
  start_at       timestamptz,
  end_at         timestamptz,
  can_override   boolean
)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT
    r.id, r.sheet_id, sh.name, s.name, e.title,
    COALESCE(e.event_type,
             CASE WHEN s.type = 'commercial' THEN 'commercial'::public.event_type
                  ELSE 'training'::public.event_type END),
    r.start_at, r.end_at,
    -- přebít smí jen admin a jen striktně vyšší prioritou
    (has_role(auth.uid(), 'admin')
     AND public.booking_priority(p_kind::public.event_type)
         > public.reservation_priority(e.event_type, s.type))
  FROM public.reservations r
  JOIN public.sheets sh     ON sh.id = r.sheet_id
  LEFT JOIN public.subjects s ON s.id = r.subject_id
  LEFT JOIN public.events   e ON e.id = r.event_id
  WHERE r.sheet_id = ANY (p_sheet_ids)
    AND r.status = 'confirmed'
    AND r.deleted_at IS NULL
    AND tstzrange(r.start_at, r.end_at) && tstzrange(p_start, p_end)
    AND (p_ignore_event IS NULL OR r.event_id IS DISTINCT FROM p_ignore_event)
    AND (p_ignore_reservation IS NULL OR r.id <> p_ignore_reservation)
  ORDER BY sh.name, r.start_at;
$$;

REVOKE ALL ON FUNCTION public.check_booking_conflicts(uuid[], timestamptz, timestamptz, text, uuid, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.check_booking_conflicts(uuid[], timestamptz, timestamptz, text, uuid, uuid) TO authenticated;

-- Kdo smí s rezervací hýbat: admin, zástupce klubu, nebo člen u vlastní rezervace.
CREATE OR REPLACE FUNCTION public.can_manage_reservation(_reservation uuid)
 RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.id = _reservation
       AND r.deleted_at IS NULL
       AND (
         has_role(auth.uid(), 'admin')
         OR (r.subject_id IS NOT NULL AND public.is_subject_rep(r.subject_id))
         OR (r.subject_id IS NOT NULL AND public.is_subject_member(r.subject_id) AND r.created_by = auth.uid())
       )
  );
$$;

-- -----------------------------------------------------------------------------
-- 5) ZALOŽENÍ REZERVACE (1 nebo obě dráhy, všechny typy akcí)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_booking(
  p_sheet_ids  uuid[],
  p_kind       text,                       -- training | tournament | commercial | maintenance
  p_title      text,
  p_start      timestamptz,
  p_end        timestamptz,
  p_subject_id uuid    DEFAULT NULL,
  p_note       text    DEFAULT NULL,
  p_role_reqs  jsonb   DEFAULT '{}'::jsonb,
  p_rate       numeric DEFAULT NULL,
  p_override   boolean DEFAULT false,
  p_series_id  uuid    DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _uid        uuid := auth.uid();
  _is_admin   boolean;
  _type       public.event_type;
  _event_id   uuid;
  _sheet      uuid;
  _res_ids    uuid[] := '{}';
  _res_id     uuid;
  _cancelled  jsonb  := '[]'::jsonb;
  _conf       record;
  _member     record;
  _required   int    := 0;
  _approved   timestamptz;
  _approver   uuid;
  _title      text;
  _new_prio   int;
  _sheet_cnt  int;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Pro rezervaci se musíte přihlásit.';
  END IF;
  _is_admin := has_role(_uid, 'admin');

  -- --- vstupy -----------------------------------------------------------------
  IF p_kind NOT IN ('training', 'tournament', 'commercial', 'maintenance') THEN
    RAISE EXCEPTION 'Neznámý typ akce: %', p_kind;
  END IF;
  _type := p_kind::public.event_type;

  _title := nullif(btrim(coalesce(p_title, '')), '');
  IF _title IS NULL THEN
    RAISE EXCEPTION 'Vyplňte název akce.';
  END IF;

  SELECT count(*) INTO _sheet_cnt FROM unnest(p_sheet_ids) AS x(id);
  IF p_sheet_ids IS NULL OR _sheet_cnt = 0 THEN
    RAISE EXCEPTION 'Vyberte aspoň jednu dráhu.';
  END IF;
  IF _sheet_cnt <> (SELECT count(DISTINCT id) FROM unnest(p_sheet_ids) AS x(id)) THEN
    RAISE EXCEPTION 'Každou dráhu lze vybrat jen jednou.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(p_sheet_ids) AS x(id)
     WHERE NOT EXISTS (SELECT 1 FROM public.sheets sh WHERE sh.id = x.id AND sh.active)
  ) THEN
    RAISE EXCEPTION 'Některá z vybraných drah neexistuje nebo není aktivní.';
  END IF;

  -- --- práva ------------------------------------------------------------------
  IF p_kind IN ('commercial', 'maintenance') THEN
    IF NOT _is_admin THEN
      RAISE EXCEPTION 'Komerční akci a údržbu ledu zadává jen správce haly.';
    END IF;
  ELSE
    IF p_subject_id IS NULL THEN
      RAISE EXCEPTION 'Vyberte klub, za který rezervujete.';
    END IF;
    IF NOT _is_admin AND NOT public.is_subject_member(p_subject_id) THEN
      RAISE EXCEPTION 'Za tento klub nemáte oprávnění rezervovat.';
    END IF;
  END IF;

  IF p_kind = 'commercial' AND p_subject_id IS NULL THEN
    RAISE EXCEPTION 'U komerční akce vyberte firmu (zákazníka).';
  END IF;
  IF p_kind = 'maintenance' AND p_subject_id IS NOT NULL THEN
    RAISE EXCEPTION 'Údržba ledu se neúčtuje — nezadávejte subjekt.';
  END IF;

  -- Komerční akce musí mít aspoň jednoho instruktora (požadavek klienta).
  IF p_kind = 'commercial' THEN
    IF COALESCE((p_role_reqs ->> 'instructor')::int, 0) < 1 THEN
      RAISE EXCEPTION 'Komerční akce potřebuje aspoň jednoho instruktora.';
    END IF;
    SELECT COALESCE(sum(value::int), 0) INTO _required FROM jsonb_each_text(p_role_reqs);
  END IF;

  -- --- kolize + případné přebití ----------------------------------------------
  _new_prio := public.booking_priority(_type);

  FOR _conf IN
    SELECT c.* FROM public.check_booking_conflicts(p_sheet_ids, p_start, p_end, p_kind) c
  LOOP
    IF NOT _is_admin THEN
      RAISE EXCEPTION '% je v tomto čase už obsazená (%). Vyberte jiný čas nebo dráhu.',
        _conf.sheet_name, COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace');
    END IF;
    IF NOT p_override THEN
      RAISE EXCEPTION '% je v tomto čase obsazená (%). Rezervaci lze založit jen s vědomým přebitím.',
        _conf.sheet_name, COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace');
    END IF;
    IF NOT _conf.can_override THEN
      RAISE EXCEPTION 'Akci „%" (%) nelze přebít — má stejnou nebo vyšší prioritu.',
        COALESCE(_conf.event_title, _conf.subject_name, 'rezervace'), _conf.sheet_name;
    END IF;
  END LOOP;

  -- Od téhle chvíle píšeme do rezervací my (guard trigger nás pustí).
  PERFORM set_config('app.trusted_booking', 'on', true);

  IF p_override AND _is_admin THEN
    FOR _conf IN
      SELECT c.* FROM public.check_booking_conflicts(p_sheet_ids, p_start, p_end, p_kind) c
    LOOP
      UPDATE public.reservations
         SET status        = 'cancelled',
             cancelled_at  = now(),
             cancelled_by  = _uid,
             cancel_reason = 'Přebito akcí vyšší priority: ' || _title
       WHERE id = _conf.reservation_id;

      _cancelled := _cancelled || jsonb_build_object(
        'reservation_id', _conf.reservation_id,
        'sheet_name',     _conf.sheet_name,
        'title',          COALESCE(_conf.event_title, _conf.subject_name),
        'start_at',       _conf.start_at,
        'end_at',         _conf.end_at);

      -- Upozorni všechny lidi napojené na dotčený klub + autora zrušené rezervace.
      FOR _member IN
        SELECT DISTINCT u.user_id
          FROM (
            SELECT sr.user_id
              FROM public.subject_reps sr
              JOIN public.reservations rr ON rr.id = _conf.reservation_id
             WHERE sr.subject_id = rr.subject_id
            UNION
            SELECT rr.created_by FROM public.reservations rr WHERE rr.id = _conf.reservation_id
          ) u(user_id)
         WHERE u.user_id IS NOT NULL
      LOOP
        PERFORM public.notify_user(
          _member.user_id,
          'reservation_overridden',
          'Vaše akce byla zrušena kvůli komerční události',
          'Rezervace „' || COALESCE(_conf.event_title, _conf.subject_name, 'akce') || '" na '
            || _conf.sheet_name || ' dne '
            || to_char(_conf.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
            || '–' || to_char(_conf.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI')
            || ' byla zrušena kvůli akci „' || _title || '". Omlouváme se, vyberte prosím náhradní termín.',
          '/calendar',
          _conf.reservation_id,
          (SELECT rr.subject_id FROM public.reservations rr WHERE rr.id = _conf.reservation_id));
      END LOOP;
    END LOOP;
  END IF;

  -- --- akce (kvůli názvu, typu a štábu) ---------------------------------------
  INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs, created_by)
  VALUES (_title, _type, p_start, p_end, _required,
          CASE WHEN p_kind = 'commercial' THEN p_role_reqs ELSE '{}'::jsonb END,
          _uid)
  RETURNING id INTO _event_id;

  -- --- potvrzení (člen klubu potřebuje potvrzení zástupce) --------------------
  IF _is_admin OR p_subject_id IS NULL OR public.is_subject_rep(p_subject_id) THEN
    _approved := now();
    _approver := _uid;
  ELSE
    _approved := NULL;
    _approver := NULL;
  END IF;

  -- --- rezervace ledu (jedna na každou dráhu) ---------------------------------
  FOREACH _sheet IN ARRAY p_sheet_ids LOOP
    INSERT INTO public.reservations (
      sheet_id, subject_id, event_id, series_id, start_at, end_at, note,
      rate_per_hour, created_by, approved_at, approved_by
    ) VALUES (
      _sheet, p_subject_id, _event_id, p_series_id, p_start, p_end,
      nullif(btrim(coalesce(p_note, '')), ''),
      CASE WHEN _is_admin THEN p_rate ELSE NULL END,   -- sazbu smí zadat jen admin
      _uid, _approved, _approver
    ) RETURNING id INTO _res_id;
    _res_ids := _res_ids || _res_id;
  END LOOP;

  -- Zvýšené oprávnění platí jen po dobu zápisů téhle funkce (GUC je transakčně
  -- lokální, takže bez tohohle by zůstalo zapnuté do konce transakce).
  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object(
    'event_id',        _event_id,
    'reservation_ids', to_jsonb(_res_ids),
    'approved',        _approved IS NOT NULL,
    'cancelled',       _cancelled);
EXCEPTION
  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Dráha už je v tomto čase obsazená — někdo byl rychlejší. Zkuste jiný čas nebo dráhu.';
END;
$$;

REVOKE ALL ON FUNCTION public.create_booking(uuid[], text, text, timestamptz, timestamptz, uuid, text, jsonb, numeric, boolean, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_booking(uuid[], text, text, timestamptz, timestamptz, uuid, text, jsonb, numeric, boolean, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6) PRAVIDELNÉ (OPAKOVANÉ) REZERVACE — např. každé Út a Čt 16–18 do data
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_booking_series(
  p_sheet_ids  uuid[],
  p_kind       text,
  p_title      text,
  p_start      timestamptz,           -- první termín (určuje i denní čas)
  p_end        timestamptz,
  p_weekdays   int[],                 -- 1 = pondělí … 7 = neděle
  p_until      date,                  -- včetně
  p_subject_id uuid    DEFAULT NULL,
  p_note       text    DEFAULT NULL,
  p_role_reqs  jsonb   DEFAULT '{}'::jsonb,
  p_rate       numeric DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _series    uuid := gen_random_uuid();
  _tz        text := 'Europe/Prague';
  _start_loc timestamp := p_start AT TIME ZONE _tz;
  _end_loc   timestamp := p_end   AT TIME ZONE _tz;
  _first     date := (p_start AT TIME ZONE _tz)::date;
  _day       date;
  _s         timestamptz;
  _e         timestamptz;
  _created   int := 0;
  _skipped   jsonb := '[]'::jsonb;
  _count     int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Pro rezervaci se musíte přihlásit.';
  END IF;
  IF p_weekdays IS NULL OR array_length(p_weekdays, 1) IS NULL THEN
    RAISE EXCEPTION 'Vyberte aspoň jeden den v týdnu.';
  END IF;
  IF p_until IS NULL OR p_until < _first THEN
    RAISE EXCEPTION 'Datum konce opakování musí být po prvním termínu.';
  END IF;
  IF p_until > _first + 365 THEN
    RAISE EXCEPTION 'Opakování jde zadat nejvýš na rok dopředu.';
  END IF;
  IF _end_loc::date <> _start_loc::date THEN
    RAISE EXCEPTION 'Opakovaná rezervace nesmí přesáhnout půlnoc.';
  END IF;

  FOR _day IN SELECT d::date FROM generate_series(_first, p_until, interval '1 day') d LOOP
    CONTINUE WHEN NOT (extract(isodow FROM _day)::int = ANY (p_weekdays));

    _count := _count + 1;
    IF _count > 200 THEN
      RAISE EXCEPTION 'Série by měla přes 200 termínů — zkraťte období.';
    END IF;

    -- stejný čas v místním pásmu (přechod na letní/zimní čas se dopočítá sám)
    _s := (_day + _start_loc::time) AT TIME ZONE _tz;
    _e := (_day + _end_loc::time)   AT TIME ZONE _tz;

    BEGIN
      PERFORM public.create_booking(
        p_sheet_ids, p_kind, p_title, _s, _e,
        p_subject_id, p_note, p_role_reqs, p_rate, false, _series);
      _created := _created + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Termín přeskočíme (nejčastěji kolize) a jedeme dál — uživatel dostane přehled.
      _skipped := _skipped || jsonb_build_object(
        'date',   to_char(_day, 'DD.MM.YYYY'),
        'reason', SQLERRM);
    END;
  END LOOP;

  IF _created = 0 THEN
    RAISE EXCEPTION 'Nepodařilo se založit ani jeden termín série (kolize nebo mimo otevírací dobu).';
  END IF;

  RETURN jsonb_build_object('series_id', _series, 'created', _created, 'skipped', _skipped);
END;
$$;

REVOKE ALL ON FUNCTION public.create_booking_series(uuid[], text, text, timestamptz, timestamptz, int[], date, uuid, text, jsonb, numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_booking_series(uuid[], text, text, timestamptz, timestamptz, int[], date, uuid, text, jsonb, numeric) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7) ÚPRAVA REZERVACE (název akce, poznámka) — i pro kluby
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_booking(
  p_reservation_id uuid,
  p_title          text    DEFAULT NULL,
  p_note           text    DEFAULT NULL,
  p_rate           numeric DEFAULT NULL
) RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _res   public.reservations%ROWTYPE;
  _title text := nullif(btrim(coalesce(p_title, '')), '');
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF NOT public.can_manage_reservation(p_reservation_id) THEN
    RAISE EXCEPTION 'Tuto rezervaci nemáte právo upravit.';
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET note = nullif(btrim(coalesce(p_note, '')), ''),
         rate_per_hour = CASE WHEN has_role(auth.uid(), 'admin') AND p_rate IS NOT NULL
                              THEN p_rate ELSE rate_per_hour END
   WHERE id = p_reservation_id;

  IF _title IS NOT NULL AND _res.event_id IS NOT NULL THEN
    UPDATE public.events SET title = _title WHERE id = _res.event_id;
  END IF;

  PERFORM set_config('app.trusted_booking', 'off', true);
END;
$$;

REVOKE ALL ON FUNCTION public.update_booking(uuid, text, text, numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_booking(uuid, text, text, numeric) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8) PŘESUN REZERVACE (drag & drop v kalendáři)
-- -----------------------------------------------------------------------------
-- Akce na dvou drahách se posouvá celá (jinak by se čas akce rozešel se směnami);
-- změna dráhy pak nedává smysl a je odmítnutá.
CREATE OR REPLACE FUNCTION public.move_booking(
  p_reservation_id uuid,
  p_start          timestamptz,
  p_end            timestamptz,
  p_sheet_id       uuid DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _res        public.reservations%ROWTYPE;
  _lanes      int := 1;
  _kind       text;
  _sheet_ids  uuid[];
  _conf       record;
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF _res.status <> 'confirmed' THEN RAISE EXCEPTION 'Stornovanou rezervaci nelze přesunout.'; END IF;
  IF NOT public.can_manage_reservation(p_reservation_id) THEN
    RAISE EXCEPTION 'Tuto rezervaci nemáte právo přesunout.';
  END IF;

  IF _res.event_id IS NOT NULL THEN
    SELECT count(*) INTO _lanes FROM public.reservations
     WHERE event_id = _res.event_id AND status = 'confirmed' AND deleted_at IS NULL;
  END IF;
  IF _lanes > 1 AND p_sheet_id IS NOT NULL AND p_sheet_id <> _res.sheet_id THEN
    RAISE EXCEPTION 'Akce běží na obou drahách — přesunout jde jen její čas, ne dráhu.';
  END IF;

  SELECT COALESCE(e.event_type::text,
                  CASE WHEN s.type = 'commercial' THEN 'commercial' ELSE 'training' END)
    INTO _kind
    FROM public.reservations r
    LEFT JOIN public.events e   ON e.id = r.event_id
    LEFT JOIN public.subjects s ON s.id = r.subject_id
   WHERE r.id = p_reservation_id;

  -- cílové dráhy (u víc drah zůstávají původní)
  IF _lanes > 1 THEN
    SELECT array_agg(sheet_id) INTO _sheet_ids FROM public.reservations
     WHERE event_id = _res.event_id AND status = 'confirmed' AND deleted_at IS NULL;
  ELSE
    _sheet_ids := ARRAY[COALESCE(p_sheet_id, _res.sheet_id)];
  END IF;

  -- kolize (vlastní akci ignorujeme)
  FOR _conf IN
    SELECT c.* FROM public.check_booking_conflicts(
      _sheet_ids, p_start, p_end, _kind, _res.event_id, _res.id) c
  LOOP
    RAISE EXCEPTION 'Nový termín se kryje s rezervací „%" (%).',
      COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace'), _conf.sheet_name;
  END LOOP;

  PERFORM set_config('app.trusted_booking', 'on', true);

  IF _lanes > 1 THEN
    UPDATE public.reservations
       SET start_at = p_start, end_at = p_end
     WHERE event_id = _res.event_id AND status = 'confirmed' AND deleted_at IS NULL;
  ELSE
    UPDATE public.reservations
       SET start_at = p_start, end_at = p_end, sheet_id = COALESCE(p_sheet_id, sheet_id)
     WHERE id = p_reservation_id;
  END IF;

  IF _res.event_id IS NOT NULL THEN
    UPDATE public.events SET start_time = p_start, end_time = p_end WHERE id = _res.event_id;
  END IF;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('moved_lanes', _lanes);
EXCEPTION
  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Nový termín je už obsazený — někdo byl rychlejší.';
END;
$$;

REVOKE ALL ON FUNCTION public.move_booking(uuid, timestamptz, timestamptz, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.move_booking(uuid, timestamptz, timestamptz, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9) STORNO (jedna dráha / celá akce / celá série)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_booking(
  p_reservation_id uuid,
  p_scope          text DEFAULT 'single',   -- single | event | series
  p_reason         text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _res       public.reservations%ROWTYPE;
  _ids       uuid[];
  _cancelled int;
BEGIN
  IF p_scope NOT IN ('single', 'event', 'series') THEN
    RAISE EXCEPTION 'Neznámý rozsah storna: %', p_scope;
  END IF;

  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF NOT public.can_manage_reservation(p_reservation_id) THEN
    RAISE EXCEPTION 'Tuto rezervaci nemáte právo stornovat.';
  END IF;

  SELECT array_agg(r.id) INTO _ids
    FROM public.reservations r
   WHERE r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND (
       (p_scope = 'single' AND r.id = _res.id)
       OR (p_scope = 'event'  AND _res.event_id  IS NOT NULL AND r.event_id  = _res.event_id)
       OR (p_scope = 'series' AND _res.series_id IS NOT NULL AND r.series_id = _res.series_id
           AND r.start_at >= now())            -- u série ruš jen budoucí termíny
     )
     AND public.can_manage_reservation(r.id);

  IF _ids IS NULL OR array_length(_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Není co stornovat.';
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET status        = 'cancelled',
         cancelled_at  = now(),
         cancelled_by  = auth.uid(),
         cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
   WHERE id = ANY (_ids);
  GET DIAGNOSTICS _cancelled = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('cancelled', _cancelled);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_booking(uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.cancel_booking(uuid, text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 10) POTVRZENÍ REZERVACE ZÁSTUPCEM KLUBU
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_reservation(p_reservation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _res public.reservations%ROWTYPE;
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF _res.approved_at IS NOT NULL THEN RETURN; END IF;

  IF NOT (has_role(auth.uid(), 'admin')
          OR (_res.subject_id IS NOT NULL AND public.is_subject_rep(_res.subject_id))) THEN
    RAISE EXCEPTION 'Rezervaci může potvrdit jen zástupce klubu nebo správce.';
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET approved_at = now(), approved_by = auth.uid()
   WHERE id = p_reservation_id;

  PERFORM set_config('app.trusted_booking', 'off', true);
END;
$$;

REVOKE ALL ON FUNCTION public.approve_reservation(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_reservation(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 11) SUBJEKT PODLE IČO (ARES bez duplicit)
-- -----------------------------------------------------------------------------
-- Klub/firmu se stejným IČO nesmíme zakládat znovu. Běžný uživatel přes RLS cizí
-- subjekty nevidí, proto to musí odpovědět server.
CREATE OR REPLACE FUNCTION public.find_subject_by_ico(p_ico text)
 RETURNS TABLE (id uuid, name text, type public.subject_type, ico text, dic text, address text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT s.id, s.name, s.type, s.ico, s.dic, s.address
    FROM public.subjects s
   WHERE s.deleted_at IS NULL
     AND s.ico = btrim(p_ico)
   LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.find_subject_by_ico(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.find_subject_by_ico(text) TO authenticated;
