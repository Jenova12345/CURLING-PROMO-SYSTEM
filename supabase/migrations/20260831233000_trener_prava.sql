-- =============================================================================
-- Trenér: zástupce ho musí i VIDĚT, přání se nedá podstrčit, klub je jednoznačný
-- Nálezy z brány (ultra review, 31. 8. 2026)
-- =============================================================================
-- 1) MUST-FIX — ZÁSTUPCE TRENÉRA PŘIŘADIL, ALE NEUVIDĚL.
--
--    `prirad_trenera` je SECURITY DEFINER a zástupce klubu pouští, jenže UI
--    pak čte směnu obyčejným `select` z `shifts` — a tam žádná politika pro
--    zástupce není. Permisivní `USING (true)` padla v `unified_calendar`
--    a od té doby platí jen „staff a admin". Zástupce dostal NULA ŘÁDKŮ BEZ
--    CHYBY, takže mu dialog tvrdil „trenér nepřiřazen", on přiřadil znovu —
--    a vznikla druhá placená směna. (Duplicitní kontrola v `prirad_trenera`
--    bere `LIMIT 1`, takže zruší vždycky jen jednu z přebytečných.)
--
--    ŘEŠÍ SE ČTECÍ FUNKCÍ, NE ROZŠÍŘENÍM RLS NA `shifts`. Otevřít zástupci
--    celou tabulku znamená pustit mu i `hourly_rate` — což je mzdový náklad
--    haly, ne údaj klubu. Funkce vydá jen to, co UI potřebuje: kdo to je.
--    Sazbu vidí jenom admin.
--
-- 2) `preferovany_trener` se zapisoval do tabulky napřímo — a to bylo špatně
--    na OBĚ strany:
--
--      • ČLENOVI KLUBU to vůbec nefungovalo. `guard_reservation_rep_changes`
--        má pro ne-admina WHITELIST sloupců a `preferovany_trener` v něm není,
--        takže hráč dostal „Pole „preferovany_trener" smí měnit jen správce" —
--        tedy funkce, kterou UI nabízí právě jemu, mu padala.
--      • ADMINOVI to naopak neověřovalo NIC: mohl přání pověsit na turnaj
--        i na údržbu a nastavit jako „trenéra" kohokoli v systému, včetně
--        deaktivovaného účtu. Cizí klíč mířil jen na `profiles`, typ akce se
--        nekontroloval (`kind === 'training'` bylo jen v dialogu) a sám
--        komentář v migraci přiznával, že „databáze to nevynutí".
--
--    Zápis proto jde přes RPC, které ověří právo na rezervaci, typ akce i roli
--    trenéra. SLOUPCOVÝ `REVOKE` by byl k ničemu: `reservations` má tabulkový
--    UPDATE grant pro `authenticated`, takže se práva stejně odvozují z něj.
--    Skutečná brána je whitelist v guardu (a ten sloupec nezná) plus tahle RPC.
--
-- 3) Přání trenéra viděl v kalendáři KAŽDÝ přihlášený. `reservations_calendar`
--    maskuje `note`, `hours`, `rate_per_hour`, `amount` i korekce — dva
--    sloupce přidané 31. 8. masku neměly, takže si hobby hráč vyjel, koho si
--    který klub přál na který trénink. Okruh je teď ten, který slibuje
--    komentář v migraci: admin, zástupce klubu a autor rezervace.
--
-- 4) Který klub akci „vlastní", rozhodoval `LIMIT 1` bez `ORDER BY`.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- funkce a pohled zpátky ze ŽIVÉHO schématu (pg_get_functiondef /
--   -- pg_get_viewdef) ve znění z 20260831200000_trener_k_treninku.sql
--   GRANT UPDATE (preferovany_trener) ON public.reservations TO authenticated;
--   DROP FUNCTION IF EXISTS public.nastav_prani_trenera(uuid[], uuid);
--   DROP FUNCTION IF EXISTS public.trener_akce(uuid);
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Kdo je k akci přiřazený — čtecí funkce místo díry v RLS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trener_akce(_event_id uuid)
 RETURNS TABLE(shift_id uuid, user_id uuid, jmeno text, status text, hourly_rate numeric)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _subject uuid; _subjektu int; _admin boolean := has_role(auth.uid(), 'admin');
