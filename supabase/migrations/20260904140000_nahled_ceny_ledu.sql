-- =============================================================================
-- Cenu ledu musí být vidět DŘÍV, než se rezervace potvrdí
-- =============================================================================
-- CO SE ŘEŠÍ
--
-- Klubový led se oceňuje PÁSMOVÝM ceníkem (`cenik_pasma`, dnes: všední
-- 6–14 = 800, 14–17 = 1000, 17–22 = 1200, víkend 1000 Kč/h). Formulář proto
-- nechává sazbu prázdnou s nápisem „z ceníku" — jinak by vyplněné číslo
-- pásmový ceník vypnulo (viz komentář u `defaultRateFor` v ReservationDialog).
--
-- Důsledek: cenu tréninku NEVIDÍ PŘED POTVRZENÍM NIKDO, ani admin. Spočítá se
-- až v `set_reservation_pricing` při INSERTu, tedy potom. Člověk potvrzuje
-- rezervaci, aniž ví, jestli stojí 1 600 nebo 2 400 Kč.
--
-- JEDNA PRAVDA O CENĚ
--
-- Náhled NESMÍ být druhý výpočet. Kdyby si cenu spočítal frontend v JS, měli
-- bychom dvě pravdy o penězích a rozešly by se v den, kdy někdo sáhne na jednu
-- z nich — což je přesně ta třída chyb, kterou tenhle repozitář sbírá
-- (viz kontrolní součet u fakturace). Tahle funkce proto rozhoduje ve STEJNÉM
-- POŘADÍ jako `set_reservation_pricing` a pásma počítá TOUŽ funkcí
-- `public.cena_ledu()`.
--
-- Pořadí je převzaté z `set_reservation_pricing` (větev pro INSERT):
--   1. `subjects.default_rate` — individuálně dohodnutá cena přebíjí všechno
--   2. klub bez vlastní sazby a typ akce není commercial/recruitment → PÁSMA
--   3. jinak sazba podle typu subjektu a akce ze `settings`
--
-- KDO SMÍ CENU VIDĚT (bezpečnostní rozhodnutí)
--
-- Admin, nebo člen/zástupce TOHO subjektu. Ne kdokoli přihlášený:
-- `subjects.default_rate` je individuálně vyjednaná cena a plošně dostupný
-- náhled by z ní udělal veřejný ceník konkurence. Odpovídá to i pravidlu
-- „obsazenost a název vidí všichni, ČÁSTKU jen admin a autor" — kdo rezervaci
-- teprve zakládá, je její budoucí autor.
--
-- A DRUHÁ BRÁNA NAVÍC: komerční ceník je jen pro admina. `authenticated` nemá
-- SELECT na sazbové sloupce `settings` ani na `subjects.default_rate`, takže
-- `commercial_default_rate` (dnes 5 000 Kč/h) běžný uživatel nikde nevidí —
-- a bez téhle brány by mu ho náhled vydal, stačilo ho zavolat na vlastní klub
-- s `_event_type='commercial'`. Zavírají se obě cesty k němu: typ akce
-- i typ subjektu. Členovi to nic nebere, komerční akci si stejně založit
-- nemůže (`create_booking` ji nadminovi odmítá).
--
-- Vlastní `subjects.default_rate` členovi vědomě ZŮSTÁVÁ: je to cena, za
-- kterou právě rezervuje, a jako autor ji stejně uvidí hned po založení
-- v `reservations_calendar.amount`.
--
-- Co to zavře do budoucna: až komerční zákazník dostane vlastní účet, náhled
-- vlastní ceny mu tahle brána zavře taky (`_subject_type = 'commercial'`)
-- a bude chtít výjimku pro vlastní subjekt. Dnes komerční subjekty žádné
-- účty nemají (0 řádků v `subject_reps`), takže to nikoho neblokuje.
--
-- CO NÁHLED NENÍ
--
-- Není to závazek. Autoritativní cena vzniká až při INSERTu v
-- `set_reservation_pricing`; když se mezitím změní ceník, platí ta při potvrzení.
-- Náhled je odpověď na „kolik to bude stát, když to potvrdím teď".
--
-- VRATNOST: `DROP FUNCTION public.nahled_ceny_ledu(uuid, public.event_type,
-- timestamptz, timestamptz, integer);`. Nic staršího se nepřepisuje, žádná
-- data se nemění — migrace je čistě přírůstková.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.nahled_ceny_ledu(
  _subject_id  uuid,
  _event_type  public.event_type,
  _start       timestamptz,
  _end         timestamptz,
  _drah        integer DEFAULT 1
) RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _subject_rate numeric;
  _subject_type public.subject_type;
  _st           public.settings%ROWTYPE;
  _rate         numeric;
  _cena         numeric;
  _rozpis       jsonb;
  _hodin        numeric;
  _za_drahu     numeric;
