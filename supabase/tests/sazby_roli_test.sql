-- =============================================================================
-- TESTY CENÍKU ROLÍ A SNAPSHOTU SAZBY DO SMĚNY (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/sazby_roli_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE:
-- Ceník rolí (`sazby_roli`, rozhodnutí PM R9) stojí na jednom křehkém detailu:
-- `shifts.hourly_rate` NESMÍ MÍT DEFAULT. S defaultem je `NEW.hourly_rate` při
-- INSERTu vždy vyplněné, trigger `set_shift_rate` tedy vždy odejde první větví
-- a ceník se neuplatní nikdy — přitom všechno vypadá zapojeně: tabulka je,
-- trigger je, sazby v ní jsou. Vrátit default zpátky je jednořádková migrace,
-- kterou při čtení nikdo nezastaví. Proto se to testuje, ne jen komentuje.
--
-- Druhá věc, kterou test drží, je SNAPSHOT: změna ceníku nesmí přepočítat
-- směny, které už vznikly. To je totéž pravidlo, na kterém stojí
-- `reservations.rate_per_hour` — a u peněz, které už někdo dostal, je to
-- jediná obhajitelná varianta.
--
-- POUČENÍ Z ETAPY 2 (a z CLAUDE.md, bod 8): tvrzení o PRÁVECH se musí testovat
-- pod skutečnou rolí `authenticated`. Jako `postgres` projde všechno, protože
-- obchází granty i RLS — dvakrát to takhle propustilo blokér.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Pojistka: jen lokální seed databáze (tenhle test zapisuje).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze. Test patří jen na lokální Docker Postgres.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

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

-- Akce, na kterou se v testu věší směny. Vlastní, ne ze seedu: test nemá
-- záviset na tom, kolik směn seed zrovna vyrábí.
CREATE OR REPLACE FUNCTION pg_temp.testovaci_akce() RETURNS uuid
 LANGUAGE sql STABLE AS $$
  SELECT id FROM public.events WHERE title = 'TEST sazby_roli' LIMIT 1;
$$;

INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs)
VALUES ('TEST sazby_roli', 'commercial',
        '2026-09-01 10:00+02', '2026-09-01 12:00+02', 0, '{}'::jsonb);

-- -----------------------------------------------------------------------------
-- 1) Sazby od PM sedí
--
-- Čtou se HODNOTY, ne default sloupce (na rozdíl od billing_settings): tyhle
-- řádky vkládá migrace a admin je smí změnit. Test proto běží na čerstvé
-- lokální databázi, kde je zdrojem pravdy migrace — a celý soubor končí
-- ROLLBACKem, takže po sobě nic nenechá.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record;
BEGIN
  FOR _r IN
    SELECT * FROM (VALUES
      ('trainer',         600, 'Trenér'),
      ('instructor',      250, 'Instruktor'),
      ('bar_staff',       200, 'Obsluha baru'),
      ('manager',         200, 'Provozní hospoda'),
      ('part_time_staff', 150, 'Brigádník')
    ) AS t(role, sazba, popis)
  LOOP
    PERFORM pg_temp.tvrd(
      EXISTS (SELECT 1 FROM public.sazby_roli z
               WHERE z.role = _r.role::public.app_role
                 AND z.sazba = _r.sazba
                 AND z.popis = _r.popis),
      format('ceník: %s = %s Kč/h (%s)', _r.role, _r.sazba, _r.popis));
  END LOOP;

  -- Role, které směny nedělají, v ceníku schválně NEJSOU. Kdyby tam někdo
  -- doplnil `hobby_player`, znamenalo by to, že hráči klubu se něco vyplácí —
  -- to je produktové rozhodnutí, ne úklid v datech.
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.sazby_roli
                 WHERE role IN ('admin','pro_player','hobby_player')),
    'ceník neobsahuje role, které dnes směny nedělají');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Peněžní zábrany na ceníku
