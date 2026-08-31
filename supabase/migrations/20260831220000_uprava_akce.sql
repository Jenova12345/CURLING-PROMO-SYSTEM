-- =============================================================================
-- Úprava akce: dráhy, typ akce, a akce zadarmo
-- Úkoly B, C, D z 31. 8. 2026
-- =============================================================================
-- CO SE MĚNÍ:
--
-- B) `uprav_drahy_akce()` — u existující akce jde PŘIDAT nebo UBRAT dráhu.
--    Dosud to nešlo: dialog v úpravě zaškrtnutím druhé dráhy jen přepnul tu
--    první, takže akce zůstala jednodráhová.
--
-- C) `zmen_typ_akce()` — typ akce (trénink / turnaj / komerční / údržba) jde
--    změnit i po založení, včetně PŘEPOČÍTÁNÍ CENY podle nového typu.
--
-- D) Akce za 0 Kč se NEFAKTURUJE. Sazba 0 byla v databázi povolená vždycky
--    („databáze je podlaha, ne strop"), ale doklad by se na ni vystavil.
--
-- -----------------------------------------------------------------------------
-- PROČ SE CENA NEPŘEPOČÍTÁVÁ PLOŠNĚ
-- -----------------------------------------------------------------------------
-- `set_reservation_pricing` počítá cenu jen při VZNIKU rezervace — snapshot se
-- pak nemá kam hnout. To je záměr: kdyby se přepočítávalo při každém UPDATE,
-- posunula by se částka i u akce, na kterou se jen sáhlo, a to klidně na
-- dokladu, který už odešel.
--
-- Změna typu akce je ale výjimka: každý typ se oceňuje jinak, takže po ní musí
-- cena odpovídat novému typu. Otevírá se to proto jen na výslovné vyžádání
-- přes `app.preceneni`, které nastavuje výhradně `zmen_typ_akce()`.
--
-- -----------------------------------------------------------------------------
-- NULOVÁ AKCE: NEFAKTURUJE SE, ALE Z PŘEHLEDU NEMIZÍ
-- -----------------------------------------------------------------------------
-- `fakturovatelne_rezervace` nově vynechá rezervace s částkou 0. Doklad na
-- nulu nemá co říct — zákazník ho nezaplatí, účetní ho vyhodí a v číselné řadě
-- zabere číslo.
--
-- Z „Kdo kolik dluží" (`reservations_billing`) se ale NEVYŘAZUJE: tam má být
-- vidět, že se led odehrál, jen zadarmo. Kontrolní součet se tím nerozbije —
-- nulová rezervace přispěje do obou stran nulou. Ověřuje to `nulova_sazba_test.sql`.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- Funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef):
--   --   set_reservation_pricing, fakturovatelne_rezervace
--   DROP FUNCTION IF EXISTS public.uprav_drahy_akce(uuid, uuid[]);
--   DROP FUNCTION IF EXISTS public.zmen_typ_akce(uuid, public.event_type);
--   -- Rezervace, které mezitím vznikly přidáním dráhy, revert NERUŠÍ.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Přecenění na vyžádání (podklad pro C)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_reservation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _rate         numeric;
  _subject_rate numeric;
  _subject_type public.subject_type;
  _event_type   public.event_type;
  _st           public.settings%ROWTYPE;
  _cena         numeric;
  _rozpis       jsonb;
