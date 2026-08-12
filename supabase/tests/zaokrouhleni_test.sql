-- =============================================================================
-- TESTY ZAOKROUHLOVÁNÍ PENĚZ (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/zaokrouhleni_test.sql
-- Celý běh je v jedné transakci, která se na konci ROLLBACKuje → data zůstanou
-- jako po `supabase db reset`. Test projde, když skript doběhne bez chyby a vypíše
-- „VŠECHNY TESTY PROŠLY".
--
-- PROČ TENHLE SOUBOR EXISTUJE (Etapa 2, rozhodnutí R3):
-- Fakturace stojí na tom, že JS a Postgres zaokrouhlují STEJNĚ. `src/lib/money.ts`
-- to o sobě tvrdí, `src/lib/money.test.ts` to ověřuje na straně JS — ale referenční
-- sémantika je tady, v `numeric`. Tenhle skript ji přišpendlí, aby se dvojice
-- „JS říká X / DB říká X" nemohla tiše rozejít. Hodnoty v části 1 jsou schválně
-- TYTÉŽ jako v money.test.ts; když měníš jednu stranu, měň obě.
--
-- Pokrývá: sémantiku round() v numeric, invariant amount = round(hours × sazba, 2),
-- totéž po ruční korekci, dostupnost rate_per_hour ve fakturačním pohledu
-- a reprodukci nálezů N2 a N3 z docs/etapa2-fakturace-plan.md.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- POJISTKA: tenhle skript zapisuje do subjects a reservations. Spoléhá se, že
-- ho `ROLLBACK` na konci uklidí — což platí, dokud běží jako celek. Kdo z něj
-- ale zkopíruje jednotlivé DO bloky do Studia nebo do MCP `execute_sql`, dostane
-- autocommit a testovací kluby mu zůstanou v datech. Proto skript odmítne běžet
-- kdekoli, kde jsou jiní než seedoví uživatelé, tedy na čemkoli kromě lokálního
-- Dockeru.
-- Ověřuje se PŘÍTOMNOST seedových UUID, ne tvar e-mailu. Podmínka na e-mail
-- („žádný uživatel mimo @test.local") totiž selhává směrem k propuštění: projde
-- na prázdné tabulce i tam, kde se lidé přihlašují bez e-mailu (OAuth, telefon),
-- protože `NULL NOT LIKE …` je NULL. Takhle formulovaná pojistka naopak nepustí
-- nic, co seed nemá.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze. Test patří jen na lokální Docker Postgres.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.prihlas(_user uuid) RETURNS void
 LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', _user)::text, true);
$$;

-- Odhlášení = žádný `auth.uid()`. Přesně to vidí pg_cron i service_role.
CREATE OR REPLACE FUNCTION pg_temp.odhlas() RETURNS void
 LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', NULL, true);
$$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.rovno(_a numeric, _b numeric, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF _a IS DISTINCT FROM _b THEN
    RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem %, vyšlo %', _popis, _b, _a;
  END IF;
  RAISE NOTICE 'OK  % (%)', _popis, _a;
END $$;

-- Očekávaná chyba: tělo musí spadnout a hláška musí obsahovat úryvek.
-- Stejný pomocník jako v rezervace_test.sql; EXCEPTION blok si udělá savepoint,
-- takže se vnější transakce po zachycené chybě nerozbije.
CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale prošla', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cas(_text text) RETURNS timestamptz
 LANGUAGE sql IMMUTABLE AS $$ SELECT (_text::timestamp) AT TIME ZONE 'Europe/Prague'; $$;

CREATE OR REPLACE FUNCTION pg_temp.draha(_n int) RETURNS uuid
 LANGUAGE sql STABLE AS $$ SELECT id FROM public.sheets WHERE name = 'Dráha ' || _n; $$;

-- -----------------------------------------------------------------------------
-- 1) Referenční sémantika: jak zaokrouhluje numeric
--    Tyhle hodnoty musí dávat TOTÉŽ jako roundCzk / toSetiny v money.test.ts.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  -- Půlka NAHORU v absolutní hodnotě, ne k +∞. Tohle je celý důvod, proč
  -- money.ts nesmí použít holé Math.round: to dá pro -1250.5 hodnotu -1250.
  PERFORM pg_temp.rovno(round(1250.5), 1251, 'round(1250.5) = 1251');
  PERFORM pg_temp.rovno(round(-1250.5), -1251, 'round(-1250.5) = -1251');
  PERFORM pg_temp.rovno(round(0.5), 1, 'round(0.5) = 1');
  PERFORM pg_temp.rovno(round(-0.5), -1, 'round(-0.5) = -1');

  -- Přesná desetinná aritmetika: v double je 1.005 * 100 = 100.49999999999999,
  -- takže naivní JS zaokrouhlení dá 1,00 Kč. numeric žádný takový šum nemá.
  PERFORM pg_temp.rovno(round(1.005, 2), 1.01, 'round(1.005, 2) = 1.01');
  PERFORM pg_temp.rovno(round(-1.005, 2), -1.01, 'round(-1.005, 2) = -1.01');
  PERFORM pg_temp.rovno(round(0.145, 2), 0.15, 'round(0.145, 2) = 0.15');
  PERFORM pg_temp.rovno(round(12.505, 2), 12.51, 'round(12.505, 2) = 12.51');
  PERFORM pg_temp.rovno(round(-12.505, 2), -12.51, 'round(-12.505, 2) = -12.51');

  -- Záporná nula v numeric neexistuje; roundCzk ji proto taky nevrací.
  PERFORM pg_temp.rovno(round(-0.4), 0, 'round(-0.4) = 0, ne -0');

  -- KANONICKÉ PRAVIDLO R3: na celé koruny se zaokrouhluje STUPŇOVITĚ, tedy
  -- `round(round(v, 2), 0)`, NIKDY `round(v, 0)` ze surové hodnoty. Důvod je
  -- účetní: základ daně i vytištěný mezisoučet jsou dvoudesetinné, a částka
  -- k úhradě se musí odvíjet od toho, co je na dokladu, ne od abstraktní hodnoty.
  -- Na 0,495 je rozdíl vidět — a právě takhle to počítá i `roundCzk` v JS.
  PERFORM pg_temp.rovno(round(round(0.495, 2), 0), 1, 'stupňovitě: 0,495 → 0,50 → 1 Kč');
  PERFORM pg_temp.rovno(round(round(-0.495, 2), 0), -1, 'stupňovitě: -0,495 → -0,50 → -1 Kč');
  PERFORM pg_temp.rovno(round(round(2.495, 2), 0), 3, 'stupňovitě: 2,495 → 2,50 → 3 Kč');

  -- A doložení, že na směru opravdu záleží: jednorázová varianta dá jinak.
  PERFORM pg_temp.rovno(round(0.495, 0), 0, 'jednorázově by 0,495 dalo 0 Kč — proto se pravidlo píše nahlas');
  PERFORM pg_temp.tvrd(round(round(2.495, 2), 0) <> round(2.495, 0),
    'stupňovitá a jednorázová cesta se liší (jinak by pravidlo nic neurčovalo)');

  -- Běžné směry pod a nad půlkou
  PERFORM pg_temp.rovno(round(2.49), 2, 'round(2.49) = 2');
  PERFORM pg_temp.rovno(round(2.51), 3, 'round(2.51) = 3');
  PERFORM pg_temp.rovno(round(-2.51), -3, 'round(-2.51) = -3');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Invariant, na kterém stojí celá fakturace:
--       amount           = round(hours × rate_per_hour, 2)
--       corrected_amount = round(corrected_hours × rate_per_hour, 2)
--    Kdyby neplatil, nesmí `Dues.tsx` brát rate_per_hour místo dopočtu z částky
--    (oprava nálezu N3) — tištěný řádek by pak nedal tištěnou cenu.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _spatne int;
BEGIN
  SELECT count(*) INTO _spatne
    FROM public.reservations r
   WHERE r.subject_id IS NOT NULL
     AND r.deleted_at IS NULL
     AND r.amount IS DISTINCT FROM round(r.hours * r.rate_per_hour, 2);
  PERFORM pg_temp.tvrd(_spatne = 0,
    format('amount = round(hours × sazba, 2) platí pro všechny rezervace (rozporů: %s)', _spatne));

  SELECT count(*) INTO _spatne
    FROM public.reservations r
   WHERE r.corrected_hours IS NOT NULL
     AND r.deleted_at IS NULL
     AND r.corrected_amount IS DISTINCT FROM round(r.corrected_hours * r.rate_per_hour, 2);
  PERFORM pg_temp.tvrd(_spatne = 0,
    format('corrected_amount = round(corrected_hours × sazba, 2) (rozporů: %s)', _spatne));
END $$;

-- -----------------------------------------------------------------------------
-- 3) Nález N2 od zdroje: tři rezervace po ošklivé sazbě
--    Sazba 1 250,50 Kč/h × 1 h × 3 rezervace. Přesný součet je 3 751,50 Kč.
--    Před opravou: obrazovka ukázala 3 752 Kč (zaokrouhlen až součet), podklad
--    k fakturaci 3 753 Kč (sečteny zaokrouhlené řádky). Rozdíl 1 Kč na ničem.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _subjekt uuid;
  _presny  numeric;
  _po_radcich numeric;
  _radku   int;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');  -- admin

  -- POZOR na vývoj fixtury: dřív tu stála sazba 1 250,50 Kč/h. Od migrace
  -- 20260812120000 (A2) je celokorunová sazba vynucená CHECKem, takže by takový
  -- subjekt vůbec nešel založit. Haléře se do součtu dostávají čtvrthodinovou
  -- korekcí, což je jediná cesta, která po A2 zbyla — a je to zároveň realističtější.
  INSERT INTO public.subjects (type, name, ico, default_rate)
    VALUES ('club', 'Zaokrouhlovací klub', '00000199', 1251)
    RETURNING id INTO _subjekt;

  -- Tři hodinové rezervace na tři různé dny, ať se nepobijí na dráze.
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, status)
  SELECT pg_temp.draha(1), _subjekt,
         pg_temp.cas('2030-03-0' || d || ' 10:00'),
         pg_temp.cas('2030-03-0' || d || ' 11:00'),
         'confirmed'
    FROM generate_series(1, 3) AS d;

  -- Korekce na čtvrthodinu: 0,25 h × 1 251 Kč = 312,75 Kč na řádek.
  UPDATE public.reservations
     SET corrected_hours = 0.25, correction_reason = 'test zaokrouhlení'
   WHERE subject_id = _subjekt;

  SELECT count(*), sum(corrected_amount), sum(round(corrected_amount, 0))
    INTO _radku, _presny, _po_radcich
    FROM public.reservations WHERE subject_id = _subjekt;

  PERFORM pg_temp.rovno(_radku, 3, 'vznikly tři rezervace');
  PERFORM pg_temp.rovno(_presny, 938.25, 'přesný součet je 938,25 Kč');
  PERFORM pg_temp.rovno(round(round(_presny, 2), 0), 938, 'stupňovité zaokrouhlení až u částky k úhradě dá 938 Kč');

  -- A takhle vypadala chyba: zaokrouhlit každý řádek zvlášť a pak teprve sečíst.
  PERFORM pg_temp.rovno(_po_radcich, 939, 'sečtené zaokrouhlené řádky dají 939 Kč — nález N2');
  PERFORM pg_temp.tvrd(round(round(_presny, 2), 0) <> _po_radcich,
    'obě politiky se opravdu liší (jinak by test nic nehlídal)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Nález N3: sazba se BERE, nedopočítává
--    Dopočet `částka / hodiny` a jeho tisk na celé koruny dal řádek
--    „Sazba 1 251 Kč × 2 h = 2 501 Kč", který si neodpovídá sám se sebou.
--
--    Po migraci A2 (celokorunové sazby) je tenhle nález z REÁLNÝCH DAT
--    nedosažitelný — proto se dělí na dvě části: aritmetika na literálech drží
--    důvod, proč pravidlo existuje, a část (b) ověřuje, že constraint tu třídu
--    chyby opravdu odřízl.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _subjekt   uuid;
  _rezervace uuid;
  _sazba     numeric;
  _hodiny    numeric;
  _castka    numeric;
BEGIN
  -- (a) Proč pravidlo vzniklo — na literálech, ne na datech.
  --     Sazba 1 250,50 Kč/h × 2 h = 2 501 Kč. Dopočtená a zaokrouhlená sazba
  --     (2 501 / 2 = 1 250,50 → tisklo se 1 251) po vynásobení dvěma dá 2 502.
  PERFORM pg_temp.rovno(round(2501.00 / 2, 0) * 2, 2502,
    'dopočtená a zaokrouhlená sazba by dala 2 502 Kč místo 2 501 — nález N3');

  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');

  -- (b) Táž situace z reálných dat po A2. Sazba musí být celokorunová.
  INSERT INTO public.subjects (type, name, ico, default_rate)
    VALUES ('club', 'Klub s haléři', '00000198', 1251)
    RETURNING id INTO _subjekt;

  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, status)
    VALUES (pg_temp.draha(2), _subjekt,
            pg_temp.cas('2030-03-05 10:00'), pg_temp.cas('2030-03-05 12:00'), 'confirmed')
    RETURNING id INTO _rezervace;

  SELECT rate_per_hour, hours, amount INTO _sazba, _hodiny, _castka
    FROM public.reservations WHERE id = _rezervace;

  PERFORM pg_temp.rovno(_sazba, 1251, 'snapshot sazby je 1 251 Kč/h');
  PERFORM pg_temp.rovno(_hodiny, 2, 'rezervace má 2 hodiny');
  PERFORM pg_temp.rovno(_castka, 2502.00, 'částka je 2 502 Kč');

  -- Tisknutá sazba × tisknuté hodiny musí dát tisknutou částku.
  PERFORM pg_temp.rovno(round(_sazba * _hodiny, 2), _castka,
    'sazba × hodiny === částka (tištěný řádek sedí sám se sebou)');

  -- Po ruční korekci na čtvrthodinu musí sazba pořád sedět.
  UPDATE public.reservations
     SET corrected_hours = 1.25, correction_reason = 'test zaokrouhlení'
   WHERE id = _rezervace;

  SELECT corrected_amount, rate_per_hour INTO _castka, _sazba
    FROM public.reservations WHERE id = _rezervace;
  PERFORM pg_temp.rovno(_castka, 1563.75, 'po korekci na 1,25 h je částka 1 563,75 Kč');
  PERFORM pg_temp.rovno(round(1.25 * _sazba, 2), _castka,
    'sazba sedí i po korekci — dopočet z částky není potřeba');
