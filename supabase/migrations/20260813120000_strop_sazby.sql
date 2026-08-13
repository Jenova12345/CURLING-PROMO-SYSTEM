-- =============================================================================
-- Strop sazby 50 000 Kč/h (drift 8g, rozhodnutí PM 13. 8. 2026)
-- =============================================================================
-- A5 dala `corrected_hours` tvrdý strop 24 h, aby z překlepu „9999" byl okamžitý
-- blok. Druhý činitel součinu `hodiny × sazba` ale zábranu neměl žádnou — ověřeno
-- před touhle migrací:
--
--   UPDATE reservations SET rate_per_hour = 99999999;
--   → amount 99999999.00 | corrected_amount 299999997.00
--
-- `hours` ohlídané je (`validate_reservation_slot`: celé hodiny, jeden den,
-- otevírací doba → nejvýš ~15 h), takže `rate_per_hour` byl JEDINÝ neomezený
-- peněžní vstup v systému. Překlep o řád v sazbě dělá tutéž fakturu na miliony
-- jako překlep v korekci, který A5 zavřela.
--
-- ZAVŘE TO I `NaN`, A TO NEBYLO ZÁMĚREM — ať to někdo při revertu nevrátí zpátky:
-- v Postgresu je `'NaN'::numeric >= 0` **true** a `'NaN' <> round('NaN')` **false**,
-- takže `NaN` prošla úplně všemi peněžními kontrolami z A2 i A5 a uložila by se
-- jako sazba (a `amount` by pak byl `NaN` u každého dopočtu). Chytí ji až
-- porovnání se stropem: `NaN > 50000` je true (trigger) a `NaN <= 50000` je
-- false (CHECK). Hlídá to vlastní tvrzení v testu.
--
-- HODNOTA STROPU JE PRODUKTOVÉ ROZHODNUTÍ, ne technikálie — proto ho A5 neudělala
-- sama a čekalo se na PM. Dnešní sazby jsou 600–1 500 Kč/h, takže 50 000 je
-- třicetinásobek nejdražší reálné sazby: na překlep o řád (15 000 by prošlo,
-- 150 000 ne) je to pořád síto, provozní rezervu to nechává velkorysou.
--
-- PROČ STROP I NA CENÍK A NA SAZBU SUBJEKTU, ne jen na `reservations`:
-- `rate_per_hour` se při INSERTu dopočítává z ceníku a ze sazby subjektu
-- (`trg_reservations_pricing`, booking_core.sql:395). Kdyby strop platil jen na
-- rezervaci, šlo by 99 999 999 uložit do ceníku — a rozbilo by se to až o krok
-- dál, na každé nové rezervaci, hláškou o sazbě, kterou nikdo nezadával. Strop
-- musí být tam, kde se hodnota zadává, ne jen tam, kde se projeví. Táž úvaha
-- vedla A2 k tomu, že celokorunovost dostaly všechny čtyři zdroje.
--
-- BEZPEČNOST MIGRACE (stejný postup jako A2):
--   1. Data se nejdřív ZKONTROLUJÍ a případný rozpor se OHLÁSÍ i s ukázkami.
--      Migrace ho záměrně NEOPRAVUJE — tiché přepsání peněžního údaje je horší
--      než zastavená migrace. Kdo uvidí hlášku, ví přesně, co má opravit.
--   2. Teprve pak se přidají CHECKy.
--
-- VRATNOST — revert je tenhle blok, žádná změna dat ani typů:
--   ALTER TABLE public.reservations DROP CONSTRAINT reservations_rate_per_hour_strop;
--   ALTER TABLE public.subjects     DROP CONSTRAINT subjects_default_rate_strop;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_club_rate_strop;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_commercial_rate_strop;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_tournament_rate_strop;
--   ALTER TABLE public.settings     DROP CONSTRAINT settings_training_rate_strop;
--   -- a `check_reservation_money` zpátky do znění z 20260812200000_security_hardening.sql
--
-- POŘADÍ NASAZENÍ (jako u A2): nejdřív oprav data, pak pusť migraci, teprve pak
-- frontend. Opačné pořadí znamená, že formulář odmítne sazbu, kterou databáze
-- ještě pouští — nebo hůř, naopak.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Kontrola stávajících dat — ohlásit, neopravovat
--
-- Predikáty tady MUSÍ být totožné s predikáty constraintů níž. Kdyby byly
-- volnější, předkontrola by řekla „data vyhovují" a rozpor by vyplaval až na
-- ADD CONSTRAINT — se syrovou hláškou Postgresu, která neuvede jediný řádek.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _rozpory text[] := ARRAY[]::text[];
  _pocet   bigint;
  _ukazky  text;
  _strop   constant numeric := 50000;
