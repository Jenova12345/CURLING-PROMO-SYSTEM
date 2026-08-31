-- =============================================================================
-- Trenér k tréninku — varianta D
-- Blok C z docs/ETAPA3-ROLE-DALSI.md · rozhodnutí PM R7 a P1
-- =============================================================================
-- CO SE ZAVÁDÍ:
--
-- C1: `reservations.preferovany_trener` — NEZÁVAZNÉ PŘÁNÍ hráče. Nic nespouští,
--     nikoho nepřiřazuje, nic nestojí. Jen zachytí, koho by si hráč přál, aby
--     to zástupce nemusel obvolávat (R7, varianta D).
--
-- C2: `prirad_trenera()` — skutečné přiřazení. Teprve TÍM vzniká placená
--     trenérská směna (600 Kč/h ze `sazby_roli`).
--
-- -----------------------------------------------------------------------------
-- ROZHODNUTÍ PM P1: SMĚNA VZNIKÁ PŘIŘAZENÍM, NE ZALOŽENÍM TRÉNINKU
-- -----------------------------------------------------------------------------
-- „Trénink generuje placenou trenérskou směnu JEN při přiřazení trenéra;
--  trénink bez trenéra negeneruje nic."
--
-- Tím ODPADL zásah, kterého se původní návrh bál: nemusí se otevírat
-- `role_reqs` pro tréninky ani v `create_booking`, ani ve filtru `event_type`
-- v `dorovnej_stab`. Obojí zůstává BEZE ZMĚNY.
--
-- Důvod je věcný, ne úsporný: `role_reqs` je POPTÁVKA („chceme trenéra, ať se
-- někdo přihlásí"), kdežto přiřazení je ADRESNÉ („povede to tenhle trenér").
-- Přes `role_reqs` by vznikla směna se `status = 'open'`, kterou si může zabrat
-- kdokoli jiný s rolí `trainer` — tedy přesný opak přiřazení.
--
-- -----------------------------------------------------------------------------
-- ⚠️ SMĚNA SE ZAKLÁDÁ ROVNOU OBSAZENÁ, NIKDY JAKO `open`
-- -----------------------------------------------------------------------------
-- Není to kosmetika. `dorovnej_stab` NEMÁ pro tréninky předčasný návrat:
-- sestaví `pozadavek` (pro trénink prázdný, protože ho odfiltruje
-- `event_type IN ('commercial','recruitment')`) a udělá FULL JOIN se všemi
-- nezrušenými směnami akce. Trenérská směna z toho vyjde jako PŘEBYTEK.
--
-- Zruší ho ale jen tehdy, když má `status = 'open'` (větev `ke_zruseni` má
-- `AND status = 'open'`). Obsazená směna je tím v bezpečí.
--
-- Trigger dorovnání se navíc spouští jen na `UPDATE OF role_reqs,
-- required_staff, event_type`, takže běžná úprava tréninku ho nevzbudí. Spoléhat
-- na to, že se ta tři pole nikdy nezmění, by ale bylo přesně to „spoléhání na
-- náhodu", které si repo jinde zakazuje — proto rovnou `claimed`.
--
-- -----------------------------------------------------------------------------
-- SAZBA SE NEPÍŠE RUČNĚ
-- -----------------------------------------------------------------------------
-- `hourly_rate` se schválně NEVYPLŇUJE — doplní ho trigger `trg_shifts_sazba`
-- z `sazby_roli` (trenér 600 Kč/h). Konstanta v kódu by byla druhá, tišší cesta
-- k sazbě. Ruční přepsání na konkrétní směně zůstává možné (R9).
--
-- -----------------------------------------------------------------------------
-- KDO CO SMÍ (R7 + P2)
-- -----------------------------------------------------------------------------
--   • PŘIŘADIT trenéra k tréninku smí admin i zástupce klubu — je to provozní
--     rozhodnutí nad konkrétní akcí.
--   • UDĚLIT ROLI `trainer` smí JEN ADMIN (P2) a tahle migrace na tom nic
--     nemění. Přiřadit lze pouze člověka, který roli už má; jinak by zástupce
--     přes přiřazení nepřímo rozdával placené role.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   DROP FUNCTION IF EXISTS public.odeber_trenera(uuid);
--   DROP FUNCTION IF EXISTS public.prirad_trenera(uuid, uuid);
--   ALTER TABLE public.reservations DROP COLUMN IF EXISTS preferovany_trener;
--   -- Směny, které mezitím vznikly, revert NERUŠÍ — jsou to odpracované
--   -- hodiny a peníze. Zrušit je jde ručně přes `odeber_trenera` PŘED revertem.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) C1 — přání hráče
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS preferovany_trener uuid REFERENCES public.profiles(user_id);