BEGIN
  SELECT count(DISTINCT r.subject_id), min(r.subject_id::text)::uuid INTO _subjektu, _subject
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL;

  -- Kdo smí vědět, kdo trénink vede: správce haly, KDOKOLI z toho klubu
  -- (trenér je provozní údaj, ne peníze) a autor rezervace. Nikdo jiný —
  -- jinak by to byla ta samá díra, jakou měl `preferovany_trener` v kalendáři.
  IF NOT (_admin
          OR (_subjektu = 1 AND public.is_subject_member(_subject))
          OR EXISTS (SELECT 1 FROM public.reservations r
                      WHERE r.event_id = _event_id AND r.deleted_at IS NULL
                        AND r.created_by = auth.uid())) THEN
    RETURN;   -- prázdno, ne chyba: kalendář se na tohle ptá u každé akce
  END IF;

  RETURN QUERY
    SELECT sh.id, sh.claimed_by, p.full_name, sh.status::text,
           -- SAZBA JEN ADMINOVI. Je to mzdový náklad haly; klub má vědět KDO,
           -- ne ZA KOLIK. (Tohle je celý důvod, proč se nerozšiřuje RLS
           -- na `shifts` — tabulkový SELECT by sazbu pustil taky.)
           CASE WHEN _admin THEN sh.hourly_rate ELSE NULL END
      FROM public.shifts sh
      LEFT JOIN public.profiles p ON p.user_id = sh.claimed_by
     WHERE sh.event_id = _event_id
       AND sh.required_role = 'trainer'
       AND sh.status <> 'cancelled'
     ORDER BY sh.created_at
     LIMIT 1;
END;
$$;

COMMENT ON FUNCTION public.trener_akce(uuid) IS
  'Kdo je k akci přiřazený jako trenér. Existuje proto, že shifts nemá SELECT politiku pro zástupce klubu — a rozšířit ji by znamenalo pustit mu i hourly_rate (mzdový náklad haly). Vydá jméno komukoli z klubu, sazbu jen adminovi. Bez téhle funkce hlásilo UI zástupci „trenér nepřiřazen" i po úspěšném přiřazení.';