END $$;

-- -----------------------------------------------------------------------------
-- 4b) A2 odřízla celou třídu chyby N3
--     Při celokorunové sazbě a čtvrthodinách je `hodiny × sazba` PŘESNÝ součin,
--     takže dopočet `částka / hodiny` vrátí přesně `rate_per_hour`. Není to už
--     jen opravené v zobrazovacím kódu — z dat to nejde vyrobit.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rozpory int; _zkoumanych int;
BEGIN
  SELECT count(*) FILTER (WHERE round(COALESCE(r.corrected_amount, r.amount) / COALESCE(r.corrected_hours, r.hours), 2)
                                IS DISTINCT FROM r.rate_per_hour),
         count(*)
    INTO _rozpory, _zkoumanych
    FROM public.reservations r
   WHERE r.rate_per_hour IS NOT NULL
     AND r.deleted_at IS NULL
     AND COALESCE(r.corrected_hours, r.hours) > 0;

  -- Bez tohohle tvrzení by test prošel i tehdy, kdyby se nepodíval na jediný
  -- řádek — a „nic jsem nenašel" by vypadalo jako „všechno je v pořádku".
  PERFORM pg_temp.tvrd(_zkoumanych > 0,
    format('je co zkoumat: %s rezervací se sazbou', _zkoumanych));
  PERFORM pg_temp.tvrd(_rozpory = 0,
    format('dopočet částka/hodiny vrací přesně rate_per_hour u všech rezervací (rozporů: %s)', _rozpory));