--
-- Strop 10 000 je TÝŽ, jaký hlídá `validate_shift_claim` na směně. Kdyby ceník
-- pustil víc, uložila by se sazba, kterou pak směna odmítne — a hláška by
-- mluvila o směně, do které to nikdo nezadával.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET sazba = 0 WHERE role = 'trainer'$q$,
    'sazby_roli_sazba', 'nulová sazba odmítnuta');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET sazba = -100 WHERE role = 'trainer'$q$,
    'sazby_roli_sazba', 'záporná sazba odmítnuta');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET sazba = 10001 WHERE role = 'trainer'$q$,
    'sazby_roli_sazba', 'sazba nad stropem 10 000 odmítnuta');

  -- NaN projde úplně všemi „je to kladné číslo" kontrolami: v Postgresu je
  -- `'NaN'::numeric > 0` TRUE. Chytí ji až porovnání se stropem, protože
  -- `NaN <= 10000` je FALSE. Tohle tvrzení tu je proto, aby to revert nevrátil.
  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET sazba = 'NaN'::numeric WHERE role = 'trainer'$q$,
    'sazby_roli_sazba', 'NaN jako sazba odmítnut (zavírá ho až horní mez)');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET sazba = 250.50 WHERE role = 'trainer'$q$,
    'sazby_roli_cele', 'haléřová sazba odmítnuta (vyplácí se v celých korunách)');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET popis = '   ' WHERE role = 'trainer'$q$,
    'sazby_roli_popis', 'prázdný popisek odmítnut (formulář by ukázal bezejmenný řádek)');

  -- A co projít MÁ.
  UPDATE public.sazby_roli SET sazba = 10000 WHERE role = 'trainer';
  PERFORM pg_temp.tvrd(
    (SELECT sazba FROM public.sazby_roli WHERE role = 'trainer') = 10000,
    'sazba přesně na stropu projde');
  UPDATE public.sazby_roli SET sazba = 600 WHERE role = 'trainer';

  -- Strop je na TŘECH místech a musí být všude stejný: tady v CHECKu,
  -- v `validate_shift_claim` a v `SAZBA_SMENY_STROP` (src/lib/money.ts).
  -- Kdyby se rozešly, formulář pustí sazbu, kterou databáze odmítne syrovou
  -- hláškou o constraintu — přesně ten druh rozporu, který v Etapě 2 vznikl
  -- mezi `iban_je_platny` a `overIban`. Tady se hlídají dva z těch tří;
  -- třetí (JS) drží protějšek v money.test.ts.
  PERFORM pg_temp.tvrd(
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conname = 'sazby_roli_sazba') LIKE '%10000%',
    'CHECK ceníku drží strop 10 000 (musí sedět se SAZBA_SMENY_STROP v money.ts)');
  PERFORM pg_temp.tvrd(
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conname = 'shifts_hourly_rate_rozsah') LIKE '%10000%',
    'a CHECK na směně drží totéž číslo');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Ceník je UZAVŘENÝ SEZNAM — nemaže se ani pod postgres
--
-- Guard je trigger, ne jen chybějící grant: `service_role` má BYPASSRLS a plná
-- práva, takže by mu granty nezabránily v ničem. A TRUNCATE řádkové BEFORE
-- DELETE triggery vůbec nespouští — proto ta statement-level varianta.
-- Tenhle blok běží jako `postgres`, což je právě ten nejsilnější případ.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$DELETE FROM public.sazby_roli WHERE role = 'trainer'$q$,
    'uzavřený seznam', 'DELETE neprojde ani jako postgres');

  PERFORM pg_temp.ocekavej_chybu(
    $q$TRUNCATE public.sazby_roli$q$,
    'uzavřený seznam', 'TRUNCATE neprojde ani jako postgres');

  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.sazby_roli) = 5,
    'ceník po pokusech o smazání pořád stojí');

  -- A ani PŘEPSAT roli nejde. `authenticated` to nesvede přes sloupcový GRANT
  -- (`role` v něm není), ale `service_role` granty ani RLS neřeší — pro ni je
  -- jedinou zábranou guard. Rozpojilo by to řádek od jeho historie v audit_log
  -- a potichu vyrobilo ceníkovou položku pro roli, o které nikdo nerozhodl.
  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.sazby_roli SET role = 'admin' WHERE role = 'trainer'$q$,
    'nepřepisuje', 'přepsání role v ceníku neprojde ani jako postgres');

  -- Ale běžná změna sazby projít MUSÍ — guard nesmí zavřít i to, kvůli čemu
  -- tabulka vznikla.
  UPDATE public.sazby_roli SET sazba = 601 WHERE role = 'trainer';
  PERFORM pg_temp.tvrd((SELECT sazba FROM public.sazby_roli WHERE role = 'trainer') = 601,
    'guard na roli nezavřel běžnou změnu sazby');
  UPDATE public.sazby_roli SET sazba = 600 WHERE role = 'trainer';
END $$;

