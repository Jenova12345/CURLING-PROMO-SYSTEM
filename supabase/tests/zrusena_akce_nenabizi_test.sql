-- =============================================================================
-- TESTY: na zrušené akci nežije žádná směna (Jakubův nález, 3. 9. 2026)
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/zrusena_akce_nenabizi_test.sql
--
-- PROČ NE LOKÁLNÍ SUPABASE: na téhle mašině není Docker, takže obvyklý
-- `supabase start` nejde. Replika se staví z čerstvého dumpu produkce a práva
-- rolí se do ní kopírují z produkce jedna ku jedné — bez toho by test běžel nad
-- jinými granty, než jaké platí doopravdy, a netvrdil by nic (CLAUDE.md, bod 3).
--
-- CO TENHLE TEST HLÍDÁ NEJVÍC:
--
-- 1) NEJEN OKAMŽIK ZRUŠENÍ. Předchozí oprava (20260902120000) spravila úklid
--    v okamžiku zrušení rezervace a bug se přesto vrátil — přes „uvolnění PO
--    zrušení". Test proto měří i tuhle cestu; test, který jen zruší rezervaci
--    a podívá se na směny, projde zeleně i s rozbitým stavem.
--
-- 2) ŽE BRÁNA OPRAVDU SÁHNE NA BRIGÁDNÍKA, NE JEN NA ADMINA. Helper
--    `akce_je_zrusena` je SECURITY DEFINER, protože brigádník na `reservations`
--    nevidí (u zrušeného Teambuildingu vidí NULA rezervací z jedné). Kdyby se
--    ten definer ztratil, podmínka „existuje rezervace" mu vyjde false, zrušená
--    akce se mu bude jevit jako ŽIVÁ a brána na něj vůbec nesáhne — tedy přesně
--    na toho, koho má zastavit. Změřeno mutací, ne odhadnuto.
--
-- 3) ŽE SE NEZAVŘELO TAKY VŠECHNO OSTATNÍ. Scénář 5: na ŽIVÉ akci musí
--    přihlášení i zabrání dál fungovat, měřeno účtem, který na tu rezervaci
--    nevidí. Bez něj by šlo „opravit" bug tím, že se zavře celý rozpis.
--
-- Testy práv běží pod rolí `authenticated`. Jako `postgres` projde všechno —
-- obchází granty i RLS (CLAUDE.md, bod 3).
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Pojistka: tenhle soubor ZAPISUJE. Na produkci nesmí nikdy.
DO $$
BEGIN
  IF current_database() <> 'curling_test' THEN
    RAISE EXCEPTION 'ODMÍTNUTO: test patří jen do repliky curling_test, běží nad "%".',
      current_database();
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE '  OK  %', _popis;
END $$;

-- Vrátí true, když příkaz pod daným uživatelem odmítla NAŠE brána.
--
-- Schválně NE „spadlo to = brána drží". Při stavbě téhle sady chyběl replice
-- grant na schéma `auth`, takže úplně každý příkaz končil chybou
-- „permission denied" — a všechny negativní testy byly zeleně rozbité. Test,
-- který bere jakoukoli výjimku jako úspěch, měří jen to, že něco selhalo.
--
-- Proto se uznává jen očekávaný důvod: náš RAISE z triggeru, nebo odmítnutí
-- politikou. Cokoli jiného (chybějící právo, překlep v SQL) se pošle dál
-- a test spadne nahlas.
CREATE OR REPLACE FUNCTION pg_temp.odmitnuto(_sql text, _uziv uuid) RETURNS boolean
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
    EXECUTE _sql;
    PERFORM set_config('role', 'none', true);
    RETURN false;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('role', 'none', true);
    IF SQLERRM LIKE '%Akce je zrušená%'
       OR SQLERRM LIKE '%Směnu nelze přesunout%'
       OR SQLERRM LIKE '%Zrušenou směnu znovu otevírá%'
       OR SQLERRM LIKE '%Do zrušené směny už zapisovat nelze%'
       OR SQLERRM LIKE '%Nemůžete zrušit cizí%'
       OR SQLERRM LIKE '%violates row-level security policy%'
       OR SQLERRM LIKE '%porušuje zásadu zabezpečení na úrovni řádků%' THEN
      RETURN true;
    END IF;
    RAISE EXCEPTION 'Příkaz sice selhal, ale z JINÉHO důvodu než kvůli bráně: %', SQLERRM;
  END;
END $$;

-- Spustí příkaz pod daným uživatelem a vrátí počet dotčených řádků.
-- RLS umí zápis odmítnout i TIŠE (porušené USING = 0 řádků, žádná výjimka),
-- takže „nespadlo to" samo o sobě nestačí.
CREATE OR REPLACE FUNCTION pg_temp.dotceno(_sql text, _uziv uuid) RETURNS integer
 LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
  EXECUTE _sql;
  GET DIAGNOSTICS _n = ROW_COUNT;
  PERFORM set_config('role', 'none', true);
  RETURN _n;
END $$;

