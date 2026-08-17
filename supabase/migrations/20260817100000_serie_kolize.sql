-- =============================================================================
-- Opakované tréninky: kolize přeskočit, zbytek série dojet
-- =============================================================================
-- Série termínů (`create_booking_series`) už existovala a kolizní termíny
-- přeskakovala. Chyběly jí ale tři věci, kvůli kterým se na její výsledek nedalo
-- spolehnout:
--
-- 1) NEROZLIŠOVALA KOLIZI OD CHYBY ZADÁNÍ. Chytala `WHEN OTHERS`, takže chybějící
--    oprávnění, sazba nad stropem nebo nevyplněný ceník — tedy věci, které platí
--    pro VŠECHNY termíny — vyšly ven jako dvacet „přeskočených termínů". To je
--    tiché selhání v převleku za vstřícnost: uživatel se nedozví, co má opravit.
--
-- 2) NEVRACELA CELKOVÝ POČET, takže nešlo napsat „Vytvořeno 18 z 20". UI si ho
--    mohlo dopočítat samo, ale rozešlo by se s databází při přechodu na letní čas
--    a u dnů, kdy se nehraje.
--
-- 3) NEŘÍKALA, PROČ se termín přeskočil. „Kolize nebo mimo otevírací dobu" je
--    dohromady poloviční odpověď — a přitom jsou to dvě různé věci, z nichž jedna
--    se řeší jiným časem a druhá nastavením haly.
--
-- ŘEŠENÍ: kolizní a časové důvody dostaly VLASTNÍ SQLSTATE, takže je série pozná
-- a nemusí hádat podle textu hlášky:
--
--   U0001  dráha obsazená (i akcí s vyšší prioritou)
--   U0002  mimo otevírací dobu / den, kdy se nehraje
--
-- PROČ VLASTNÍ KÓDY A NE STANDARDNÍ TŘÍDA 55 (`object_in_use` a spol.): PostgREST
-- mapuje CELOU třídu 55 na HTTP 500. Běžná uživatelská chyba „dráha je obsazená"
-- by se tím stala serverovou — a to nejen v sérii, ale i u jednotlivé rezervace,
-- protože `create_booking` obsluhuje obojí. Na demu by se každý pokus o obsazený
-- termín zapsal do logů Supabase jako 500 a „pětistovka" by přestala znamenat
-- „něco je rozbité". Změřeno sondou přes PostgREST: 55006 → 500, 55000 → 500,
-- P0001 → 400, 23P01 → 400, vlastní kód (U0001) → 400.
--
-- Cokoli jiného sérii ZASTAVÍ a probublá ven — nic se nezaloží a je vidět proč.
-- Priorita akcí se nemění: komerční > turnaj > trénink, přebít smí jen admin
-- a jen vědomě (`p_override`), což série nikdy nedělá.
--
-- Těla všech tří funkcí jsou vygenerovaná z `pg_get_functiondef` živého schématu
-- (pravidlo 7 v CLAUDE.md); vložené jsou do nich jen zásahy popsané výš.
--
-- VRATNOST: `CREATE OR REPLACE` všech tří funkcí zpět do znění z
--   supabase/migrations/20260731110000_booking_core.sql     (validate_reservation_slot)
--   supabase/migrations/20260812200000_security_hardening.sql (create_booking, create_booking_series)
--
-- ⚠️ POZOR NA TEN DRUHÝ ODKAZ. Obě `create_booking*` naposledy nahradila A5, ne
-- `booking_api.sql` — revert podle staršího souboru by SHODIL A5 a klientovi by
-- se přes PostgREST zase vracelo `DETAIL: Failing row contains (…)` se sazbou
-- a částkou (drift 8b). Poznat to jde podle `check_violation`: v A5 je,
-- v `booking_api.sql` ani jednou.
--
-- Data se nemění, žádný sloupec ani constraint nepřibývá.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Otevírací doba je důvod pro TERMÍN, ne pro celé zadání
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_reservation_slot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  _oh          jsonb;
  _dow         text;
  _open        time;
  _close       time;
  _local_start timestamp;
  _local_end   timestamp;