-- -----------------------------------------------------------------------------
-- 4) `shifts.hourly_rate` NESMÍ MÍT DEFAULT
--
-- Tohle je nejdůležitější tvrzení celého souboru — viz hlavička. Kdyby default
-- byl zpátky, všechny testy níž by pořád procházely (sazby by seděly, protože
-- by se braly z defaultu 150… až na to, že by nesouhlasily), ale ceník by byl
-- mrtvý kód. Ptáme se katalogu, ne chování.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _default text; _nullable text;
BEGIN
  SELECT column_default, is_nullable INTO _default, _nullable
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'shifts' AND column_name = 'hourly_rate';

  PERFORM pg_temp.tvrd(_default IS NULL,
    format('shifts.hourly_rate nemá DEFAULT (jinak by se ceník neuplatnil nikdy; nalezeno: %s)',
           COALESCE(_default, '—')));
  PERFORM pg_temp.tvrd(_nullable = 'NO',
    'shifts.hourly_rate je NOT NULL (prázdná sazba se v useShifts tiše počítá jako 150)');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Dopočet sazby z ceníku a ruční přepsání
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _sazba numeric;
BEGIN
  -- 5a) Role z ceníku → sazba z ceníku
  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (pg_temp.testovaci_akce(), 'open', 'trainer')
  RETURNING id, hourly_rate INTO _id, _sazba;
  PERFORM pg_temp.tvrd(_sazba = 600, 'směna trenéra dostala 600 Kč/h z ceníku');

  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (pg_temp.testovaci_akce(), 'open', 'instructor')
  RETURNING hourly_rate INTO _sazba;
  PERFORM pg_temp.tvrd(_sazba = 250, 'směna instruktora dostala 250 Kč/h z ceníku');

  -- 5b) RUČNÍ SAZBA MÁ PŘEDNOST a nikdy se nepřepisuje. To je celá podstata
  --     „ručně přepsatelné" z R9 — a taky důvod, proč sloupec nesmí mít DEFAULT.
  INSERT INTO public.shifts (event_id, status, required_role, hourly_rate)
  VALUES (pg_temp.testovaci_akce(), 'open', 'trainer', 999)
  RETURNING hourly_rate INTO _sazba;
  PERFORM pg_temp.tvrd(_sazba = 999, 'ručně zadaná sazba přebije ceník');

  -- Zvlášť ta, která se ceníkové hodnotě náhodou rovná: kdyby se rozhodovalo
  -- podle „liší se od ceníku", tenhle případ by prošel omylem.
  INSERT INTO public.shifts (event_id, status, required_role, hourly_rate)
  VALUES (pg_temp.testovaci_akce(), 'open', 'trainer', 600)
  RETURNING hourly_rate INTO _sazba;
  PERFORM pg_temp.tvrd(_sazba = 600, 'ručně zadaná sazba shodná s ceníkem projde beze změny');

  -- 5c) Směna BEZ role (starší cesta přes events.required_staff) → záložních 150,
  --     tedy táž hodnota, jakou měl dosud default sloupce. Pro tyhle směny se
  --     tímhle nemění nic.
  INSERT INTO public.shifts (event_id, status)
  VALUES (pg_temp.testovaci_akce(), 'open')
  RETURNING hourly_rate INTO _sazba;
  PERFORM pg_temp.tvrd(_sazba = 150, 'směna bez role dostala záložních 150 Kč/h');

  -- 5d) Role, která v ceníku není. Dnes to nastat nemá (ceník je uzavřený),
  --     ale kdyby do `app_role` přibyla placená hodnota a nikdo ji do ceníku
  --     nedal, nesmí to být tiché — funkce na to píše WARNING.
  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (pg_temp.testovaci_akce(), 'open', 'pro_player')
  RETURNING hourly_rate INTO _sazba;
  PERFORM pg_temp.tvrd(_sazba = 150, 'role mimo ceník spadne na záložních 150 Kč/h');
END $$;