REVOKE ALL ON FUNCTION public.trener_akce(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trener_akce(uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2) Přání trenéra: zápis přes RPC, ne přes sloupcový grant
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nastav_prani_trenera(
  _reservation_ids uuid[],
  _user_id         uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _r record; _zmeneno int;
BEGIN
  IF _reservation_ids IS NULL OR array_length(_reservation_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Není u čeho měnit přání trenéra.';
  END IF;

  -- ROLE SE OVĚŘUJE, I KDYŽ JE PŘÁNÍ NEZÁVAZNÉ. Bez toho šlo do sloupce
  -- zapsat libovolný účet v systému (cizí, adminův, deaktivovaný) — cizí klíč
  -- mířil jen na `profiles`. Přání se pak zobrazí zástupci jako návrh, koho
  -- přiřadit; nabízet mu člověka, který trenér není, je horší než nic.
  IF _user_id IS NOT NULL AND NOT has_role(_user_id, 'trainer') THEN
    RAISE EXCEPTION 'Tenhle člověk není vedený jako trenér.'
      USING HINT = 'Roli trenéra přiděluje správce haly.';
  END IF;

  FOR _r IN
    SELECT r.id, r.event_id, e.event_type
      FROM public.reservations r
      LEFT JOIN public.events e ON e.id = r.event_id
     WHERE r.id = ANY (_reservation_ids) AND r.deleted_at IS NULL
  LOOP
    -- Na rezervaci smí sáhnout jen ten, kdo ji smí spravovat — táž brána,
    -- jakou má úprava rezervace samotné.
    IF NOT public.can_manage_reservation(_r.id) THEN
      RAISE EXCEPTION 'Tuhle rezervaci nemáte právo upravit.';
    END IF;
    -- PŘÁNÍ PATŘÍ JEN K TRÉNINKU. Doteď to hlídalo pouze UI (`kind ===
    -- 'training'`), takže REST volání ho pověsilo i na turnaj nebo údržbu.
    IF COALESCE(_r.event_type, 'training') <> 'training' THEN
      RAISE EXCEPTION 'Přání trenéra dává smysl jen u tréninku (tahle akce je %).',
        COALESCE(_r.event_type::text, 'bez typu');
    END IF;
  END LOOP;

  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET preferovany_trener = _user_id
   WHERE id = ANY (_reservation_ids) AND deleted_at IS NULL;
  GET DIAGNOSTICS _zmeneno = ROW_COUNT;
  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('zmeneno', _zmeneno, 'trener', _user_id);
END;
$$;

COMMENT ON FUNCTION public.nastav_prani_trenera(uuid[], uuid) IS
  'Zapíše NEZÁVAZNÉ přání trenéra na rezervace. Nahrazuje přímý zápis do sloupce: ten měl sloupcový UPDATE grant, takže přes REST šlo přání nastavit komukoli a na jakoukoli akci. Tady se ověří právo na rezervaci, typ akce (jen trénink) i to, že cíl má roli trenéra. Placenou směnu z toho nevznikne — na to je prirad_trenera.';

REVOKE ALL ON FUNCTION public.nastav_prani_trenera(uuid[], uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.nastav_prani_trenera(uuid[], uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Přiřazení a odebrání: klub jednoznačně, ne podle plánovače
--
-- Těla z živého schématu (pravidlo 7); zásah je v obou tentýž — `LIMIT 1`
-- vystřídal počet různých subjektů.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prirad_trenera(_event_id uuid, _user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _ev        public.events%ROWTYPE;
  _subject   uuid;
  _subjektu  int;
  _stary     uuid;
  _novy      uuid;
BEGIN
  SELECT * INTO _ev FROM public.events WHERE id = _event_id;
  IF _ev.id IS NULL THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  -- TRENÉR PATŘÍ K TRÉNINKU. U komerční akce se štáb řeší přes `role_reqs`
  -- a dorovnání; míchat obě cesty by znamenalo dvě pravdy o jedné směně.
  IF _ev.event_type <> 'training' THEN
    RAISE EXCEPTION 'Trenéra lze přiřadit jen k tréninku (tahle akce je %).', _ev.event_type;
  END IF;

  -- Klub, kterému trénink patří — kvůli právům zástupce.
  --
  -- `LIMIT 1` bez `ORDER BY` tu dřív znamenalo, že o tom, ČÍ zástupce smí
  -- k akci pověsit placenou směnu, rozhodoval plánovač: u akce s drahami dvou
  -- klubů vracel jednou jeden subjekt, jindy druhý. `approve_reservation` se
  -- proti témuž brání výslovně („kdyby někdo ručně pověsil na akci rezervaci
  -- jiného klubu, nesmí ji zástupce potvrdit jedním kliknutím s tou svou").
  --
  -- Tady se to řeší přísněji: buď má akce JEDEN klub, nebo ji zástupce neřídí
  -- vůbec a zbývá admin.
  SELECT count(DISTINCT r.subject_id), min(r.subject_id::text)::uuid INTO _subjektu, _subject
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL;

  IF _subjektu > 1 THEN
    _subject := NULL;   -- víc klubů na jedné akci → jen admin
  END IF;

  IF NOT (has_role(auth.uid(), 'admin')
          OR (_subject IS NOT NULL AND public.is_subject_rep(_subject))) THEN
    -- `USING HINT` tu být NEMŮŽE podmíněně: `RAISE ... USING HINT = NULL`
    -- skončí chybou „RAISE statement option cannot be null", takže by se
    -- z běžného odmítnutí stala havárie. Upřesnění jde proto do zprávy.
    RAISE EXCEPTION 'Trenéra přiřazuje správce haly nebo zástupce klubu.%',
      CASE WHEN _subjektu > 1
           THEN ' Tahle akce má navíc dráhy víc klubů, takže ji zástupce neřídí — musí správce haly.'
           ELSE '' END;
  END IF;

  -- P2: roli `trainer` uděluje jen admin. Tady se jen ověří, že ji člověk má —
  -- jinak by zástupce přes přiřazení nepřímo rozdával placené role.
  IF NOT has_role(_user_id, 'trainer') THEN
    RAISE EXCEPTION 'Tenhle člověk není vedený jako trenér. Roli přiděluje správce haly.';
  END IF;

  -- Jeden trenér na trénink. Když už nějaký je, původní směna se ZRUŠÍ SOFT
  -- (zásada 2) a založí se nová — zrušit natvrdo odpracované hodiny nejde.
  SELECT id INTO _stary
    FROM public.shifts
   WHERE event_id = _event_id
     AND required_role = 'trainer'
     AND status <> 'cancelled'
   LIMIT 1;

  IF _stary IS NOT NULL THEN
    -- Už odpracovanou směnu neodebíráme ani při výměně — jsou to peníze.
    IF (SELECT status FROM public.shifts WHERE id = _stary) = 'completed' THEN
      RAISE EXCEPTION 'Trenér už má tuhle směnu uzavřenou, vyměnit ho nejde.'
        USING HINT = 'Uzavřená směna je podklad pro výplatu.';
    END IF;
    IF (SELECT claimed_by FROM public.shifts WHERE id = _stary) = _user_id THEN
      RETURN jsonb_build_object('zmena', false, 'shift_id', _stary, 'trener', _user_id);
    END IF;
    UPDATE public.shifts
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     WHERE id = _stary;
  END IF;

  -- SMĚNA VZNIKÁ ROVNOU OBSAZENÁ — viz hlavička. `hourly_rate` se nevyplňuje,
  -- doplní ho `trg_shifts_sazba` z ceníku rolí.
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_event_id, 'trainer', 'claimed', _user_id, now())
  RETURNING id INTO _novy;

  RETURN jsonb_build_object(
    'zmena', true,
    'shift_id', _novy,
    'trener', _user_id,
    'sazba', (SELECT hourly_rate FROM public.shifts WHERE id = _novy),
    'vymenen_za', _stary
  );

EXCEPTION
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Trenéra se nepodařilo přiřadit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontroluj, jestli je akce trénink a člověk má roli trenéra.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.odeber_trenera(_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _subject uuid; _subjektu int; _sh record;
BEGIN
  -- Jednoznačný klub, souměrně s `prirad_trenera` — viz komentář tam.
  SELECT count(DISTINCT r.subject_id), min(r.subject_id::text)::uuid INTO _subjektu, _subject
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL;

  IF _subjektu > 1 THEN
    _subject := NULL;
  END IF;

  IF NOT (has_role(auth.uid(), 'admin')
          OR (_subject IS NOT NULL AND public.is_subject_rep(_subject))) THEN
    RAISE EXCEPTION 'Trenéra odebírá správce haly nebo zástupce klubu.';
  END IF;

  SELECT id, status INTO _sh
    FROM public.shifts
   WHERE event_id = _event_id AND required_role = 'trainer' AND status <> 'cancelled'
   LIMIT 1;

  IF _sh.id IS NULL THEN
    RETURN jsonb_build_object('zmena', false);
  END IF;

  -- Uzavřená směna se neodebírá — je to podklad pro výplatu (zásada 2).
  IF _sh.status = 'completed' THEN
    RAISE EXCEPTION 'Trenér má směnu uzavřenou, odebrat ho nejde.'
      USING HINT = 'Uzavřená směna je podklad pro výplatu.';
  END IF;

  UPDATE public.shifts
     SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
   WHERE id = _sh.id;

  RETURN jsonb_build_object('zmena', true, 'shift_id', _sh.id);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) Přání trenéra v kalendáři vidí jen ti, kdo mají
--
-- Znění z `pg_get_viewdef` živého schématu; zásah jsou dvě `CASE` masky na
-- posledních dvou sloupcích. `CREATE OR REPLACE VIEW` nepustí jiné pořadí ani
-- jiné typy, takže maska musí vracet `uuid` a `text`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.reservations_calendar AS
 SELECT r.id,
    r.sheet_id,
    r.subject_id,
    r.event_id,
    r.series_id,
    r.start_at,
    r.end_at,
    r.status,
    s.name AS subject_name,
    s.type AS subject_type,
    e.title AS event_title,
    COALESCE(e.event_type,
        CASE
            WHEN s.type = 'commercial'::subject_type THEN 'commercial'::event_type
            ELSE 'training'::event_type
        END) AS event_type,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND s2.deleted_at IS NULL)) THEN r.note
            ELSE NULL::text
        END AS note,
    r.approved_at,
    r.created_by,
    cp.full_name AS created_by_name,
    r.created_at,
    r.cancelled_at,
    r.cancelled_by,
    xp.full_name AS cancelled_by_name,
    r.cancel_reason,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.hours
            ELSE NULL::numeric
        END AS hours,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.rate_per_hour
            ELSE NULL::numeric
        END AS rate_per_hour,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.amount
            ELSE NULL::numeric
        END AS amount,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.corrected_hours
            ELSE NULL::numeric
        END AS corrected_hours,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.corrected_amount
            ELSE NULL::numeric
        END AS corrected_amount,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid(), false) AS can_see_amount,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() AND (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND s2.deleted_at IS NULL)), false) AS can_manage,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)), false) AS can_approve,
        CASE
            WHEN (( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid()) THEN r.preferovany_trener
            ELSE NULL::uuid
        END AS preferovany_trener,
        CASE
            WHEN (( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid()) THEN tp.full_name
            ELSE NULL::text
        END AS preferovany_trener_jmeno
   FROM reservations r
     LEFT JOIN subjects s ON s.id = r.subject_id
     LEFT JOIN events e ON e.id = r.event_id
     LEFT JOIN profiles cp ON cp.user_id = r.created_by
     LEFT JOIN profiles xp ON xp.user_id = r.cancelled_by
     LEFT JOIN profiles tp ON tp.user_id = r.preferovany_trener
  WHERE r.deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 5) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
BEGIN
  -- Guard drží whitelist sloupců pro ne-admina. Kdyby do něj někdo přání
  -- doplnil, obešel by tím celou kontrolu v `nastav_prani_trenera`.
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.guard_reservation_rep_changes()'::regprocedure)
     LIKE '%''preferovany_trener''%' THEN
    RAISE EXCEPTION 'preferovany_trener se objevil ve whitelistu guardu — přání by šlo zapsat mimo RPC.';
  END IF;

  IF pg_get_viewdef('public.reservations_calendar'::regclass) NOT LIKE '%preferovany_trener_jmeno%'
     OR (SELECT count(*) FROM regexp_matches(
           pg_get_viewdef('public.reservations_calendar'::regclass), 'preferovany_trener', 'g')) < 3 THEN
    RAISE EXCEPTION 'Maska na přání trenéra v reservations_calendar chybí.';
  END IF;

  PERFORM 1 FROM pg_proc WHERE oid = 'public.trener_akce(uuid)'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'trener_akce se nevytvořila.'; END IF;
  PERFORM 1 FROM pg_proc WHERE oid = 'public.nastav_prani_trenera(uuid[], uuid)'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'nastav_prani_trenera se nevytvořila.'; END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.prirad_trenera(uuid, uuid)'::regprocedure)
     NOT LIKE '%_subjektu%' THEN
    RAISE EXCEPTION 'prirad_trenera pořád vybírá klub přes LIMIT 1.';
  END IF;

  RAISE NOTICE 'Trenér: zástupce ho vidí, přání se nedá podstrčit a klub je jednoznačný.';
END $kontrola$;