-- Vrátí true, když zápis NEPROŠEL — ať už výjimkou z naší brány, nebo TIŠE.
--
-- RLS má dva různé způsoby, jak odmítnout: porušený `WITH CHECK` vyhodí chybu,
-- kdežto porušený `USING` jen nedotkne žádný řádek a mlčí. Druhá vrstva téhle
-- opravy sedí právě v `USING`, takže test, který čeká výjimku, by ji prohlásil
-- za nefunkční. Proto se tady kontroluje i počet dotčených řádků.
CREATE OR REPLACE FUNCTION pg_temp.neprojde(_sql text, _uziv uuid) RETURNS boolean
 LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
    EXECUTE _sql;
    GET DIAGNOSTICS _n = ROW_COUNT;
    PERFORM set_config('role', 'none', true);
    RETURN _n = 0;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('role', 'none', true);
    IF SQLERRM LIKE '%Zrušenou směnu znovu otevírá%'
       OR SQLERRM LIKE '%Do zrušené směny už zapisovat nelze%'
       OR SQLERRM LIKE '%Roli na směně mění jen správce haly%'
       OR SQLERRM LIKE '%violates row-level security policy%' THEN
      RETURN true;
    END IF;
    RAISE EXCEPTION 'Zápis selhal z JINÉHO důvodu než kvůli bráně: %', SQLERRM;
  END;
END $$;

-- ---------------------------------------------------------------------------
-- FIXTURY
-- ---------------------------------------------------------------------------
-- Směny se zakládají PŘED zrušením rezervace — po něm už nová směna na akci
-- vzniknout nemůže, a přesně to je smyslem opravy.
--
-- `validate_shift_before_update` se pro stavbu fixtur dočasně vypíná. Není to
-- obcházení testu, ale jediná cesta, jak vyrobit stav, který na produkci dnes
-- reálně existuje: `open` směna na zrušené akci. Po opravě už ho normální
-- cestou vytvořit nejde, a právě na něm se testuje, že se na takovou směnu
-- nedá přihlásit. Trigger se zapíná zpátky hned po fixtuře, takže samotné
-- scénáře běží nad plnou branou.
DO $$
DECLARE _sheet uuid; _subj uuid; _kdo uuid; _typ public.event_type;
BEGIN
  SELECT r.sheet_id, r.subject_id, r.created_by INTO _sheet, _subj, _kdo
    FROM public.reservations r WHERE r.status = 'confirmed' LIMIT 1;
  SELECT e.event_type INTO _typ FROM public.events e LIMIT 1;

  -- A) ŽIVÁ akce
  INSERT INTO public.events (id, title, event_type, start_time, end_time, required_staff, created_by)
  VALUES ('00000000-0000-0000-0000-0000000000a1', 'TEST ziva akce', _typ,
          '2027-06-01 08:00:00+00', '2027-06-01 10:00:00+00', 1, _kdo);
  INSERT INTO public.reservations (id, event_id, sheet_id, start_at, end_at, status, subject_id, created_by)
  VALUES ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1',
          _sheet, '2027-06-01 08:00:00+00', '2027-06-01 10:00:00+00', 'confirmed', _subj, _kdo);

  -- B) akce, která se za chvíli zruší
  INSERT INTO public.events (id, title, event_type, start_time, end_time, required_staff, created_by)
  VALUES ('00000000-0000-0000-0000-0000000000a2', 'TEST zrusena akce', _typ,
          '2027-06-02 08:00:00+00', '2027-06-02 10:00:00+00', 1, _kdo);
  INSERT INTO public.reservations (id, event_id, sheet_id, start_at, end_at, status, subject_id, created_by)
  VALUES ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a2',
          _sheet, '2027-06-02 08:00:00+00', '2027-06-02 10:00:00+00', 'confirmed', _subj, _kdo);
END $$;

ALTER TABLE public.shifts DISABLE TRIGGER validate_shift_before_update;

INSERT INTO public.shifts (id, event_id, status, required_role)
VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', 'open', 'instructor'),
       ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000a1', 'open', 'bar_staff');

INSERT INTO public.shifts (id, event_id, status, required_role, claimed_by, claimed_at)
VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a2', 'open', 'instructor', NULL, NULL),
       ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 'claimed', 'trainer',
        '494ca54e-b9b5-444b-9d08-2a637c58eda3', now());

INSERT INTO public.shifts (id, event_id, status, required_role, hours_worked, hourly_rate, completed_at)
VALUES ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a2', 'completed', 'bar_staff',
        4, 150, now());

-- zrušení běžnou cestou, ať se spustí i stávající jednorázový úklid
UPDATE public.reservations SET status = 'cancelled', cancelled_at = now()
 WHERE id = '00000000-0000-0000-0000-0000000000b2';

-- legacy stav, který na produkci reálně existuje: živá směna na zrušené akci
UPDATE public.shifts SET status = 'open', cancelled_at = NULL, cancelled_by = NULL
 WHERE id = '00000000-0000-0000-0000-0000000000d1';