-- -----------------------------------------------------------------------------
-- 6) SNAPSHOT: změna ceníku nepřepočítá směny, které už vznikly
--
-- Tohle je táž zásada jako u `reservations.rate_per_hour`. Kdyby ji někdo
-- „opravil" na dohledávání sazby při výplatě, úprava ceníku by tiše přepsala
-- historii výplat — včetně těch už proplacených.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _stara uuid; _nova uuid;
BEGIN
  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (pg_temp.testovaci_akce(), 'open', 'bar_staff')
  RETURNING id INTO _stara;
  PERFORM pg_temp.tvrd((SELECT hourly_rate FROM public.shifts WHERE id = _stara) = 200,
    'směna baru vznikla se 200 Kč/h');

  UPDATE public.sazby_roli SET sazba = 275 WHERE role = 'bar_staff';

  PERFORM pg_temp.tvrd((SELECT hourly_rate FROM public.shifts WHERE id = _stara) = 200,
    'SNAPSHOT: zdražení ceníku nepřepsalo už vzniklou směnu');

  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (pg_temp.testovaci_akce(), 'open', 'bar_staff')
  RETURNING id INTO _nova;
  PERFORM pg_temp.tvrd((SELECT hourly_rate FROM public.shifts WHERE id = _nova) = 275,
    'nová směna po zdražení dostala novou sazbu');

  UPDATE public.sazby_roli SET sazba = 200 WHERE role = 'bar_staff';
END $$;

-- -----------------------------------------------------------------------------
-- 7) Rozsah sazby platí i na INSERT
--
-- Dosud ho hlídal jen trigger `validate_shift_claim`, a ten běží POUZE NA
-- UPDATE. INSERT tedy neměl zábranu žádnou: sazba 99 999 999 se dala vložit
-- rovnou a projevila by se až ve výplatě.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.shifts (event_id, status, hourly_rate)
              VALUES ('%s', 'open', 99999999)$q$, pg_temp.testovaci_akce()),
    'shifts_hourly_rate_rozsah', 'sazba nad stropem neprojde ani při INSERTu');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.shifts (event_id, status, hourly_rate)
              VALUES ('%s', 'open', 0)$q$, pg_temp.testovaci_akce()),
    'shifts_hourly_rate_rozsah', 'nulová sazba neprojde ani při INSERTu');

  -- Vymazat sazbu hotové směně má skončit chybou, ne tichým doplněním:
  -- `useShifts.ts` počítá `hours_worked * (hourly_rate || 150)`, takže prázdná
  -- sazba u trenéra je 450 Kč/h v neprospěch člověka, kterému se to vyplácí.
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET hourly_rate = NULL
               WHERE event_id = '%s'$q$, pg_temp.testovaci_akce()),
    'null value in column "hourly_rate"', 'vymazání sazby u směny skončí chybou');
END $$;

-- -----------------------------------------------------------------------------
-- 8) Auditní stopa
--
-- Požadavek zákazníka zní „musí být vidět, kdo co zadával". U ceníku, ze
-- kterého se počítají výplaty, to platí dvojnásob. `write_audit_log` by tady
-- spadl (tabulka nemá sloupec `id`), takže má vlastní variantu — a ta se musí
-- otestovat, jinak by se na chybějící audit přišlo až při reklamaci výplaty.
-- -----------------------------------------------------------------------------
--
-- Pozn. k hledání toho jednoho řádku: `changed_at` je `now()`, tedy čas ZAČÁTKU
-- TRANSAKCE — všechny auditní řádky z tohohle testu ho mají identický a řadit
-- podle něj „ten poslední" nedává nic. Hledá se proto podle obsahu.
-- Claim se nastavuje schválně: bez něj je `auth.uid()` NULL a tvrzení o tom,
-- KDO změnu udělal, by nešlo napsat smysluplně. Požadavek zákazníka zní
-- „musí být vidět, kdo co zadával" — samotné CO je jen půlka.
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

DO $$
DECLARE _pred int; _po int;
BEGIN
  SELECT count(*) INTO _pred FROM public.audit_log WHERE table_name = 'sazby_roli';
  UPDATE public.sazby_roli SET sazba = 610 WHERE role = 'trainer';
  SELECT count(*) INTO _po FROM public.audit_log WHERE table_name = 'sazby_roli';
  PERFORM pg_temp.tvrd(_po = _pred + 1, 'změna sazby se zapsala do audit_log');

  PERFORM pg_temp.tvrd(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE table_name = 'sazby_roli' AND action = 'update'
       AND new_data ->> 'role' = 'trainer'
       AND (new_data ->> 'sazba')::numeric = 610
       AND (old_data ->> 'sazba')::numeric = 600),
    'audit drží roli, starou i novou sazbu (record_id je NULL — tabulka nemá sloupec id)');

  PERFORM pg_temp.tvrd(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE table_name = 'sazby_roli' AND action = 'update'
       AND new_data ->> 'role' = 'trainer'
       AND (new_data ->> 'sazba')::numeric = 610
       AND changed_by = '11111111-1111-1111-1111-111111111111'),
    'audit drží i KDO změnu udělal — bez toho je požadavek „kdo co zadával" splněný jen z půlky');

  PERFORM pg_temp.tvrd(
    (SELECT updated_by FROM public.sazby_roli WHERE role = 'trainer')
      = '11111111-1111-1111-1111-111111111111',
    'a razítko updated_by na řádku ceníku sedí na téhož člověka');

  UPDATE public.sazby_roli SET sazba = 600 WHERE role = 'trainer';