COMMENT ON COLUMN public.reservations.preferovany_trener IS
  'NEZÁVAZNÉ přání hráče, koho by chtěl jako trenéra (R7, varianta D). Nic nespouští a nikoho nepřiřazuje — přiřazení dělá prirad_trenera() a teprve tím vzniká placená směna. Vyplňuje se jen u tréninků; databáze to nevynutí (typ akce je na events, ne na reservations), hlídá to UI a create_booking.';

-- Kdo přání uvidí: admin, zástupce klubu a autor rezervace — tedy stejný okruh
-- jako u částky (rozhodnutí klienta 31. 7.). Sloupec jede na existujících
-- politikách `reservations`, ale GRANT je sloupcový, tak ho musíme udělit.
GRANT SELECT (preferovany_trener), UPDATE (preferovany_trener)
   ON public.reservations TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) C2 — přiřazení trenéra
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prirad_trenera(
  _event_id uuid,
  _user_id  uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _ev        public.events%ROWTYPE;
  _subject   uuid;
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
  SELECT r.subject_id INTO _subject
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL
   LIMIT 1;

  IF NOT (has_role(auth.uid(), 'admin')
          OR (_subject IS NOT NULL AND public.is_subject_rep(_subject))) THEN
    RAISE EXCEPTION 'Trenéra přiřazuje správce haly nebo zástupce klubu.';
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
$$;

COMMENT ON FUNCTION public.prirad_trenera(uuid, uuid) IS
  'Přiřadí trenéra k tréninku a TÍM založí placenou trenérskou směnu (P1) — rovnou obsazenou, aby ji dorovnání štábu nezrušilo jako přebytek. Sazbu doplní ceník rolí. Přiřazuje admin nebo zástupce klubu; roli `trainer` uděluje jen admin.';

REVOKE ALL ON FUNCTION public.prirad_trenera(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prirad_trenera(uuid, uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Odebrání trenéra
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.odeber_trenera(_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _subject uuid; _sh record;
BEGIN
  SELECT r.subject_id INTO _subject
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL
   LIMIT 1;

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
$$;

COMMENT ON FUNCTION public.odeber_trenera(uuid) IS
  'Odebere trenéra z tréninku — směnu ruší SOFT (status cancelled + razítka), nikdy nemaže. Uzavřenou směnu odebrat nelze, je to podklad pro výplatu.';

REVOKE ALL ON FUNCTION public.odeber_trenera(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.odeber_trenera(uuid) TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 5) Přání trenéra musí být vidět v kalendáři
--
-- Aplikace čte rezervace z pohledu `reservations_calendar`, ne z tabulky, takže
-- bez tohohle by `preferovany_trener` sice v databázi byl, ale UI by ho nemělo
-- odkud vzít. Sloupec se PŘIDÁVÁ NA KONEC — `CREATE OR REPLACE VIEW` jiné
-- pořadí ani ubrání sloupce nepustí.
--
-- Jméno se joinuje rovnou, ať se na ně UI nemusí doptávat druhým dotazem.
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
    r.preferovany_trener,
    tp.full_name AS preferovany_trener_jmeno
   FROM reservations r
     LEFT JOIN subjects s ON s.id = r.subject_id
     LEFT JOIN events e ON e.id = r.event_id
     LEFT JOIN profiles cp ON cp.user_id = r.created_by
     LEFT JOIN profiles xp ON xp.user_id = r.cancelled_by
     LEFT JOIN profiles tp ON tp.user_id = r.preferovany_trener
  WHERE r.deleted_at IS NULL;;

-- -----------------------------------------------------------------------------
-- 4) Kontrola
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM 1 FROM pg_proc WHERE oid = 'public.prirad_trenera(uuid, uuid)'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'prirad_trenera se nevytvořila.'; END IF;
  PERFORM 1 FROM pg_proc WHERE oid = 'public.odeber_trenera(uuid)'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'odeber_trenera se nevytvořila.'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.sazby_roli WHERE role = 'trainer') THEN
    RAISE EXCEPTION 'V ceníku rolí chybí trenér — směna by vznikla bez sazby.';
  END IF;

  RAISE NOTICE 'Trenér k tréninku je na místě (přání + přiřazení, sazba z ceníku rolí).';
END $$;