UPDATE public.shifts SET status = 'claimed', cancelled_at = NULL, cancelled_by = NULL,
       claimed_by = '494ca54e-b9b5-444b-9d08-2a637c58eda3'
 WHERE id = '00000000-0000-0000-0000-0000000000d2';

ALTER TABLE public.shifts ENABLE TRIGGER validate_shift_before_update;

SELECT pg_temp.tvrd(
  (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d1') = 'open'
  AND public.akce_je_zrusena('00000000-0000-0000-0000-0000000000a2'),
  'FIXTURA: open směna na zrušené akci existuje (výchozí stav bugu)');
SELECT pg_temp.tvrd(
  NOT public.akce_je_zrusena('00000000-0000-0000-0000-0000000000a1'),
  'FIXTURA: živá akce je vedená jako živá');
SELECT pg_temp.tvrd(
  (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d3') = 'completed',
  'FIXTURA: odpracovaná směna na zrušené akci existuje');

-- Kontrola samotných účtů. Bez ní by scénáře 3 a 4c mohly projít zeleně
-- z úplně jiného důvodu: kdyby „admin" přestal být adminem, jeho pokus by
-- selhal na chybějícím právu a test by to považoval za funkční bránu. Totéž
-- obráceně u brigádníků. (Jednou už se to v téhle session stalo — sonda běžela
-- pod účtem, o kterém jsem si myslel, že je řadový, a byl to admin.)
SELECT pg_temp.tvrd(
  public.has_role('ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5', 'admin'),
  'FIXTURA: testovací admin je opravdu admin');
SELECT pg_temp.tvrd(
  NOT public.has_role('30e86078-5435-445b-9a87-5f0c691c388f', 'admin')
  AND NOT public.has_role('494ca54e-b9b5-444b-9d08-2a637c58eda3', 'admin'),
  'FIXTURA: oba testovací brigádníci admini NEJSOU');
SELECT pg_temp.tvrd(
  public.ucet_aktivni('30e86078-5435-445b-9a87-5f0c691c388f')
  AND public.ucet_aktivni('494ca54e-b9b5-444b-9d08-2a637c58eda3'),
  'FIXTURA: oba testovací brigádníci mají aktivní účet');

-- ---------------------------------------------------------------------------
-- 1) Zabrání a přihláška na směně zrušené akce se odmítne
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts
     SET status = 'pending', claimed_by = '30e86078-5435-445b-9a87-5f0c691c388f', claimed_at = now()
   WHERE id = '00000000-0000-0000-0000-0000000000d1'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '1a) zabrání open směny na zrušené akci: ODMÍTNUTO');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  INSERT INTO public.shift_applications (shift_id, user_id, status)
  VALUES ('00000000-0000-0000-0000-0000000000d1', '30e86078-5435-445b-9a87-5f0c691c388f', 'pending')
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '1b) přihláška na směnu zrušené akce: ODMÍTNUTA');

-- ---------------------------------------------------------------------------
-- 2) Uvolnění PO zrušení neobnoví živou nabídku
-- ---------------------------------------------------------------------------
-- Tohle je cesta, kterou minulá oprava přehlédla. Držitel se odhlásit MUSÍ umět
-- (chyba by ho zasekla na akci, která se nekoná), ale výsledkem nesmí být
-- nabídka — proto `cancelled`, ne `open`.
DO $$
DECLARE _n integer;
BEGIN
  _n := pg_temp.dotceno($sql$
    UPDATE public.shifts SET status = 'open', claimed_by = NULL, claimed_at = NULL
     WHERE id = '00000000-0000-0000-0000-0000000000d2'
  $sql$, '494ca54e-b9b5-444b-9d08-2a637c58eda3');
  PERFORM pg_temp.tvrd(_n = 1, '2a) držitel se ze směny na zrušené akci odhlásit MŮŽE');
END $$;

SELECT pg_temp.tvrd(
  (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d2') = 'cancelled',
  '2b) uvolnění po zrušení skončilo jako cancelled, ne open');

SELECT pg_temp.tvrd(
  (SELECT cancelled_at IS NOT NULL FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d2'),
  '2c) zavřená směna má razítko zrušení (audit)');

-- ---------------------------------------------------------------------------
-- 3) Adminské schválení na zrušené akci se odmítne
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts
     SET status = 'claimed', claimed_by = '30e86078-5435-445b-9a87-5f0c691c388f', claimed_at = now()
   WHERE id = '00000000-0000-0000-0000-0000000000d1'
$sql$, 'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5'),
  '3) admin nemůže schválit směnu na zrušené akci');

