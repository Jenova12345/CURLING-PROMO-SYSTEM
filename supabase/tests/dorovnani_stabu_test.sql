-- =============================================================================
-- TESTY DOROVNÁNÍ ŠTÁBU (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/dorovnani_stabu_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE:
-- Původní `create_shifts_for_commercial_event` byl `AFTER INSERT ON events`,
-- takže se štáb s akcí nikdy nehnul: změna rozpisu se ve směnách neprojevila,
-- přidání dráhy nepřidalo směnu, ubrání dráhy nechalo směnu viset. Rozejde se
-- to TIŠE a přijde se na to na place.
--
-- Dvě věci, které tenhle test hlídá nejvíc:
--
-- 1) DOROVNÁNÍ, NE PŘEMAZÁNÍ. Nejjednodušší implementace („smaž směny akce
--    a založ znovu") projde všemi testy na počty a přitom při každé úpravě
--    názvu akce sebere brigádníkům zabrané směny. Test proto pokaždé kontroluje
--    i IDENTITU směn, na kterých někdo visí, ne jen jejich počet.
--
-- 2) ZDROJEM PRAVDY JE `role_reqs`, NE POČET DRAH (rozhodnutí PM R8). Dráha
--    navíc vede na VAROVÁNÍ v pohledu `stab_kontrola`, ne na automatickou
--    směnu — jinak by nešlo zapsat vědomé přebití, které R8 povoluje.
--
-- POUČENÍ Z ETAPY 2 (CLAUDE.md, bod 8): tvrzení o PRÁVECH se testují pod
-- skutečnou rolí `authenticated`. Jako `postgres` projde všechno.
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

-- Většina souboru běží jako `postgres` (RLS neplatí), ale `auth.uid()` je tam
-- pořád NULL — a `stab_kontrola` má v těle `has_role(auth.uid(),'admin')`,
-- takže by bez claimů vracela prázdno a tvrzení o ní by byla falešně červená.
-- Uživatel se proto vydává za admina; kdo doopravdy co smí, se testuje až
-- v kapitole 10 pod skutečnou rolí `authenticated`.
-- Vedlejší efekt je žádoucí: razítka `cancelled_by` / `changed_by` pak sedí
-- na skutečného člověka, tedy tak, jak to vypadá v provozu.
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

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

-- Kolik AKTIVNÍCH směn (tj. ne zrušených) má akce, případně jen pro jednu roli.
CREATE OR REPLACE FUNCTION pg_temp.smen(_akce uuid, _role text DEFAULT NULL) RETURNS int
 LANGUAGE sql STABLE AS $$
  SELECT count(*)::int FROM public.shifts
   WHERE event_id = _akce
     AND status <> 'cancelled'
     AND (_role IS NULL OR required_role::text = _role);
$$;

CREATE OR REPLACE FUNCTION pg_temp.zrusenych(_akce uuid) RETURNS int
 LANGUAGE sql STABLE AS $$
  SELECT count(*)::int FROM public.shifts
   WHERE event_id = _akce AND status = 'cancelled';
$$;

-- Založí komerční akci s daným rozpisem a vrátí její id.
CREATE OR REPLACE FUNCTION pg_temp.akce(_nazev text, _rozpis jsonb, _staff int DEFAULT 0) RETURNS uuid
 LANGUAGE plpgsql AS $$
DECLARE _id uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs)
  VALUES (_nazev, 'commercial', '2026-09-10 10:00+02', '2026-09-10 12:00+02', _staff, _rozpis)
  RETURNING id INTO _id;
  RETURN _id;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Trigger opravdu poslouchá na INSERT I UPDATE
--
-- Ptáme se katalogu, ne chování: kdyby se někdo vrátil k `AFTER INSERT`,
-- testy na vznik směn níž by pořád procházely a rozpadlo by se jen dorovnání.
-- `tgtype` je bitová maska — 4 = INSERT, 16 = UPDATE, 8 = DELETE.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _typ smallint; _sloupcu int;
BEGIN
  SELECT tgtype INTO _typ FROM pg_trigger
   WHERE tgname = 'trg_events_dorovnani' AND NOT tgisinternal;
  PERFORM pg_temp.tvrd(_typ IS NOT NULL, 'trigger trg_events_dorovnani existuje');
  PERFORM pg_temp.tvrd((_typ & 4) > 0,  'trigger poslouchá na INSERT');
  PERFORM pg_temp.tvrd((_typ & 16) > 0, 'trigger poslouchá na UPDATE — to je celý smysl téhle migrace');

  -- A že je vázaný na správné sloupce. Bez `tgattr` by `UPDATE OF` mohl
  -- nedopatřením sledovat jen `role_reqs` a starší akce podle `required_staff`
  -- by se přestaly dorovnávat.
  SELECT count(*) INTO _sloupcu
    FROM pg_trigger t, unnest(t.tgattr) AS a(attnum)
    JOIN pg_attribute att ON att.attrelid = 'public.events'::regclass AND att.attnum = a.attnum
   WHERE t.tgname = 'trg_events_dorovnani' AND NOT t.tgisinternal
     AND att.attname IN ('role_reqs', 'required_staff', 'event_type');
  PERFORM pg_temp.tvrd(_sloupcu = 3,
    format('UPDATE OF sleduje role_reqs, required_staff i event_type (nalezeno %s)', _sloupcu));

  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgname = 'create_shifts_for_commercial_event' AND NOT tgisinternal),
    'starý trigger je pryč (jinak by se směny zakládaly dvakrát)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Vznik akce — chování jako dřív
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid;
BEGIN
  _a := pg_temp.akce('TEST vznik', '{"instructor": 2, "bar_staff": 1}'::jsonb, 3);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 3, 'nová akce založila 3 směny podle rozpisu');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 2, '… z toho 2 instruktoři');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'bar_staff') = 1,  '… a 1 bar');

  -- A sazby z ceníku (napojení na migraci 20260827090000) — dorovnání nesmí
  -- psát sazbu samo, musí ji nechat na `set_shift_rate`.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _a AND required_role = 'instructor' AND hourly_rate = 250) = 2,
    'nové směny dostaly sazbu z ceníku (250 za instruktora), ne konstantu');

  -- Starší cesta bez rolí: `required_staff` na komerční akci s prázdným rozpisem.
  _a := pg_temp.akce('TEST vznik legacy', '{}'::jsonb, 2);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'starší cesta přes required_staff pořád funguje');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id = _a AND required_role IS NULL) = 2,
    '… a zakládá směny bez role');