END $$;

-- -----------------------------------------------------------------------------
-- 4c) CHECKy z migrace A2 opravdu drží
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');

  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.subjects (type, name, ico, default_rate)
       VALUES ('club', 'Sazba s haléři', '00000197', 1250.50)$q$,
    'subjects_default_rate_cele_koruny', 'sazba subjektu s haléři je odmítnuta');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.settings SET club_default_rate = 600.50$q$,
    'settings_club_rate_cele_koruny', 'ceník s haléři je odmítnut (hláška ukáže na konkrétní sloupec)');

  -- U rezervací mluví dřív trigger (viz 4d), takže se tady ověřuje ZÁRUKA:
  -- že constrainty existují a že drží i bez triggeru. Trigger je jen hlas,
  -- constraint je zámek — a test musí umět rozeznat, který z nich zabral.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM pg_constraint WHERE conname IN (
       'reservations_corrected_hours_nezaporne', 'reservations_corrected_hours_ctvrthodiny',
       'reservations_rate_per_hour_cele_koruny', 'subjects_default_rate_cele_koruny',
       'settings_club_rate_cele_koruny', 'settings_commercial_rate_cele_koruny',
       'settings_tournament_rate_cele_koruny', 'settings_training_rate_cele_koruny')) = 8,
    'všech 8 CHECK constraintů z A2 je na místě');

  -- Vypneme hlas a ověříme, že zámek drží sám o sobě.
  ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_z_money;

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.reservations SET corrected_hours = -1, correction_reason = 'x'
        WHERE id = (SELECT id FROM public.reservations WHERE deleted_at IS NULL ORDER BY id LIMIT 1)$q$,
    'reservations_corrected_hours_nezaporne', 'bez triggeru drží CHECK: záporná korekce');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.reservations SET corrected_hours = 1.1, correction_reason = 'x'
        WHERE id = (SELECT id FROM public.reservations WHERE deleted_at IS NULL ORDER BY id LIMIT 1)$q$,
    'reservations_corrected_hours_ctvrthodiny', 'bez triggeru drží CHECK: korekce mimo čtvrthodiny');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.reservations SET rate_per_hour = 1250.50
        WHERE id = (SELECT id FROM public.reservations WHERE deleted_at IS NULL ORDER BY id LIMIT 1)$q$,
    'reservations_rate_per_hour_cele_koruny', 'bez triggeru drží CHECK: sazba s haléři');

  ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_z_money;

  -- Nula constraintem projde (viz komentář v migraci — není to promyšlená funkce
  -- „zdarma", jen tvar podmínky; formuláře ji nepouštějí).
  --
  -- Schválně se to NEOVĚŘUJE na `settings`. Ta je singleton a UPDATE nad ní by
  -- ve scénáři, před kterým varuje hlavička souboru (někdo zkopíruje DO blok do
  -- Studia a dostane autocommit), tiše přepsal ceník — všechna tvrzení by hlásila
  -- OK a cena ledu by byla jiná. Odhoditelný subjekt má týž constraint a po
  -- zneužití po sobě nechá viditelný nepořádek, ne změněnou cenu.
  DECLARE _zdarma uuid;
  BEGIN
    INSERT INTO public.subjects (type, name, ico, default_rate)
      VALUES ('club', 'Klub zdarma', '00000196', 0)
      RETURNING id INTO _zdarma;
    PERFORM pg_temp.tvrd(
      (SELECT default_rate FROM public.subjects WHERE id = _zdarma) = 0,
      'nulová sazba projde constraintem (databáze je podlaha, ne strop)');
  END;
END $$;

-- -----------------------------------------------------------------------------
-- 4d) Srozumitelná hláška místo syrového CHECKu
--     Trigger trg_reservations_z_money musí promluvit dřív než constraint —
--     jinak dostane admin volající RPC hlášku v jazyce Postgresu, a s ní
--     (uvnitř SECURITY DEFINER funkce, kde neplatí RLS) i celý obsah řádku
--     včetně sazby a částky.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r uuid;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  SELECT id INTO _r FROM public.reservations WHERE deleted_at IS NULL ORDER BY id LIMIT 1;

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET rate_per_hour = 1250.50 WHERE id = %L', _r),
    'v celých korunách', 'sazba s haléři: česká hláška, ne jméno constraintu');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET rate_per_hour = -5 WHERE id = %L', _r),
    'nesmí být záporná', 'záporná sazba: česká hláška');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 1.1, correction_reason = %L WHERE id = %L', 'x', _r),
    'po čtvrthodinách', 'korekce mimo čtvrthodiny: česká hláška');

  -- A hlavně: hláška nesmí obsahovat výpis řádku, kterým Postgres doprovází
  -- porušení CHECKu („Failing row contains …“).
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET rate_per_hour = 1250.50 WHERE id = %L', _r),
    'Kč/h', 'hláška uvádí jen zadanou hodnotu, ne celý řádek');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Fakturační pohled musí sazbu vůbec vydat