-- ---------------------------------------------------------------------------
-- 4) Opakovaná přihláška a schválení přihlášky
-- ---------------------------------------------------------------------------
-- Pozor na to, CO který scénář měří — zjištěno mutačním testem:
--   * 4a (upsert) chytá INSERT politika, ne UPDATE. Sám o sobě tedy o UPDATE
--     politice netvrdí nic; s vrácenou UPDATE politikou zůstal zelený.
--   * 4b a 4c jdou PŘÍMÝM UPDATE (přes API prostý PATCH), což je jediná cesta,
--     kterou INSERT politika nevidí. Teprve ony hlídají UPDATE větev.
INSERT INTO public.shift_applications (id, shift_id, user_id, status)
VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1',
        '30e86078-5435-445b-9a87-5f0c691c388f', 'cancelled'),
       ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000d1',
        '494ca54e-b9b5-444b-9d08-2a637c58eda3', 'pending');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  INSERT INTO public.shift_applications (shift_id, user_id, status)
  VALUES ('00000000-0000-0000-0000-0000000000d1', '30e86078-5435-445b-9a87-5f0c691c388f', 'pending')
  ON CONFLICT (shift_id, user_id) DO UPDATE SET status = 'pending'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '4a) opakovaná přihláška přes upsert na zrušené akci: ODMÍTNUTA');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shift_applications SET status = 'pending'
   WHERE id = '00000000-0000-0000-0000-0000000000e1'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '4b) oživení vlastní přihlášky přímým UPDATE na zrušené akci: ODMÍTNUTO');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shift_applications SET status = 'approved'
   WHERE id = '00000000-0000-0000-0000-0000000000e2'
$sql$, 'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5'),
  '4c) admin nemůže schválit přihlášku na zrušené akci');

-- Zrušit smí každý pořád — jinak by si nikdo neuklidil ani vlastní přihlášku.
DO $$
DECLARE _n integer;
BEGIN
  _n := pg_temp.dotceno($sql$
    UPDATE public.shift_applications SET status = 'cancelled'
     WHERE id = '00000000-0000-0000-0000-0000000000e2'
  $sql$, '494ca54e-b9b5-444b-9d08-2a637c58eda3');
  PERFORM pg_temp.tvrd(_n = 1, '4d) zrušení vlastní přihlášky na zrušené akci PROJDE');
END $$;

-- ---------------------------------------------------------------------------
-- 5) NA ŽIVÉ AKCI SE NESMÍ ZMĚNIT NIC
-- ---------------------------------------------------------------------------
-- Nejdůležitější scénář souboru. Účet Daniel Basista na rezervaci živé akce
-- NEVIDÍ (patří cizímu subjektu) — kdyby helper přestal být SECURITY DEFINER,
-- vyšla by mu jako zrušená a tenhle scénář zčervená. Bez něj by celá sada byla
-- zeleně rozbitá.
SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.reservations r
    WHERE r.event_id = '00000000-0000-0000-0000-0000000000a1') = 1,
  '5a) předpoklad: živá akce má rezervaci');

DO $$
DECLARE _n integer;
BEGIN
  _n := pg_temp.dotceno($sql$
    INSERT INTO public.shift_applications (shift_id, user_id, status)
    VALUES ('00000000-0000-0000-0000-0000000000c1', '30e86078-5435-445b-9a87-5f0c691c388f', 'pending')
  $sql$, '30e86078-5435-445b-9a87-5f0c691c388f');
  PERFORM pg_temp.tvrd(_n = 1, '5b) přihláška na ŽIVOU akci dál PROJDE');
END $$;

DO $$
DECLARE _n integer;
BEGIN
  _n := pg_temp.dotceno($sql$
    UPDATE public.shifts
       SET status = 'pending', claimed_by = '30e86078-5435-445b-9a87-5f0c691c388f', claimed_at = now()
     WHERE id = '00000000-0000-0000-0000-0000000000c2'
  $sql$, '30e86078-5435-445b-9a87-5f0c691c388f');
  PERFORM pg_temp.tvrd(_n = 1, '5c) zabrání směny na ŽIVÉ akci dál PROJDE');
END $$;

SELECT pg_temp.tvrd(
  (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000c2') = 'pending',
  '5d) zabraná směna na živé akci zůstala pending (nepřepsala se na cancelled)');

-- ---------------------------------------------------------------------------
-- 6) Odpracovaná směna se nedotkne
-- ---------------------------------------------------------------------------
UPDATE public.shifts
   SET status = 'cancelled', cancelled_at = now()
 WHERE status IN ('open', 'pending', 'claimed')
   AND public.akce_je_zrusena(event_id);