BEGIN
  IF NEW.status = 'cancelled' OR NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;  -- storno/smazání čas neřeší
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.start_at = OLD.start_at AND NEW.end_at = OLD.end_at THEN
    RETURN NEW;  -- čas se nemění → nic nevaliduj (nezablokuje úpravy starých rezervací)
  END IF;

  _local_start := NEW.start_at AT TIME ZONE 'Europe/Prague';
  _local_end   := NEW.end_at   AT TIME ZONE 'Europe/Prague';

  IF _local_start <> date_trunc('hour', _local_start)
     OR _local_end <> date_trunc('hour', _local_end) THEN
    RAISE EXCEPTION 'Rezervovat jde jen na celé hodiny (např. 17:00–19:00).';
  END IF;

  IF _local_end::date <> _local_start::date THEN
    RAISE EXCEPTION 'Rezervace nesmí přesáhnout půlnoc — rozděl ji na dva dny.';
  END IF;

  SELECT opening_hours INTO _oh FROM public.settings LIMIT 1;
  _dow   := extract(isodow FROM _local_start)::int::text;   -- 1 = pondělí … 7 = neděle
  _open  := (_oh -> _dow ->> 'open')::time;
  _close := (_oh -> _dow ->> 'close')::time;

  IF _open IS NULL OR _close IS NULL THEN
    -- SQLSTATE 55000 = „důvod platí pro TENHLE termín, ne pro celé zadání".
    -- Série podle něj pozná, že má termín přeskočit a jet dál (viz create_booking_series).
    RAISE EXCEPTION 'Pro tento den není nastavená otevírací doba — doplňte ji v Nastavení.'
      USING ERRCODE = 'U0002';
  END IF;

  IF _local_start::time < _open OR _local_end::time > _close THEN
    -- Otevírací doba se liší den od dne, takže tohle je taky důvod PRO TERMÍN.
    RAISE EXCEPTION 'Mimo otevírací dobu (%–%). Vyberte čas uvnitř provozní doby.',
      to_char(_open, 'HH24:MI'), to_char(_close, 'HH24:MI')
      USING ERRCODE = 'U0002';
  END IF;

  RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 2) Kolize dostane vlastní SQLSTATE
--
-- Včetně větve „nelze přebít — vyšší priorita": termín, který drží komerční akce,
-- je pro trénink prostě obsazený. Priorita tím zůstává v platnosti, jen se o ní
-- série dozví způsobem, který nemusí louskat z textu hlášky.
-- -----------------------------------------------------------------------------
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
      -- SQLSTATE U0001 = KOLIZE. Série podle něj pozná, že má
      -- termín přeskočit a jet dál. Bez vlastního kódu by musela chytat všechno
      -- (WHEN OTHERS) a hlásila by jako „kolizi" i chybějící oprávnění nebo
      -- sazbu nad stropem — tedy věci, které platí pro celé zadání, ne pro termín.
      RAISE EXCEPTION '% je v tomto čase už obsazená (%). Vyberte jiný čas nebo dráhu.',
        _conf.sheet_name, COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace')
        USING ERRCODE = 'U0001';
    END IF;
    IF NOT p_override THEN
      RAISE EXCEPTION '% je v tomto čase obsazená (%). Rezervaci lze založit jen s vědomým přebitím.',
        _conf.sheet_name, COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace')
        USING ERRCODE = 'U0001';
    END IF;
    IF NOT _conf.can_override THEN
      -- Priorita zůstává v platnosti (komerční > turnaj > trénink): termín, který
      -- drží akce se stejnou nebo vyšší prioritou, je pro sérii prostě obsazený.
      RAISE EXCEPTION 'Akci „%" (%) nelze přebít — má stejnou nebo vyšší prioritu.',
        COALESCE(_conf.event_title, _conf.subject_name, 'rezervace'), _conf.sheet_name
        USING ERRCODE = 'U0001';
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
    -- ERRCODE MUSÍ ZŮSTAT: holý `RAISE EXCEPTION` dostane P0001, čímž se z kolize
    -- stane „obyčejná chyba" a série ji nepozná — přesně tak byla větev pro
    -- `exclusion_violation` v `create_booking_series` chvíli mrtvým kódem.
    -- Je to táž kolize jako z `check_booking_conflicts`, jen zjištěná o vteřinu
    -- později, takže dostává týž kód.
    RAISE EXCEPTION 'Dráha už je v tomto čase obsazená — někdo byl rychlejší. Zkuste jiný čas nebo dráhu.'
      USING ERRCODE = 'U0001';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3) Série: přeskoč termín, zastav se na chybě zadání, vrať souhrn