END $$;

-- -----------------------------------------------------------------------------
-- 3) ÚPRAVA ROZPISU — jádro věci
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid;
BEGIN
  _a := pg_temp.akce('TEST úprava nahoru', '{"instructor": 1}'::jsonb, 1);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 1, 'výchozí stav: 1 směna');

  UPDATE public.events SET role_reqs = '{"instructor": 3}'::jsonb, required_staff = 3 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 3,
    'zvýšení rozpisu doplnilo směny (1 → 3) — dřív se nestalo NIC');

  UPDATE public.events SET role_reqs = '{"instructor": 1}'::jsonb, required_staff = 1 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 1, 'snížení rozpisu zrušilo přebytek (3 → 1)');
  PERFORM pg_temp.tvrd(pg_temp.zrusenych(_a) = 2,
    'přebytek je ZRUŠENÝ, ne smazaný (nic nemazat natvrdo)');

  -- Razítko, kdo to udělal. Bez něj by brigádníkovi zmizela směna a nikde by
  -- nebylo, čím to bylo způsobeno.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _a AND status = 'cancelled'
        AND cancelled_at IS NOT NULL
        AND cancelled_by = '11111111-1111-1111-1111-111111111111') = 2,
    'zrušené směny mají razítko KDY a KDO — jinak brigádníkovi zmizí směna bez stopy');

  -- Přidání ÚPLNĚ NOVÉ role.
  UPDATE public.events SET role_reqs = '{"instructor": 1, "manager": 2}'::jsonb, required_staff = 3 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'manager') = 2, 'přidaná role dostala své směny');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 1, '… a původní role zůstala beze změny');

  -- ODEBRÁNÍ role z rozpisu. Tohle je případ, který by čistý průchod po
  -- `role_reqs` minul — role, která v novém rozpisu není, se v něm nedá najít.
  UPDATE public.events SET role_reqs = '{"instructor": 1}'::jsonb, required_staff = 1 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'manager') = 0,
    'odebraná role přišla o směny (FULL JOIN, ne průchod po rozpisu)');

  -- Vynulování celého rozpisu.
  UPDATE public.events SET role_reqs = '{}'::jsonb, required_staff = 0 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0, 'prázdný rozpis zruší všechny volné směny');
END $$;

-- -----------------------------------------------------------------------------
-- 4) ZABRANÉ SMĚNY SE NESAHAJÍ — a kontroluje se IDENTITA, ne počet
--
-- Tohle je test, který odchytí „smaž a založ znovu". Implementace, která směny
-- přemazává, projde všemi počty výš a tady spadne.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _zabrana uuid; _vysledek jsonb;
BEGIN
  _a := pg_temp.akce('TEST zabraná směna', '{"instructor": 3}'::jsonb, 3);

  SELECT id INTO _zabrana FROM public.shifts
   WHERE event_id = _a AND status = 'open' ORDER BY id LIMIT 1;
  UPDATE public.shifts
     SET status = 'claimed', claimed_by = '22222222-2222-2222-2222-222222222222', claimed_at = now()
   WHERE id = _zabrana;

  -- Úprava, která se štábu vůbec netýká.
  UPDATE public.events SET title = 'TEST zabraná směna (přejmenováno)' WHERE id = _a;
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE id = _zabrana) = 'claimed',
    'přejmenování akce nechalo zabranou směnu být (a je to TÁŽ směna, ne nová)');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 3, 'přejmenování nezměnilo počet směn');

  -- Snížení rozpisu pod počet obsazených směn.
  UPDATE public.events SET role_reqs = '{"instructor": 1}'::jsonb, required_staff = 1 WHERE id = _a;
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE id = _zabrana) = 'claimed',
    'snížení rozpisu zabranou směnu NEZRUŠILO');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 1,
    'zbyla jen ta zabraná — obě volné se zrušily');

  -- Snížení pod počet ZABRANÝCH směn: dorovnat to nejde a musí to být slyšet.
  UPDATE public.events SET role_reqs = '{}'::jsonb, required_staff = 0 WHERE id = _a;
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE id = _zabrana) = 'claimed',
    'ani vynulování rozpisu nesebere zabranou směnu');

  _vysledek := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd(
    jsonb_array_length(_vysledek -> 'prebytek') = 1
      AND (_vysledek -> 'prebytek' -> 0 ->> 'nezruseno')::int = 1,
    'nedorovnaný přebytek se HLÁSÍ v návratové hodnotě, nezůstane tichý');