SELECT pg_temp.tvrd(
  (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d3') = 'completed'
  AND (SELECT hours_worked FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d3') = 4,
  '6) odpracovaná směna na zrušené akci zůstala completed i s hodinami');

-- ---------------------------------------------------------------------------
-- 7) Nová směna na zrušené akci nevznikne (a nic přitom nespadne)
-- ---------------------------------------------------------------------------
-- Přímý zápis:
DO $$
DECLARE _pred integer; _po integer;
BEGIN
  SELECT count(*) INTO _pred FROM public.shifts
   WHERE event_id = '00000000-0000-0000-0000-0000000000a2';
  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES ('00000000-0000-0000-0000-0000000000a2', 'open', 'instructor');
  SELECT count(*) INTO _po FROM public.shifts
   WHERE event_id = '00000000-0000-0000-0000-0000000000a2';
  PERFORM pg_temp.tvrd(_pred = _po, '7a) vložení směny na zrušenou akci se tiše přeskočilo');
END $$;

-- Skutečná cesta z provozu: dorovnání štábu při úpravě akce.
DO $$
DECLARE _pred integer; _po integer;
BEGIN
  SELECT count(*) INTO _pred FROM public.shifts
   WHERE event_id = '00000000-0000-0000-0000-0000000000a2';
  UPDATE public.events SET required_staff = 3
   WHERE id = '00000000-0000-0000-0000-0000000000a2';
  SELECT count(*) INTO _po FROM public.shifts
   WHERE event_id = '00000000-0000-0000-0000-0000000000a2';
  PERFORM pg_temp.tvrd(_pred = _po,
    '7b) dorovnání štábu na zrušené akci nezaložilo nabídku (a úprava akce nespadla)');
END $$;

-- Na ŽIVÉ akci dorovnání dál funguje.
DO $$
DECLARE _pred integer; _po integer;
BEGIN
  SELECT count(*) INTO _pred FROM public.shifts
   WHERE event_id = '00000000-0000-0000-0000-0000000000a1';
  UPDATE public.events SET required_staff = 4
   WHERE id = '00000000-0000-0000-0000-0000000000a1';
  SELECT count(*) INTO _po FROM public.shifts
   WHERE event_id = '00000000-0000-0000-0000-0000000000a1';
  PERFORM pg_temp.tvrd(_po > _pred, '7c) dorovnání štábu na ŽIVÉ akci dál zakládá směny');
END $$;

-- ---------------------------------------------------------------------------
-- 8) Přihláška na zrušenou směnu se odmítne i na ŽIVÉ akci
-- ---------------------------------------------------------------------------
-- Druhá díra, nalezená při téhle opravě: přihlásit se šlo i na směnu, která
-- byla sama `cancelled`. UI ji nenabízí, ale API ji přijalo.
UPDATE public.shifts SET status = 'cancelled', cancelled_at = now()
 WHERE id = '00000000-0000-0000-0000-0000000000c1';

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  INSERT INTO public.shift_applications (shift_id, user_id, status)
  VALUES ('00000000-0000-0000-0000-0000000000c1', '494ca54e-b9b5-444b-9d08-2a637c58eda3', 'pending')
$sql$, '494ca54e-b9b5-444b-9d08-2a637c58eda3'),
  '8) přihláška na zrušenou směnu (živá akce): ODMÍTNUTA');

-- ---------------------------------------------------------------------------
-- 9) Invariant celkově
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.shifts s
    WHERE s.status IN ('open', 'pending', 'claimed') AND public.akce_je_zrusena(s.event_id)) = 0,
  '9a) v celé databázi nevisí živá směna na zrušené akci');

SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.shift_applications a
     JOIN public.shifts s ON s.id = a.shift_id
    WHERE a.status IN ('pending', 'approved') AND public.akce_je_zrusena(s.event_id)) = 0,
  '9b) v celé databázi nevisí živá přihláška na zrušené akci');

-- ---------------------------------------------------------------------------
-- 10) Směna se nestěhuje mezi akcemi
-- ---------------------------------------------------------------------------
-- Regrese, kterou zavlekla migrace 20260903120000 a zavírá 20260903160000.
-- Nová větev politiky pouští `status='cancelled'`, když `akce_je_zrusena(event_id)`
-- — jenže `event_id` si do UPDATE dosadil sám volající. Kterýkoli člen štábu
-- tím mohl zavřít kolegovi potvrzenou směnu na ŽIVÉ akci a ještě ji přestěhovat.
SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts
     SET status = 'cancelled', event_id = '00000000-0000-0000-0000-0000000000a2'
   WHERE id = '00000000-0000-0000-0000-0000000000c2'
$sql$, '494ca54e-b9b5-444b-9d08-2a637c58eda3'),
  '10a) zavření CIZÍ směny přesunem na zrušenou akci: ODMÍTNUTO');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts
     SET status = 'open', claimed_by = NULL, claimed_at = NULL,
         event_id = '00000000-0000-0000-0000-0000000000a2'
   WHERE id = '00000000-0000-0000-0000-0000000000c2'
$sql$, '494ca54e-b9b5-444b-9d08-2a637c58eda3'),
  '10b) totéž přes status=open (obcházelo „Nemůžete zrušit cizí směnu"): ODMÍTNUTO');

SELECT pg_temp.tvrd(
  (SELECT event_id FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000c2')
    = '00000000-0000-0000-0000-0000000000a1',
  '10c) směna po pokusech pořád visí na své původní akci');

-- ---------------------------------------------------------------------------
-- 11) Trenér na zrušené akci: hláška, ne tiché „hotovo"
-- ---------------------------------------------------------------------------
-- `prirad_trenera` vkládá směnu přímo. Od zavedení BEFORE INSERT brány se ten
-- INSERT tiše přeskočí, ale `RETURNING ... INTO` bez `STRICT` chybu nevyhodí —
-- funkce vracela {"zmena": true, "shift_id": null} a UI hlásilo úspěch.
-- Pozor na konstrukci: tvrzení musí být VEN z bloku s `EXCEPTION`. Když je
-- uvnitř, chytí jeho vlastní `RAISE` tentýž handler a z padlého testu se stane
-- nesrozumitelná hláška o něčem jiném. (Stalo se při psaní téhle sady.)
CREATE OR REPLACE FUNCTION pg_temp.chyba_z(_sql text) RETURNS text
 LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE _sql;
  RETURN NULL;                 -- prošlo bez chyby
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;