-- -----------------------------------------------------------------------------
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
  _duvod     text;
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

    -- NEEXISTUJÍCÍ ČAS PŘI PŘECHODU NA LETNÍ ČAS. Poslední březnovou neděli se
    -- ve 2:00 posunou hodiny na 3:00, takže třeba 02:00–03:00 ten den vůbec
    -- neexistuje: `AT TIME ZONE` obojí přeloží na 03:00 a vyjde `_e <= _s`.
    -- `create_booking` by to odmítlo hláškou „Konec musí být po začátku" — což je
    -- P0001, tedy chyba zadání, a shodilo by to CELOU sérii. Přitom je to důvod
    -- vázaný na jeden jediný termín. (Dosažitelné jen když hala v tu hodinu
    -- otvírá, ale právě takové případy sérii rozbíjejí nejošklivěji.)
    IF _e <= _s THEN
      _skipped := _skipped || jsonb_build_object(
        'iso',    to_char(_day, 'YYYY-MM-DD'),
        'date',   to_char(_day, 'DD.MM.YYYY'),
        'duvod',  'neexistujici_cas',
        'reason', 'Tenhle čas v daný den neexistuje — posouvají se hodiny na letní čas.');
      CONTINUE;
    END IF;

    BEGIN
      PERFORM public.create_booking(
        p_sheet_ids, p_kind, p_title, _s, _e,
        p_subject_id, p_note, p_role_reqs, p_rate, false, _series);
      _created := _created + 1;

    -- PŘESKAKUJÍ SE JEN DŮVODY, KTERÉ PLATÍ PRO TENHLE TERMÍN.
    --
    -- Dřív tu stálo `WHEN OTHERS`, což vypadá vstřícně, ale je to tiché selhání
    -- v převleku: chybějící oprávnění, sazba nad stropem nebo nevyplněný ceník
    -- platí pro VŠECHNY termíny, takže se uživateli nahlásilo dvacet „přeskočeno
    -- kvůli kolizi" místo jedné věty o tom, co má opravit. Tyhle chyby proto
    -- probublají ven a sérii zastaví — nic se nezaloží a je jasné proč.
    --
    --   U0001  → dráha obsazená, včetně akce s vyšší prioritou
    --             (komerční > turnaj > trénink)
    --   U0002  → mimo otevírací dobu / den, kdy se nehraje
    --   23P01  → kolize, která vznikla AŽ MEZI kontrolou a zápisem
    --
    -- Ten poslední případ je snadné přehlédnout: `check_booking_conflicts` se ptá
    -- před INSERTem, takže mezi dotazem a zápisem může někdo jiný slot zabrat.
    -- Pak vystřelí exclusion constraint `reservations_no_overlap` — a kdyby ho
    -- série nechytala, jeden nešťastně načasovaný termín by shodil celou sérii.
    -- Až poběží automatika vedle ručního zadávání, bude to trefovat pravidelně.
    EXCEPTION
      WHEN SQLSTATE 'U0001' OR SQLSTATE 'U0002' OR exclusion_violation THEN
        -- Guard zůstává i u vlastních kódů: `exclusion_violation` je konkrétní,
        -- ale kdyby sem někdo přidal další podmínku, ať se cizí chyba nepřevleče
        -- za kolizi v daný den. To je přesně to tiché selhání, kvůli kterému
        -- tahle migrace vznikla.
        IF SQLSTATE NOT IN ('U0002', 'U0001', '23P01') THEN
          RAISE;
        END IF;
        _duvod := CASE SQLSTATE WHEN 'U0002' THEN 'mimo_otviraci_dobu' ELSE 'kolize' END;
        -- `iso` je pro UI, `date` pro člověka. Formátovat „15. 4." patří do UI
        -- (má locale i date-fns); databáze dodá tvar, ze kterého to jde spolehlivě
        -- složit, ne hotovou větu.
        _skipped := _skipped || jsonb_build_object(
          'iso',    to_char(_day, 'YYYY-MM-DD'),
          'date',   to_char(_day, 'DD.MM.YYYY'),
          'duvod',  _duvod,
          -- U exclusion constraintu by se ven dostala syrová hláška Postgresu
          -- („conflicting key value violates exclusion constraint …"), což
          -- uživateli nic neřekne a vypisuje vnitřnosti schématu.
          'reason', CASE SQLSTATE
                      WHEN '23P01' THEN 'Dráha byla obsazena, než se termín stihl založit.'
                      ELSE SQLERRM
                    END);
    END;
  END LOOP;

  IF _count = 0 THEN
    -- Jinak by z toho vypadlo „nepodařilo se založit ani jeden z 0 termínů".
    -- Dialog hlídá, že je vybraný aspoň jeden den a že konec není před začátkem,
    -- ale ne to, že vybraný den do období vůbec padne (pondělí v období 17.–17. 8.).
    -- Chyba zadání, ne obsazení — proto obyčejný P0001 (a HTTP 400).
    RAISE EXCEPTION 'V zadaném období nevychází ani jeden z vybraných dnů v týdnu.'
      USING HINT = 'Prodluž období nebo vyber jiný den.';
  END IF;

  IF _created = 0 THEN
    -- Všechny termíny kolidovaly (chyby zadání sem nedojdou, ty vyletí výš).
    -- Vyjmenovat je je k ničemu, když jich je dvacet — stačí důvod prvního.
    -- Bez vlastního kódu: důvodem nemusí být obsazení (může padnout i všechno
    -- na otevírací dobu), takže „obsazeno" by tady mohlo lhát. Konkrétní důvod
    -- nese text hlášky.
    RAISE EXCEPTION 'Nepodařilo se založit ani jeden z % termínů. Důvod prvního: %',
      _count, COALESCE(_skipped->0->>'reason', 'neznámý')
      USING HINT = 'Zkontroluj čas, dráhu, vybrané dny i otevírací dobu haly.';
  END IF;

  -- `celkem` je nutné, aby šlo napsat „Vytvořeno 18 z 20" — bez něj by UI muselo
  -- počítat termíny znovu a mohlo by se s databází rozejít (svátky, letní čas).
  RETURN jsonb_build_object(
    'series_id', _series,
    'celkem',    _count,
    'created',   _created,
    'skipped',   _skipped);
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
-- 4) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _def text;
BEGIN
  -- Komentáře se strhnou: tělo funkce `WHEN OTHERS` cituje ve vysvětlení, proč
  -- se od něj ustoupilo, a kontrola by se chytla vlastního textu.
  _def := regexp_replace(
    pg_get_functiondef('public.create_booking_series(uuid[], text, text, timestamptz, timestamptz, int[], date, uuid, text, jsonb, numeric)'::regprocedure),
    '--[^\n]*', '', 'g');
  IF position('WHEN OTHERS' in _def) > 0 THEN
    RAISE EXCEPTION 'Série pořád chytá WHEN OTHERS — chyby zadání by se hlásily jako kolize.';
  END IF;
  IF position('SQLSTATE ''U0001''' in _def) = 0 THEN
    RAISE EXCEPTION 'Série nerozpoznává kolizi podle SQLSTATE.';
  END IF;
  IF position('celkem' in _def) = 0 THEN
    RAISE EXCEPTION 'Série nevrací celkový počet termínů — nešlo by napsat „X z Y".';
  END IF;

  -- I tady se komentáře strhávají: obě funkce ty kódy zmiňují ve vysvětlení,
  -- takže by kontrola prošla, i kdyby se všechny `USING ERRCODE` smazaly.
  -- Hledá se proto celá klauzule, ne jen číslo.
  IF position('ERRCODE = ''U0001''' in regexp_replace(
       pg_get_functiondef('public.create_booking(uuid[], text, text, timestamptz, timestamptz, uuid, text, jsonb, numeric, boolean, uuid)'::regprocedure),
       '--[^\n]*', '', 'g')) = 0 THEN
    RAISE EXCEPTION 'create_booking neoznačuje kolize vlastním SQLSTATE.';
  END IF;
  IF position('ERRCODE = ''U0002''' in regexp_replace(
       pg_get_functiondef('public.validate_reservation_slot()'::regprocedure),
       '--[^\n]*', '', 'g')) = 0 THEN
    RAISE EXCEPTION 'validate_reservation_slot neoznačuje důvody mimo otevírací dobu.';
  END IF;

  RAISE NOTICE 'Série: kolize se přeskakují, chyby zadání zastaví, souhrn nese celkem/vytvořeno/přeskočeno.';
END $kontrola$;