END $$;

-- -----------------------------------------------------------------------------
-- 4b) REŽIM „JEN DOPLŇUJ" (`_jen_doplnit => true`)
--
-- Používá ho datová část migrace (kapitola 5). Bez něj by migrace rušila směny,
-- přestože hlavička slibuje, že jen doplňuje — a nešlo by to poznat, protože
-- výběrový filtr tam počítá SOUČTY za akci, kdežto funkce pracuje PO ROLÍCH.
-- Přesně ten smíšený případ se testuje níž.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _v jsonb;
BEGIN
  -- Akce, kterou by součtový filtr vzal jako „chybí lidi" (rozpis 4 > 3 směny),
  -- a přitom má PŘEBYTEK v jiné roli: instruktor chybí, bar přebývá.
  _a := pg_temp.akce('TEST jen doplnit', '{"instructor": 1, "bar_staff": 2}'::jsonb, 3);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 1 AND pg_temp.smen(_a, 'bar_staff') = 2,
    'výchozí stav: 1 instruktor, 2 bary');

  UPDATE public.events SET role_reqs = '{"instructor": 4}'::jsonb, required_staff = 4 WHERE id = _a;
  -- Trigger jede v běžném režimu, takže bar zruší — a to je správně, protože
  -- to je vědomá úprava akce člověkem.
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'bar_staff') = 0,
    'běžný režim: odebraná role o směny přišla');

  -- A teď totéž v režimu, který používá migrace.
  _a := pg_temp.akce('TEST jen doplnit 2', '{"instructor": 1, "bar_staff": 2}'::jsonb, 3);
  UPDATE public.events SET role_reqs = '{"instructor": 4}'::jsonb, required_staff = 4 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'bar_staff') = 0, 'kontrola: trigger bar zrušil');

  -- Vrátíme bar zpátky a pustíme dorovnání v režimu „jen doplňuj".
  _a := pg_temp.akce('TEST jen doplnit 3', '{"instructor": 1, "bar_staff": 2}'::jsonb, 3);
  UPDATE public.events SET role_reqs = '{"instructor": 4}'::jsonb WHERE id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  _v := public.dorovnej_stab(_a, _jen_doplnit => true);
  PERFORM pg_temp.tvrd((_v ->> 'zruseno')::int = 0, 'režim „jen doplňuj" nezrušil nic');

  -- Ostrý případ: rozpis se změní, ale dorovnání se pustí ručně v tom režimu.
  -- Simuluje se to tak, že se rozpis změní BEZ triggeru (sloupec mimo UPDATE OF
  -- trigger nespustí… `role_reqs` ale sledovaný JE, takže se použije funkce
  -- napřímo nad akcí, které se rozpis nezměnil, ale směny nesedí).
  _a := pg_temp.akce('TEST jen doplnit 4', '{"instructor": 3}'::jsonb, 3);
  INSERT INTO public.shifts (event_id, status, required_role)
  VALUES (_a, 'open', 'bar_staff'), (_a, 'open', 'bar_staff');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 5, 'akce má 3 instruktory a 2 bary navíc');

  _v := public.dorovnej_stab(_a, _jen_doplnit => true);
  PERFORM pg_temp.tvrd((_v ->> 'zruseno')::int = 0,
    'JEN DOPLŇUJ: bary se nezrušily, přestože je rozpis nežádá');
  PERFORM pg_temp.tvrd((_v ->> 'neruseno')::int = 2,
    '… a přebytek se VRÁTIL jako „neruseno", takže se o něm dá napsat do logu');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 5, 'počet směn se nezměnil');

  -- Táž akce v běžném režimu už bary zruší.
  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd((_v ->> 'zruseno')::int = 2 AND pg_temp.smen(_a) = 3,
    'běžný režim tytéž bary zruší — přepínač opravdu rozhoduje');
END $$;