END $$;

-- -----------------------------------------------------------------------------
-- 9) PRÁVA — pod skutečnou rolí `authenticated`
--
-- Jako `postgres` projde všechno (obchází granty i RLS), takže by test tvrdil
-- zavřeno o dveřích, vedle kterých je otevřené okno. Dvakrát to takhle
-- propustilo blokér — viz CLAUDE.md, bod 8.
-- -----------------------------------------------------------------------------
DO $$ BEGIN RAISE NOTICE '--- pod rolí authenticated ---'; END $$;

-- 9a) Admin ceník vidí i uloží
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.sazby_roli;
  PERFORM pg_temp.tvrd(_radku = 5, 'admin (role authenticated): ceník vidí celý');

  UPDATE public.sazby_roli SET sazba = 640 WHERE role = 'trainer';
  PERFORM pg_temp.tvrd(
    (SELECT sazba FROM public.sazby_roli WHERE role = 'trainer') = 640,
    'admin (role authenticated): sazbu uloží');
  UPDATE public.sazby_roli SET sazba = 600 WHERE role = 'trainer';
END $$;

-- 9b) Člen ceník NEVIDÍ a NEZMĚNÍ
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
DECLARE _radku int; _po numeric;
BEGIN
  SELECT count(*) INTO _radku FROM public.sazby_roli;
  PERFORM pg_temp.tvrd(_radku = 0,
    'člen (role authenticated): ceník nevidí — je to mzdový přehled celé haly');

  UPDATE public.sazby_roli SET sazba = 1 WHERE role = 'trainer';

  RESET ROLE;                       -- na odečet skutečné hodnoty
  SELECT sazba INTO _po FROM public.sazby_roli WHERE role = 'trainer';
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.tvrd(_po = 600,
    'člen (role authenticated): sazbu nepřepíše (RLS zahodí 0 řádků)');
END $$;

-- 9c) Brigádník ceník taky nevidí — sazbu, která se ho týká, má na SVÉ směně
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.sazby_roli;
  PERFORM pg_temp.tvrd(_radku = 0,
    'brigádník (role authenticated): ceník nevidí (svou sazbu má na směně)');
END $$;

-- 9d) Ani admin nemá INSERT a DELETE — ceník je uzavřený seznam
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.sazby_roli (role, sazba, popis, poradi)
       VALUES ('hobby_player', 100, 'Hráč klubu', 9)$q$,
    'permission denied', 'admin (role authenticated): novou roli do ceníku nepřidá — je to migrace');

  PERFORM pg_temp.ocekavej_chybu(
    $q$DELETE FROM public.sazby_roli WHERE role = 'trainer'$q$,
    'permission denied', 'admin (role authenticated): řádek ceníku nesmaže');
END $$;

-- 9e) Dopočet sazby musí projít i uživateli, který do ceníku NEVIDÍ.
--
-- Tohle je test na přesně ten blokér, kvůli kterému musel být pricing trigger
-- u rezervací přepnutý na SECURITY DEFINER: rezervaci (a tím i směny) zakládá
-- běžný člen, a směna přitom musí dostat sazbu z tabulky, do které ten člen
-- nevidí. Kdyby byl `set_shift_rate` SECURITY INVOKER, spadlo by to na
-- „permission denied for table sazby_roli" — tedy na zakládání rezervací.
DO $$
DECLARE _sazba numeric;
BEGIN
  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (pg_temp.testovaci_akce(), 'open', 'instructor')
  RETURNING hourly_rate INTO _sazba;
  PERFORM pg_temp.tvrd(_sazba = 250,
    'admin (role authenticated): směna dostane sazbu z ceníku');
END $$;

