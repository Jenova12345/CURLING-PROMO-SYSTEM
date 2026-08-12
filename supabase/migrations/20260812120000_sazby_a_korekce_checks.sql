-- =============================================================================
-- A2 — Zpevnění zdroje peněžních dat (Etapa 2, rozhodnutí R3 „navíc u zdroje")
-- =============================================================================
-- Kanonické pravidlo zaokrouhlení (R3) je poslední obrana, ne první. Levnější je
-- nepustit do systému hodnoty, kvůli kterým by zaokrouhlení vůbec muselo něco
-- rozhodovat:
--
--   • sazby v CELÝCH KORUNÁCH — ceník i sazba subjektu i snapshot na rezervaci,
--   • ruční korekce hodin NEZÁPORNÉ a na ČTVRTHODINY.
--
-- Vedlejší efekt, kvůli kterému to stojí za to: `amount = round(hodiny × sazba, 2)`
-- je vždy PŘESNÝ součin, takže dopočet `amount / hodiny` dá zpátky přesně
-- `rate_per_hour`. Nález N3 z docs/etapa2-fakturace-plan.md (tištěná sazba nesedí
-- na tištěný řádek) tím přestává být dosažitelný z dat, ne jen opravený
-- v zobrazovacím kódu.
--
-- POZOR, co přesně to drží: nosná je CELOKORUNOVÁ SAZBA plus to, že hodiny jsou
-- `numeric(6,2)` — celé číslo krát dvoudesetinné má nejvýš dvě desetinná místa.
-- Čtvrthodinové pravidlo na tom NEMÁ podíl (změřeno: 0,33 h × 1 251 Kč dá přesný
-- součin taky). Čtvrthodiny jsou byznys pravidlo, ne pojistka proti zaokrouhlení —
-- kdyby někdo příště povolil sazbu 1 250,50 s tím, že „čtvrthodiny to podrží",
-- N3 se vrátí.
--
-- BEZPEČNOST MIGRACE:
--   1. Nejdřív se data ZKONTROLUJÍ a případný rozpor se OHLÁSÍ i s ukázkami.
--      Migrace ho záměrně NEOPRAVUJE — tiché přepsání peněžního údaje je horší
--      než zastavená migrace. Kdo uvidí hlášku, ví přesně, co má opravit ručně.
--   2. Teprve pak se přidají CHECKy.
--
-- POZOR NA ZÁMKY — a na to, co tady NEDĚLÁME:
-- Nabízí se dvoukrokové `ADD CONSTRAINT … NOT VALID` + `VALIDATE CONSTRAINT`,
-- aby dlouhá validace nedržela `ACCESS EXCLUSIVE`. V JEDNOM SOUBORU to ale nic
-- nezískává: migrace běží v jediné transakci, takže `ACCESS EXCLUSIVE` vzatý
-- prvním krokem se drží až do commitu (změřeno v pg_locks). Rozdělit by to šlo
-- jen na dvě samostatné migrace — a to je pro tabulky s desítkami řádků
-- zbytečná složitost. Až některá z nich naroste, tohle je místo, kde se to má
-- rozdělit; do té doby platí přímé `ADD CONSTRAINT`.
--
-- VRATNOST — revert je tenhle blok, žádná změna dat ani typů:
--   ALTER TABLE public.reservations DROP CONSTRAINT reservations_corrected_hours_nezaporne;
--   ALTER TABLE public.reservations DROP CONSTRAINT reservations_corrected_hours_ctvrthodiny;
--   ALTER TABLE public.reservations DROP CONSTRAINT reservations_rate_per_hour_cele_koruny;
--   ALTER TABLE public.subjects     DROP CONSTRAINT subjects_default_rate_cele_koruny;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_club_rate_cele_koruny;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_commercial_rate_cele_koruny;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_tournament_rate_cele_koruny;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_training_rate_cele_koruny;
--
-- POŘADÍ NASAZENÍ (netriviální, Netlify deployuje frontend automaticky z GitHubu,
-- kdežto migrace se pouští ručně): nejdřív oprav data, pak pusť migraci, teprve
-- pak frontend. Opačné pořadí znamená, že formulář odmítne haléřovou sazbu, kterou
-- adminovi sám předvyplnil z ceníku — a bude to vypadat nahodile.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Kontrola stávajících dat — ohlásit, neopravovat
--
-- Predikáty tady MUSÍ být totožné s predikáty constraintů níž. Kdyby byly
-- volnější, předkontrola by řekla „data vyhovují" a rozpor by vyplaval až na
-- ADD CONSTRAINT — se syrovou hláškou Postgresu, která neuvede jediný řádek.
-- Operátor by dostal rozbitou migraci a žádné vodítko, tedy přesně to, čemu má
-- tenhle blok předejít. Proto se testuje `< 0 OR <> round(x)`, ne jen půlka.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _rozpory text[] := ARRAY[]::text[];
  _pocet   bigint;
  _ukazky  text;
BEGIN
  -- Korekce hodin: záporné
  SELECT count(*) INTO _pocet FROM public.reservations
   WHERE corrected_hours IS NOT NULL AND corrected_hours < 0;
  IF _pocet > 0 THEN
    -- LIMIT patří JEN na ukázky. Kdyby byl i v počítaném dotazu, hlásilo by se
    -- napořád „5 záznamů" a operátor by opravoval po pěticích, dokolečka.
    SELECT string_agg(format('%s (%s h)', id, corrected_hours), ', ' ORDER BY id) INTO _ukazky
      FROM (SELECT id, corrected_hours FROM public.reservations
             WHERE corrected_hours IS NOT NULL AND corrected_hours < 0
             ORDER BY id LIMIT 5) t;
    _rozpory := _rozpory || format('reservations.corrected_hours < 0: %s záznamů, např. %s', _pocet, _ukazky);
  END IF;

  -- Korekce hodin: mimo čtvrthodiny
  SELECT count(*) INTO _pocet FROM public.reservations
   WHERE corrected_hours IS NOT NULL AND corrected_hours * 4 <> round(corrected_hours * 4);
  IF _pocet > 0 THEN
    SELECT string_agg(format('%s (%s h)', id, corrected_hours), ', ' ORDER BY id) INTO _ukazky
      FROM (SELECT id, corrected_hours FROM public.reservations
             WHERE corrected_hours IS NOT NULL AND corrected_hours * 4 <> round(corrected_hours * 4)
             ORDER BY id LIMIT 5) t;
    _rozpory := _rozpory || format('reservations.corrected_hours mimo čtvrthodiny: %s záznamů, např. %s', _pocet, _ukazky);
  END IF;

  -- Sazba na rezervaci: záporná nebo s haléři
  SELECT count(*) INTO _pocet FROM public.reservations
   WHERE rate_per_hour IS NOT NULL AND (rate_per_hour < 0 OR rate_per_hour <> round(rate_per_hour));
  IF _pocet > 0 THEN
    SELECT string_agg(format('%s (%s Kč/h)', id, rate_per_hour), ', ' ORDER BY id) INTO _ukazky
      FROM (SELECT id, rate_per_hour FROM public.reservations
             WHERE rate_per_hour IS NOT NULL AND (rate_per_hour < 0 OR rate_per_hour <> round(rate_per_hour))
             ORDER BY id LIMIT 5) t;
    _rozpory := _rozpory || format('reservations.rate_per_hour záporná nebo s haléři: %s záznamů, např. %s', _pocet, _ukazky);
  END IF;

  -- Sazba subjektu: záporná nebo s haléři
  SELECT count(*) INTO _pocet FROM public.subjects
   WHERE default_rate IS NOT NULL AND (default_rate < 0 OR default_rate <> round(default_rate));
  IF _pocet > 0 THEN
    SELECT string_agg(format('%s (%s Kč/h)', name, default_rate), ', ' ORDER BY name) INTO _ukazky
      FROM (SELECT name, default_rate FROM public.subjects
             WHERE default_rate IS NOT NULL AND (default_rate < 0 OR default_rate <> round(default_rate))
             ORDER BY name LIMIT 5) t;
    _rozpory := _rozpory || format('subjects.default_rate záporná nebo s haléři: %s záznamů, např. %s', _pocet, _ukazky);
  END IF;

  -- Ceník: každý sloupec zvlášť, ať hláška ukáže na konkrétní pole
  DECLARE
    _sloupec text;
    _hodnota numeric;
  BEGIN
    FOR _sloupec IN SELECT unnest(ARRAY['club_default_rate', 'commercial_default_rate',
                                        'tournament_rate', 'training_rate'])
    LOOP
      EXECUTE format('SELECT %I FROM public.settings LIMIT 1', _sloupec) INTO _hodnota;
      IF _hodnota IS NOT NULL AND (_hodnota < 0 OR _hodnota <> round(_hodnota)) THEN
        _rozpory := _rozpory || format('settings.%s je %s (musí být celé koruny, nezáporné)', _sloupec, _hodnota);
      END IF;
    END LOOP;
  END;

  IF array_length(_rozpory, 1) > 0 THEN
    RAISE EXCEPTION E'Migrace zastavena — data neodpovídají novým pravidlům:\n  %',
      array_to_string(_rozpory, E'\n  ')
      USING HINT = 'Oprav uvedené záznamy ručně (sazby na celé koruny a nezáporné, korekce na čtvrthodiny) '
                   'a migraci spusť znovu. Migrace peněžní údaje záměrně nepřepisuje sama.';
  END IF;

  RAISE NOTICE 'A2: stávající data vyhovují, přidávám CHECKy.';
END $$;

-- Druhý běh migrace by jinak spadl na „constraint already exists", což je matoucí.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'subjects_default_rate_cele_koruny') THEN
    RAISE EXCEPTION 'Migrace A2 už na téhle databázi proběhla (constrainty existují).'
      USING HINT = 'Není co dělat. Pokud ji chceš pustit znovu, nejdřív constrainty zahoď (revert je v hlavičce souboru).';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) CHECKy
