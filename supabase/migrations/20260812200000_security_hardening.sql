-- =============================================================================
-- A5 — Bezpečnostní zpevnění před fází B (Etapa 2)
-- =============================================================================
-- POSLEDNÍ PR FÁZE A. Musí být hotový DŘÍV, než B1 sáhne na peněžní tabulky —
-- všechno níž jsou nálezy bran u A2, A3 a A4, které ležely v docs/SCHEMA_DRIFT.md
-- (kapitola 8) a podle rozhodnutí PM se řeší tady, ne „někdy".
--
-- Obsah:
--   1. Únik obsahu řádku z SECURITY DEFINER RPC (drift 8b)
--   2. `deleted_at IS NULL` v politice `reservations_update` (drift 8c)
--   3. Strop a povinný důvod u korekce hodin (drift 8e)
--   4. REVOKE TRUNCATE/DELETE na peněžních tabulkách (drift 8d)
--   5. Citlivá pole profilu jen vlastník + admin (drift 8f)
--
-- VRATNOST: každá část má revert popsaný u sebe. Žádná část nemění data —
-- jen práva, politiky, omezení a chybové hlášky.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Chyby integrity nesmí ke klientovi v syrové podobě (drift 8b)
--
-- Uvnitř SECURITY DEFINER funkce vlastněné `postgres` NEPLATÍ RLS. Postgres proto
-- do chyby doplní `DETAIL: Failing row contains (…)` s celým řádkem a PostgREST
-- ho u RPC přepošle volajícímu. U rezervací je v tom řádku sazba i částka — tedy
-- údaje, které jsou jinak před `authenticated` schované sloupcovým REVOKE.
--
-- Ověřeno útokem u A3 na `billing_settings`: člen, který z přímého SELECTu dostal
-- prázdno, dostal z RPC IBAN, číslo účtu, IČO i DIČ.
--
-- Funkce jsou tu vypsané celé, protože `CREATE OR REPLACE FUNCTION` jinak nejde —
-- je to týž vzor jako u všech předchozích migrací, které funkce mění. Těla NEJSOU
-- přepsaná ručně: vygenerovala je `pg_get_functiondef` z živého schématu a skript
-- do nich vložil jen blok EXCEPTION. Kdo bude tyhle funkce příště měnit, musí
-- vyjít z TÉHLE migrace, ne z booking_api.sql.
--
-- REVERT: obnovit definice z 20260731120000_booking_api.sql
--         (a z 20260804090000_group_actions_and_billing.sql u approve_reservation).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_reservation(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_booking(p_reservation_id uuid, p_scope text DEFAULT 'single'::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking(p_sheet_ids uuid[], p_kind text, p_title text, p_start timestamp with time zone, p_end timestamp with time zone, p_subject_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_role_reqs jsonb DEFAULT '{}'::jsonb, p_rate numeric DEFAULT NULL::numeric, p_override boolean DEFAULT false, p_series_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'Konec rezervace musí být po jejím začátku.';
  END IF;

  -- Do cizí série se nikdo nepřipojí (kazilo by to přehled opakovaných tréninků).
  IF p_series_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.series_id = p_series_id
       AND r.subject_id IS DISTINCT FROM p_subject_id
  ) THEN
    RAISE EXCEPTION 'Série patří jinému subjektu.';
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
      -- Znovu i tady: mezi kontrolou a stornem mohla vzniknout akce vyšší priority.
      IF NOT _conf.can_override THEN
        RAISE EXCEPTION 'Akci „%" (%) nelze přebít — má stejnou nebo vyšší prioritu.',
          COALESCE(_conf.event_title, _conf.subject_name, 'rezervace'), _conf.sheet_name;
      END IF;

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
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';

  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Dráha už je v tomto čase obsazená — někdo byl rychlejší. Zkuste jiný čas nebo dráhu.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking_series(p_sheet_ids uuid[], p_kind text, p_title text, p_start timestamp with time zone, p_end timestamp with time zone, p_weekdays integer[], p_until date, p_subject_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_role_reqs jsonb DEFAULT '{}'::jsonb, p_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- Ať uživatel vidí skutečný důvod (typicky kolize, ale může jít i o chybějící
    -- oprávnění nebo nevyplněný ceník) — jinak by hádal.
    RAISE EXCEPTION 'Nepodařilo se založit ani jeden termín série. Důvod prvního termínu: %',
      COALESCE(_skipped->0->>'reason', 'neznámý');
  END IF;

  RETURN jsonb_build_object('series_id', _series, 'created', _created, 'skipped', _skipped);
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.move_booking(p_reservation_id uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_sheet_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';

  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Nový termín je už obsazený — někdo byl rychlejší.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_booking(p_reservation_id uuid, p_title text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_rate numeric DEFAULT NULL::numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- p_note = NULL znamená „neměň"; prázdný řetězec znamená „smaž poznámku".
  -- (Bez tohohle rozlišení by úprava samotného názvu poznámku tiše vymazala.)
  UPDATE public.reservations
     SET note = CASE WHEN p_note IS NULL THEN note ELSE nullif(btrim(p_note), '') END,
         rate_per_hour = CASE WHEN has_role(auth.uid(), 'admin') AND p_rate IS NOT NULL
                              THEN p_rate ELSE rate_per_hour END
   WHERE id = p_reservation_id;

  IF _title IS NOT NULL AND _res.event_id IS NOT NULL THEN
    UPDATE public.events SET title = _title WHERE id = _res.event_id;
  END IF;

  PERFORM set_config('app.trusted_booking', 'off', true);
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 2) `deleted_at IS NULL` v politice reservations_update (drift 8c)
--
-- Politika pro UPDATE ho na rozdíl od SELECT politiky neměla. Dnes to nevadí,
-- protože Postgres na `UPDATE … WHERE sloupec = …` uplatní i SELECT politiku,
-- takže se soft-smazané řádky stejně nenajdou — ověřeno útokem. Je to ale ochrana
-- NÁHODOU, ne návrhem: stačí, aby někdo `authenticated` přidal tabulkový SELECT,
-- a soft-smazané rezervace se stanou zapisovatelnými.
--
-- REVERT: obnovit politiku bez `deleted_at IS NULL` z 20260718120000_membership_levels.sql
--         — NE z etapa1_rls.sql! Tamní verze nemá větev
--         `is_subject_member(subject_id) AND created_by = auth.uid()`, takže by
--         revert tiše sebral členům klubu právo editovat vlastní rezervace.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS reservations_update ON public.reservations;
CREATE POLICY reservations_update ON public.reservations
  FOR UPDATE TO authenticated
  USING (
    deleted_at IS NULL
    AND (has_role(auth.uid(), 'admin')
         OR public.is_subject_rep(subject_id)
         OR (public.is_subject_member(subject_id) AND created_by = auth.uid()))
  )
  -- WITH CHECK schválně BEZ `deleted_at IS NULL`: `USING` říká, na které řádky
  -- smím sáhnout, `WITH CHECK` jak smí vypadat výsledek. Se stejnou podmínkou
  -- v obou by nešlo `deleted_at` vůbec NASTAVIT — tedy ani soft-smazat, a to
  -- ani adminovi. Spolu s odebraným DELETE by rezervace nešla odstranit nijak,
  -- což je přesný opak zásady „nic nemazat natvrdo, ale jít to musí".
  WITH CHECK (
    has_role(auth.uid(), 'admin')
    OR public.is_subject_rep(subject_id)
    OR (public.is_subject_member(subject_id) AND created_by = auth.uid())
  );

-- -----------------------------------------------------------------------------
-- 3) Korekce hodin: strop 24 h a povinný důvod (drift 8e)
--
-- Dnes projde `corrected_hours = 9999.75`, což je na jednohodinové rezervaci
-- faktura na šest milionů. Rozhodnutí PM (12. 8. 2026): TVRDÝ ABSOLUTNÍ STROP
-- 24 hodin, NEvázaný na délku rezervace.
--
-- Proč ne vázat na rezervaci: zablokovalo by to běžný případ „klub použil led
-- o půl hodiny déle, naúčtuj mu víc, než měl rezervováno". Rezervace je vždy
-- v rámci jednoho dne a otevírací okno je nejvýš 7–22, tedy 15 h; 24 h je
-- pohodlná rezerva, která nezablokuje nic legitimního, ale z překlepu „9999"
-- udělá okamžitý blok.
--
-- `correction_reason` je povinný, protože požadavek klienta zní „musí být vidět,
-- kdo co a proč zadával". Korekce bez zdůvodnění je u peněz nedohledatelná změna.
--
-- REVERT: DROP CONSTRAINT u obou.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _nad_strop int; _bez_duvodu int;
BEGIN
  SELECT count(*) INTO _nad_strop FROM public.reservations WHERE corrected_hours > 24;
  SELECT count(*) INTO _bez_duvodu FROM public.reservations
   WHERE corrected_hours IS NOT NULL AND nullif(btrim(coalesce(correction_reason, '')), '') IS NULL;

  IF _nad_strop > 0 OR _bez_duvodu > 0 THEN
    RAISE EXCEPTION E'Migrace zastavena — existující korekce neodpovídají novým pravidlům:\n'
      '  nad stropem 24 h: %\n  bez zdůvodnění: %', _nad_strop, _bez_duvodu
      USING HINT = 'Oprav uvedené rezervace ručně. Migrace peněžní údaje záměrně nepřepisuje sama.';
  END IF;
END $$;

-- `ADD CONSTRAINT` nemá `IF NOT EXISTS`, takže druhý běh migrace by spadl na
-- „constraint already exists". Supabase migrace eviduje, takže to kousne jen při
-- ručním přeaplikování — ale spadnout na tomhle je matoucí, ne poučné.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reservations_corrected_hours_strop') THEN
    ALTER TABLE public.reservations
      ADD CONSTRAINT reservations_corrected_hours_strop
      CHECK (corrected_hours IS NULL OR corrected_hours <= 24);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reservations_korekce_ma_duvod') THEN
        -- `btrim` strhává jen ASCII mezery, takže nedělitelná mezera by prošla jako
    -- „vyplněný důvod". Constraint má zaručit, že tam je něco čitelného.
    ALTER TABLE public.reservations
      ADD CONSTRAINT reservations_korekce_ma_duvod
      CHECK (corrected_hours IS NULL
             OR regexp_replace(coalesce(correction_reason, ''),
                               '[[:space:]\u00a0\u200b-\u200f\u2060\ufeff]', '', 'g') <> '');
  END IF;
END $$;

-- Srozumitelná hláška dřív, než promluví CHECK (týž důvod jako u A2).
CREATE OR REPLACE FUNCTION public.check_reservation_money()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.rate_per_hour IS NOT NULL THEN
    IF NEW.rate_per_hour < 0 THEN
      RAISE EXCEPTION 'Sazba nesmí být záporná (dostal jsem % Kč/h).', NEW.rate_per_hour;
    END IF;
    IF NEW.rate_per_hour <> round(NEW.rate_per_hour) THEN
      RAISE EXCEPTION 'Sazba se zadává v celých korunách, bez haléřů (dostal jsem % Kč/h).', NEW.rate_per_hour;
    END IF;
  END IF;

  IF NEW.corrected_hours IS NOT NULL THEN
    IF NEW.corrected_hours < 0 THEN
      RAISE EXCEPTION 'Korekce hodin nesmí být záporná (dostal jsem % h).', NEW.corrected_hours;
    END IF;
    IF NEW.corrected_hours > 24 THEN
      RAISE EXCEPTION 'Korekce hodin je nejvýš 24 h (dostal jsem % h). Vyšší číslo je skoro jistě překlep.', NEW.corrected_hours;
    END IF;
    IF NEW.corrected_hours * 4 <> round(NEW.corrected_hours * 4) THEN
      RAISE EXCEPTION 'Korekce hodin jde jen po čtvrthodinách (0,25 / 0,50 / 0,75 …), dostal jsem % h.', NEW.corrected_hours;
    END IF;
    IF regexp_replace(coalesce(NEW.correction_reason, ''),
                      '[[:space:]\u00a0\u200b-\u200f\u2060\ufeff]', '', 'g') = '' THEN
      RAISE EXCEPTION 'Ke korekci hodin je potřeba důvod — musí být dohledatelné, kdo co a proč změnil.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.check_reservation_money() IS
  'Srozumitelné české hlášky pro peněžní pravidla (A2 + A5: strop korekce 24 h a povinný důvod). Záruku dávají CHECK constrainty, tenhle trigger jen mluví dřív — hlavně kvůli RPC.';

-- -----------------------------------------------------------------------------
-- 4) REVOKE TRUNCATE a DELETE na peněžních tabulkách (drift 8d)
--
-- Výchozí práva Supabase dávají `anon` i `authenticated` na každou novou tabulku
-- v `public` plné `arwdDxtm` — VČETNĚ TRUNCATE, na který se **RLS nevztahuje**.
-- Ověřeno: `SET ROLE anon; TRUNCATE public.audit_log;` projde a smaže celou
-- auditní stopu.
--
-- Přes PostgREST se TRUNCATE vyjádřit nedá a DELETE zahodí RLS, takže dnes to
-- není živý exploit (verdikt v driftu 8d). Je to ale latentní zesilovač: TRUNCATE
-- je jediná operace bez RLS, takže první RPC s dynamickým SQL by ji zpřístupnila.
-- REVOKE je nulová změna chování.
--
-- `audit_log` dostal REVOKE už v A3 (naložila do něj IBAN), tady se dorovnává zbytek.
--
-- REVERT — ZRCADLO toho, co se odebralo, NE `GRANT ALL`:
--   GRANT TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.settings, public.subjects,
--     public.reservations, public.audit_log, public.profiles, public.payouts, public.shifts
--     TO anon, authenticated;
--   GRANT INSERT, UPDATE ON public.settings, public.subjects TO anon;
--
-- `GRANT ALL` by revertem NEBYL — přidal by SELECT, který tyhle tabulky pro
-- `authenticated` nemají (A2b) ani nikdy neměly pro `anon`. Zapnul by tím
-- peněžní sloupce všem přihlášeným i nepřihlášeným, tedy pravý opak A2b.
-- -----------------------------------------------------------------------------
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.settings     FROM anon, authenticated;
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.subjects     FROM anon, authenticated;
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.reservations FROM anon, authenticated;
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.audit_log    FROM anon, authenticated;

-- Argument „TRUNCATE je jediná operace bez RLS" platí i pro tabulky, které nedrží
-- ceny, ale drží peníze nebo osobní údaje. Ověřeno, že je nemaže žádná cesta
-- v aplikaci ani žádná migrace — jediné mazání ve frontendu míří na `subject_reps`,
-- `user_roles`, `events` a `chat_groups`.
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.profiles FROM anon, authenticated;
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.payouts  FROM anon, authenticated;
REVOKE TRUNCATE, DELETE, TRIGGER, REFERENCES ON public.shifts   FROM anon, authenticated;

-- A TEĎ PLOŠNĚ, protože výčet tabulek je špatný nástroj na tohle.
--
-- Bezpečnostní brána ukázala, proč: `TRUNCATE public.user_roles` jako `anon`
-- prošel — a `has_role()` je v podstatě v každé RLS politice, takže vyprázdnění
-- téhle tabulky neznamená ztrátu admina, ale rozpad přístupových práv v celém
-- systému. Totéž `subject_reps` (zástupci klubů) a `email_outbox`.
--
-- Vyjmenovávat „peněžní" tabulky tedy nestačí. TRUNCATE je jediná operace, na
-- kterou se RLS nevztahuje, a v aplikaci ho nepotřebuje NIKDO — všechno mazání
-- jde přes DELETE s RLS, nebo přes soft-delete.
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- A ať to nezáleží na tom, jestli si někdo vzpomene: nové tabulky ho nedostanou.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE TRUNCATE ON TABLES FROM anon, authenticated;

-- `anon` nemá na peněžních tabulkách co dělat vůbec. Rezervace i subjekty jsou
-- za přihlášením, ceník po A2b taky.
REVOKE ALL ON public.settings FROM anon;
REVOKE ALL ON public.subjects FROM anon;

-- -----------------------------------------------------------------------------
-- 5) Citlivá pole profilu jen vlastník + admin (drift 8f)
--
-- Politika „Anyone authenticated can read profiles USING (true)" plus plné
-- sloupcové granty znamenaly, že si běžný člen přes REST přečetl CIZÍ bankovní
-- účty a telefony brigádníků. Ověřeno útokem.
--
-- Je absurdní chránit IBAN haly na úroveň „nikdo kromě admina" a nechat čísla
-- účtů brigádníků na jeden GET. Rozhodnutí PM (12. 8. 2026): citlivá pole vidí
-- jen vlastník a admin.
--
-- `full_name` citlivé NENÍ a zůstává čitelné — stojí na něm `profiles_public`
-- a jména v celé aplikaci (kdo rezervoval, kdo si vzal směnu). Zúžit ho by
-- rozbilo legitimní cesty, což je přesně to, co se stát nemá.
--
-- Vzor je týž jako u A2b: tabulkový SELECT pryč, necitlivé sloupce zpět
-- sloupcovým grantem, citlivé vydává pohled jen tomu, komu patří.
--
-- REVERT:
--   DROP VIEW public.profiles_self;
--   REVOKE SELECT ON public.profiles FROM authenticated;
--   GRANT  SELECT ON public.profiles TO   authenticated;
--   (a obnovit profiles_public bez maskování telefonu, pokud se má vrátit i to)
--
-- POZOR: revert DB se MUSÍ dělat spolu s revertem kódu. `AuthContext` i `Members`
-- čtou `profiles_self`; samotné shození pohledu rozbije přihlášení.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.profiles_self;

CREATE VIEW public.profiles_self
  WITH (security_invoker = off) AS
  SELECT
    p.id,
    p.user_id,
    p.full_name,
    -- Vlastník nebo admin. Ostatní dostanou NULL, ne chybu — profil cizího
    -- člověka se má dát zobrazit, jen bez jeho kontaktních a platebních údajů.
    CASE WHEN p.user_id = auth.uid() OR (SELECT has_role(auth.uid(), 'admin'))
         THEN p.phone END AS phone,
    CASE WHEN p.user_id = auth.uid() OR (SELECT has_role(auth.uid(), 'admin'))
         THEN p.bank_account END AS bank_account,
    p.created_at,
    p.updated_at,
    -- Schválně NE „je_muj": pro admina je to true i u cizích profilů. Název má
    -- říkat, co hodnota znamená — tedy „smím u tohohle profilu vidět údaje".
    COALESCE(p.user_id = auth.uid() OR (SELECT has_role(auth.uid(), 'admin')), false) AS smim_videt_udaje
  FROM public.profiles p;

REVOKE ALL ON public.profiles_self FROM anon, authenticated, public;
GRANT SELECT ON public.profiles_self TO authenticated;

COMMENT ON VIEW public.profiles_self IS
  'Profily pro frontend. Telefon a bankovní účet vidí jen vlastník a admin (rozhodnutí PM 12. 8. 2026); full_name zůstává čitelné všem, stojí na něm jména v celé aplikaci.';

REVOKE SELECT ON public.profiles FROM anon, authenticated;
GRANT SELECT (id, user_id, full_name, created_at, updated_at)
  ON public.profiles TO authenticated;

-- -----------------------------------------------------------------------------
-- 5b) `profiles_public` — starší pohled, kterým to všechno teklo dál
--
-- Samotný REVOKE na tabulce cíle NEDOSÁHNE. Vedle ní stojí pohled `profiles_public`
-- se `security_invoker = off`, který obchází sloupcové granty i RLS — a maskuje
-- jen `bank_account`, ne `phone`. Ověřeno: `SET ROLE anon` vrátil 5 řádků a 4
-- telefonní čísla, tedy `GET /rest/v1/profiles_public?select=phone` se samotným
-- veřejným anon klíčem, BEZ PŘIHLÁŠENÍ.
--
-- A protože je pohled auto-updatable a běží pod vlastníkem, šlo jím i ZAPISOVAT:
-- `SET ROLE anon; UPDATE profiles_public SET full_name='HACKED' …` přepsalo cizí
-- profil. RLS se neuplatnila, protože pohled ji obchází.
--
-- Je to starší dluh, ne regrese A5 — ale leží přesně v jejím záběru, takže se
-- řeší tady: telefon se maskuje stejně jako účet, `anon` nedostane nic a zápis
-- se zavírá úplně (pohled je čtecí, měnit profil se má přes tabulku, kde platí RLS).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.profiles_public
  WITH (security_invoker = off) AS
  SELECT
    p.id,
    p.user_id,
    p.full_name,
    CASE WHEN p.user_id = auth.uid() OR (SELECT has_role(auth.uid(), 'admin'))
         THEN p.phone END AS phone,
    CASE WHEN p.user_id = auth.uid() OR (SELECT has_role(auth.uid(), 'admin'))
         THEN p.bank_account END AS bank_account,
    p.created_at,
    p.updated_at
  FROM public.profiles p;