BEGIN
  IF _start IS NULL OR _end IS NULL OR _end <= _start THEN
    RAISE EXCEPTION 'Neplatný časový rozsah pro výpočet ceny.';
  END IF;
  IF _drah IS NULL OR _drah < 1 THEN
    RAISE EXCEPTION 'Počet drah musí být aspoň 1.';
  END IF;

  -- Bez subjektu není komu fakturovat (interní trénink, údržba) — souměrně
  -- s `set_reservation_pricing`, které v té větvi nechává `amount` NULL.
  IF _subject_id IS NULL THEN
    RETURN jsonb_build_object('zdroj', 'zadna', 'celkem', NULL, 'bez_dph', false);
  END IF;

  -- BRÁNA: cenu subjektu vidí jen admin nebo jeho lidé. `is_subject_member`
  -- i `is_subject_rep` jsou SECURITY DEFINER (běžný člen na `subject_reps`
  -- cizích klubů nevidí), takže se na ně dá spolehnout i odsud.
  IF NOT (public.has_role(auth.uid(), 'admin')
          OR public.is_subject_member(_subject_id)
          OR public.is_subject_rep(_subject_id)) THEN
    RAISE EXCEPTION 'Cenu ledu pro tenhle klub vidí jen jeho členové a správce haly.';
  END IF;

  SELECT s.default_rate, s.type INTO _subject_rate, _subject_type
    FROM public.subjects s WHERE s.id = _subject_id AND s.deleted_at IS NULL;
  IF _subject_type IS NULL THEN
    RAISE EXCEPTION 'Subjekt neexistuje.';
  END IF;

  -- KOMERČNÍ CENÍK JE JEN PRO SPRÁVCE HALY (nález bezpečnostní brány T1).
  --
  -- `authenticated` nemá SELECT na sazbové sloupce `settings` ani na
  -- `subjects.default_rate`, takže `commercial_default_rate` (dnes 5 000 Kč/h)
  -- se běžný uživatel nikde nedozví. Bez téhle věty by mu ho náhled vydal:
  -- stačilo zavolat ho na VLASTNÍ klub s `_event_type='commercial'`, pásma se
  -- přeskočí a vrátí se komerční sazba. Změřeno.
  --
  -- Zavírají se obě cesty k ní: typ AKCE i typ SUBJEKTU. Členovi klubu to nic
  -- nebere — komerční akci si stejně založit nemůže (formulář mu ten typ
  -- nenabízí a `create_booking` ho odmítne).
  --
  -- Vlastní klubová sazba (`subjects.default_rate`) členovi zůstává: je to
  -- cena, za kterou právě rezervuje, a bez ní by feature pro klub s dohodnutou
  -- cenou nefungovala.
  IF NOT public.has_role(auth.uid(), 'admin')
     AND (_subject_type = 'commercial'
          OR COALESCE(_event_type, 'training') IN ('commercial', 'recruitment')) THEN
    RAISE EXCEPTION 'Cenu komerční akce spočítá jen správce haly.';
  END IF;
  SELECT * INTO _st FROM public.settings LIMIT 1;

  _hodin := round((extract(epoch FROM (_end - _start)) / 3600.0)::numeric, 2);

  -- 2) PÁSMA — táž podmínka i tatáž funkce jako v `set_reservation_pricing`.
  IF _subject_type = 'club' AND _subject_rate IS NULL
     AND COALESCE(_event_type, 'training') <> 'commercial'
     AND COALESCE(_event_type, 'training') <> 'recruitment' THEN
    SELECT c.castka, c.rozpis INTO _cena, _rozpis
      FROM public.cena_ledu(_start, _end) c;
    _za_drahu := _cena;
    RETURN jsonb_build_object(
      'zdroj',    'pasma',
      'hodin',    _hodin,
      'drah',     _drah,
      'za_drahu', _za_drahu,
      'celkem',   round(_za_drahu * _drah, 2),
      'sazba',    round(_cena / NULLIF(_hodin, 0), 2),   -- odvozený průměr, ne vstup
      'rozpis',   _rozpis,
      -- Klubový pásmový ceník je vedený VČETNĚ DPH (viz `set_reservation_pricing`).
      'bez_dph',  false);
  END IF;

  -- 1)+3) Jedna sazba za hodinu. COALESCE je opsaný z `set_reservation_pricing`;
  -- kdyby se tam změnil, musí se změnit i tady — proto na to upozorňuje
  -- sebekontrola níž.
  _rate := COALESCE(
    _subject_rate,
    CASE
      WHEN _subject_type = 'commercial' THEN _st.commercial_default_rate
      WHEN _event_type = 'commercial'   THEN _st.commercial_default_rate
      WHEN _event_type = 'recruitment'  THEN _st.commercial_default_rate
      WHEN _event_type = 'tournament'   THEN COALESCE(_st.tournament_rate, _st.club_default_rate)
      WHEN _event_type = 'training'     THEN COALESCE(_st.training_rate, _st.club_default_rate)
      ELSE _st.club_default_rate
    END,
    CASE _subject_type WHEN 'commercial' THEN _st.commercial_default_rate
                       ELSE _st.club_default_rate END
  );

  IF _rate IS NULL THEN
    -- Táž věta jako z triggeru, ať člověk nedostane před potvrzením jinou
    -- odpověď než při něm.
    RAISE EXCEPTION 'Sazba není nastavena — admin musí nejdřív vyplnit ceník (Nastavení) nebo sazbu subjektu';
  END IF;

  _za_drahu := round(_rate * _hodin, 2);
  RETURN jsonb_build_object(
    'zdroj',    CASE WHEN _subject_rate IS NOT NULL THEN 'sazba_subjektu' ELSE 'cenik' END,
    'hodin',    _hodin,
    'drah',     _drah,
    'za_drahu', _za_drahu,
    'celkem',   round(_za_drahu * _drah, 2),
    'sazba',    _rate,
    'rozpis',   NULL,
    'bez_dph',  public.cena_je_bez_dph(_subject_type, _event_type, _subject_rate));