--    `useDues` ji od A1 vybírá ze `reservations_billing`; kdyby ve view chyběla,
--    spadne celý přehled „Kdo kolik dluží".
-- -----------------------------------------------------------------------------
DO $$
DECLARE _radku int; _bez_sazby int;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'reservations_billing'
               AND column_name = 'rate_per_hour'),
    'reservations_billing vydává sloupec rate_per_hour');

  SELECT count(*), count(*) FILTER (WHERE rate_per_hour IS NULL)
    INTO _radku, _bez_sazby FROM public.reservations_billing;

  PERFORM pg_temp.tvrd(_radku > 0, format('pohled vrací adminovi řádky (%s)', _radku));
  PERFORM pg_temp.tvrd(_bez_sazby = 0,
    format('žádný fakturovatelný řádek nemá prázdnou sazbu (prázdných: %s)', _bez_sazby));
END $$;

-- -----------------------------------------------------------------------------
-- 5b) NÁLEZ N4 přišpendlený v kódu, ne jen v plánu
--     `reservations_billing` končí na `has_role(auth.uid(), 'admin')`. Bez
--     přihlášeného uživatele (pg_cron, service_role) je `auth.uid()` NULL,
--     takže view vrátí NULA řádků — a fakturační běh postavený nad ním by tiše
--     nevystavil nic, ohlásil úspěch a kontrolní součet by seděl 0 == 0.
--     Test to schválně tvrdí jako ŽÁDOUCÍ stav view (je adminské záměrně)
--     a tím drží připomínku, že běh MUSÍ číst základní tabulky.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _pres_view int; _pres_tabulku int;
BEGIN
  PERFORM pg_temp.odhlas();

  SELECT count(*) INTO _pres_view FROM public.reservations_billing;
  SELECT count(*) INTO _pres_tabulku
    FROM public.reservations WHERE status = 'confirmed' AND deleted_at IS NULL;

  PERFORM pg_temp.tvrd(_pres_tabulku > 0,
    format('základní tabulka má potvrzené rezervace (%s)', _pres_tabulku));
  PERFORM pg_temp.tvrd(_pres_view = 0,
    format('bez přihlášení vrátí reservations_billing nulu — nález N4 (vrátil %s)', _pres_view));