BEGIN
  -- `cenove_pasma` JE ODVOZENÁ HODNOTA, NE VSTUP.
  --
  -- `reservations` má tabulkové INSERT/UPDATE granty, takže nový sloupec je pro
  -- `authenticated` rovnou zapisovatelný. Podstrčený rozpis by přitom rozhodoval
  -- o tom, co se vyfakturuje, tak se na vstupu zahazuje a plní ho jen tenhle
  -- trigger.
  --
  -- A pozor na `'null'::jsonb`: to NENÍ SQL NULL, takže `cenove_pasma IS NULL`
  -- je u něj false — a tím by vypnul pravidlo o celých korunách i dopočet
  -- `amount`. Ověřeno: rezervace se sazbou 1 234,56 Kč/h a `amount = NULL`
  -- takhle prošla. Proto se netestuje NULL, ale jestli je to vůbec pole.
  IF TG_OP = 'INSERT' OR jsonb_typeof(NEW.cenove_pasma) IS DISTINCT FROM 'array' THEN
    NEW.cenove_pasma := NULL;
  END IF;

  IF NEW.subject_id IS NULL THEN
    NEW.rate_per_hour    := NULL;
    NEW.amount           := NULL;
    NEW.corrected_amount := NULL;
    NEW.hours := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    RETURN NEW;
  END IF;

  -- Snapshot sazby jen při vzniku; pozdější změna ceníku nepřepočítává minulé rezervace.
  -- PŘECENĚNÍ PŘI ZMĚNĚ TYPU AKCE.
  --
  -- Cena se normálně počítá jen při vzniku rezervace — snapshot se pak nemá
  -- kam hnout. Když ale admin změní TYP akce (trénink ↔ komerční ↔ turnaj),
  -- musí se cena přepočítat, protože každý typ se oceňuje jinak.
  --
  -- Otevírá se to jen na výslovné vyžádání přes `app.preceneni`, ne plošně:
  -- kdyby se přepočítávalo při každém UPDATE, posunula by se částka i u akce,
  -- na kterou se jen sáhlo — a to na dokladu, který už mohl odejít.
  -- Nastavuje ho `zmen_typ_akce()`, jinde se nepoužívá.
  IF (TG_OP = 'INSERT'
      OR COALESCE(current_setting('app.preceneni', true), 'off') = 'on')
     AND NEW.rate_per_hour IS NULL THEN
    SELECT s.default_rate, s.type INTO _subject_rate, _subject_type
      FROM public.subjects s WHERE s.id = NEW.subject_id;
    SELECT * INTO _st FROM public.settings LIMIT 1;

    IF NEW.event_id IS NOT NULL THEN
      SELECT e.event_type INTO _event_type FROM public.events e WHERE e.id = NEW.event_id;
    END IF;

    -- PÁSMOVÝ CENÍK — jen pro KLUBY a jen když nemají vlastní sazbu.
    --
    -- Komerční zákazník má dál jednu sazbu (rozhodnutí PM: 5 000 Kč/h bez DPH),
    -- takže se pásem netýká. A `subjects.default_rate` má přednost před vším —
    -- individuálně dohodnutá cena je dohoda, ne ceník.
    IF _subject_type = 'club' AND _subject_rate IS NULL
       AND COALESCE(_event_type, 'training') <> 'commercial'
       AND COALESCE(_event_type, 'training') <> 'recruitment' THEN
      SELECT c.castka, c.rozpis INTO _cena, _rozpis
        FROM public.cena_ledu(NEW.start_at, NEW.end_at) c;

      NEW.cenove_pasma := _rozpis;
      NEW.amount       := _cena;
      NEW.hours        := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
      -- `rate_per_hour` je u pásmové ceny ODVOZENÝ PRŮMĚR, ne vstup. Autoritativní
      -- je `amount` a `cenove_pasma`; tohle číslo je do přehledů a na starý kód,
      -- který sazbu čte. Proto smí mít haléře — a proto se z něj částka NEPOČÍTÁ.
      NEW.rate_per_hour := round(_cena / NULLIF(NEW.hours, 0), 2);
      NEW.corrected_amount := CASE
        WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
        ELSE NULL END;
      RETURN NEW;
    END IF;

    -- Komerční zákazník se účtuje komerční sazbou i u turnaje/tréninku — jinak by
    -- firma jezdila za klubovou cenu jen proto, že se akce jmenuje „turnaj".
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
      -- akce bez vlastní sazby (např. údržba s fakturačním subjektem) → podle typu subjektu
      CASE _subject_type WHEN 'commercial' THEN _st.commercial_default_rate
                         ELSE _st.club_default_rate END
    );

    IF _rate IS NULL THEN
      RAISE EXCEPTION 'Sazba není nastavena — admin musí nejdřív vyplnit ceník (Nastavení) nebo sazbu subjektu';
    END IF;
    NEW.rate_per_hour := _rate;
  END IF;

  -- RUČNÍ SAZBA PŘEBÍJÍ PÁSMA.
  --
  -- Když admin u pásmové rezervace vědomě přepíše `rate_per_hour`, je to dohoda
  -- s klubem a má vyhrát. Bez tohohle by se `amount` NEPŘEPOČÍTALO (viz níž) a
  -- systém by vyfakturoval starou částku: sazba v UI 900 Kč/h, na faktuře
  -- pořád 3 400 Kč místo 2 700. Tichý rozdíl mezi zobrazenou a fakturovanou
  -- cenou je to nejhorší, co může peněžní vrstva udělat.
  --
  -- Rozpis se proto zahodí — přestal cenu popisovat — a dál se rezervace chová
  -- jako každá jiná s ruční sazbou, včetně pravidla o celých korunách.
  IF TG_OP = 'UPDATE' AND NEW.cenove_pasma IS NOT NULL
     AND NEW.rate_per_hour IS DISTINCT FROM OLD.rate_per_hour
     AND NEW.cenove_pasma IS NOT DISTINCT FROM OLD.cenove_pasma THEN
    NEW.cenove_pasma := NULL;
  END IF;

  -- PŘESUN NEBO PRODLOUŽENÍ PÁSMOVÉ REZERVACE JI PŘECENÍ.
  --
  -- Snapshot ceny platí pro ČAS, na který byl pořízený. Když rezervace 16–19
  -- (3 400 Kč) přejede na 9–12, je to ranní led za 2 400 Kč — držet dál starou
  -- částku znamená přeúčtovat klubu 1 000 Kč. A kdyby se změnila jen délka,
  -- rozešel by se rozpis s hodinami a doklad by se vůbec nedal vystavit
  -- (`mapping.ts` takovou rezervaci odmítne).
  --
  -- Přeceňuje se podle PLATNÉHO ceníku — na nový čas žádný jiný neexistuje.
  -- Je to táž úvaha jako u nepásmové rezervace, které se při změně délky taky
  -- přepočítá `amount`; jen tady je vstupem rozpis, ne sazba.
  IF TG_OP = 'UPDATE' AND NEW.cenove_pasma IS NOT NULL
     AND (NEW.start_at, NEW.end_at) IS DISTINCT FROM (OLD.start_at, OLD.end_at) THEN
    SELECT c.castka, c.rozpis INTO _cena, _rozpis
      FROM public.cena_ledu(NEW.start_at, NEW.end_at) c;

    NEW.cenove_pasma  := _rozpis;
    NEW.amount        := _cena;
    NEW.hours         := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    NEW.rate_per_hour := round(_cena / NULLIF(NEW.hours, 0), 2);
    NEW.corrected_amount := CASE
      WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
      ELSE NULL END;
    RETURN NEW;
  END IF;

  IF NEW.rate_per_hour IS NULL THEN
    RAISE EXCEPTION 'Sazba (rate_per_hour) nesmí zůstat prázdná';
  END IF;

  NEW.hours  := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);

  -- U PÁSMOVÉ CENY SE `amount` NEPŘEPOČÍTÁVÁ. `hodiny × rate_per_hour` by dalo
  -- jiné číslo než snapshot rozpisu (průměr je zaokrouhlený na haléře), takže
  -- by každý UPDATE rezervace tiše posunul částku — třeba jen o pár haléřů,
  -- ale na dokladu, který už mohl odejít.
  IF NEW.cenove_pasma IS NULL THEN
    NEW.amount := round(NEW.hours * NEW.rate_per_hour, 2);
  END IF;
  NEW.corrected_amount := CASE
    WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
    ELSE NULL END;

  RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 2) D — akce za nulu se nefakturuje
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturovatelne_rezervace(_subject_id uuid, _od timestamp with time zone, _do timestamp with time zone)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, invoice_id uuid, approved_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT r.id,
         r.start_at,
         r.end_at,
         sh.name,
         e.title,
         COALESCE(r.corrected_hours, r.hours)   AS hodiny,
         r.rate_per_hour                        AS sazba,
         COALESCE(r.corrected_amount, r.amount) AS castka,
         r.invoice_id,
         r.approved_at
    FROM public.reservations r
    JOIN public.sheets sh ON sh.id = r.sheet_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.status = 'confirmed'
     AND r.deleted_at IS NULL
     -- Bez subjektu není komu fakturovat: interní tréninky a údržba ledu.
     AND r.subject_id IS NOT NULL
     AND (_subject_id IS NULL OR r.subject_id = _subject_id)
     AND r.start_at >= _od
     AND r.start_at <  _do
     AND (r.approved_at IS NOT NULL
          OR NOT COALESCE((SELECT bs.invoice_only_approved FROM public.billing_settings bs LIMIT 1), true))
     -- AKCE ZA NULU SE NEFAKTURUJE. Doklad na 0 Kč nemá co říct: zákazník ho
     -- nezaplatí, účetní ho stejně vyhodí, a v číselné řadě zabere číslo.
     --
     -- Z „Kdo kolik dluží" se přitom NEVYŘAZUJE — tam má být vidět, že se led
     -- odehrál, jen zadarmo. Kontrolní součet to nerozbije: nulová rezervace
     -- přispěje do obou stran nulou.
     --
     -- ⚠️ VYNECHÁVÁ SE JEN CENA ZADARMO, NE NULOVÁ KOREKCE.
     --
     -- Rezervace za 0 Kč je záměr (ukázková hodina, protislužba). Kdežto
     -- `corrected_hours = 0` na jinak placené rezervaci znamená „nedorazili" —
     -- a to je rozhodnutí, které má člověk udělat vědomě. Na takový případ
     -- existuje od A5 guard, který fakturu zastaví a jmenuje termín; kdyby ji
     -- tenhle filtr vynechal, guard by se k ní nedostal a rezervace by z dokladu
     -- tiše zmizela. (Ověřeno: bez téhle výjimky padá `fakturace_test.sql`.)
     AND NOT (COALESCE(r.corrected_amount, r.amount, 0) = 0
              AND r.corrected_amount IS NULL)
   ORDER BY r.start_at, r.id;
