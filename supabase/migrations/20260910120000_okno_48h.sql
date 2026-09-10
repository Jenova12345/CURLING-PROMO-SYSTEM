-- ---------------------------------------------------------------------------
-- OKNO 48 HODIN PŘED AKCÍ
--
-- Míň než 48 h před začátkem akce smí s rezervací hýbat jen správce haly.
-- Neadminovi se v okně zavře ZALOŽENÍ, STORNO i ZMĚNA ČASU A DRAH (včetně
-- přetažení myší v kalendáři — to jde přes `move_booking`, takže guard tam
-- chytí i drag-and-drop).
--
-- Proč zrovna storno: na ledu se v tu chvíli už plánuje. Když klub zruší akci
-- na poslední chvíli, hala si čas nedoplní a přijde o peníze. Pravidlo proto
-- říká „akce zůstává a naúčtuje se v plné výši" — technicky to znamená, že
-- `cancel_booking` neadminovi HLASITĚ SPADNE a rezervace zůstane `confirmed`,
-- takže do fakturace vstoupí normálně. Žádné tiché zrušení bez naúčtování.
--
-- PŘESUN DO OKNA SE POČÍTÁ TAKY. `move_booking` blokuje, když je v okně
-- PŮVODNÍ NEBO NOVÝ termín. Kdyby se hlídal jen původní, dalo by se pravidlo
-- obejít přetažením: akce za pět dní se přetáhne na zítra a v okně tím vznikne
-- termín, který ledař nikdy neodsouhlasil. (Rozhodnutí PM, 10. 9. 2026.)
--
-- Jméno v hlášce je v `settings.ledar_jmeno`, výchozí „Jirka – Ledař".
-- Hláška se skládá v databázi, ne ve frontendu, aby zněla stejně na všech
-- cestách i při přímém volání RPC.
--
-- CO SEBEKONTROLA V TÉHLE MIGRACI NEMĚŘÍ: chování SÉRIÍ (sekce 4c). Hlídá ho
-- jen `supabase/tests/okno_48h_test.sql`, kapitola 2b, která na produkci
-- neběží. Je to vědomé: nejhorší následek špatné série je hlasitý pád nebo
-- špatný štítek u přeskočeného termínu — ne otevřené okno a ne ztracené peníze.
-- Závěrečné NOTICE si proto sérii nenárokuje. (Poznámka migrační brány.)
--
-- ROLLBACK (v tomhle pořadí):
--   1) obnovit ŠEST funkcí z jejich posledních definujících migrací — guard je
--      vložený v jejich tělech, není to nový trigger, takže se nic nedropuje:
--        `create_booking`      z `20260909180000_rucni_celkova_cena.sql`
--        `cancel_booking`      z `20260909180000_rucni_celkova_cena.sql`
--        `move_booking`        z `20260909180000_rucni_celkova_cena.sql`
--        `uprav_drahy_akce`    z `20260909180000_rucni_celkova_cena.sql`
--        `guard_reservation_rep_changes` z `20260813090000_faktury_zaklad.sql`
--        `create_booking_series`         z `20260817100000_serie_kolize.sql`
--      Ověřeno diffem 10. 9. 2026, ne odhadem: pozdější migrace se téhle
--      trigger funkce jen DOTÝKAJÍ v komentářích a sebekontrolách
--      (`20260817160000_storno_dobropis.sql`, `20260831233000_trener_prava.sql`,
--      `20260902280000_upozorneni_whitelist.sql`),
--      ale žádná ji nepředefinovává. Sáhnout na starší z pěti souborů, kde
--      `CREATE OR REPLACE` na tenhle název je, by vrátilo STARŠÍ tělo.
--      Signatury se nemění, takže `CREATE OR REPLACE` stačí a granty zůstanou.
--   2) pohled `settings_public` vrátit bez `ledar_jmeno` — a POZOR, `CREATE OR
--      REPLACE VIEW` to NEUMÍ: sloupec jde jen přidat na konec, ubrat ne
--      (`ERROR: cannot drop columns from view`, ověřeno 10. 9. 2026). Musí to být
--      DROP a nové založení, a `DROP VIEW` vezme s sebou i granty, takže se
--      musí udělat znovu:
--        DROP VIEW public.settings_public;
--        -- tělo z `20260831235000_cekajici_ucet_nevidi_nic.sql` (poslední
--        -- definice před touhle migrací; starší `20260812140000_cenik_jen_adminovi.sql`
--        -- má JINÉ tělo, bez brány čekajícího účtu — nebrat ho)
--        REVOKE ALL ON public.settings_public FROM anon, authenticated, public;
--        GRANT SELECT ON public.settings_public TO authenticated;
--        GRANT ALL    ON public.settings_public TO service_role;
--      Granty musí sedět na `{postgres=arwdDxtm, service_role=arwdDxtm,
--      authenticated=r}` — to je stav před migrací i po ní.
--   3) `DROP FUNCTION public.v_okne_48h(timestamptz);`
--      `DROP FUNCTION public.hlaska_okna_48h(text);`
--   4) `ALTER TABLE public.settings DROP COLUMN ledar_jmeno;`
--      (vezme s sebou i CHECK `settings_ledar_jmeno_neprazdne`)
--   Pořadí je důležité: sloupec až nakonec, jinak by funkce a view v kroku
--   1–2 sahaly na sloupec, který už neexistuje.
-- ---------------------------------------------------------------------------

-- ---- 1) Jméno ledaře v nastavení ------------------------------------------
ALTER TABLE public.settings
  ADD COLUMN IF NOT EXISTS ledar_jmeno text NOT NULL DEFAULT 'Jirka – Ledař';

ALTER TABLE public.settings DROP CONSTRAINT IF EXISTS settings_ledar_jmeno_neprazdne;
ALTER TABLE public.settings ADD CONSTRAINT settings_ledar_jmeno_neprazdne
  CHECK (btrim(ledar_jmeno) <> '' AND length(ledar_jmeno) <= 80);

COMMENT ON COLUMN public.settings.ledar_jmeno IS
  'Kdo v okně 48 h před akcí jediný smí zakládat, rušit a přesouvat. Jméno se objeví v hlášce.';

-- ---- 2) Pomocné funkce -----------------------------------------------------
-- Okno je „míň než 48 h do začátku". Už proběhlé termíny do něj spadají taky
-- (rozdíl je záporný) — na akci, která začala, taky nemá neadmin sahat.
CREATE OR REPLACE FUNCTION public.v_okne_48h(_start timestamptz)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT _start - now() < interval '48 hours';
$function$;

COMMENT ON FUNCTION public.v_okne_48h(timestamptz) IS
  'True, když do začátku zbývá míň než 48 h (nebo už začalo).';