-- -----------------------------------------------------------------------------
-- 4c) ROZPIS ŠTÁBU MÁ KONEČNĚ PRAVIDLA
--
-- `events.role_reqs` dosud neměl žádnou validaci. Nevadilo to, dokud se rozpis
-- četl jen při vzniku akce; jakmile se čte i při každé úpravě, udělá z jedné
-- zkažené hodnoty akci, kterou UŽ NIKDY NIKDO NEULOŽÍ.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid;
BEGIN
  _a := pg_temp.akce('TEST validace rozpisu', '{"instructor": 1}'::jsonb, 1);

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.events SET role_reqs = '{"instructor": "dva"}'::jsonb WHERE id = '%s'$q$, _a),
    'events_role_reqs_platny', 'rozpis s textem místo čísla neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.events SET role_reqs = '{"instruktor": 1}'::jsonb WHERE id = '%s'$q$, _a),
    'events_role_reqs_platny', 'rozpis s neexistující rolí neprojde (překlep v klíči)');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.events SET role_reqs = '{"instructor": -1}'::jsonb WHERE id = '%s'$q$, _a),
    'events_role_reqs_platny', 'záporný počet neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.events SET role_reqs = '{"instructor": 1.5}'::jsonb WHERE id = '%s'$q$, _a),
    'events_role_reqs_platny', 'desetinný počet neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.events SET role_reqs = '{"instructor": 51}'::jsonb WHERE id = '%s'$q$, _a),
    'events_role_reqs_platny', 'počet nad 50 neprojde (VALIDATION_LIMITS.STAFF_COUNT_MAX)');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.events SET role_reqs = '[1,2]'::jsonb WHERE id = '%s'$q$, _a),
    'events_role_reqs_platny', 'pole místo objektu neprojde');

  -- A co projít MÁ.
  UPDATE public.events SET role_reqs = '{"instructor": 0}'::jsonb, required_staff = 0 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0,
    'nula projde a čte se jako „nikoho nechci" (stejně jako vynechaný klíč)');

  UPDATE public.events SET role_reqs = '{"instructor": 50}'::jsonb, required_staff = 50 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 50, 'počet přesně na mezi projde');

  UPDATE public.events SET role_reqs = '{}'::jsonb, required_staff = 0 WHERE id = _a;
  UPDATE public.events SET role_reqs = NULL WHERE id = _a;
  PERFORM pg_temp.tvrd(true, 'prázdný i NULL rozpis projde');
END $$;

-- -----------------------------------------------------------------------------
-- 4d) AKCE SE NESMÍ DÁT ZABETONOVAT
--
-- CHECK z kapitoly 0 brání novým špatným datům. Kdyby ho ale někdo shodil (nebo
-- kdyby se data dostala dovnitř jinudy), NESMÍ to skončit tím, že se akce stane
-- needitovatelnou — cast `'dva'::int` uvnitř triggeru by shodil každý UPDATE té
-- akce, tedy i ten, kterým by to šlo opravit. Tenhle test přesně tu situaci
-- vyrobí: constraint dočasně sundá, zkažený rozpis vloží a zkusí akci uložit.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _v jsonb;
BEGIN
  _a := pg_temp.akce('TEST zabetonovaná akce', '{"instructor": 2}'::jsonb, 2);

  ALTER TABLE public.events DROP CONSTRAINT events_role_reqs_platny;
  UPDATE public.events
     SET role_reqs = '{"instructor": 2, "instruktor": 1, "bar_staff": "dva"}'::jsonb
   WHERE id = _a;

  -- Klíčové tvrzení: UPDATE prošel, nespadl.
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 2,
    'zkažený rozpis akci NEZABETONOVAL — použitelná část se zpracovala');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'bar_staff') = 0,
    '… a nepoužitelná se přeskočila, ne dohadovala');

  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd(jsonb_array_length(_v -> 'spatne') = 2,
    'nepoužitelné položky se VRÁTÍ v „spatne", takže je kde uvidět');

  -- A jde to opravit, což je celý smysl té tolerance.
  UPDATE public.events SET role_reqs = '{"instructor": 2}'::jsonb WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'akce šla opravit běžným uložením');

  ALTER TABLE public.events ADD CONSTRAINT events_role_reqs_platny
    CHECK (public.role_reqs_je_platny(role_reqs));
END $$;

-- -----------------------------------------------------------------------------
-- 4e) PENĚŽNÍ INVARIANT: dorovnání nesahá na proplacené směny
--
-- Ověřoval se dosud jen ručně. `payout_id` je vazba na vyplacené peníze —
-- kdyby ji dorovnání zrušilo, výplata by ukazovala na zrušenou směnu.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _vyplata uuid; _smena uuid;
BEGIN
  _a := pg_temp.akce('TEST proplacená směna', '{"instructor": 2}'::jsonb, 2);
  SELECT id INTO _smena FROM public.shifts WHERE event_id = _a ORDER BY id LIMIT 1;

  UPDATE public.shifts SET status = 'claimed', claimed_by = '33333333-3333-3333-3333-333333333333',
         claimed_at = now() WHERE id = _smena;
  UPDATE public.shifts SET status = 'completed', hours_worked = 4, completed_at = now()
   WHERE id = _smena;

  INSERT INTO public.payouts (user_id, amount, created_by)
  VALUES ('33333333-3333-3333-3333-333333333333', 1000,
          '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _vyplata;
  UPDATE public.shifts SET payout_id = _vyplata WHERE id = _smena;

  -- Vynulování rozpisu je ta nejagresivnější možná úprava.
  UPDATE public.events SET role_reqs = '{}'::jsonb, required_staff = 0 WHERE id = _a;

  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE id = _smena) = 'completed',
    'PENÍZE: proplacená směna zůstala completed i po vynulování rozpisu');
  PERFORM pg_temp.tvrd(
    (SELECT payout_id FROM public.shifts WHERE id = _smena) = _vyplata,
    'PENÍZE: vazba na výplatu zůstala netknutá');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Idempotence