$function$;

-- -----------------------------------------------------------------------------
-- 3) B — přidání a ubrání dráhy u existující akce
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.uprav_drahy_akce(
  _event_id  uuid,
  _sheet_ids uuid[]
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
      INSERT INTO public.reservations
        (sheet_id, subject_id, event_id, start_at, end_at, status,
         rate_per_hour, note, approved_at, approved_by)
      VALUES
        (_sheet, _vzor.subject_id, _event_id, _vzor.start_at, _vzor.end_at, _vzor.status,
         _vzor.rate_per_hour, _vzor.note, _vzor.approved_at, _vzor.approved_by);
      _pridano := _pridano + 1;
    END IF;
  END LOOP;

  PERFORM set_config('app.trusted_booking', 'off', true);

  IF NOT EXISTS (SELECT 1 FROM public.reservations
                  WHERE event_id = _event_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Akce by zůstala bez dráhy — na zrušení celé akce je storno.';
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
$$;

COMMENT ON FUNCTION public.uprav_drahy_akce(uuid, uuid[]) IS
  'Přidá nebo ubere dráhy u existující akce. Přidání = nová rezervace pod touž akcí se stejným časem, subjektem i SAZBOU (aby jedna akce neměla dvě ceny); ubrání = soft delete. Poslední dráhu ubrat nelze — na to je storno celé akce.';

REVOKE ALL ON FUNCTION public.uprav_drahy_akce(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.uprav_drahy_akce(uuid, uuid[]) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4) C — změna typu akce s přepočtem ceny
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.zmen_typ_akce(
  _event_id uuid,
  _typ      public.event_type
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _stary public.event_type; _zmeneno int;
BEGIN
  -- Typ akce hýbe cenou, takže ho mění jen správce haly — táž úvaha jako
  -- u sazby v `update_booking` a `uprav_sazbu_akce`.
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Typ akce může změnit jen správce haly.';
  END IF;

  SELECT event_type INTO _stary FROM public.events WHERE id = _event_id;
  IF _stary IS NULL THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  IF _stary = _typ THEN
    RETURN jsonb_build_object('zmena', false, 'typ', _typ);
  END IF;

  UPDATE public.events SET event_type = _typ WHERE id = _event_id;

  -- PŘEPOČET CENY. Sazba se vynuluje a `set_reservation_pricing` ji dopočítá
  -- podle NOVÉHO typu — pásma u klubového tréninku, komerční sazba u komerčky.
  -- `app.preceneni` je jediné místo, kde se snapshot smí přepsat.
  PERFORM set_config('app.preceneni', 'on', true);
  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET rate_per_hour = NULL, cenove_pasma = NULL
   WHERE event_id = _event_id AND deleted_at IS NULL;
  GET DIAGNOSTICS _zmeneno = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);
  PERFORM set_config('app.preceneni', 'off', true);

  RETURN jsonb_build_object(
    'zmena', true, 'typ', _typ, 'puvodni', _stary, 'preceneno', _zmeneno,
    'celkem', (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                 FROM public.reservations
                WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  WHEN check_violation OR not_null_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'Typ akce se nepodařilo změnit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'U nového typu možná chybí sazba v ceníku (Nastavení).';
END;
$$;

COMMENT ON FUNCTION public.zmen_typ_akce(uuid, public.event_type) IS
  'Změní typ akce a PŘEPOČÍTÁ cenu podle nového typu (klubový led → pásma, komerční → sazba z ceníku). Jediné místo, které smí přepsat cenový snapshot — přes app.preceneni. Jen admin, protože typ akce hýbe cenou.';

REVOKE ALL ON FUNCTION public.zmen_typ_akce(uuid, public.event_type) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.zmen_typ_akce(uuid, public.event_type) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5) Kontrola
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM 1 FROM pg_proc WHERE oid = 'public.uprav_drahy_akce(uuid, uuid[])'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'uprav_drahy_akce se nevytvořila.'; END IF;
  PERFORM 1 FROM pg_proc WHERE oid = 'public.zmen_typ_akce(uuid, public.event_type)'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'zmen_typ_akce se nevytvořila.'; END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.fakturovatelne_rezervace'::regproc)
     NOT LIKE '%r.corrected_amount IS NULL%' THEN
    RAISE EXCEPTION 'Filtr akcí zdarma ve fakturovatelne_rezervace chybí.';
  END IF;

  RAISE NOTICE 'Úprava akce: dráhy, typ i nulová sazba jsou na místě.';
END $$;
