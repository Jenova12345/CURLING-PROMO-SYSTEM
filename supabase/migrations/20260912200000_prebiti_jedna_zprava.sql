-- =============================================================================
-- Přebití akcí: jedna zpráva na člověka, ne na každý přebitý řádek
-- =============================================================================
-- KROK 0 (12. 9. 2026, změřeno bezpečnostní bránou na lokální replice, ne odhad):
--
--   admin přebije komerční akcí celý den 7–22 na obou drahách (30 rezervací)
--   → zástupce klubu dostane 45 zpráv o JEDNÉ akci
--     (30× `reservation_overridden` + 15× `reservation_cancelled`)
--
-- PROČ: `create_booking` volá `notify_user` UVNITŘ smyčky přes kolizní
-- rezervace, tedy jednou za každý přebitý ŘÁDEK × každého člověka napojeného
-- na klub. Je to tentýž nešvar, jaký migrace 20260912160000 opravila u zrušené
-- série, jen na jiném místě — a tam ho žádná značka neumlčí, protože každá
-- přebitá rezervace je jiná akce.
--
-- PROČ TO ŘEŠIT TEĎ A NE POZDĚJI: dokud jsou e-maily vypnuté, je to 45 řádků
-- ve zvonku. Po zapnutí je to 45 e-mailů, a se stropem odchozí pošty se z toho
-- stane 45 e-mailů rozložených do několika hodin. Obojí je špatně a obojí by
-- se projevilo až na klientovi.
--
-- CO SE TU MĚNÍ: upozornění se posílá AŽ ZA smyčkou, shrnuté podle příjemce.
-- Kdo přišel o víc termínů, dostane jednu zprávu s počtem a rozsahem; kdo
-- o jeden, dostane původní znění i s dráhou a časem.
--
-- Tělo je vygenerované z `pg_get_functiondef` ŽIVÉ PRODUKCE (12. 9. 2026,
-- ověřeno, že se shoduje s lokální replikou) a zasažená je JEN ta jedna
-- smyčka — CLAUDE.md, pravidlo 7. Všechno ostatní (priority, zámky,
-- `app.trusted_booking`, dělení ceny na dráhy, haléře) je slovo od slova
-- původní.
--
-- MUTAČNÍ ZKOUŠKA: viz `supabase/tests/prebiti_jednou_test.sql`, hlavička.
-- VRATNOST: `CREATE OR REPLACE` s tělem z historie migrací. Nic se nemaže,
--   žádný sloupec ani omezení nepřibývá.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.create_booking(p_sheet_ids uuid[], p_kind text, p_title text, p_start timestamp with time zone, p_end timestamp with time zone, p_subject_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_role_reqs jsonb DEFAULT '{}'::jsonb, p_rate numeric DEFAULT NULL::numeric, p_override boolean DEFAULT false, p_series_id uuid DEFAULT NULL::uuid, p_celkem numeric DEFAULT NULL::numeric)
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
  _celkem     numeric;   -- ruční celková cena akce (jen admin), NULL = spočítá engine
  _podil      numeric;   -- základní díl na jednu dráhu
  _halere     int;       -- haléře, které po dělení zbyly a musí se rozdat
  _poradi     int := 0;  -- kolikátou dráhu právě zakládáme
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Pro rezervaci se musíte přihlásit.';
  END IF;
  _is_admin := has_role(_uid, 'admin');

  -- OKNO 48 H PŘED AKCÍ: zakládat smí jen správce haly.
  --
  -- Kontrola stojí HNED ZA zjištěním role a PŘED vším ostatním: kdyby byla až
  -- za kontrolou kolizí, dozvěděl by se volající nejdřív „termín je obsazený"
  -- a teprve po přesunu, že v okně stejně nesmí zakládat.
  IF NOT _is_admin AND public.v_okne_48h(p_start) THEN
    -- ERRCODE MUSÍ ZŮSTAT U0003. Je to „důvod platí pro TENHLE termín", takže
    -- `create_booking_series` podle něj termín přeskočí a jede dál. S holým
    -- P0001 (což je výchozí kód `RAISE EXCEPTION`) by série spadla celá a
    -- zástupci klubu by se kvůli zítřku nezaložil ani jeden z pozdějších
    -- termínů. Táž úmluva jako U0001 (obsazeno) a U0002 (mimo otevírací dobu).
    RAISE EXCEPTION '%', public.hlaska_okna_48h('vytvořit')
      USING ERRCODE = 'U0003',
            HINT = 'Vyberte termín aspoň 48 h dopředu, nebo se domluvte se správcem haly.';
  END IF;

  -- --- ruční celková cena ------------------------------------------------------
  -- Částku smí zadat JEN admin — stejné pravidlo jako u sazby. Neadminovi se
  -- zahazuje potichu (ne chybou): pole v UI nevidí, takže když ho někdo pošle
  -- ručně přes API, není co vysvětlovat, jen se to nepoužije.
  _celkem := CASE WHEN _is_admin THEN p_celkem ELSE NULL END;

  IF _celkem IS NOT NULL THEN
    -- NaN A NEKONEČNO PROKLOUZNOU OBĚMA KONTROLAMA NÍŽ.
    --
    -- PostgREST umí `p_celkem` poslat jako řetězec, takže „NaN" i „Infinity"
    -- se do numeric dostanou. V Postgresu je `NaN = NaN` PRAVDA a NaN se řadí
    -- NAD všechny hodnoty, takže `NaN < 0` i `NaN <> round(NaN, 2)` jsou obě
    -- false — a spadlo by to až o kus dál na `NaN::int` v rozpadu částky,
    -- syrovou hláškou „cannot convert NaN to integer". (Proto ne `_celkem
    -- <> _celkem`, jak by se čekalo od plovoucí čárky — ta podmínka je tu
    -- vždycky false.) `-Infinity` chytne až kontrola na zápornou částku.
    IF _celkem = 'NaN'::numeric OR _celkem = 'Infinity'::numeric THEN
      RAISE EXCEPTION 'Celková cena musí být číslo.';
    END IF;
    IF _celkem < 0 THEN
      RAISE EXCEPTION 'Celková cena nemůže být záporná.';
    END IF;
    IF _celkem <> round(_celkem, 2) THEN
      RAISE EXCEPTION 'Celková cena se zadává nejvýš na haléře (dostal jsem %).', _celkem;
    END IF;
    -- Obojí najednou nedává smysl: sazba i celková cena popisují touž věc a
    -- při rozporu by se tiše rozhodlo za admina.
    IF p_rate IS NOT NULL THEN
      RAISE EXCEPTION 'Zadejte buď sazbu za hodinu, nebo celkovou cenu akce — ne obojí.';
    END IF;
    -- Bez subjektu není komu fakturovat, takže by se částka stejně zahodila.
    IF p_subject_id IS NULL THEN
      RAISE EXCEPTION 'Celkovou cenu lze zadat jen akci, která má klub nebo firmu.';
    END IF;
  END IF;

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

      -- Upozornění se posílá až ZA touhle smyčkou, hromadně. Proč, viz níž.
    END LOOP;

    -- ---- Jedna zpráva na člověka, ne na každý přebitý řádek ----------------
    -- Dřív se `notify_user` volalo UVNITŘ smyčky přes kolizní rezervace, tedy
    -- jednou za KAŽDÝ přebitý ŘÁDEK × každého člověka z klubu. Změřeno
    -- bezpečnostní bránou 12. 9. 2026: admin přebije komerční akcí celý den
    -- na obou drahách (30 rezervací) a zástupce klubu dostane 45 zpráv
    -- o JEDNÉ akci. Je to tentýž nešvar jako u zrušené série, jen na jiném
    -- místě, a stejná oprava: shrnout to do jedné zprávy.
    --
    -- ⚠️ `count(DISTINCT COALESCE(event_id, id))`, NE `count(*)`. Termín přes
    -- OBĚ DRÁHY jsou DVA řádky se společným `event_id`; s `count(*)` by se
    -- jeden dvoudráhový termín hlásil jako dva zrušené.
    FOR _member IN
      SELECT u.user_id,
             count(DISTINCT COALESCE(rr.event_id, rr.id))::int          AS terminu,
             min((z.value->>'start_at')::timestamptz)                   AS od,
             max((z.value->>'end_at')::timestamptz)                     AS do,
             (array_agg(z.value ORDER BY (z.value->>'start_at')::timestamptz))[1] AS prvni,
             (array_agg(rr.id ORDER BY rr.start_at))[1]                 AS rezervace_id,
             (array_agg(rr.subject_id ORDER BY rr.start_at))[1]         AS subject_id
        FROM jsonb_array_elements(_cancelled) z
        JOIN public.reservations rr ON rr.id = (z.value->>'reservation_id')::uuid
        CROSS JOIN LATERAL (
          SELECT sr.user_id FROM public.subject_reps sr WHERE sr.subject_id = rr.subject_id
          UNION
          SELECT rr.created_by
        ) u(user_id)
       WHERE u.user_id IS NOT NULL
       GROUP BY u.user_id
    LOOP
      PERFORM public.notify_user(
        _member.user_id,
        'reservation_overridden',
        'Vaše akce byla zrušena kvůli komerční události',
        CASE WHEN _member.terminu > 1 THEN
          'Kvůli akci „' || _title || '" bylo zrušeno ' || _member.terminu
            || ' vašich termínů, od '
            || to_char(_member.od AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
            || ' do '
            || to_char(_member.do AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
            || '. Omlouváme se, vyberte prosím náhradní termíny.'
        ELSE
          -- Jediný přebitý termín si nechává původní znění i s dráhou a časem:
          -- u jedné rezervace je konkrétní údaj užitečnější než souhrn.
          'Rezervace „' || COALESCE(_member.prvni->>'title', 'akce') || '" na '
            || COALESCE(_member.prvni->>'sheet_name', 'dráha') || ' dne '
            || to_char(_member.od AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
            || '–' || to_char(_member.do AT TIME ZONE 'Europe/Prague', 'HH24:MI')
            || ' byla zrušena kvůli akci „' || _title || '". Omlouváme se, vyberte prosím náhradní termín.'
        END,
        '/calendar',
        _member.rezervace_id,
        _member.subject_id);
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

  -- --- rozpad ruční ceny na dráhy ---------------------------------------------
  -- Akce na dvou drahách je JEDNA akce s jednou cenou, ale v databázi jsou to
  -- dva řádky — částka se tedy musí rozdělit tak, aby SOUČET seděl na haléř.
  -- Dělení samo o sobě to nezaručí: 14 000 / 3 = 4 666,666…, tři zaokrouhlené
  -- díly dají 13 999,98 a dvě koruny by zmizely. Zbylé haléře se proto rozdají
  -- po jednom prvním drahám, místo aby se zaokrouhlily stranou.
  IF _celkem IS NOT NULL THEN
    _podil  := trunc(_celkem / _sheet_cnt, 2);
    _halere := round((_celkem - _podil * _sheet_cnt) * 100)::int;
    -- Zapnout `cena_rucni` smí jen tahle funkce; trigger jinak příznak zahodí.
    PERFORM set_config('app.rucni_cena', 'on', true);
  END IF;

  -- --- rezervace ledu (jedna na každou dráhu) ---------------------------------
  FOREACH _sheet IN ARRAY p_sheet_ids LOOP
    _poradi := _poradi + 1;
    INSERT INTO public.reservations (
      sheet_id, subject_id, event_id, series_id, start_at, end_at, note,
      rate_per_hour, amount, created_by, approved_at, approved_by
    ) VALUES (
      _sheet, p_subject_id, _event_id, p_series_id, p_start, p_end,
      nullif(btrim(coalesce(p_note, '')), ''),
      CASE WHEN _is_admin THEN p_rate ELSE NULL END,   -- sazbu smí zadat jen admin
      CASE WHEN _celkem IS NOT NULL
           -- prvních `_halere` drah dostane o haléř víc, ať součet sedí přesně
           THEN _podil + CASE WHEN _poradi <= _halere THEN 0.01 ELSE 0 END
           ELSE NULL END,
      _uid, _approved, _approver
    ) RETURNING id INTO _res_id;
    _res_ids := _res_ids || _res_id;
  END LOOP;

  IF _celkem IS NOT NULL THEN
    PERFORM set_config('app.rucni_cena', 'off', true);

    -- Kontrolní součet, ne důvěra ve výpočet: zadaná částka MUSÍ sedět na haléř
    -- se součtem toho, co se opravdu uložilo. Kdyby se rozešly, je to chyba
    -- rozpadu a rezervace nesmí vzniknout.
    IF (SELECT round(sum(r.amount), 2) FROM public.reservations r
         WHERE r.id = ANY(_res_ids)) <> round(_celkem, 2) THEN
      RAISE EXCEPTION 'Rozpad ceny na dráhy nesedí se zadanou částkou (%). Rezervace nevznikla.', _celkem;
    END IF;
  END IF;

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
-- Sebekontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _zdroj text;
BEGIN
  SELECT prosrc INTO _zdroj FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='create_booking';

  IF _zdroj NOT LIKE '%GROUP BY u.user_id%' THEN
    RAISE EXCEPTION 'Upozornění na přebití se neshrnuje podle příjemce.';
  END IF;
  IF _zdroj NOT LIKE '%count(DISTINCT COALESCE(rr.event_id, rr.id))%' THEN
    RAISE EXCEPTION 'Termíny se počítají po řádcích, dvoudráhový termín se nahlásí dvakrát.';
  END IF;

  -- Ochrana proti přepsání ze staré verze: tyhle věci v create_booking byly
  -- už dřív a nesmí zmizet (CLAUDE.md, pravidlo 7).
  IF _zdroj NOT LIKE '%app.trusted_booking%' THEN
    RAISE EXCEPTION 'Zmizel marker app.trusted_booking, přepsalo se to ze staré verze.';
  END IF;
  IF _zdroj NOT LIKE '%nelze přebít%' THEN
    RAISE EXCEPTION 'Zmizela kontrola priorit, přepsalo se to ze staré verze.';
  END IF;
  IF _zdroj NOT LIKE '%_halere%' THEN
    RAISE EXCEPTION 'Zmizelo rozdělení haléřů mezi dráhy, přepsalo se to ze staré verze.';
  END IF;

  RAISE NOTICE 'Přebití posílá jednu zprávu na člověka, ne na každý přebitý řádek.';
END $kontrola$;