--
-- Dorovnání se pouští při každé úpravě akce, i takové, která se štábu netýká.
-- Kdyby nebylo idempotentní, každé uložení by štáb posunulo.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _v jsonb;
BEGIN
  _a := pg_temp.akce('TEST idempotence', '{"instructor": 2, "bar_staff": 1}'::jsonb, 3);

  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd((_v ->> 'pridano')::int = 0 AND (_v ->> 'zruseno')::int = 0,
    'druhé volání dorovnání nic nedělá');

  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd((_v ->> 'pridano')::int = 0 AND (_v ->> 'zruseno')::int = 0,
    'ani třetí');
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 3, 'počet směn se opakováním nehnul');

  -- UPDATE, který sloupec ZMÍNÍ, ale hodnotu nezmění. `UPDATE OF` se v Postgresu
  -- spouští podle SET klauzule, ne podle změny hodnoty — takže trigger jde,
  -- a nesmí nic pokazit.
  UPDATE public.events SET role_reqs = role_reqs WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 3, 'UPDATE beze změny hodnoty štáb nerozhodil');

  -- Neexistující akce nesmí shodit volajícího.
  PERFORM pg_temp.tvrd(public.dorovnej_stab('00000000-0000-0000-0000-0000000000ff') IS NULL,
    'dorovnání neexistující akce vrátí NULL, ne chybu');

  -- Záporný počet do databáze od kapitoly 0 vůbec nedojde (CHECK, testováno
  -- v 4c). Druhá vrstva je ale pořád na místě: kdyby CHECK někdo shodil,
  -- `-1` je nepřečtená položka jako každá jiná — a rozpis, který nejde přečíst
  -- celý, není podklad ke zrušení směn (viz 6c). Dřív se z toho četla nula
  -- a směny mizely; to bylo horší, protože „mínus jeden instruktor" neznamená
  -- „žádného nechci", ale „tomuhle rozpisu nerozumím".
  ALTER TABLE public.events DROP CONSTRAINT events_role_reqs_platny;
  UPDATE public.events SET role_reqs = '{"instructor": -1}'::jsonb WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 3,
    'i bez CHECKu záporný počet žádnou směnu nezrušil');
  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd((_v ->> 'zruseno')::int = 0
                       AND jsonb_array_length(_v -> 'spatne') = 1,
    '… a hlásí se jako nepoužitelná položka, ne jako nedorovnatelný přebytek');
  PERFORM pg_temp.tvrd(jsonb_array_length(_v -> 'prebytek') = 0,
    '… takže žádné trvale svítící falešné varování nevzniká');
  UPDATE public.events SET role_reqs = '{"instructor": 3}'::jsonb WHERE id = _a;
  ALTER TABLE public.events ADD CONSTRAINT events_role_reqs_platny
    CHECK (public.role_reqs_je_platny(role_reqs));
END $$;

-- -----------------------------------------------------------------------------
-- 6) Překlopení typu akce
--
-- Starší cesta (`required_staff` bez rolí) platí jen pro `commercial`
-- a `recruitment`. Změna typu tedy počet směn mění, i když se `required_staff`
-- nehne — proto je `event_type` mezi sledovanými sloupci.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid;
BEGIN
  _a := pg_temp.akce('TEST typ akce', '{}'::jsonb, 2);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'komerční akce má 2 směny podle required_staff');

  UPDATE public.events SET event_type = 'training' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0,
    'překlopení na trénink zrušilo štáb (starší cesta pro trénink neplatí)');

  UPDATE public.events SET event_type = 'commercial' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'zpátky na komerční akci se štáb obnovil');
END $$;

-- -----------------------------------------------------------------------------
-- 6b) ŠTÁB MAJÍ JEN KOMERČNÍ AKCE — i když rozpis přijde odjinud
--
-- Tohle je test na díru, která tu byla: `dorovnej_stab` brala rozpis podle rolí
-- BEZ OHLEDU NA TYP AKCE, kdežto starší cesta jen u komerčky. Dokud byl trigger
-- INSERT-only, nebylo to vidět. Jakmile se rozpis čte i při ÚPRAVĚ, znamenalo
-- to, že přepnutí akce na trénink jí založí PLACENÉ směny — na které se
-- brigádníci můžou přihlásit a které z UI nejdou odebrat, protože sekce štábu
-- je pro trénink skrytá.
--
-- `create_booking` tudy neprojde (rozpis u ne-komerčky zahazuje), ale
-- `useEvents.updateEvent` píše do `events` napřímo přes PostgREST.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid;
BEGIN
  _a := pg_temp.akce('TEST typ vs štáb', '{"instructor": 2}'::jsonb, 2);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'komerční akce štáb má');

  UPDATE public.events SET event_type = 'training' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0,
    'po přepnutí na trénink štáb zmizel — trénink placené směny nedostává');

  -- A rozpis se na tréninku neuplatní, ani když ho tam někdo napíše.
  UPDATE public.events SET role_reqs = '{"instructor": 4}'::jsonb, required_staff = 4 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0,
    'rozpis zapsaný na trénink NEVYROBÍ směny (dřív vyrobil 4 po 250 Kč/h)');

  -- Turnaj ani údržba taky ne.
  UPDATE public.events SET event_type = 'tournament' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0, 'turnaj štáb nedostane');
  UPDATE public.events SET event_type = 'maintenance' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 0, 'údržba ledu taky ne');

  -- Zpátky na komerčku se štáb vrátí — pravidlo je o typu, ne o cestě.
  UPDATE public.events SET event_type = 'commercial' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 4,
    'zpátky na komerční akci se rozpis uplatní');

  -- Nábor je ta druhá povolená hodnota.
  UPDATE public.events SET event_type = 'recruitment' WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 4, 'nábor štáb má taky');