DO $$
DECLARE _sheet uuid; _subj uuid; _kdo uuid; _vysledek jsonb;
BEGIN
  -- Adminský token MUSÍ být nastavený UŽ TEĎ, ne až před `prirad_trenera`.
  -- Vkládání rezervace pod tokenem řadového brigádníka guard na `reservations`
  -- TIŠE zahodí (řádek nevznikne, chyba nepřijde) — akce pak nemá rezervaci
  -- a je tím pádem správně vedená jako ŽIVÁ, takže scénář 11b měřil něco
  -- úplně jiného, než si myslel. Zjištěno diagnostikou, ne odhadem.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);

  SELECT r.sheet_id, r.subject_id, r.created_by INTO _sheet, _subj, _kdo
    FROM public.reservations r WHERE r.status = 'confirmed' LIMIT 1;

  INSERT INTO public.events (id, title, event_type, start_time, end_time, required_staff, created_by)
  VALUES ('00000000-0000-0000-0000-0000000000f1', 'TEST trenink', 'training',
          '2027-07-01 08:00:00+00', '2027-07-01 10:00:00+00', 1, _kdo);
  INSERT INTO public.reservations (id, event_id, sheet_id, start_at, end_at, status, subject_id, created_by)
  VALUES ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000f1',
          _sheet, '2027-07-01 08:00:00+00', '2027-07-01 10:00:00+00', 'confirmed', _subj, _kdo);

  -- Kontrola, že fixtura opravdu vznikla. Bez ní by scénář 11b tiše měřil
  -- akci bez rezervace, což zrušená akce NENÍ.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id = '00000000-0000-0000-0000-0000000000f1') = 1,
    'FIXTURA: trénink má rezervaci (jinak by nebyl co rušit)');

  -- na ŽIVÉ akci to musí normálně fungovat
  _vysledek := public.prirad_trenera('00000000-0000-0000-0000-0000000000f1',
                                     '494ca54e-b9b5-444b-9d08-2a637c58eda3');
  PERFORM pg_temp.tvrd((_vysledek->>'shift_id') IS NOT NULL,
    '11a) trenér na ŽIVOU akci se přiřadí a směna opravdu vznikne');

  UPDATE public.reservations SET status = 'cancelled', cancelled_at = now()
   WHERE id = '00000000-0000-0000-0000-0000000000f2';
END $$;

DO $$
DECLARE _msg text;
BEGIN
  _msg := pg_temp.chyba_z($sql$
    SELECT public.prirad_trenera('00000000-0000-0000-0000-0000000000f1',
                                 '30e86078-5435-445b-9a87-5f0c691c388f')
  $sql$);
  PERFORM pg_temp.tvrd(coalesce(_msg, '') LIKE '%Akce je zrušená%',
    '11b) trenér na ZRUŠENOU akci: ODMÍTNUTO hláškou, ne tichým shift_id=null (dostal jsem: '
    || coalesce(_msg, 'ŽÁDNOU CHYBU') || ')');
END $$;

SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.shifts
    WHERE event_id = '00000000-0000-0000-0000-0000000000f1'
      AND status <> 'cancelled') = 0,
  '11c) na zrušeném tréninku nezůstala žádná živá trenérská směna');

-- ---------------------------------------------------------------------------
-- 12) RPC pro UI vidí brigádník správně
-- ---------------------------------------------------------------------------
-- Na téhle funkci stojí celý frontendový filtr. Kdyby ztratila SECURITY DEFINER,
-- vrátí brigádníkovi prázdno, filtr přestane mlčky platit a nic jiného v téhle
-- sadě by to nechytlo.
DO $$
DECLARE _zrusene uuid[];
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"30e86078-5435-445b-9a87-5f0c691c388f","role":"authenticated"}', true);
  SELECT array_agg(x) INTO _zrusene FROM public.zrusene_akce_se_smenami() AS x;
  PERFORM set_config('role', 'none', true);

  PERFORM pg_temp.tvrd('00000000-0000-0000-0000-0000000000a2' = ANY(_zrusene),
    '12a) RPC vrací NEADMINOVI zrušenou akci (drží SECURITY DEFINER)');
  PERFORM pg_temp.tvrd(NOT ('00000000-0000-0000-0000-0000000000a1' = ANY(_zrusene)),
    '12b) RPC nevydává živou akci za zrušenou');
END $$;