-- -----------------------------------------------------------------------------

-- Korekce hodin. Dvě samostatná omezení schválně: hláška pak rovnou řekne,
-- které z obou pravidel bylo porušeno.
ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_corrected_hours_nezaporne
  CHECK (corrected_hours IS NULL OR corrected_hours >= 0);

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_corrected_hours_ctvrthodiny
  CHECK (corrected_hours IS NULL OR corrected_hours * 4 = round(corrected_hours * 4));

-- Sazby v celých korunách, nezáporné.
--
-- K NULE, ať to není matoucí: constraint ji pouští, formuláře ne. Není to
-- promyšlená funkce „zdarma" — je to jen tvar podmínky. Rozdíl přitom význam má:
-- `default_rate = NULL` znamená „spadni na ceník", `= 0` znamená „zdarma"
-- (viz COALESCE v pricing triggeru, booking_core.sql:395). Dokud formuláře nulu
-- nepouštějí, je „zdarma" dosažitelné jen přes SQL. Jestli to má být skutečná
-- funkce, je to produktové rozhodnutí — ne něco, co si tady doplníme sami.
ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_rate_per_hour_cele_koruny
  CHECK (rate_per_hour IS NULL OR (rate_per_hour >= 0 AND rate_per_hour = round(rate_per_hour)));