END $$;

-- -----------------------------------------------------------------------------
-- 6) Kontrolní součet nanečisto: rozdělení na dva doklady nesmí změnit celek
--    Malá verze akceptačního kritéria Etapy 2. Přesné částky se sčítat smí,
--    zaokrouhlené (částky k úhradě) NE — proto se kontrolní součet dělá nad
--    `total`, ne nad `total_rounded` (rozhodnutí R3).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _celkem numeric;
  _doklad1 numeric;
  _doklad2 numeric;
  _k_uhrade numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');

  SELECT sum(COALESCE(corrected_amount, amount)) INTO _celkem
    FROM public.reservations_billing;

  SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0) INTO _doklad1
    FROM public.reservations_billing WHERE subject_type = 'club';
  SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0) INTO _doklad2
    FROM public.reservations_billing WHERE subject_type <> 'club';

  PERFORM pg_temp.rovno(_doklad1 + _doklad2, _celkem,
    'přesné součty dokladů dají přesný součet zdroje');

  -- Kanonická forma i tady: vstupy jsou sice dvoudesetinné, ale test je vzor,
  -- který si budoucí SQL implementace opíše.
  SELECT round(round(_doklad1, 2), 0) + round(round(_doklad2, 2), 0) INTO _k_uhrade;
  PERFORM pg_temp.tvrd(abs(_k_uhrade - _celkem) <= 1,
    format('součet ČÁSTEK K ÚHRADĚ se od zdroje smí lišit, ale jen o zaokrouhlení (%s vs %s)',
           _k_uhrade, _celkem));
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