-- ---------------------------------------------------------------------------
-- 13) Zavřená směna je zavřená
-- ---------------------------------------------------------------------------
-- N1: zrušenou směnu na ŽIVÉ akci šlo jedním UPDATE oživit na `pending`
--     s cizí rolí a zděděnou sazbou (starší díra od 20260902240000).
-- N2: do cizí zavřené směny na zrušené akci šlo zapsat, kdo ji držel a kdo
--     a kdy ji zrušil (regrese z 20260903120000).
-- Fixtura pro N1: zrušená trenérská směna za 600 Kč/h na akci, která ŽIJE —
-- přesně to, co v provozu vyrobí `odeber_trenera` nebo přebytek v `dorovnej_stab`.
INSERT INTO public.shifts (id, event_id, required_role, status, hourly_rate)
VALUES ('00000000-0000-0000-0000-0000000000e9', '00000000-0000-0000-0000-0000000000a1',
        'trainer', 'cancelled', 600);

SELECT pg_temp.tvrd(
  NOT public.akce_je_zrusena('00000000-0000-0000-0000-0000000000a1')
  AND (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000e9') = 'cancelled',
  'FIXTURA: zrušená směna na ŽIVÉ akci existuje (to, co vyrobí odeber_trenera)');

-- Vrstvy se měří ZVLÁŠŤ, jinak jedna zastíní druhou a mutace na tu zastíněnou
-- nezčervená. Tady se vypíná RLS, takže odpovídá TRIGGER; níž (13g–13i) se
-- vypíná trigger, takže odpovídá RLS.
ALTER TABLE public.shifts DISABLE ROW LEVEL SECURITY;

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts
     SET status = 'pending', claimed_by = '30e86078-5435-445b-9a87-5f0c691c388f', claimed_at = now()
   WHERE id = '00000000-0000-0000-0000-0000000000e9'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '13a) N1 trigger: oživení zrušené směny na živé akci: ODMÍTNUTO');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts SET status = 'open', claimed_by = NULL
   WHERE id = '00000000-0000-0000-0000-0000000000e9'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '13b) N1 trigger: totéž přes „vrátit do nabídky": ODMÍTNUTO');