BEGIN
  -- Sazba na rezervaci
  SELECT count(*) INTO _pocet FROM public.reservations
   WHERE rate_per_hour IS NOT NULL AND rate_per_hour > _strop;
  IF _pocet > 0 THEN
    -- LIMIT patří JEN na ukázky. Kdyby byl i v počítaném dotazu, hlásilo by se
    -- napořád „5 záznamů" a operátor by opravoval po pěticích, dokolečka.
    SELECT string_agg(format('%s (%s Kč/h)', id, rate_per_hour), ', ' ORDER BY id) INTO _ukazky
      FROM (SELECT id, rate_per_hour FROM public.reservations
             WHERE rate_per_hour IS NOT NULL AND rate_per_hour > _strop
             ORDER BY id LIMIT 5) t;
    _rozpory := _rozpory || format('reservations.rate_per_hour nad stropem: %s záznamů, např. %s', _pocet, _ukazky);
  END IF;

  -- Sazba subjektu
  SELECT count(*) INTO _pocet FROM public.subjects
   WHERE default_rate IS NOT NULL AND default_rate > _strop;
  IF _pocet > 0 THEN
    SELECT string_agg(format('%s (%s Kč/h)', name, default_rate), ', ' ORDER BY name) INTO _ukazky
      FROM (SELECT name, default_rate FROM public.subjects
             WHERE default_rate IS NOT NULL AND default_rate > _strop
             ORDER BY name LIMIT 5) t;
    _rozpory := _rozpory || format('subjects.default_rate nad stropem: %s záznamů, např. %s', _pocet, _ukazky);
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
      IF _hodnota IS NOT NULL AND _hodnota > _strop THEN
        _rozpory := _rozpory || format('settings.%s je %s (strop je %s Kč/h)', _sloupec, _hodnota, _strop);
      END IF;
    END LOOP;
  END;

  IF array_length(_rozpory, 1) > 0 THEN
    RAISE EXCEPTION E'Migrace zastavena — data neodpovídají stropu sazby:\n  %',
      array_to_string(_rozpory, E'\n  ')
      USING HINT = 'Oprav uvedené sazby ručně (nejvýš 50 000 Kč/h) a migraci spusť znovu. '
                   'Migrace peněžní údaje záměrně nepřepisuje sama.';
  END IF;

  RAISE NOTICE 'Strop sazby: stávající data vyhovují, přidávám CHECKy.';
END $$;

-- -----------------------------------------------------------------------------
-- 2) CHECKy
--
-- `ADD CONSTRAINT` nemá `IF NOT EXISTS`, takže druhý běh by spadl na „constraint
-- already exists". Supabase migrace eviduje, takže to kousne jen při ručním
-- přeaplikování (a přesně to dělá `scripts/build-demo-sql.sh`) — spadnout na
-- tomhle je matoucí, ne poučné. Stejný tvar jako v A5.
--
-- Nulu ani NULL tenhle strop neřeší: obojí ošetřují CHECKy z A2 (nezápornost)
-- a význam NULL („spadni na ceník") zůstává beze změny.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reservations_rate_per_hour_strop') THEN
    ALTER TABLE public.reservations
      ADD CONSTRAINT reservations_rate_per_hour_strop
      CHECK (rate_per_hour IS NULL OR rate_per_hour <= 50000);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'subjects_default_rate_strop') THEN
    ALTER TABLE public.subjects
      ADD CONSTRAINT subjects_default_rate_strop
      CHECK (default_rate IS NULL OR default_rate <= 50000);
  END IF;

  -- Ceník: JEDEN CONSTRAINT NA SLOUPEC, ne jeden na celou tabulku — admin, který
  -- přepíše jedno pole ze čtyř, jinak dostane hlášku, ze které nepozná které.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'settings_club_rate_strop') THEN
    ALTER TABLE public.settings
      ADD CONSTRAINT settings_club_rate_strop
      CHECK (club_default_rate IS NULL OR club_default_rate <= 50000);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'settings_commercial_rate_strop') THEN
    ALTER TABLE public.settings
      ADD CONSTRAINT settings_commercial_rate_strop
      CHECK (commercial_default_rate IS NULL OR commercial_default_rate <= 50000);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'settings_tournament_rate_strop') THEN
    ALTER TABLE public.settings
      ADD CONSTRAINT settings_tournament_rate_strop
      CHECK (tournament_rate IS NULL OR tournament_rate <= 50000);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'settings_training_rate_strop') THEN
    ALTER TABLE public.settings
      ADD CONSTRAINT settings_training_rate_strop
      CHECK (training_rate IS NULL OR training_rate <= 50000);
  END IF;
END $$;

COMMENT ON CONSTRAINT reservations_rate_per_hour_strop ON public.reservations IS
  'Strop sazby 50 000 Kč/h (rozhodnutí PM 13. 8. 2026, drift 8g). Uzavírá poslední neomezený peněžní vstup — s korekcí hodin ≤ 24 h je tím ohraničený celý součin hodiny × sazba.';

-- -----------------------------------------------------------------------------
-- 3) Srozumitelná hláška místo syrového CHECKu
--
-- Tělo je vygenerované z `pg_get_functiondef` živého schématu (pravidlo 7
-- v CLAUDE.md) a vložená je do něj JEN nová větev se stropem — přepis z paměti
-- už jednou utnul půlku guardu (commit 87b1f78).
--
-- Pořadí kontrol u sazby zrcadlí pořadí u korekce hodin z A5:
-- záporná → strop → tvar hodnoty.
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
    IF NEW.rate_per_hour > 50000 THEN
      RAISE EXCEPTION 'Sazba je nejvýš 50 000 Kč/h (dostal jsem % Kč/h). Vyšší číslo je skoro jistě překlep.', NEW.rate_per_hour;
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
  'Srozumitelné české hlášky pro peněžní pravidla (A2 + A5: strop korekce 24 h a povinný důvod; + strop sazby 50 000 Kč/h). Záruku dávají CHECK constrainty, tenhle trigger jen mluví dřív — hlavně kvůli RPC.';
