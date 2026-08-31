-- =============================================================================
-- Úprava akce: co se nesmí stát po vystavení dokladu, a co po změně typu
-- Nálezy z brány (ultra review, 31. 8. 2026)
-- =============================================================================
-- ČTYŘI OPRAVY NAD TÍM, CO PŘIBYLO 31. 8.:
--
-- 1) MUST-FIX — přidat dráhu k pásmově oceněné klubové rezervaci NEŠLO.
--    `uprav_drahy_akce` kopírovala do nové dráhy `rate_per_hour`, což je
--    u pásmové ceny ODVOZENÝ PRŮMĚR s haléři (3 400 / 3 = 1 133,33). Na tom
--    padly obě pojistky na celé koruny — `check_reservation_money` i CHECK
--    `reservations_rate_per_hour_cele_koruny` — a chyba propadla surová,
--    protože `P0001` není v odchytávaném seznamu. Jednopásmová rezervace sice
--    prošla, ale nová dráha tiše přišla o `cenove_pasma`.
--
-- 2) Tři nové RPC (`uprav_sazbu_akce`, `zmen_typ_akce`, `uprav_drahy_akce`)
--    neznaly pojem „už vyfakturováno". Jedno kliknutí po odeslání dokladu
--    přepsalo částky, na které zní faktura.
--
-- 3) `zmen_typ_akce` uměla vyrobit KOMERČNÍ AKCI BEZ INSTRUKTORA — invariant,
--    který `create_booking` drží od Etapy 1 (požadavek klienta).
--
-- 4) `zmen_typ_akce` nechávala viset PLACENOU TRENÉRSKOU SMĚNU i poté, co
--    z tréninku udělala komerční akci. Dorovnání štábu ji sebrat neumí
--    (ruší jen `open`), takže hala platila trenéra za akci, která trenéry nemá.
--
-- -----------------------------------------------------------------------------
-- CO SE NEMĚNÍ
-- -----------------------------------------------------------------------------
-- Ceny ani jejich výpočet. `uprav_drahy_akce` u NEpásmové rezervace dál kopíruje
-- sazbu ze vzoru; mění se jen pásmová větev, kde se sazba dopočítá z ceníku na
-- tentýž čas — a hned se ověří, že vyšla stejná částka.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- tři funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef)
--   DROP FUNCTION IF EXISTS public.over_neni_vyfakturovano(uuid, text);
--   -- Zrušené trenérské směny revert nevrací (soft delete, zásada 2).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) „Už je to na dokladu" — jedna odpověď pro všechny tři cesty
--
-- Zamyká OBOJE: `reservations.invoice_id` (interní engine) i vazbu na
-- Fakturoid. Storno se nerozlišuje schválně — rezervace na stornovaném dokladu
-- drží zámek dál a rozplétá se dobropisem, ne přepsáním částky pod rukama.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.over_neni_vyfakturovano(_event_id uuid, _co text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _kolik int;
BEGIN
  SELECT count(*) INTO _kolik
    FROM public.reservations r
   WHERE r.event_id = _event_id
     AND r.deleted_at IS NULL
     AND (r.invoice_id IS NOT NULL
          OR EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations fr
                      WHERE fr.reservation_id = r.id));

  IF _kolik > 0 THEN
    RAISE EXCEPTION '% už měnit nejde — % z jejích rezervací je na vystaveném dokladu.', _co, _kolik
      USING HINT = 'Doklad nejdřív stornuj nebo dobropisuj; jinak by faktura zněla na jinou částku než rozvrh.';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.over_neni_vyfakturovano(uuid, text) IS
  'Zastaví úpravu akce, jejíž rezervace už jsou na dokladu (interním nebo z Fakturoidu). Bez téhle brány uměly uprav_sazbu_akce, zmen_typ_akce i uprav_drahy_akce jedním kliknutím rozejít vystavenou fakturu s „Kdo kolik dluží" — billing_reconcile to odhalí až potom.';