REVOKE ALL ON public.profiles_public FROM anon, authenticated, public;
GRANT SELECT ON public.profiles_public TO authenticated;

COMMENT ON VIEW public.profiles_public IS
  'Profily pro seznamy (jména, obsazení směn). Telefon i bankovní účet jen vlastníkovi a adminovi. Jen ke čtení a jen pro přihlášené — dřív šlo přes tenhle pohled číst telefony i bez přihlášení a zapisovat do cizích profilů.';

-- -----------------------------------------------------------------------------
-- 6) Kontrola, že to všechno drží
-- -----------------------------------------------------------------------------
DO $$
DECLARE _zbyva text;
BEGIN
  -- 8d: nikde na peněžních tabulkách nesmí zůstat TRUNCATE ani DELETE
  SELECT string_agg(DISTINCT table_name || '.' || privilege_type, ', ') INTO _zbyva
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name IN ('settings', 'subjects', 'reservations', 'audit_log', 'billing_settings')
     AND grantee IN ('anon', 'authenticated', 'PUBLIC')
     AND privilege_type IN ('TRUNCATE', 'DELETE');
  IF _zbyva IS NOT NULL THEN
    RAISE EXCEPTION 'A5 selhala: na peněžních tabulkách zůstal TRUNCATE/DELETE (%).', _zbyva;
  END IF;

  -- 8f: citlivé sloupce profilu nesmí být čitelné napřímo
  SELECT string_agg(DISTINCT column_name, ', ') INTO _zbyva
    FROM information_schema.column_privileges
   WHERE table_schema = 'public' AND table_name = 'profiles'
     AND privilege_type = 'SELECT' AND grantee IN ('anon', 'authenticated', 'PUBLIC')
     AND column_name IN ('phone', 'bank_account');
  IF _zbyva IS NOT NULL THEN
    RAISE EXCEPTION 'A5 selhala: citlivá pole profilu zůstala čitelná (%).', _zbyva;
  END IF;

  -- ...a naopak: full_name čitelné zůstat MUSÍ, jinak se rozbijí jména v aplikaci
  IF NOT has_column_privilege('authenticated', 'public.profiles', 'full_name', 'SELECT') THEN
    RAISE EXCEPTION 'A5 selhala: full_name přestalo být čitelné — to rozbije jména v celé aplikaci.';
  END IF;

  -- 8c: politika pro UPDATE musí vylučovat soft-smazané
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='reservations'
                    AND policyname='reservations_update' AND qual LIKE '%deleted_at IS NULL%') THEN
    RAISE EXCEPTION 'A5 selhala: reservations_update nevylučuje soft-smazané rezervace.';
  END IF;

  RAISE NOTICE 'A5: zpevnění hotové (RPC hlášky, deleted_at, strop korekcí, REVOKE, profily).';
END $$;