-- Hláška se skládá tady, ať zní stejně ze všech čtyř cest i z přímého RPC.
--
-- SECURITY DEFINER schválně: `authenticated` nemá SELECT na `public.settings`,
-- takže bez toho by funkce volaná napřímo spadla na „permission denied for
-- table settings" místo aby vrátila hlášku. Uvnitř guardů se to neprojeví (ty
-- samy běží jako definer), ale grant pro `authenticated` by byl slib naprázdno.
-- Vydává se jen `ledar_jmeno`, které je stejně vidět v `settings_public`.
CREATE OR REPLACE FUNCTION public.hlaska_okna_48h(_co text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT format('V okně 48 h před akcí může rezervaci %s jen %s.', _co,
                COALESCE((SELECT s.ledar_jmeno FROM public.settings s LIMIT 1), 'Jirka – Ledař'));
$function$;

REVOKE ALL ON FUNCTION public.v_okne_48h(timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hlaska_okna_48h(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.v_okne_48h(timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hlaska_okna_48h(text) TO authenticated, service_role;

-- ---- 3) Jméno ledaře i do veřejného pohledu -------------------------------
-- Pohled běží s právy vlastníka (není `security_invoker`), takže si sloupec
-- přečte i účet, který na něj v tabulce SELECT nemá. Jméno není citlivé —
-- objevuje se v hlášce, kterou stejně uvidí každý, kdo na okno narazí.
CREATE OR REPLACE VIEW public.settings_public AS
SELECT id,
    singleton,
    opening_hours,
    email_notifications_enabled,
    updated_at,
    updated_by,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN club_default_rate
            ELSE NULL::numeric
        END AS club_default_rate,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN commercial_default_rate
            ELSE NULL::numeric
        END AS commercial_default_rate,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN training_rate
            ELSE NULL::numeric
        END AS training_rate,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN tournament_rate
            ELSE NULL::numeric
        END AS tournament_rate,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role), false) AS can_see_rates,
    s.ledar_jmeno
   FROM settings s
  WHERE ucet_aktivni() OR auth.uid() IS NULL AND (SESSION_USER = ANY (ARRAY['postgres'::name, 'supabase_admin'::name]));

-- ---- 4) Guardy okna ve čtyřech mutačních cestách ---------------------------
-- Těla jsou VYGENEROVANÁ z `pg_get_functiondef` a vložený je do nich jen
-- guard; ověřeno diffem, že z původní logiky neubyl ani řádek (pravidlo 7).
-- Signatury se nemění, takže `CREATE OR REPLACE` drží i granty.

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

  -- FAIL-CLOSED: JEDNU DRÁHU Z PEVNĚ OCENĚNÉ AKCE VYJMOUT NELZE.
  --
  -- `uprav_drahy_akce` je nad pevnou cenou zavřená právě proto, že ubrání
  -- dráhy TIŠE SNÍŽILO cenu ze 14 000 na 7 000. Přes storno jedné dráhy jde
  -- vyrobit týž výsledek — a narozdíl od té zavřené cesty bez jediné chyby.
  -- Smí to i zástupce klubu, protože `can_manage_reservation` mu na vlastní
  -- rezervaci storno povoluje; admin u toho být nemusí.
  --
  -- U paušálu je částka cenou za CELOU AKCI bez ohledu na počet drah, takže
  -- ubrání dráhy má cenu nechat být, nebo zrušit akci celou. Storno celé akce
  -- (`p_scope = 'event'`) proto zůstává otevřené — to cenu nepůlí, ruší ji.
  -- Jednodráhová akce sem nespadne: tam je `single` totéž co `event`.
  IF p_scope = 'single' AND _res.cena_rucni AND _res.event_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.reservations r
        WHERE r.event_id = _res.event_id
          AND r.id <> _res.id
          AND r.status = 'confirmed'
          AND r.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (jednu dráhu z ní vyjmout nelze).'
      USING HINT = 'Stornujte celou akci. Pevná cena platí za akci jako celek, ne za jednotlivou dráhu.';
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

  -- OKNO 48 H PŘED AKCÍ: rušit smí jen správce haly.
  --
  -- Kontroluje se AŽ NAD SEZNAMEM `_ids`, ne nad tou jednou kliknutou
  -- rezervací: u `p_scope` „event" i „series" se ruší víc řádků naráz a stačí,
  -- aby v okně byl jediný z nich. Kdyby se hlídala jen `_res`, dala by se
  -- akce v okně zrušit stornem celé série z termínu, který v okně není.
  --
  -- Blokuje se HLASITĚ a rezervace zůstává `confirmed`, takže do fakturace
  -- vstoupí normálně — to je celý smysl pravidla: „akce zůstává a naúčtuje se
  -- v plné výši". Tiché nezrušení by znamenalo neúčtovaný led.
  IF NOT public.has_role(auth.uid(), 'admin') AND EXISTS (
       SELECT 1 FROM public.reservations r
        WHERE r.id = ANY (_ids) AND public.v_okne_48h(r.start_at)
     ) THEN
    RAISE EXCEPTION '%', public.hlaska_okna_48h('zrušit')
      USING HINT = 'Akce zůstává a naúčtuje se v plné výši.';
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

  -- OKNO 48 H PŘED AKCÍ: přesouvat smí jen správce haly.
  --
  -- Tudy chodí i PŘETAŽENÍ MYŠÍ v kalendáři, takže guard zavírá i drag-and-drop.
  --
  -- Hlídá se PŮVODNÍ I NOVÝ termín. Jen původní by nestačil: akci za pět dní
  -- by šlo přetáhnout na zítra a v okně by vznikl termín, který ledař nikdy
  -- neodsouhlasil — přesně to, co má pravidlo zakázat.
  IF NOT public.has_role(auth.uid(), 'admin')
     AND (public.v_okne_48h(_res.start_at) OR public.v_okne_48h(p_start)) THEN
    RAISE EXCEPTION '%', public.hlaska_okna_48h('přesunout')
      USING HINT = 'Platí i pro přetažení v kalendáři a pro přesun akce do okna zvenku.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY — viz `uprav_sazbu_akce`.
  --
  -- Přesun ani prodloužení částku nezmění (o to u paušálu jde), ale mění
  -- odvozenou sazbu a délku, za kterou se ta částka účtuje. Zástupce klubu si
  -- takhle roztáhl akci z 2 na 13 hodin a zaplatil pořád 14 000 — jedenáct
  -- hodin ledu navíc zadarmo, bez schválení a bez upozornění.
  IF _res.cena_rucni THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (přesouvat ani prodlužovat ji nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Pevnou cenu akce nastavuje jen zakládání rezervace.';
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

CREATE OR REPLACE FUNCTION public.uprav_drahy_akce(_event_id uuid, _sheet_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _vzor     public.reservations%ROWTYPE;
  _pridano  int := 0;
  _ubrano   int := 0;
  _sheet    uuid;
BEGIN
  IF _sheet_ids IS NULL OR array_length(_sheet_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Akce musí mít aspoň jednu dráhu.';
  END IF;

  -- Vzorová rezervace: z ní se berou časy, subjekt i sazba pro nové dráhy.
  -- Nová dráha téže akce musí mít TOTOŽNÉ podmínky, jinak by z jedné akce
  -- vznikly dvě různě drahé půlky.
  SELECT * INTO _vzor
    FROM public.reservations
   WHERE event_id = _event_id AND deleted_at IS NULL
   ORDER BY created_at LIMIT 1;

  IF _vzor.id IS NULL THEN
    RAISE EXCEPTION 'Akce nemá žádnou živou rezervaci.';
  END IF;

  IF NOT public.can_manage_reservation(_vzor.id) THEN
    RAISE EXCEPTION 'Tuhle akci nemáte právo upravit.';
  END IF;

  -- OKNO 48 H PŘED AKCÍ: dráhy mění jen správce haly.
  -- Přidání i ubrání dráhy je zásah do obsazenosti ledu na poslední chvíli,
  -- takže platí totéž co pro čas.
  IF NOT public.has_role(auth.uid(), 'admin') AND public.v_okne_48h(_vzor.start_at) THEN
    RAISE EXCEPTION '%', public.hlaska_okna_48h('změnit')
      USING HINT = 'Dráhy u akce v okně 48 h mění jen správce haly.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY.
  --
  -- `set_reservation_pricing` u ruční ceny drží `amount` a sazbu si dopočítá
  -- zpátky z částky, takže tahle funkce dřív TIŠE NEUDĚLALA NIC a přitom
  -- vracela úspěch — admin dostal zelený toast a v datech se nezměnilo nic.
  -- Tichý no-op je u peněz horší než chyba, tak ať je z toho chyba.
  --
  -- Zakázáno je to i ADMINOVI, schválně: skutečný editor paušálu (RPC, která
  -- částku znovu rozdělí mezi dráhy a ohlídá kontrolní součet) je samostatný
  -- ticket. Dokud není, je jediná podporovaná cesta storno a založit znovu.
  IF EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.event_id = _event_id AND r.deleted_at IS NULL AND r.cena_rucni
  ) THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (dráhy u ní měnit nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Pevnou cenu akce nastavuje jen zakládání rezervace.';
  END IF;

  -- VYFAKTUROVANOU AKCI UŽ NEJDE PŘESKLÁDAT. Ubraná dráha by zmizela z rozvrhu,
  -- ale zůstala na odeslaném dokladu; přidaná by na dokladu chyběla.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Dráhy akce');

  PERFORM set_config('app.trusted_booking', 'on', true);

  -- UBRÁNÍ: soft delete (zásada 2), nikdy DELETE.
  UPDATE public.reservations
     SET deleted_at = now()
   WHERE event_id = _event_id
     AND deleted_at IS NULL
     AND NOT (sheet_id = ANY (_sheet_ids));
  GET DIAGNOSTICS _ubrano = ROW_COUNT;

  -- PŘIDÁNÍ: nová rezervace pod TOUTÉŽ akcí, se stejným časem, subjektem
  -- i sazbou. `rate_per_hour` se kopíruje ze vzoru schválně — jinak by ji
  -- trigger dopočítal z ceníku a nová dráha by mohla stát jinak než ta první.
  FOREACH _sheet IN ARRAY _sheet_ids LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.reservations
       WHERE event_id = _event_id AND sheet_id = _sheet AND deleted_at IS NULL
    ) THEN
      -- PÁSMOVÁ CENA SE NEKOPÍRUJE, DOPOČÍTÁ SE.
      --
      -- `_vzor.rate_per_hour` je u pásmové rezervace ODVOZENÝ PRŮMĚR, klidně
      -- s haléři (3 400 Kč / 3 h = 1 133,33). Zkopírovat ho do nové dráhy
      -- znamenalo jistý pád: `check_reservation_money` vyžaduje celé koruny
      -- a `reservations_rate_per_hour_cele_koruny` totéž. Přidat dráhu
      -- k dvoupásmové klubové rezervaci proto nešlo VŮBEC — a jednopásmová
      -- sice prošla, ale nová dráha tiše přišla o snapshot `cenove_pasma`.
      --
      -- S `NULL` ji ocení `set_reservation_pricing` z ceníku na TENTÝŽ čas,
      -- takže vyjde stejná částka i stejný rozpis. Že to opravdu vyšlo stejně,
      -- se ověřuje hned pod smyčkou — kdyby se mezitím změnil ceník, nesmí
      -- z jedné akce vzniknout dvě různě drahé půlky.
      INSERT INTO public.reservations
        (sheet_id, subject_id, event_id, start_at, end_at, status,
         rate_per_hour, note, approved_at, approved_by)
      VALUES
        (_sheet, _vzor.subject_id, _event_id, _vzor.start_at, _vzor.end_at, _vzor.status,
         CASE WHEN _vzor.cenove_pasma IS NULL THEN _vzor.rate_per_hour ELSE NULL END,
         _vzor.note, _vzor.approved_at, _vzor.approved_by);
      _pridano := _pridano + 1;
    END IF;
  END LOOP;

  PERFORM set_config('app.trusted_booking', 'off', true);

  IF NOT EXISTS (SELECT 1 FROM public.reservations
                  WHERE event_id = _event_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Akce by zůstala bez dráhy — na zrušení celé akce je storno.';
  END IF;

  -- JEDNA AKCE, JEDNA CENA. U pásmové rezervace se nová dráha oceňuje
  -- z ceníku, ne kopií — a kdyby se ceník mezi založením akce a přidáním
  -- dráhy změnil, vyšla by jiná částka. Radši to nedopustit než mít akci,
  -- kde stojí Dráha 1 jinak než Dráha 2.
  IF _pridano > 0
     AND (SELECT count(DISTINCT COALESCE(corrected_amount, amount))
            FROM public.reservations
           WHERE event_id = _event_id AND deleted_at IS NULL) > 1 THEN
    RAISE EXCEPTION 'Přidaná dráha by stála jinak než ty stávající — ceník se od založení akce změnil.'
      USING HINT = 'Založ akci znovu, nebo nejdřív srovnej cenu (Cena akce).';
  END IF;

  RETURN jsonb_build_object(
    'pridano', _pridano,
    'ubrano',  _ubrano,
    'drah',    (SELECT count(*) FROM public.reservations
                 WHERE event_id = _event_id AND deleted_at IS NULL),
    'celkem',  (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                  FROM public.reservations
                 WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Na té dráze už v tom čase něco je.'
      USING HINT = 'Vyberte jinou dráhu nebo nejdřív zrušte kolidující rezervaci.';
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Dráhy se nepodařilo upravit — zadané údaje neprošly kontrolou databáze.';
END;
$function$;


-- ---- 4b) Přímý zápis do rezervací ------------------------------------------
-- Guardy v RPC výš zavírají cestu, kterou chodí aplikace. Nejsou ale jediné
-- dveře: `authenticated` má na `public.reservations` tabulkové INSERT/UPDATE
-- granty a RLS je členovi i zástupci klubu povoluje, takže se dá zakládat
-- a rušit i úplně mimo `create_booking`/`cancel_booking`. Jediné místo, kterým
-- KAŽDÝ takový zápis projde, je tenhle trigger — proto sem patří i pravidlo
-- okna, ne do pátého RPC.
--
-- Tělo je vygenerované z `pg_get_functiondef` živého schématu (pravidlo 7
-- v CLAUDE.md); vloženy jsou jen dva bloky označené „OKNO 48 H PŘED AKCÍ".
-- Čas a dráhu přímý zápis měnit nemůže už dnes („Čas a dráhu měňte přesunem
-- rezervace"), takže na tu část zadání tu žádný nový blok není potřeba.
CREATE OR REPLACE FUNCTION public.guard_reservation_rep_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- Co smí ne-admin přímým zápisem vůbec změnit. Whitelist schválně: při blacklistu
  -- by každý nově přidaný sloupec byl automaticky povolený (a přesně tak se sem
  -- třikrát po sobě vloudilo falšování auditu).
  _allowed CONSTANT text[] := ARRAY[
    'note', 'status',
    'approved_at', 'approved_by',
    'cancelled_at', 'cancelled_by', 'cancel_reason',
    'updated_at', 'updated_by'          -- doplňuje pozdější trigger, klientská hodnota se přepíše
  ];
  _changed text[];
  _forbidden text;
BEGIN
  -- Migrace, seed a servisní zásahy pod databázovou rolí. `session_user` schválně:
  -- uvnitř SECURITY DEFINER je current_user vždy vlastník funkce, takže by tahle
  -- podmínka nerozlišila vůbec nic. PostgREST se připojuje jako `authenticator`,
  -- takže nepřihlášený klient sem nespadne.
  -- Serverové skripty pod service_role ať používají RPC funkce, ne přímý zápis.
  IF auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- Servisní klíč (service_role) se sem dostane bez přihlášeného uživatele přes
  -- PostgREST. Zápis mu nepovolíme — obešel by kontrolu kolizí i schvalování —
  -- ale ať hláška rovnou řekne kudy, jinak to vypadá jako chyba oprávnění uživatele.
  IF auth.uid() IS NULL AND session_user = 'authenticator' THEN
    RAISE EXCEPTION 'Servisní zápis do rezervací jde jen přes RPC (create_booking, move_booking, cancel_booking, …)';
  END IF;

  -- Zápis z důvěryhodných RPC funkcí (public.create_booking a spol.), které samy ověřují
  -- práva, kolize a priority. GUC je transakčně lokální; přes PostgREST ho klient nenastaví
  -- a RPC funkce ho po svých zápisech samy vypínají, aby zvýšené oprávnění neplatilo
  -- pro zbytek transakce.
  IF current_setting('app.trusted_booking', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- ZÁMEK FAKTURACE stojí NAD adminskou výjimkou (doplněno v B1+B2).
  -- Admin má u rezervací jinak volnou ruku a je to správně. Tohle je ale účetní
  -- vazba: odpojit rezervaci od vystavené (a tím neměnné) faktury znamená, že se
  -- naúčtuje podruhé. Uvolnit ji smí jen storno nebo dobropis, tedy RPC — a ty si
  -- nastaví `app.trusted_booking`, takže sem vůbec nedojdou.
  IF TG_OP = 'UPDATE'
     AND (NEW.invoice_id IS DISTINCT FROM OLD.invoice_id
          OR NEW.invoiced_at IS DISTINCT FROM OLD.invoiced_at) THEN
    RAISE EXCEPTION 'Vazbu rezervace na fakturu mění jen fakturační funkce, ne přímý zápis.'
      USING HINT = 'Odpojit rezervaci od vystaveného dokladu lze jen stornem nebo dobropisem.';
  END IF;

  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- OKNO 48 H PŘED AKCÍ — ZALOŽENÍ.
    --
    -- Stojí ZÁMĚRNĚ tady, ne (jen) v `create_booking`. `reservations` má pro
    -- `authenticated` tabulkové INSERT granty a RLS je členovi i zástupci klubu
    -- povoluje, takže rezervace jde založit i úplně mimo RPC — POST /reservations
    -- z prohlížeče. Guard jen v RPC by hlídal jedny ze dvou dveří.
    -- Nad tímhle místem už proběhly výjimky pro `postgres`, `app.trusted_booking`
    -- (tedy naše vlastní RPC) i pro admina, takže sem dojde jen neadminský
    -- přímý zápis.
    IF public.v_okne_48h(NEW.start_at) THEN
      RAISE EXCEPTION '%', public.hlaska_okna_48h('vytvořit')
        USING HINT = 'Vyberte termín aspoň 48 h dopředu, nebo se domluvte se správcem haly.';
    END IF;

    -- Zástupce i člen zakládají jen čistě klubovou rezervaci. Od klienta se přebírá
    -- pouze dráha, subjekt, čas a poznámka — všechno ostatní se tady přepisuje.
    -- (Kdo sem bude přidávat sloupec, musí ho v tomhle výčtu ošetřit; úpravy hlídá
    -- whitelist v UPDATE větvi níž.)
    NEW.created_at        := now();   -- rezervaci nelze zpětně datovat
    NEW.updated_at        := now();
    NEW.created_by        := auth.uid();
    NEW.status            := 'confirmed';
    NEW.deleted_at        := NULL;
    NEW.event_id          := NULL;
    NEW.rate_per_hour     := NULL;   -- sazbu dopočítá pricing z ceníku
    NEW.corrected_hours   := NULL;
    NEW.corrected_amount  := NULL;
    NEW.correction_reason := NULL;
    NEW.cancelled_at      := NULL;
    NEW.cancelled_by      := NULL;
    NEW.cancel_reason     := NULL;
    NEW.series_id         := NULL;   -- sérii zakládá jen create_booking_series (hlídá si subjekt)
    -- ← doplněno v B1+B2. Bez toho si ne-admin nastavil fakturační zámek sám
    --   a jeho rezervace navždy vypadla z fakturačního běhu.
    NEW.invoice_id        := NULL;
    NEW.invoiced_at       := NULL;
    -- Zástupce klubu rezervuje rovnou platně, člen čeká na potvrzení zástupcem.
    IF public.is_subject_rep(NEW.subject_id) THEN
      NEW.approved_at := now();
      NEW.approved_by := auth.uid();
    ELSE
      NEW.approved_at := NULL;
      NEW.approved_by := NULL;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: přístup k řádku hlídá RLS (rep = celý klub, člen = jen created_by = self).
  IF NOT public.is_subject_member(OLD.subject_id) THEN
    RAISE EXCEPTION 'Nemáte právo měnit tuto rezervaci';
  END IF;

  -- Které sloupce se vlastně mění
  SELECT array_agg(n.key) INTO _changed
    FROM jsonb_each(to_jsonb(NEW)) n
    JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
   WHERE n.value IS DISTINCT FROM o.value;
  _changed := COALESCE(_changed, '{}');

  -- Čas a dráha jdou měnit VÝHRADNĚ přes public.move_booking. Přímý zápis by minul
  -- kontrolu kolizí, pravidlo „akce na dvou drahách se posouvá celá" i srovnání času
  -- navázané akce — a směny brigádníků by pak ukazovaly na jiný den.
  IF _changed && ARRAY['sheet_id', 'start_at', 'end_at'] THEN
    RAISE EXCEPTION 'Čas a dráhu měňte přesunem rezervace, ne přímým zápisem';
  END IF;

  -- OKNO 48 H PŘED AKCÍ — STORNO.
  --
  -- `status` a `cancelled_*` JSOU ve whitelistu výš, a to schválně: mimo okno
  -- si klub svoje rezervace ruší sám. V okně ale platí „akce zůstává a naúčtuje
  -- se v plné výši", a `cancel_booking` na to nestačí — rezervace jde stornovat
  -- i přímým zápisem, PATCH /reservations {"status":"cancelled"}, RPC úplně
  -- mimo. Naměřeno bezpečnostní bránou 10. 9. 2026: neadmin takhle sundal
  -- akci za 2 000 Kč z `fakturovatelne_rezervace` na nulu, zatímco `cancel_booking`
  -- mu to na téže rezervaci správně odmítlo.
  --
  -- Rozhoduje PŮVODNÍ začátek (`OLD.start_at`) — čas se stejně o pár řádků výš
  -- měnit nedá, a kdyby se hlídal jen nový, stačilo by ho v témž UPDATE odsunout.
  IF _changed && ARRAY['status', 'cancelled_at', 'cancelled_by', 'cancel_reason']
     AND public.v_okne_48h(OLD.start_at) THEN
    RAISE EXCEPTION '%', public.hlaska_okna_48h('zrušit')
      USING HINT = 'Akce zůstává a naúčtuje se v plné výši.';
  END IF;

  -- Cokoli mimo whitelist (sazba, subjekt, autor, korekce, vazby, soft-delete…)
  SELECT c INTO _forbidden FROM unnest(_changed) c WHERE c <> ALL (_allowed) LIMIT 1;
  IF _forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'Pole „%" smí měnit jen správce', _forbidden;
  END IF;

  -- --- potvrzení rezervace ---------------------------------------------------
  IF (_changed && ARRAY['approved_at', 'approved_by'])
     AND NOT public.is_subject_rep(OLD.subject_id) THEN
    RAISE EXCEPTION 'Rezervaci může potvrdit jen zástupce klubu';
  END IF;
  IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
     AND NEW.approved_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Autora potvrzení nelze podvrhnout';   -- ani jménem někoho jiného
  END IF;
  IF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    IF NEW.approved_at IS NULL THEN
      RAISE EXCEPTION 'Potvrzení může odebrat jen správce';  -- vynulováním by zmizela stopa
    END IF;
    NEW.approved_at := now();                                -- a nelze ho zpětně datovat
  END IF;

  -- --- storno ----------------------------------------------------------------
  IF NEW.cancelled_by IS DISTINCT FROM OLD.cancelled_by
     AND NEW.cancelled_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Autora storna nelze podvrhnout';
  END IF;
  IF NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at THEN
    IF NEW.cancelled_at IS NULL THEN
      RAISE EXCEPTION 'Razítko storna nelze smazat';
    END IF;
    NEW.cancelled_at := now();
  END IF;
  -- Důvod storna patří tomu, kdo rušil — jinak by si klub přepsal „přebito komerční akcí"
  -- na vlastní verzi příběhu.
  IF NEW.cancel_reason IS DISTINCT FROM OLD.cancel_reason
     AND OLD.cancelled_by IS NOT NULL
     AND OLD.cancelled_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Důvod storna smí měnit jen ten, kdo rezervaci zrušil';
  END IF;
  -- Storno je jednosměrné: „od-stornovat" (a nechat u toho staré razítko, kdo rušil)
  -- smí jen správce. Ne-admin ať založí novou rezervaci.
  IF OLD.status = 'cancelled' AND NEW.status = 'confirmed' THEN
    RAISE EXCEPTION 'Stornovanou rezervaci může obnovit jen správce — založte novou.';
  END IF;

  RETURN NEW;
END;
$function$;


-- ---- 4c) Série přeskočí termíny v okně, místo aby spadla celá ---------------
-- `create_booking_series` schválně pouští ven každou chybu, která NENÍ vázaná
-- na jeden termín — chybějící právo nebo nevyplněný ceník platí pro všechny
-- termíny a nemá smysl hlásit dvacetkrát „přeskočeno". Guard okna ale takový
-- důvod JE: v okně je první termín, ne série. Dostává proto vlastní SQLSTATE
-- U0003 (vedle U0001 „obsazeno" a U0002 „mimo otevírací dobu") a série ho
-- přeskočí s vlastním důvodem `okno_48h`, ať uživateli nikdo netvrdí, že má
-- zavřenou halu.
--
-- Tělo je vygenerované z `pg_get_functiondef` (pravidlo 7 v CLAUDE.md);
-- vložený je jen kód do výčtu a větev v `_duvod`.
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
  -- Konec před začátkem je CHYBA ZADÁNÍ a musí spadnout hned. Kdyby se to
  -- nechalo na cyklus, sebral by to jako každý jiný termín přeskočený níž a
  -- uživatel by dostal „posouvají se hodiny na letní čas" u všech dvaceti
  -- termínů — vysvětlení, které s jeho překlepem nemá nic společného.
  IF _end_loc <= _start_loc THEN
    RAISE EXCEPTION 'Konec rezervace musí být po jejím začátku.';
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
    --
    -- Že jde OPRAVDU o letní čas a ne o obrácené zadání, hlídá kontrola
    -- `_end_loc <= _start_loc` nahoře: bez ní by sem spadl každý překlep.
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
      WHEN SQLSTATE 'U0001' OR SQLSTATE 'U0002' OR SQLSTATE 'U0003' OR exclusion_violation THEN
        -- Guard zůstává i u vlastních kódů: `exclusion_violation` je konkrétní,
        -- ale kdyby sem někdo přidal další podmínku, ať se cizí chyba nepřevleče
        -- za kolizi v daný den. To je přesně to tiché selhání, kvůli kterému
        -- tahle migrace vznikla.
        IF SQLSTATE NOT IN ('U0002', 'U0001', 'U0003', '23P01') THEN
          RAISE;
        END IF;
        -- U0003 = OKNO 48 H PŘED AKCÍ (`20260910120000_okno_48h.sql`).
        --
        -- Je to důvod vázaný na JEDEN termín, ne na zadání: „začíná to zítra"
        -- platí o prvním termínu, ne o těch dvaceti pěti za měsíc. Bez tohohle
        -- vystřelil guard obyčejný P0001, ten prošel skrz a shodil CELOU sérii —
        -- zástupci klubu se kvůli jednomu termínu nezaložil ani jeden z ostatních.
        -- (Rozhodnutí zákazníka, 10. 9. 2026.)
        _duvod := CASE SQLSTATE
                    WHEN 'U0002' THEN 'mimo_otviraci_dobu'
                    WHEN 'U0003' THEN 'okno_48h'
                    ELSE 'kolize'
                  END;
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


-- ---- 5) Vlastní kontrola ---------------------------------------------------
-- Měří CHOVÁNÍ na skutečném zápisu, ne tvar objektů. Na prázdné databázi
-- (lokální `db reset` — dráhy a klub zakládá až seed, tedy AŽ PO migracích)
-- se kontrola chování přeskočí a hláška to řekne, ať se netváří, že měřila.
--
-- TAHLE KONTROLA BĚŽÍ UVNITŘ ZÁMKU. Než sem přidáš další nohu, přečti si to.
--
-- Supabase CLI neposílá `BEGIN`, ale celý migrační soubor pošle jako JEDNU
-- dávku a potvrdí ji až na konci (rozšířený protokol, jediný `Sync` až za
-- zápisem do `schema_migrations`). Soubor je tím pádem implicitní transakce —
-- což je dobře, protože pád kdekoli uvnitř vrátí úplně všechno a produkce
-- nezůstane půl migrovaná. Změřeno 10. 9. 2026 na lokále: úmyslný pád za
-- `ALTER TABLE` nenechal ani sloupec, ani řádek v historii migrací.
-- POZOR NA ROZSAH TOHO MĚŘENÍ: proběhlo na `supabase migration up`, ne na
-- `db push`. Oba zapisují do téže historie, což na společný aplikátor ukazuje,
-- ale `db push` proti živé databázi změřený není a tvrdit se to nedá.
--
-- Má to ale druhou stranu. V téže transakci leží:
--     ACCESS EXCLUSIVE na `settings`         (z `ADD COLUMN` v kapitole 1)
--     ACCESS EXCLUSIVE na `settings_public`  (z `CREATE OR REPLACE VIEW`, kap. 3)
-- a oba se drží AŽ DO KONCE SOUBORU, ne do konce svého příkazu. Po celou dobu
-- migrace tedy čeká všechno, co čte nastavení — včetně kalendáře, který si
-- ze `settings_public` bere otevírací dobu.
--
-- Doba běhu téhle kontroly proto neleží jen na délce migrace, ale NA KRITICKÉ
-- CESTĚ TOHO ZÁMKU. Dnes je to lokálně ~0,1 s a je to neškodné; každá další
-- noha (a jsou to skutečné zápisy přes `create_booking`) to prodlužuje.
-- Dřívější protokol uváděl „zámek držel 3,9 ms" — to byla délka samotného
-- `ALTER TABLE` a je to o dva řády optimističtější než skutečnost.
--
-- Z téže atomicity plyne ještě jedna podmínka na celý soubor: nesmí obsahovat
-- nic, co uvnitř transakce běžet nejde. Změřeno na téhle PG 17, ne odhadnuto:
--     NELZE   VACUUM · REINDEX DATABASE · CREATE INDEX CONCURRENTLY · ALTER SYSTEM
--     PROJDE  ALTER TYPE … ADD VALUE — uvnitř transakce se provést SMÍ (od PG 12);
--             omezení je jinde: novou hodnotu nesmíš použít v TÉŽE transakci,
--             tedy ani nikde dál v tomhle souboru.
-- Dnes tu není nic z obojího. (Doplněno po měření s migrační bránou, 10. 9. 2026;
-- dřívější znění řadilo `ADD VALUE` mezi zakázané, což NEPLATÍ.)
DO $kontrola$
DECLARE
  _sheet1 uuid; _subj uuid; _admin uuid; _neadmin uuid;
  _v jsonb; _ids uuid[]; _jmeno text; _hlaska text;
  _zitra timestamptz; _pozdeji timestamptz; _h int; _chyba text; _nedomereno text;
BEGIN
  -- (a) tvar: sloupec, výchozí hodnota, funkce, pohled
  --
  -- NEPOROVNÁVAT AKTUÁLNÍ HODNOTU S TOVÁRNÍ. `ledar_jmeno` je editovatelné pole
  -- v Nastavení — celý smysl toho sloupce je, že si hala ledaře přejmenuje.
  -- Kontrola na rovnost s „Jirka – Ledař" by po prvním přejmenování shodila
  -- KAŽDÉ další přehrání migrace (oprava, replay, obnova ze zálohy s doběhem
  -- migrací), a to bez jediné chyby v migraci samotné.
  -- Testuje se proto to, co má kontrola opravdu tvrdit:
  --   • hodnota existuje a není prázdná,
  --   • VÝCHOZÍ hodnota SLOUPCE je „Jirka – Ledař" (to je požadavek zadání
  --     a přejmenováním se nemění),
  --   • hláška se řídí tím, co v nastavení opravdu je.
  SELECT s.ledar_jmeno INTO _jmeno FROM public.settings s LIMIT 1;
  IF _jmeno IS NULL OR btrim(_jmeno) = '' THEN
    RAISE EXCEPTION 'Jméno ledaře v nastavení chybí nebo je prázdné (%).', COALESCE(_jmeno, 'NULL');
  END IF;

  IF (SELECT pg_get_expr(d.adbin, d.adrelid)
        FROM pg_attrdef d
        JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       WHERE d.adrelid = 'public.settings'::regclass
         AND a.attname = 'ledar_jmeno') NOT LIKE '%Jirka – Ledař%' THEN
    RAISE EXCEPTION 'Výchozí hodnota sloupce ledar_jmeno není „Jirka – Ledař".';
  END IF;

  _hlaska := public.hlaska_okna_48h('vytvořit');
  IF _hlaska <> format('V okně 48 h před akcí může rezervaci vytvořit jen %s.', _jmeno) THEN
    RAISE EXCEPTION 'Hláška okna zní „%", čekal jsem tvar se jménem „%".', _hlaska, _jmeno;
  END IF;

  IF NOT public.v_okne_48h(now() + interval '47 hours') THEN
    RAISE EXCEPTION '47 h dopředu MÁ být v okně.';
  END IF;
  IF public.v_okne_48h(now() + interval '49 hours') THEN
    RAISE EXCEPTION '49 h dopředu NEMÁ být v okně.';
  END IF;
  IF NOT public.v_okne_48h(now() - interval '1 hour') THEN
    RAISE EXCEPTION 'Už začatá akce MÁ být v okně.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='settings_public'
                    AND column_name='ledar_jmeno') THEN
    RAISE EXCEPTION 'Pohled settings_public jméno ledaře nevydává.';
  END IF;

  -- `hlaska_okna_48h` čte `settings`, na které `authenticated` SELECT nemá.
  -- Bez definera by grant pro `authenticated` byl slib naprázdno — funkce by
  -- z API spadla na „permission denied for table settings".
  IF NOT (SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname='public' AND p.proname='hlaska_okna_48h') THEN
    RAISE EXCEPTION 'hlaska_okna_48h musí být SECURITY DEFINER, jinak ji authenticated nezavolá.';
  END IF;

  -- (b) chování: neadmin v okně nesmí založit, admin smí
  SELECT id INTO _sheet1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _subj FROM public.subjects
   WHERE type = 'club' AND deleted_at IS NULL ORDER BY created_at LIMIT 1;
  SELECT ur.user_id INTO _admin FROM public.user_roles ur WHERE ur.role = 'admin' LIMIT 1;
  SELECT sr.user_id INTO _neadmin
    FROM public.subject_reps sr
   WHERE sr.subject_id = _subj
     AND NOT EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = sr.user_id AND ur.role = 'admin')
   LIMIT 1;

  IF _sheet1 IS NULL OR _subj IS NULL OR _admin IS NULL OR _neadmin IS NULL THEN
    RAISE NOTICE 'Okno 48 h: tvar OK, chování NEPROMĚŘENO — chybí dráhy, klub, admin nebo neadmin.';
    RETURN;
  END IF;

  -- TERMÍNY SE NESMÍ VOLIT NASLEPO.
  --
  -- Dřív tu bylo `now() + interval '25 hours'`, což je libovolná hodina dne:
  -- při běhu ve 23:30 vyjde půlnoc, tedy MIMO otevírací dobu, a `create_booking`
  -- skončí chybou U0002. Na ostré produkci k tomu přibývá obsazený led
  -- (kolize U0001). Obojí by shodilo celý `db push` — kvůli sebekontrole, ne
  -- kvůli chybě v migraci.
  --
  -- Bere se proto pevná hodina uvnitř otevírací doby, a to taková, kde na
  -- vybrané dráze nic nestojí. Zítřek je vždycky míň než 48 h (nejhorší případ
  -- 46 h — zítra ve 22:00 při běhu o půlnoci), za sedm dní je vždycky mimo okno.
  --
  -- HORNÍ MEZ JE `close - 4`, NE `close - 1`. Nohy sahají od `_h` po `_h+4`
  -- (poslední je „admin v okně"), takže s mezí `close - 1` mohlo při 7–22 vyjít
  -- `_h = 21` a nohy by přetekly přes zavíračku i přes půlnoc. Změřeno, co se
  -- pak doopravdy stane: kontrola se ZASTAVÍ na noze 23:00–24:00 hláškou
  -- „Rezervace nesmí přesáhnout půlnoc" a celá skončí jako
  --     chování NEDOMĚŘENO — Rezervace nesmí přesáhnout půlnoc…
  -- Není to tedy tichá zeleň, ale zbytečné nedoměření: kontrola je k ničemu
  -- a důvod je matoucí (mluví o půlnoci, ne o obsazeném ledu).
  --
  -- Dřívější znění téhle poznámky tvrdilo, že by noha „admin v okně projde"
  -- tiše měřila „admin mimo okno projde" a byla zelená za všech okolností.
  -- To NEPLATÍ — k té noze se při `_h = 21` vůbec nedojde, protože předchozí
  -- spadne na půlnoci. (Opraveno po měření, nález migrační brány.)
  --
  -- A ani to „přesně 48 h" není samostatné riziko: aby noha z okna vypadla
  -- (`_h >= 21`) a zároveň se všechny vešly do otevírací doby (`_h + 4 <= close`),
  -- musela by hala zavírat v 25:00. Do typu `time` se to nevejde, takže ta
  -- situace NENÍ DOSAŽITELNÁ — dopočítáno pro všechny zavíračky 20:00–24:00.
  -- Pojistka o kus níž tu proto není proti dnešku, ale proti budoucí změně
  -- offsetů noh nebo otevírací doby.
  --
  -- DVAKRÁT ZA ROK TO SEDNE VEDLE, A JE TO V POŘÁDKU. Hodiny se přičítají
  -- k `timestamptz`, tedy ABSOLUTNĚ, kdežto otevírací doba je lokální. V den
  -- přechodu na letní čas vyjde `_zitra + 7 h` na lokální 08:00, na podzim
  -- naopak na 06:00 (změřeno na 28. 3. a 31. 10. 2027). Rozsah použitelných
  -- hodin je tím pádem ten jeden den o hodinu užší a kontrola má o chlup vyšší
  -- šanci skončit na NEDOMĚŘENO. Vadit to nemůže: měření se tím jen vzdá, guard
  -- se nedotkne, a vzdálenost do začátku se v absolutních hodinách nemění, takže
  -- okenní matematika je nedotčená. Důkaz o nedosažitelnosti výš to dokonce
  -- utahuje — v den přechodu je podmínka `_h + 5 <= close`, tedy `_h <= 19`,
  -- ještě dál od potřebné 21. (Doplněno migrační bránou.)
  -- S `close - 4` vyjde nejpozdější `_h = 18`, poslední měřená noha na 21:00,
  -- tedy 45 h do začátku i při běhu o půlnoci, a všechny nohy se vejdou do
  -- otevírací doby. (Nález brány code review, upřesněný migrační bránou.)
  _zitra   := (date_trunc('day', now() AT TIME ZONE 'Europe/Prague') + interval '1 day')
              AT TIME ZONE 'Europe/Prague';
  _pozdeji := (date_trunc('day', now() AT TIME ZONE 'Europe/Prague') + interval '7 days')
              AT TIME ZONE 'Europe/Prague';

  SELECT h INTO _h
    FROM generate_series(
           extract(hour FROM (SELECT (s.opening_hours -> extract(isodow FROM _zitra AT TIME ZONE 'Europe/Prague')::int::text ->> 'open')::time
                                FROM public.settings s LIMIT 1))::int,
           extract(hour FROM (SELECT (s.opening_hours -> extract(isodow FROM _zitra AT TIME ZONE 'Europe/Prague')::int::text ->> 'close')::time
                                FROM public.settings s LIMIT 1))::int - 4) h
   WHERE NOT EXISTS (
           SELECT 1 FROM public.reservations r
            WHERE r.sheet_id = _sheet1 AND r.status = 'confirmed' AND r.deleted_at IS NULL
              AND tstzrange(r.start_at, r.end_at, '[)') && tstzrange(
                    _zitra + (h || ' hours')::interval,
                    _zitra + ((h + 4) || ' hours')::interval, '[)'))
     AND NOT EXISTS (
           SELECT 1 FROM public.reservations r
            WHERE r.sheet_id = _sheet1 AND r.status = 'confirmed' AND r.deleted_at IS NULL
              AND tstzrange(r.start_at, r.end_at, '[)') && tstzrange(
                    _pozdeji + (h || ' hours')::interval,
                    _pozdeji + ((h + 1) || ' hours')::interval, '[)'))
   ORDER BY h LIMIT 1;

  IF _h IS NULL THEN
    RAISE NOTICE 'Okno 48 h: tvar OK, chování NEPROMĚŘENO — na dráze není volné čtyřhodinové okno v otevírací době.';
    RETURN;
  END IF;

  -- PŘEDPOKLAD SI OVĚŘUJE SÁM.
  --
  -- `close - 4` platí pro dnešní otevírací dobu. Jiná doba v `settings`,
  -- posunutá noha nebo změněný strop by mohly termíny vytlačit na špatnou
  -- stranu okna — a kontrola by pak tiše měřila něco jiného, než tvrdí.
  -- Stačí dvě krajní: nejpozdější noha, která má být UVNITŘ okna (`_h+3`;
  -- dřívější mají do začátku míň času, takže když projde ona, projdou všechny),
  -- a ta jediná, která má být VENKU. Když se rozejdou, přizná se to jako
  -- NEDOMĚŘENO — ne jako zelená.
  IF NOT public.v_okne_48h(_zitra + ((_h + 3) || ' hours')::interval)
     OR public.v_okne_48h(_pozdeji + (_h || ' hours')::interval) THEN
    RAISE NOTICE 'Okno 48 h: tvar OK, chování NEDOMĚŘENO — měřicí termíny nevyšly na správné strany okna (_h = %).', _h;
    RETURN;
  END IF;

  BEGIN
    -- NEADMIN V OKNĚ: založení musí spadnout
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _neadmin, 'role', 'authenticated')::text, true);
    -- OVĚŘUJE SE TEXT HLÁŠKY, NE „něco spadlo".
    -- Kdyby stačil libovolný pád, kontrola by zezelenala i tehdy, když
    -- `create_booking` skončí na obsazené dráze nebo na nevyplněném ceníku —
    -- a o okně by neřekla vůbec nic. `_chyba` proto musí nést naši hlášku.
    _chyba := NULL;
    BEGIN
      PERFORM public.create_booking(
        ARRAY[_sheet1], 'training', '__okno48_neadmin__',
        _zitra + (_h || ' hours')::interval,
        _zitra + ((_h + 1) || ' hours')::interval,
        _subj, NULL, '{}'::jsonb, NULL, false, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN _chyba := SQLERRM;
    END;
    IF _chyba IS NULL THEN
      RAISE EXCEPTION 'Neadmin založil rezervaci v okně 48 h — mělo to spadnout.'
        USING ERRCODE = 'ZO002';
    END IF;
    IF position('V okně 48 h' in _chyba) = 0 THEN
      RAISE EXCEPTION 'nedomereno: založení v okně spadlo z jiného důvodu (%)', _chyba
        USING ERRCODE = 'ZO003';
    END IF;

    -- NEADMIN MIMO OKNO: založení musí projít
    _v := public.create_booking(
      ARRAY[_sheet1], 'training', '__okno48_mimo__',
      _pozdeji + (_h || ' hours')::interval,
      _pozdeji + ((_h + 1) || ' hours')::interval,
      _subj, NULL, '{}'::jsonb, NULL, false, NULL, NULL);
    SELECT array_agg((x)::uuid) INTO _ids FROM jsonb_array_elements_text(_v->'reservation_ids') x;

    -- a tutéž rezervaci nesmí přetáhnout DO okna
    _chyba := NULL;
    BEGIN
      PERFORM public.move_booking(_ids[1],
        _zitra + (_h || ' hours')::interval,
        _zitra + ((_h + 1) || ' hours')::interval, NULL);
    EXCEPTION WHEN OTHERS THEN _chyba := SQLERRM;
    END;
    IF _chyba IS NULL THEN
      RAISE EXCEPTION 'Neadmin přetáhl akci zvenku DO okna 48 h — mělo to spadnout.'
        USING ERRCODE = 'ZO002';
    END IF;
    IF position('V okně 48 h' in _chyba) = 0 THEN
      RAISE EXCEPTION 'nedomereno: přetažení do okna spadlo z jiného důvodu (%)', _chyba
        USING ERRCODE = 'ZO003';
    END IF;

    -- NEADMIN V OKNĚ PŘÍMÝM ZÁPISEM: obojí musí spadnout na triggeru.
    -- Tohle je ta druhá cesta do rezervací — kdyby guard žil jen v RPC,
    -- prošel by tudy POST i PATCH z prohlížeče úplně mimo `create_booking`
    -- a `cancel_booking` (a jednou už tudy prošel: 2 000 Kč zmizelo
    -- z fakturace, nález bezpečnostní brány 10. 9. 2026).
    _chyba := NULL;
    BEGIN
      INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at)
      VALUES (_sheet1, _subj,
              _zitra + ((_h + 1) || ' hours')::interval,
              _zitra + ((_h + 2) || ' hours')::interval);
    EXCEPTION WHEN OTHERS THEN _chyba := SQLERRM;
    END;
    IF _chyba IS NULL THEN
      RAISE EXCEPTION 'Neadmin založil rezervaci v okně 48 h PŘÍMÝM ZÁPISEM — mělo to spadnout.'
        USING ERRCODE = 'ZO002';
    END IF;
    IF position('V okně 48 h' in _chyba) = 0 THEN
      RAISE EXCEPTION 'nedomereno: přímý INSERT v okně spadl z jiného důvodu (%)', _chyba
        USING ERRCODE = 'ZO003';
    END IF;

    -- k tomu potřebujeme rezervaci, která v okně UŽ JE — založí ji admin
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
    _v := public.create_booking(
      ARRAY[_sheet1], 'training', '__okno48_ke_stornu__',
      _zitra + ((_h + 2) || ' hours')::interval,
      _zitra + ((_h + 3) || ' hours')::interval,
      _subj, NULL, '{}'::jsonb, NULL, false, NULL, NULL);
    SELECT array_agg((x)::uuid) INTO _ids FROM jsonb_array_elements_text(_v->'reservation_ids') x;

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _neadmin, 'role', 'authenticated')::text, true);
    -- STORNO A DRÁHY PŘES RPC. Bez těchhle dvou noh měřila kontrola jen
    -- `create_booking` a `move_booking` — zbylé dva guardy hlídal pouze
    -- `okno_48h_test.sql`, který na produkci neběží. NOTICE dole si je sice
    -- nenárokoval, ale na ostré databázi je tohle jediné ověření, které máme.
    _chyba := NULL;
    BEGIN
      PERFORM public.cancel_booking(_ids[1], 'single', NULL);
    EXCEPTION WHEN OTHERS THEN _chyba := SQLERRM;
    END;
    IF (SELECT r.status FROM public.reservations r WHERE r.id = _ids[1]) = 'cancelled' THEN
      RAISE EXCEPTION 'Neadmin zrušil akci v okně 48 h přes cancel_booking — akce měla zůstat a naúčtovat se.'
        USING ERRCODE = 'ZO002';
    END IF;
    IF _chyba IS NULL OR position('V okně 48 h' in _chyba) = 0 THEN
      RAISE EXCEPTION 'nedomereno: storno v okně nespadlo na okně (%)', COALESCE(_chyba, 'prošlo bez chyby')
        USING ERRCODE = 'ZO003';
    END IF;

    -- Dráhy se schválně předávají BEZ ZMĚNY (táž jediná dráha): guard stojí
    -- před vším ostatním, takže se měří jen on a nic se nerozbije ani tehdy,
    -- když hala druhou dráhu nemá.
    _chyba := NULL;
    BEGIN
      PERFORM public.uprav_drahy_akce(
        (SELECT r.event_id FROM public.reservations r WHERE r.id = _ids[1]),
        ARRAY[_sheet1]);
    EXCEPTION WHEN OTHERS THEN _chyba := SQLERRM;
    END;
    IF _chyba IS NULL THEN
      RAISE EXCEPTION 'Neadmin sáhl na dráhy akce v okně 48 h — mělo to spadnout.'
        USING ERRCODE = 'ZO002';
    END IF;
    IF position('V okně 48 h' in _chyba) = 0 THEN
      RAISE EXCEPTION 'nedomereno: změna drah v okně spadla z jiného důvodu (%)', _chyba
        USING ERRCODE = 'ZO003';
    END IF;

    _chyba := NULL;
    BEGIN
      UPDATE public.reservations SET status = 'cancelled' WHERE id = _ids[1];
    EXCEPTION WHEN OTHERS THEN _chyba := SQLERRM;
    END;
    IF (SELECT r.status FROM public.reservations r WHERE r.id = _ids[1]) = 'cancelled' THEN
      RAISE EXCEPTION 'Neadmin zrušil akci v okně 48 h PŘÍMÝM ZÁPISEM — akce měla zůstat a naúčtovat se.'
        USING ERRCODE = 'ZO002';
    END IF;
    IF _chyba IS NULL OR position('V okně 48 h' in _chyba) = 0 THEN
      RAISE EXCEPTION 'nedomereno: přímé storno v okně nespadlo na okně (%)', COALESCE(_chyba, 'UPDATE 0 řádků')
        USING ERRCODE = 'ZO003';
    END IF;

    -- ADMIN V OKNĚ: založení musí projít
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
    PERFORM public.create_booking(
      ARRAY[_sheet1], 'training', '__okno48_admin__',
      _zitra + ((_h + 3) || ' hours')::interval,
      _zitra + ((_h + 4) || ' hours')::interval,
      _subj, NULL, '{}'::jsonb, NULL, false, NULL, NULL);

    RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZO001';
  EXCEPTION
    WHEN SQLSTATE 'ZO001' THEN NULL;      -- úklid: měřicí zápisy se vrací zpátky
    WHEN SQLSTATE 'ZO002' THEN RAISE;     -- guard nedrží → migrace NESMÍ projít
    WHEN SQLSTATE 'ZO003' THEN            -- nedoměřeno, ale ne kvůli guardu
      _nedomereno := SQLERRM;
    WHEN OTHERS THEN
      -- SEBEKONTROLA NESMÍ SHODIT `db push`.
      --
      -- Měřicí zápisy jsou obyčejné rezervace a na ostré produkci můžou selhat
      -- z důvodů, které s oknem nesouvisí — obsazený led, nevyplněný ceník,
      -- zavřený den. Kdyby to vyletělo ven, spadla by celá migrace kvůli
      -- kontrole, ne kvůli chybě v ní. Selhání GUARDU (ZO002) zůstává fatální,
      -- tohle ne — jen se přizná, že se nedoměřilo.
      _nedomereno := SQLERRM;
  END;
  PERFORM set_config('request.jwt.claims', NULL, true);

  IF _nedomereno IS NOT NULL THEN
    RAISE NOTICE 'Okno 48 h: tvar OK, chování NEDOMĚŘENO — %', _nedomereno;
  ELSE
    RAISE NOTICE 'Okno 48 h OK: neadmin v okně nezaloží, nezruší, nepřetáhne dovnitř ani nesáhne na dráhy (všechny čtyři RPC i přímý zápis); mimo okno založí; admin v okně projde.';
  END IF;
END $kontrola$;