REVOKE ALL ON FUNCTION public.over_neni_vyfakturovano(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.over_neni_vyfakturovano(uuid, text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2) Dráhy: pásmová cena se dopočítá, vyfakturovaná akce se nepřeskládá
--
-- Tělo z `pg_get_functiondef` živého schématu (pravidlo 7); zásahy jsou tři —
-- brána, `NULL` místo průměrné sazby u pásmové rezervace, a kontrola, že
-- přidaná dráha vyšla stejně.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 3) Typ akce: brána, instruktor u komerčky, konec trenérské směny
--
-- Tělo z živého schématu; zásahy jsou brána, doplnění `role_reqs` a soft zrušení
-- trenérské směny při odchodu od tréninku.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.zmen_typ_akce(_event_id uuid, _typ event_type)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _stary public.event_type;
  _zmeneno int;
  _instruktoru int;
  _trener_zrusen int := 0;
  _doplnen_instruktor boolean := false;
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

  -- Vyfakturovanou akci nepřeceňuj — doklad by zůstal na staré částce.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Typ akce');

  -- TRENÉR PATŘÍ K TRÉNINKU, TAKŽE S NÍM ODCHÁZÍ — a odchází PRVNÍ.
  --
  -- `prirad_trenera` zakládá směnu rovnou jako `claimed`, aby ji dorovnání
  -- štábu nesebralo jako přebytek — jenže tím ji neumělo sebrat ani po změně
  -- typu akce. Hala tak platila trenéra za komerční akci a `stab_kontrola`
  -- hlásila „o směnu víc" napořád, protože rušit obsazené směny sama odmítá.
  --
  -- Ruší se PŘED zásahem do `events`, aby ji dorovnání štábu (trigger na
  -- `role_reqs`, `required_staff` i `event_type`) nestihlo ohlásit jako
  -- přebytek — jinak admin dostane WARNING o něčem, co se za dva řádky vyřeší
  -- samo. Ruší se SOFT (zásada 2); uzavřená směna se nesahá, je to podklad
  -- pro výplatu.
  IF _stary = 'training' AND _typ <> 'training' THEN
    UPDATE public.shifts
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     WHERE event_id = _event_id
       AND required_role = 'trainer'
       AND status NOT IN ('cancelled', 'completed');
    GET DIAGNOSTICS _trener_zrusen = ROW_COUNT;
  END IF;

  -- KOMERČNÍ AKCE POTŘEBUJE INSTRUKTORA (požadavek klienta).
  --
  -- `create_booking` to vynucuje od Etapy 1, tahle cesta ho obcházela: přepnutý
  -- trénink měl `role_reqs = '{}'`, takže `dorovnej_stab` neměl z čeho směnu
  -- udělat a v hale vznikla komerční akce bez štábu — a `stab_kontrola` na ni
  -- napořád svítila „chybí instruktor" bez čehokoli, co by to spravilo.
  --
  -- Nedoplňuje se odhad podle drah, ale MINIMUM, které pravidlo žádá: jeden.
  -- Kolik jich ve skutečnosti bude, ví admin a doplní to ve Správě směn.
  IF _typ IN ('commercial', 'recruitment') THEN
    SELECT COALESCE((role_reqs ->> 'instructor')::int, 0) INTO _instruktoru
      FROM public.events WHERE id = _event_id;
    IF _instruktoru < 1 THEN
      UPDATE public.events
         SET role_reqs = COALESCE(role_reqs, '{}'::jsonb) || jsonb_build_object('instructor', 1),
             required_staff = GREATEST(COALESCE(required_staff, 0), 1)
       WHERE id = _event_id;
      _doplnen_instruktor := true;
    END IF;
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
    -- Ať volající pozná, co se stalo kolem směn — obojí je vidět v UI.
    'trener_zrusen', _trener_zrusen,
    'doplnen_instruktor', _doplnen_instruktor,
    'celkem', (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                 FROM public.reservations
                WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  WHEN check_violation OR not_null_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'Typ akce se nepodařilo změnit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'U nového typu možná chybí sazba v ceníku (Nastavení).';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) Cena akce: brána
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.uprav_sazbu_akce(_event_id uuid, _sazba numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _zmeneno int;
  _drah    int;
  _hodin   numeric;
BEGIN
  -- Sazbu smí měnit jen admin — stejně jako v `update_booking`, kde je to
  -- `has_role(auth.uid(), 'admin') AND p_rate IS NOT NULL`.
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Cenu akce může měnit jen správce haly.';
  END IF;

  IF _sazba IS NULL OR _sazba < 0 THEN
    RAISE EXCEPTION 'Sazba musí být nezáporné číslo.';
  END IF;
  -- Kontrolu celých korun a stropu dělá `check_reservation_money` na každém
  -- řádku; tady se ptáme dřív, aby chyba mluvila o AKCI, ne o jedné rezervaci.
  IF _sazba <> round(_sazba) THEN
    RAISE EXCEPTION 'Sazba se zadává v celých korunách, bez haléřů (dostal jsem % Kč/h).', _sazba;
  END IF;
  IF _sazba > 50000 THEN
    RAISE EXCEPTION 'Sazba je nejvýš 50 000 Kč/h (dostal jsem % Kč/h). Vyšší číslo je skoro jistě překlep.', _sazba;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = _event_id) THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  -- PŘECENIT VYFAKTUROVANOU AKCI NEJDE. Doklad si drží staré částky, takže by
  -- se „Kdo kolik dluží" a vystavená faktura rozešly — a vypadalo by to jako
  -- vada fakturace, ne jako důsledek jednoho kliknutí. `billing_reconcile` to
  -- odhalí až POTOM; tohle tomu předchází.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Cena akce');

  PERFORM set_config('app.trusted_booking', 'on', true);

  -- CELÁ AKCE NARÁZ. `amount` dopočítá trigger `set_reservation_pricing`
  -- z nové sazby, takže se tu schválně nepíše — jinak by vznikla druhá,
  -- tišší cesta k částce.
  UPDATE public.reservations
     SET rate_per_hour = _sazba
   WHERE event_id = _event_id
     AND deleted_at IS NULL;
  GET DIAGNOSTICS _zmeneno = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);

  IF _zmeneno = 0 THEN
    RAISE EXCEPTION 'Akce nemá žádnou živou rezervaci, není co přecenit.';
  END IF;

  SELECT count(DISTINCT sheet_id), max(hours) INTO _drah, _hodin
    FROM public.reservations
   WHERE event_id = _event_id AND deleted_at IS NULL;

  RETURN jsonb_build_object(
    'rezervaci', _zmeneno,
    'drah',      _drah,
    'hodin',     _hodin,
    'sazba',     _sazba,
    'celkem',    (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                    FROM public.reservations
                   WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  -- Táž úvaha jako v `update_booking`: syrová chyba integrity nese v DETAILu
  -- celý řádek včetně sazby a částky, a PostgREST by ho poslal klientovi.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Cenu akce se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Sazba musí být v celých korunách a nejvýš 50 000 Kč/h.';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _f text;
BEGIN
  FOREACH _f IN ARRAY ARRAY['public.uprav_drahy_akce(uuid, uuid[])',
                            'public.zmen_typ_akce(uuid, public.event_type)',
                            'public.uprav_sazbu_akce(uuid, numeric)'] LOOP
    IF (SELECT prosrc FROM pg_proc WHERE oid = _f::regprocedure)
       NOT LIKE '%over_neni_vyfakturovano%' THEN
      RAISE EXCEPTION 'Brána „už je to na dokladu" chybí v %.', _f;
    END IF;
  END LOOP;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.zmen_typ_akce(uuid, public.event_type)'::regprocedure)
     NOT LIKE '%required_role = ''trainer''%' THEN
    RAISE EXCEPTION 'zmen_typ_akce neruší trenérskou směnu — hala by platila trenéra za komerční akci.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.uprav_drahy_akce(uuid, uuid[])'::regprocedure)
     NOT LIKE '%_vzor.cenove_pasma IS NULL%' THEN
    RAISE EXCEPTION 'uprav_drahy_akce pořád kopíruje průměrnou sazbu do nové dráhy.';
  END IF;

  RAISE NOTICE 'Úprava akce: doklad je chráněný, komerčka má instruktora a trenér s tréninkem odchází.';
END $kontrola$;