END $$;

-- -----------------------------------------------------------------------------
-- 6c) ROZPIS, KTERÝ NEJDE PŘEČÍST CELÝ, NENÍ PODKLAD KE ZRUŠENÍ SMĚN
--
-- Tolerantní čtení slibuje, že nepoužitelnou položku „přeskočí". Dřív to
-- neplatilo: překlep `{"instruktor": 2}` znamenal, že role `instructor` z rozpisu
-- vypadla, četla se jako „chceme 0" a její volné směny zmizely. Slib o tom, že
-- se akce nedá zabetonovat, tedy platil za cenu ztráty směn — a ani komentář,
-- ani hláška to nepřiznávaly.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _v jsonb;
BEGIN
  _a := pg_temp.akce('TEST nečitelný rozpis', '{"instructor": 2}'::jsonb, 2);
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'akce má 2 směny instruktorů');

  ALTER TABLE public.events DROP CONSTRAINT events_role_reqs_platny;
  UPDATE public.events SET role_reqs = '{"instruktor": 2}'::jsonb WHERE id = _a;

  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2,
    'překlep v klíči směny NEZRUŠIL — rozpis se nedal přečíst celý, tak se nic nebere');
  PERFORM pg_temp.tvrd(pg_temp.zrusenych(_a) = 0, 'a opravdu se nic nezrušilo');

  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd((_v ->> 'zruseno')::int = 0
                       AND jsonb_array_length(_v -> 'spatne') = 1,
    'dorovnání to hlásí v „spatne" a pořád nic neruší');

  -- Doplňovat se smí dál — přidaná směna nikomu nic nebere.
  UPDATE public.events SET role_reqs = '{"instruktor": 2, "bar_staff": 1}'::jsonb WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'bar_staff') = 1,
    'čitelná část rozpisu se ale doplní — přidání nikomu nic nebere');

  UPDATE public.events SET role_reqs = '{"instructor": 2}'::jsonb WHERE id = _a;
  ALTER TABLE public.events ADD CONSTRAINT events_role_reqs_platny
    CHECK (public.role_reqs_je_platny(role_reqs));
END $$;

-- -----------------------------------------------------------------------------
-- 6d) TOLERANTNÍ FILTR MUSÍ ZRCADLIT CHECK CELÝ, i strop 50
--
-- Tolerantní čtení je pojistka pro případ, že by CHECK někdo shodil — takže
-- když zopakuje jen půlku jeho pravidel, není to pojistka, ale falešný pocit
-- bezpečí. Dvě konkrétní mezery, obě ověřené, než se zavřely:
--   • `{"instructor": 5000}` založilo jedním UPDATE 5000 směn,
--   • dvacetimístné číslo regexem `^[0-9]+$` prošlo a spadlo až na `::int`
--     („out of range for type integer") — tedy přesně tím pádem, kterému se
--     tolerantní čtení má vyhýbat.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _v jsonb;
BEGIN
  _a := pg_temp.akce('TEST tolerance = celý CHECK', '{"instructor": 2}'::jsonb, 2);
  ALTER TABLE public.events DROP CONSTRAINT events_role_reqs_platny;

  UPDATE public.events SET role_reqs = '{"instructor": 5000}'::jsonb WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2,
    'počet nad strop 50 se přeskočí, nezaloží 5000 směn');

  UPDATE public.events SET role_reqs = '{"instructor": 99999999999999999999}'::jsonb WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2,
    'číslo mimo rozsah int NESPADNE na castu, jen se přeskočí');

  _v := public.dorovnej_stab(_a);
  PERFORM pg_temp.tvrd(jsonb_array_length(_v -> 'spatne') = 1,
    '… a hlásí se jako nepoužitelná položka');

  -- Pohled na tom taky nesmí spadnout: jediná vadná akce by jinak sebrala
  -- adminovi varování o štábu na VŠECH akcích, ne jen na téhle.
  -- SUMA, ne `count(*)`: počet řádků se dá spočítat bez vyhodnocení sloupců,
  -- takže by tenhle test prošel, i kdyby pohled na vadné akci padal. Sečtení
  -- vynutí, aby se každý dopočítávaný sloupec opravdu spočítal.
  PERFORM pg_temp.tvrd(
    (SELECT sum(instruktoru_v_rozpisu + stabu_v_rozpisu + smen_navic + instruktoru_chybi)
       FROM public.stab_kontrola) IS NOT NULL,
    'stab_kontrola vadnou akcí nespadne — vyhodnotí se i dopočítávané sloupce');

  UPDATE public.events SET role_reqs = '{"instructor": 2}'::jsonb WHERE id = _a;
  ALTER TABLE public.events ADD CONSTRAINT events_role_reqs_platny
    CHECK (public.role_reqs_je_platny(role_reqs));
END $$;