END;
$function$;

-- `anon` ne: cena je pro přihlášené.
REVOKE ALL ON FUNCTION public.nahled_ceny_ledu(uuid, public.event_type, timestamptz, timestamptz, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.nahled_ceny_ledu(uuid, public.event_type, timestamptz, timestamptz, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- Sebekontrola
-- ---------------------------------------------------------------------------
DO $kontrola$
DECLARE _src text;
BEGIN
  SELECT prosrc INTO _src FROM pg_proc
   WHERE oid = 'public.nahled_ceny_ledu(uuid,public.event_type,timestamptz,timestamptz,integer)'::regprocedure;

  -- Náhled musí pásma počítat TOUŽ funkcí jako trigger. Vlastní výpočet by byl
  -- druhá pravda o penězích.
  IF position('public.cena_ledu(_start, _end)' in _src) = 0 THEN
    RAISE EXCEPTION 'Náhled nepoužívá cena_ledu() — vznikla druhá pravda o ceně.';
  END IF;
  -- Bez brány by byl z náhledu veřejný výpis individuálně dohodnutých sazeb.
  IF position('is_subject_member(_subject_id)' in _src) = 0 THEN
    RAISE EXCEPTION 'Náhled nemá bránu na členství — cena by byla veřejná.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE oid = 'public.nahled_ceny_ledu(uuid,public.event_type,timestamptz,timestamptz,integer)'::regprocedure
       AND prosecdef) THEN
    RAISE EXCEPTION 'Náhled není SECURITY DEFINER — cena_ledu() mu nepůjde zavolat.';
  END IF;
  IF NOT has_function_privilege('authenticated',
        'public.nahled_ceny_ledu(uuid,public.event_type,timestamptz,timestamptz,integer)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated nemá EXECUTE — frontend náhled nezavolá.';
  END IF;

  IF position('Cenu komerční akce spočítá jen správce haly.' in _src) = 0 THEN
    RAISE EXCEPTION 'Chybí brána na komerční ceník — člen by si vytáhl commercial_default_rate.';
  END IF;

  RAISE NOTICE 'Náhled ceny ledu: jedna pravda (cena_ledu), brány na členství i komerční ceník, grant sedí.';
END $kontrola$;