-- Zbytek 9e se ptá katalogu, ne chování — a je potřeba říct proč.
--
-- Živá cesta, kde by směnu zakládal někdo BEZ přístupu do ceníku, dnes
-- neexistuje: komerční akci smí zadat jen admin (`create_booking` to odmítne
-- hláškou „Komerční akci a údržbu ledu zadává jen správce haly.") a klubová
-- rezervace dostane `role_reqs = '{}'`, takže žádné směny nevyrábí. Test to
-- níž ověřuje, ať to tvrzení nestojí na komentáři.
--
-- Přesto MUSÍ být `set_shift_rate` SECURITY DEFINER. Kdyby byl INVOKER, první
-- rozšíření (trenér ke tréninku podle R7, potvrzovací dialog, cokoli, co pustí
-- ke směnám zástupce klubu) by spadlo na „permission denied for table
-- sazby_roli" — tedy na zakládání rezervací, což je to nejhorší možné místo.
-- Přesně tohle se v Etapě 2 stalo `set_reservation_pricing` a stálo to blokér.
DO $$
DECLARE _definer boolean; _path text[];
BEGIN
  SELECT p.prosecdef, p.proconfig INTO _definer, _path
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'set_shift_rate';

  PERFORM pg_temp.tvrd(_definer,
    'set_shift_rate je SECURITY DEFINER (jinak dopočet spadne každému, kdo do ceníku nevidí)');
  PERFORM pg_temp.tvrd(_path @> ARRAY['search_path=public'],
    'set_shift_rate má přišpendlený search_path (SECURITY DEFINER bez něj je díra)');

  -- A NIKDO ji nesmí volat napřímo. Postgres dává EXECUTE roli PUBLIC
  -- automaticky; u SECURITY DEFINER funkce v schématu vystaveném přes PostgREST
  -- je to zbytečně široké. Trigger na EXECUTE nekouká — právo se ověřuje při
  -- CREATE TRIGGER, ne při každém spuštění. Že to platí, dokazují testy výš:
  -- směny sazbu dostávají.
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.set_shift_rate()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.set_shift_rate()', 'EXECUTE'),
    'set_shift_rate nejde zavolat zvenčí (EXECUTE odebrané anon i authenticated)');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.guard_sazby_roli_delete()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.write_audit_log_sazby_roli()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.guard_sazby_roli_role()', 'EXECUTE'),
    'ani guardy a auditní funkce ceníku nejdou zavolat zvenčí');

  -- SECURITY DEFINER bez přišpendleného search_path je díra; u ostatních funkcí
  -- téhle migrace to platí taky, i když guardy DEFINER nejsou (hygiena + advisor).
  PERFORM pg_temp.tvrd((SELECT bool_and(p.proconfig @> ARRAY['search_path=public'])
                          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                         WHERE n.nspname = 'public'
                           AND p.proname IN ('write_audit_log_sazby_roli',
                                             'guard_sazby_roli_delete',
                                             'guard_sazby_roli_role')),
    'všechny funkce ceníku mají přišpendlený search_path');
END $$;

SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
DECLARE _akce uuid; _smen int;
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$SELECT public.create_booking(
         ARRAY[(SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1)],
         'commercial', 'TEST člen zkouší komerčku', '2026-09-02 10:00+02', '2026-09-02 11:00+02',
         NULL, NULL, '{"instructor": 1}'::jsonb)$q$,
    'jen správce haly', 'člen (role authenticated): komerční akci nezaloží, takže dnes směny nevyrábí');

  -- A co člen SMÍ: klubový trénink. `create_booking` mu `role_reqs` zahodí,
  -- takže žádná směna nevznikne.
  --
  -- POZOR, CO TOHLE TVRZENÍ NEŘÍKÁ: platí jen pro RPC `create_booking`.
  -- `useEvents.updateEvent` píše do `events` napřímo přes PostgREST a tuhle
  -- zábranu obchází — dřív tudy šlo přepnout akci na trénink a nechat jí
  -- placené směny. Zavírá to od 27. 8. podmínka na `event_type` přímo
  -- v `dorovnej_stab` (testuje ji dorovnani_stabu_test.sql, kapitola 6).
  -- Původní znění téhle poznámky tvrdilo, že tím drží „žádná živá cesta",
  -- a to byla nepravda: certifikovalo to jako bezpečné něco, co nebylo.
  SELECT (public.create_booking(
            ARRAY[(SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1)],
            'training', 'TEST členův trénink', '2026-09-02 10:00+02', '2026-09-02 11:00+02',
            'aaaa1111-0000-0000-0000-000000000001', NULL, '{"instructor": 1}'::jsonb) ->> 'event_id')::uuid
    INTO _akce;

  RESET ROLE;
  SELECT count(*) INTO _smen FROM public.shifts WHERE event_id = _akce;
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.tvrd(_smen = 0,
    'člen (role authenticated): trénink přes create_booking štáb nevyrábí (rozpis se u ne-komerčky zahodí)');
END $$;

RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