-- -----------------------------------------------------------------------------
-- 7) DRÁHY: varování, ne automatická směna (rozhodnutí PM R8)
--
-- Tohle je to místo, kde se doslovné znění zadání („směny se dopočítají i při
-- přidání dráhy") potkává s rozhodnutím R8 („vědomé přebití je povolené").
-- Kdyby dráha zakládala směnu sama, akce se dvěma dráhami a jedním instruktorem
-- by si druhou směnu pokaždé vyrobila zpátky a přebití by nešlo zapsat.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _draha1 uuid; _draha2 uuid; _r record;
BEGIN
  _a := pg_temp.akce('TEST dráhy', '{"instructor": 1}'::jsonb, 1);

  SELECT id INTO _draha1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _draha2 FROM public.sheets WHERE active AND id <> _draha1 ORDER BY name LIMIT 1;

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, rate_per_hour)
  VALUES (_draha1, 'aaaa1111-0000-0000-0000-000000000003', _a,
          '2026-09-10 10:00+02', '2026-09-10 12:00+02', 1000);

  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 1, 'první dráha: 1 dráha, 1 instruktor — sedí');

  -- Druhá dráha. Směna kvůli ní VZNIKNOUT NESMÍ.
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, rate_per_hour)
  VALUES (_draha2, 'aaaa1111-0000-0000-0000-000000000003', _a,
          '2026-09-10 10:00+02', '2026-09-10 12:00+02', 1000);

  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 1,
    'přidaná dráha směnu NEZALOŽILA — jinak by nešlo zapsat vědomé přebití (R8)');

  -- Zato se to musí OZVAT.
  SELECT drah, instruktoru_smen, instruktoru_chybi INTO _r
    FROM public.stab_kontrola WHERE event_id = _a;
  PERFORM pg_temp.tvrd(_r.drah = 2 AND _r.instruktoru_smen = 1 AND _r.instruktoru_chybi = 1,
    'stab_kontrola hlásí 2 dráhy, 1 instruktora, chybí 1 — varování je vidět');

  -- Člověk varování uvidí a zvedne rozpis. TEPRVE TEĎ směna vzniká.
  UPDATE public.events SET role_reqs = '{"instructor": 2}'::jsonb, required_staff = 2 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'po zvednutí rozpisu směna vznikla');

  SELECT instruktoru_chybi INTO _r FROM public.stab_kontrola WHERE event_id = _a;
  PERFORM pg_temp.tvrd(_r.instruktoru_chybi = 0, 'a varování zmizelo');

  -- UBRÁNÍ DRÁHY ŠTÁB NESNIŽUJE. Sebrat směnu někomu, kdo s ní počítá, je horší
  -- chyba než přebytek — a přebytek je v pohledu vidět.
  UPDATE public.reservations SET deleted_at = now() WHERE event_id = _a AND sheet_id = _draha2;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a) = 2, 'ubrání dráhy štáb automaticky nesnížilo');

  SELECT drah, instruktoru_smen INTO _r FROM public.stab_kontrola WHERE event_id = _a;
  PERFORM pg_temp.tvrd(_r.drah = 1 AND _r.instruktoru_smen = 2,
    'a je to v pohledu vidět jako 1 dráha / 2 instruktoři');
END $$;

-- -----------------------------------------------------------------------------
-- 8) `smen_navic` ukazuje nedorovnaný přebytek
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _navic int;
BEGIN
  _a := pg_temp.akce('TEST přebytek v pohledu', '{"instructor": 2}'::jsonb, 2);
  UPDATE public.shifts SET status = 'claimed', claimed_by = '33333333-3333-3333-3333-333333333333',
         claimed_at = now()
   WHERE id IN (SELECT id FROM public.shifts WHERE event_id = _a);

  UPDATE public.events SET role_reqs = '{"instructor": 1}'::jsonb, required_staff = 1 WHERE id = _a;

  SELECT smen_navic INTO _navic FROM public.stab_kontrola WHERE event_id = _a;
  PERFORM pg_temp.tvrd(_navic = 1,
    'stab_kontrola ukazuje 1 směnu navíc — přebytek, který nešlo zrušit, nezůstává tichý');
END $$;

-- -----------------------------------------------------------------------------
-- 9) Auditní stopa směn
--
-- Dorovnání od teď ruší směny SAMO, takže bez auditu by brigádníkovi zmizela
-- volná směna a nikde by nebylo, čím.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _id uuid;
BEGIN
  _a := pg_temp.akce('TEST audit směn', '{"instructor": 2}'::jsonb, 2);
  SELECT id INTO _id FROM public.shifts WHERE event_id = _a ORDER BY id LIMIT 1;

  PERFORM pg_temp.tvrd(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE table_name = 'shifts' AND record_id = _id AND action = 'insert'),
    'vznik směny se zapsal do audit_log');

  UPDATE public.events SET role_reqs = '{"instructor": 1}'::jsonb, required_staff = 1 WHERE id = _a;

  PERFORM pg_temp.tvrd(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE table_name = 'shifts' AND action = 'update'
       AND old_data ->> 'status' <> 'cancelled'
       AND new_data ->> 'status' = 'cancelled'
       AND new_data ->> 'event_id' = _a::text),
    'automatické zrušení směny je v audit_log dohledatelné');

  -- A hlavně KDO. Bez toho je požadavek zákazníka „musí být vidět, kdo co
  -- zadával" splněný jen z půlky — a u směny, která někomu zmizela, je „kdo"
  -- ta podstatnější polovina.
  PERFORM pg_temp.tvrd(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE table_name = 'shifts' AND action = 'update'
       AND new_data ->> 'status' = 'cancelled'
       AND new_data ->> 'event_id' = _a::text
       AND changed_by = '11111111-1111-1111-1111-111111111111'),
    'audit u zrušené směny drží i KDO ji zrušil');