ALTER TABLE public.subjects
  ADD CONSTRAINT subjects_default_rate_cele_koruny
  CHECK (default_rate IS NULL OR (default_rate >= 0 AND default_rate = round(default_rate)));

-- Ceník: JEDEN CONSTRAINT NA SLOUPEC, ne jeden na celou tabulku. Kdyby byly
-- slité, admin, který přepíše jedno pole ze čtyř, dostane
-- „violates check constraint settings_sazby_cele_koruny" a bude hádat které.
ALTER TABLE public.settings
  ADD CONSTRAINT settings_club_rate_cele_koruny
  CHECK (club_default_rate IS NULL OR (club_default_rate >= 0 AND club_default_rate = round(club_default_rate)));

ALTER TABLE public.settings
  ADD CONSTRAINT settings_commercial_rate_cele_koruny
  CHECK (commercial_default_rate IS NULL OR (commercial_default_rate >= 0 AND commercial_default_rate = round(commercial_default_rate)));

ALTER TABLE public.settings
  ADD CONSTRAINT settings_tournament_rate_cele_koruny
  CHECK (tournament_rate IS NULL OR (tournament_rate >= 0 AND tournament_rate = round(tournament_rate)));

ALTER TABLE public.settings
  ADD CONSTRAINT settings_training_rate_cele_koruny
  CHECK (training_rate IS NULL OR (training_rate >= 0 AND training_rate = round(training_rate)));