SELECT pg_temp.tvrd(
  (SELECT hourly_rate FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000e9') = 600
  AND (SELECT status::text FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000e9') = 'cancelled',
  '13c) N1: sazba ani stav zrušené směny se pokusy nezměnily');

-- N2: cizí zavřená směna na ZRUŠENÉ akci (d2 zavřel scénář 2, držel ji Petr)
SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.shifts
     SET claimed_by   = '30e86078-5435-445b-9a87-5f0c691c388f',
         cancelled_by = '30e86078-5435-445b-9a87-5f0c691c388f',
         cancelled_at = '2020-01-01'
   WHERE id = '00000000-0000-0000-0000-0000000000d2'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '13d) N2 trigger: přepsání auditní stopy cizí zavřené směny: ODMÍTNUTO');

ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;

-- `claimed_by` je tu NULL schválně: ve scénáři 2 ji držitel legitimně pustil
-- a trigger ji zavřel. Podstatné je, že útočníkův zápis NEPROŠEL — jinak by
-- tu bylo jeho id a `cancelled_at` v roce 2020.
SELECT pg_temp.tvrd(
  (SELECT claimed_by IS NULL FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d2')
  AND (SELECT cancelled_at FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000d2')
      > '2025-01-01'::timestamptz,
  '13e) N2: auditní stopa zůstala nedotčená (útočníkův zápis neprošel)');

-- A protějšek: admin to smí, jinak by se zavřená směna nedala nikdy opravit.
DO $$
DECLARE _n integer;
BEGIN
  _n := pg_temp.dotceno($sql$
    UPDATE public.shifts SET status = 'open', claimed_by = NULL
     WHERE id = '00000000-0000-0000-0000-0000000000e9'
  $sql$, 'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5');
  PERFORM pg_temp.tvrd(_n = 1, '13f) admin zrušenou směnu na živé akci otevřít MŮŽE');
END $$;

-- Druhá vrstva: RLS musí odmítnout i BEZ triggeru.
--
-- Kontrola vlastnictví je schválně na dvou místech — v triggeru i v politice.
-- Dokud trigger drží, politiku není jak změřit: zastíní ji. Proto se tady
-- trigger na moment vypne, což je přesně scénář, kvůli kterému druhá vrstva
-- existuje (někdo trigger vypne kvůli migraci, nebo přibude cesta mimo něj).
--
-- Měří se na směně, která si DRŽITELE PAMATUJE. Politika vidí jen výsledný
-- řádek, ne ten původní, takže u zavřené směny s `claimed_by = NULL` prostě
-- nemá jak poznat „cizí" od „ničí" — tam drží jen trigger. Zavřená směna
-- s vyplněným `claimed_by` je přitom běžný stav: `cancel_open_shifts_on_
-- reservation_cancel` držitele schválně nemaže, je to auditní stopa.
ALTER TABLE public.shifts DISABLE TRIGGER validate_shift_before_update;
ALTER TABLE public.shifts DISABLE TRIGGER trg_shifts_a_zrusena_akce;

INSERT INTO public.shifts (id, event_id, required_role, status, claimed_by, cancelled_at)
VALUES ('00000000-0000-0000-0000-0000000000eb', '00000000-0000-0000-0000-0000000000a2',
        'instructor', 'cancelled', '494ca54e-b9b5-444b-9d08-2a637c58eda3', now());

-- Útočník si SCHVÁLNĚ nastavuje i `claimed_by` na sebe. První podoba téhle
-- opravy měla vlastnictví jen ve `WITH CHECK`, které vidí pouze výsledný řádek
-- — a útočník ho tímhle jedním sloupcem navíc splnil. Test bez `claimed_by`
-- byl zelený i s obejitelnou ochranou, což je přesně to, co testy nemají dělat.
SELECT pg_temp.tvrd(pg_temp.neprojde($sql$
  UPDATE public.shifts
     SET claimed_by   = '30e86078-5435-445b-9a87-5f0c691c388f',
         cancelled_by = '30e86078-5435-445b-9a87-5f0c691c388f',
         cancelled_at = '2020-01-01'
   WHERE id = '00000000-0000-0000-0000-0000000000eb'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '13g) N2 druhá vrstva: i s vypnutým triggerem RLS odmítne zápis do cizí zavřené směny');

SELECT pg_temp.tvrd(
  (SELECT claimed_by FROM public.shifts WHERE id = '00000000-0000-0000-0000-0000000000eb')
    = '494ca54e-b9b5-444b-9d08-2a637c58eda3'
  AND (SELECT extract(year from cancelled_at) FROM public.shifts
        WHERE id = '00000000-0000-0000-0000-0000000000eb') > 2025,
  '13h) N2 druhá vrstva: hodnoty na cizí zavřené směně zůstaly původní');

-- N1 přes RLS: oživení zavřené směny musí neprojít i bez triggeru.
SELECT pg_temp.tvrd(pg_temp.neprojde($sql$
  UPDATE public.shifts
     SET status = 'pending', claimed_by = '30e86078-5435-445b-9a87-5f0c691c388f', claimed_at = now()
   WHERE id = '00000000-0000-0000-0000-0000000000eb'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '13i) N1 druhá vrstva: i s vypnutým triggerem RLS oživení zavřené směny NEPUSTÍ');

ALTER TABLE public.shifts ENABLE TRIGGER trg_shifts_a_zrusena_akce;
ALTER TABLE public.shifts ENABLE TRIGGER validate_shift_before_update;

-- ---------------------------------------------------------------------------
-- 14) Úklid přihlášek se nedotkne odpracované směny
-- ---------------------------------------------------------------------------
-- `20260903160000` tuhle podmínku neměla; opravuje ji 20260903180000.
INSERT INTO public.shift_applications (id, shift_id, user_id, status)
VALUES ('00000000-0000-0000-0000-0000000000ea', '00000000-0000-0000-0000-0000000000d3',
        '30e86078-5435-445b-9a87-5f0c691c388f', 'approved');

UPDATE public.shift_applications a
   SET status = 'cancelled', updated_at = now()
  FROM public.shifts s
 WHERE s.id = a.shift_id
   AND a.status IN ('pending', 'approved')
   AND s.status <> 'completed'
   AND (s.status = 'cancelled' OR public.akce_je_zrusena(s.event_id));

SELECT pg_temp.tvrd(
  (SELECT status FROM public.shift_applications
    WHERE id = '00000000-0000-0000-0000-0000000000ea') = 'approved',
  '14) přihláška u ODPRACOVANÉ směny na zrušené akci zůstala approved');

-- ---------------------------------------------------------------------------
-- 15) Roli na směně mění jen správce haly (F3)
-- ---------------------------------------------------------------------------
-- Starší mezera: `required_role` nehlídala ani politika, ani trigger, a
-- `trg_shifts_sazba` je BEFORE INSERT only, takže se sazba nepřepočítá.
-- Změřeno: brigádník si při zabírání volné směny `bar_staff` přepsal roli na
-- `manager`. Obchází to „jednu roli jednou" i vazbu role na člověka.
SELECT pg_temp.tvrd(pg_temp.neprojde($sql$
  UPDATE public.shifts
     SET status = 'pending', claimed_by = '30e86078-5435-445b-9a87-5f0c691c388f',
         claimed_at = now(), required_role = 'manager'
   WHERE id = '00000000-0000-0000-0000-0000000000c2'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '15a) přepsání role při zabírání směny: ODMÍTNUTO');

SELECT pg_temp.tvrd(
  (SELECT required_role::text FROM public.shifts
    WHERE id = '00000000-0000-0000-0000-0000000000c2') = 'bar_staff',
  '15b) role na směně zůstala původní');

DO $$
DECLARE _n integer;
BEGIN
  _n := pg_temp.dotceno($sql$
    UPDATE public.shifts SET required_role = 'manager'
     WHERE id = '00000000-0000-0000-0000-0000000000c1'
  $sql$, 'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5');
  PERFORM pg_temp.tvrd(_n = 1, '15c) admin roli na směně změnit MŮŽE');
END $$;

DO $$ BEGIN RAISE NOTICE 'VŠECHNY TESTY PROŠLY'; END $$;

ROLLBACK;