END $$;

-- -----------------------------------------------------------------------------
-- 10) PRÁVA — pod skutečnou rolí `authenticated`
-- -----------------------------------------------------------------------------
DO $$ BEGIN RAISE NOTICE '--- pod rolí authenticated ---'; END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _a uuid; _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.stab_kontrola;
  PERFORM pg_temp.tvrd(_radku > 0, 'admin (role authenticated): stab_kontrola vidí');

  -- Úprava akce adminem projde a štáb se dorovná, i když admin nemá přímý
  -- INSERT do `shifts` skrz politiku (má, ale funkce na tom nesmí viset).
  SELECT id INTO _a FROM public.events WHERE title = 'TEST vznik' LIMIT 1;
  UPDATE public.events SET role_reqs = '{"instructor": 4}'::jsonb, required_staff = 4 WHERE id = _a;
  PERFORM pg_temp.tvrd(pg_temp.smen(_a, 'instructor') = 4,
    'admin (role authenticated): úprava akce dorovnala štáb');
END $$;

-- 10b) `dorovnej_stab` NENÍ RPC a nesmí jít zavolat zvenčí.
--
-- Tohle je test na SKUTEČNOU DÍRU, která tu byla, než se zavřela. Postgres dává
-- na novou funkci EXECUTE roli PUBLIC automaticky a v Supabase je `public`
-- schéma vystavené přes PostgREST, takže šlo poslat
--     POST /rest/v1/rpc/dorovnej_stab   {"_event_id": "…"}
-- BEZ PŘIHLÁŠENÍ. Funkce je SECURITY DEFINER, takže by běžela s plnými právy.
-- Ověřeno před opravou: pod `SET ROLE anon` vrátila {"zruseno": 1} a směna byla
-- opravdu zrušená. Id akce se přitom do světa dostane úplně běžně.
--
-- Testuje se jak GRANT, tak SKUTEČNÉ CHOVÁNÍ — samotný `has_function_privilege`
-- by nechytil, kdyby EXECUTE dostala jiná role, přes kterou se `anon` dostane.
DO $$
DECLARE _akce uuid;
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.dorovnej_stab(uuid, boolean)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.dorovnej_stab(uuid, boolean)', 'EXECUTE'),
    'dorovnej_stab nemá EXECUTE pro anon ani authenticated');

  SELECT id INTO _akce FROM public.events WHERE title = 'TEST vznik' LIMIT 1;

  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.dorovnej_stab(_akce);
    RESET ROLE;
    RAISE EXCEPTION 'TEST SELHAL: anon zavolal dorovnej_stab — nepřihlášený uživatel může rušit směny';
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    RAISE NOTICE 'OK  anon dorovnej_stab NEZAVOLÁ (permission denied)';
  END;
END $$;

SET LOCAL ROLE authenticated;

-- Ne-admin pohled NEVIDÍ. Není to utajení: pod `security_invoker` by mu čísla
-- vyšla ŠPATNĚ (viděl by jen část rezervací a směn), a tiše nesprávný počet je
-- horší než prázdno.
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.stab_kontrola;
  PERFORM pg_temp.tvrd(_radku = 0,
    'člen (role authenticated): stab_kontrola je prázdná (nesprávný počet je horší než žádný)');
END $$;

SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.stab_kontrola;
  PERFORM pg_temp.tvrd(_radku = 0, 'brigádník (role authenticated): stab_kontrola je prázdná');
END $$;

RESET ROLE;

-- 10c) Pohled má i DRUHOU vrstvu, ne jen filtr v těle.
--
-- Supabase má na schématu `public` nastavené
--   ALTER DEFAULT PRIVILEGES … GRANT ALL ON TABLES TO anon, authenticated;
-- takže čerstvě vytvořený pohled dostane pro `anon` rovnou SELECT, INSERT,
-- UPDATE, DELETE, REFERENCES i TRIGGER — a migrace dělá DROP + CREATE VIEW,
-- takže by se to sypalo znovu při každé aplikaci.
--
-- Dnes by tím nic neuniklo (`security_invoker = on` + `has_role` v těle vrátí
-- nula řádků), ale ochrana by stála na JEDINÉ WHERE klauzuli, kterou příští
-- úprava pohledu smaže bez povšimnutí.
DO $$
DECLARE _anon int;
BEGIN
  SELECT count(*) INTO _anon FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'stab_kontrola'
     AND grantee IN ('anon', 'PUBLIC');
  PERFORM pg_temp.tvrd(_anon = 0,
    format('stab_kontrola nemá granty pro anon/PUBLIC (nalezeno %s)', _anon));

  PERFORM pg_temp.tvrd(
    (SELECT c.reloptions FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = 'stab_kontrola') @> ARRAY['security_invoker=on'],
    'stab_kontrola má security_invoker=on (bez něj by obcházel RLS podkladových tabulek)');
END $$;

SET LOCAL ROLE authenticated;

RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