-- POZNÁMKA K TOMU, CO CONSTRAINT NEDĚLÁ: `numeric(10,2)` vstup zaokrouhlí DŘÍV,
-- než se CHECK vyhodnotí. `1250.999` se tedy uloží jako `1251.00` a projde,
-- kdežto `1250.504` skončí chybou. Uložená hodnota je vždy celokorunová — jen
-- databáze u některých vstupů tiše opraví místo aby odmítla. Přísnější je
-- `parseSazba` na vstupu (odmítne obojí), a to je správné pořadí obran.
COMMENT ON CONSTRAINT reservations_rate_per_hour_cele_koruny ON public.reservations IS
  'Sazby v celých korunách (R3, „navíc u zdroje"). Se čtvrthodinovými korekcemi je pak amount přesný součin a dopočet amount/hodiny vrátí přesně rate_per_hour — nález N3 se tím stává nedosažitelným z dat.';

-- -----------------------------------------------------------------------------
-- 3) Srozumitelná hláška místo syrového CHECKu
--
-- Constrainty výš jsou záruka, ale mluví jazykem Postgresu:
--   „new row for relation "reservations" violates check constraint
--    reservations_rate_per_hour_cele_koruny"
-- Formuláře tohle nikdy neuvidí (`parseSazba` je zachytí dřív), jenže RPC
-- `create_booking` / `create_booking_series` / `update_booking` berou `p_rate`
-- bez validace a volat je může každý přihlášený admin. Hranice API má mluvit
-- česky, stejně jako sousední kontroly („Rezervovat jde jen na celé hodiny").
--
-- Trigger schválně NEnahrazuje constrainty — jen mluví dřív. Kdyby se jeho
-- podmínka někdy rozešla s constraintem, data pořád chrání constraint;
-- shodu obou hlídá supabase/tests/zaokrouhleni_test.sql.
--
-- Jméno `z_money` je kvůli pořadí: triggery se spouštějí abecedně a tenhle musí
-- běžet AŽ ZA `trg_reservations_pricing`, který sazbu teprve dopočítá z ceníku.
-- -----------------------------------------------------------------------------
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
    IF NEW.corrected_hours * 4 <> round(NEW.corrected_hours * 4) THEN
      RAISE EXCEPTION 'Korekce hodin jde jen po čtvrthodinách (0,25 / 0,50 / 0,75 …), dostal jsem % h.', NEW.corrected_hours;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reservations_z_money ON public.reservations;
CREATE TRIGGER trg_reservations_z_money
  BEFORE INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.check_reservation_money();

COMMENT ON FUNCTION public.check_reservation_money() IS
  'Srozumitelná česká hláška pro peněžní pravidla A2. Záruku dávají CHECK constrainty, tenhle trigger jen mluví dřív — hlavně kvůli RPC s p_rate.';
