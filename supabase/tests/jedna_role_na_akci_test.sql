-- =============================================================================
-- TESTY: jedna role na akci jenom jednou — a nedá se to obejít schvalováním
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/jedna_role_na_akci_test.sql
--
-- CO TENHLE TEST HLÍDÁ NEJVÍC:
--
-- 1) ŽE SE HLÍDAJÍ OBĚ CESTY, NE JEN SAMOOBSLUHA. Scénář 2 je ten, kvůli
--    kterému test vznikl: kontrola „jednu roli jednou" seděla uvnitř větve
--    `open -> pending`, takže schvalování přihlášky (které píše rovnou
--    `open -> claimed`) ji PŘESKOČILO CELOU. Scénář 7 měří tutéž věc přes
--    samoobsluhu — ta padala i předtím. Kdyby byl v souboru jen scénář 7,
--    tvrdil by „zavřeno" o dveřích, vedle kterých bylo otevřené okno.
--
-- 2) ŽE INDEX DRŽÍ I MIMO TRIGGER. Scénáře 6 a 9 zapisují `INSERT`em rovnou
--    obsazenou směnu. `validate_shift_claim` je BEFORE **UPDATE**, takže tudy
--    neuvidí nic — chytit to musí unikátní index. Tudy vkládá `prirad_trenera`,
--    takže to není teoretická cesta.
--
-- 3) ŽE SE NEZAVŘELO VÍC, NEŽ MĚLO. Scénář 3 je nejdůležitější test celého
--    souboru: RŮZNÉ role na téže akci musí dál PROCHÁZET. Brigádník, který na
--    jedné akci dělá bar a zároveň instruktora, je běžný provoz a platí se za
--    obojí (potvrzeno klientem 1. 9. 2026); na produkci takový případ reálně
--    leží (instructor + bar_staff, obě `completed`). Kdyby to někdo příště
--    „zpřísnil" na jednu směnu na akci, má to spadnout tady.
--    Totéž hlídají scénáře 4 (jiná akce), 5 (zrušená neblokuje), 8 (úprava
--    hodin na dokončené) a 10 (uvolnit a vzít si znovu).
--
-- 4) ŽE UŽIVATEL ČTE ČESKOU VĚTU, NE „duplicate key value violates…".
--    Scénáře 2 a 7 kontrolují ZNĚNÍ hlášky, ne jen to, že se zápis nepovedl.
--    Bez kontroly znění projde i stav, kdy trigger mlčí a chytá to až index —
--    což je funkčně v pořádku, ale uživateli to nic neřekne. Změřeno: přesně
--    tenhle rozdíl je jediné, co odlišuje opravený trigger od původního.
--
-- Admin a brigádník jsou schválně RŮZNÍ lidé. Na produkci je jeden účet
-- zároveň admin i instruktor, a kdyby test vzal jeho, netestoval by větev
-- „admin přiřazuje NĚKOHO JINÉHO" ani její jinou hlášku.
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

-- Vrátí hlášku, na které zápis spadl, nebo NULL když prošel.
--
-- `EXECUTE` s dynamickým SQL je tu v pořádku a NEODPORUJE bodu 8 v CLAUDE.md:
-- je to funkce v `pg_temp` (žije jen v této session), není grantovaná
-- `authenticated` a není dosažitelná z API. Do `public` takovou funkci dát nelze.
--
-- Blok `EXCEPTION` navíc otevírá subtransakci, takže neúspěšný pokus se vrátí
-- sám a nezabije zbytek testu. Předchozí podoba téhle sady tohle neměla a
-- scénář 3 se kvůli tomu VŮBEC NESPUSTIL — jen se tvářil jako změřený.
CREATE OR REPLACE FUNCTION pg_temp.zkus(_sql text) RETURNS text
 LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE _sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;

-- Přepnutí do role žadatele. `set_config('role', …, true)` = `SET LOCAL ROLE`.
-- Musí se volat ZNOVU po každém zachyceném výjimkovém bloku: subtransakce se
-- vrátila a s ní i nastavení.
CREATE OR REPLACE FUNCTION pg_temp.jako(_uid uuid) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
END $$;

-- Smaže směny nasazené tímhle testem. Scénáře běží v JEDNÉ transakci (ROLLBACK
-- je až na konci), takže bez úklidu by si kulisy jednoho scénáře srazily
-- s kulisami dalšího — a index by spadl v SETUPU, ne v měřeném kroku.
-- Poznáváme je podle `notes`, ne podle id: id se časem přidávají a na jedno
-- se vždycky zapomene.
CREATE OR REPLACE FUNCTION pg_temp.uklid() RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM shifts WHERE notes = 'TEST-jedna-role';
END $$;

-- ---------------------------------------------------------------------------
-- Herci a kulisy
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE t_kdo AS
SELECT
  (SELECT ur.user_id FROM user_roles ur
    WHERE ur.role = 'instructor'
      AND NOT EXISTS (SELECT 1 FROM user_roles a
                       WHERE a.user_id = ur.user_id AND a.role = 'admin')
    ORDER BY ur.user_id LIMIT 1)                                      AS bri,
  (SELECT ur.user_id FROM user_roles ur WHERE ur.role = 'admin'
    ORDER BY ur.user_id LIMIT 1)                                      AS adm,
  -- AKCE MUSÍ BÝT ŽIVÉ, JINAK BARVA TESTU ZÁVISÍ NA CIZÍCH DATECH.
  --
  -- Replika se plní z produkce, takže „nejnovější akce" je ta, kterou klient
  -- naposled založil. Jakmile bude zrušená, `validate_shift_claim` odmítne
  -- obsadit na ní cokoli („Akce je zrušená, směnu na ní vzít nelze.") a
  -- zčervenaly by scénáře, které se změnou vůbec nesouvisí (1, 3, 4, 5;
  -- u 10 by se uvolnění navíc překlopilo na `cancelled` a 10b spadlo na
  -- „Zrušenou směnu znovu otevírá jen správce haly."). Dnes je to zelené jen
  -- shodou okolností — nejnovější akce na produkci zrušené nejsou.
  (SELECT e.id FROM events e WHERE NOT public.akce_je_zrusena(e.id)
    ORDER BY e.created_at DESC LIMIT 1)                               AS ev1,
  (SELECT e.id FROM events e WHERE NOT public.akce_je_zrusena(e.id)
    ORDER BY e.created_at DESC OFFSET 1 LIMIT 1)                      AS ev2;

DO $$
DECLARE _k record;
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.tvrd(_k.bri IS NOT NULL, 'v datech je instruktor bez adminské role');
  PERFORM pg_temp.tvrd(_k.adm IS NOT NULL, 'v datech je admin');
  PERFORM pg_temp.tvrd(_k.adm <> _k.bri,   'admin a brigádník jsou RŮZNÍ lidé (jinak test neměří druhou hlášku)');
  PERFORM pg_temp.tvrd(_k.ev1 IS NOT NULL AND _k.ev2 IS NOT NULL,
    'v datech jsou aspoň dvě NEZRUŠENÉ akce (na zrušené nejde obsadit nic a test by měřil to)');
END $$;

-- ---------------------------------------------------------------------------
-- Scénáře
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  _k     record;
  _chyba text;
  -- Pevná id, ať se na ně dá odkázat v dynamickém SQL.
  _a1 uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  _a2 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  _a3 uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 1) Schvalovací cesta, PRVNÍ přiřazení — musí projít ================
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, notes)
  VALUES (_a1, _k.ev1, 'open', 200, 'instructor', 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''claimed'', claimed_by=%L, claimed_at=now() WHERE id=%L',
    _k.bri, _a1));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '1) admin přiřadí brigádníka na volnou směnu (open -> claimed)');

  -- === 2) TÁŽ role, TÁŽ akce, schvalovací cestou — MUSÍ SPADNOUT ==========
  -- Tohle je ten nález: dřív prošlo, protože kontrola visela na `-> pending`.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, notes)
  VALUES (_a2, _k.ev1, 'open', 200, 'instructor', 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''claimed'', claimed_by=%L, claimed_at=now() WHERE id=%L',
    _k.bri, _a2));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba LIKE '%už na této akci tuhle roli má%',
    '2) druhá směna TÉŽE role schvalovací cestou se odmítne — a českou větou');

  -- === 3) JINÁ role na téže akci — musí PROJÍT ============================
  -- Nejdůležitější test souboru: hlídá, že se nezavřelo víc, než mělo.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, notes)
  VALUES (_a3, _k.ev1, 'open', 200, 'bar_staff', 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''claimed'', claimed_by=%L, claimed_at=now() WHERE id=%L',
    _k.bri, _a3));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '3) JINÁ role na téže akci projde (bar + instruktor je běžný provoz)');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _b1 uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  _b2 uuid := 'bbbbbbbb-0000-0000-0000-000000000002';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 4) TÁŽ role na JINÉ akci — musí projít =============================
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, notes)
  VALUES (_b1, _k.ev1, 'claimed', 200, 'instructor', _k.bri, 'TEST-jedna-role');
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, notes)
  VALUES (_b2, _k.ev2, 'open', 200, 'instructor', 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''claimed'', claimed_by=%L WHERE id=%L', _k.bri, _b2));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '4) TÁŽ role na JINÉ akci projde (omezení je per akce, ne globální)');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _c1 uuid := 'cccccccc-0000-0000-0000-000000000001';
  _c2 uuid := 'cccccccc-0000-0000-0000-000000000002';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 5) ZRUŠENÁ směna téže role neblokuje novou =========================
  -- Kdyby `cancelled` v predikátu indexu bylo, člověk by si po zrušení směnu
  -- na téže akci už nikdy nevzal. Proto tam schválně není.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, cancelled_at, notes)
  VALUES (_c1, _k.ev1, 'cancelled', 200, 'instructor', _k.bri, now(), 'TEST-jedna-role');
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, notes)
  VALUES (_c2, _k.ev1, 'open', 200, 'instructor', 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''claimed'', claimed_by=%L WHERE id=%L', _k.bri, _c2));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '5) zrušená směna téže role NEBLOKUJE novou na téže akci');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _d1 uuid := 'dddddddd-0000-0000-0000-000000000001';
  _d2 uuid := 'dddddddd-0000-0000-0000-000000000002';
  _n1 uuid := '99999999-0000-0000-0000-000000000001';
  _n2 uuid := '99999999-0000-0000-0000-000000000002';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 6) INSERT rovnou obsazené směny — chytá až INDEX ===================
  -- `validate_shift_claim` je BEFORE UPDATE, tudy neuvidí nic.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, notes)
  VALUES (_d1, _k.ev1, 'claimed', 200, 'instructor', _k.bri, 'TEST-jedna-role');
  _chyba := pg_temp.zkus(format(
    'INSERT INTO shifts (id,event_id,status,hourly_rate,required_role,claimed_by,notes)
     VALUES (%L,%L,''claimed'',200,''instructor'',%L,''TEST-jedna-role'')', _d2, _k.ev1, _k.bri));
  PERFORM pg_temp.tvrd(_chyba LIKE '%shifts_jedna_role_na_akci%',
    '6) druhá obsazená směna téže role INSERTem (mimo trigger) padne na indexu');

  -- === 9) Dvě směny BEZ role — NULLS NOT DISTINCT =========================
  -- Bez `NULLS NOT DISTINCT` by tohle prošlo: NULL se v indexu běžně nerovná
  -- NULL. Trigger to řeší přes `IS NOT DISTINCT FROM`, index tímhle.
  INSERT INTO shifts (id, event_id, status, hourly_rate, claimed_by, notes)
  VALUES (_n1, _k.ev1, 'claimed', 200, _k.bri, 'TEST-jedna-role');
  _chyba := pg_temp.zkus(format(
    'INSERT INTO shifts (id,event_id,status,hourly_rate,claimed_by,notes)
     VALUES (%L,%L,''claimed'',200,%L,''TEST-jedna-role'')', _n2, _k.ev1, _k.bri));
  PERFORM pg_temp.tvrd(_chyba LIKE '%shifts_jedna_role_na_akci%',
    '9) dvě směny BEZ role na téže akci se srazí (NULLS NOT DISTINCT)');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _e1 uuid := 'eeeeeeee-0000-0000-0000-000000000001';
  _e2 uuid := 'eeeeeeee-0000-0000-0000-000000000002';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 7) Samoobsluha (open -> pending) — hlídané i předtím ===============
  -- Kontrolní vzorek: kdyby zčervenal tenhle, oprava rozbila starou cestu.
  -- Hlídá se i ZNĚNÍ — tady má stát „máte", ne „tenhle člověk".
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, notes)
  VALUES (_e1, _k.ev1, 'pending', 200, 'instructor', _k.bri, 'TEST-jedna-role');
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, notes)
  VALUES (_e2, _k.ev1, 'open', 200, 'instructor', 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.bri);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''pending'', claimed_by=%L WHERE id=%L', _k.bri, _e2));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba LIKE '%Na této akci už tuhle roli máte%',
    '7) samoobsluha druhé směny téže role se odmítne — a hláškou pro samotného žadatele');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _f1 uuid := 'ffffffff-0000-0000-0000-000000000001';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 8) Úprava hodin na DOKONČENÉ směně — nesmí zaškrtnout ==============
  --
  -- CO TENHLE SCÉNÁŘ DOOPRAVDY PINUJE — a co ne. Změřeno mutacemi 14. 9. 2026,
  -- protože první znění tohohle komentáře tvrdilo víc, než je pravda:
  --
  --   * Samotné vypuštění podmínky „obsazení se změnilo" scénář NEZČERVENÁ.
  --     Kontrola by sice běžela i při úpravě hodin, ale nic by nenašla:
  --     index `shifts_jedna_role_na_akci` zaručuje, že druhý takový řádek
  --     nemůže existovat, takže `EXISTS` je vždycky false. Ta podmínka je
  --     tedy VÝKONOVÁ pojistka (ušetří poddotaz), ne nosný prvek — a tvrdit
  --     o ní, že „bez ní spadne proplácení", by bylo nepravdivé.
  --   * Zčervená ale na DVOJICI mutací: bez té podmínky A ZÁROVEŇ bez
  --     `id != NEW.id` se kontrola potká sama se sebou (BEFORE UPDATE vidí
  --     v tabulce ještě starý řádek) a proplácení spadne. Ověřeno.
  --
  -- Samotné `id != NEW.id` pinují scénáře 11 a 12 níž — tam kontrola běží
  -- (obsazení se mění) a starý řádek už obsazený JE.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, hours_worked, completed_at, notes)
  VALUES (_f1, _k.ev1, 'completed', 200, 'instructor', _k.bri, 4, now(), 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format('UPDATE shifts SET hours_worked=5 WHERE id=%L', _f1));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '8) admin upraví hodiny na dokončené směně (obsazení se nemění)');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _g1 uuid := '77777777-0000-0000-0000-000000000001';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 10) Uvolnit a vzít si znovu — musí jít ============================
  -- Při uvolnění jde `claimed_by` na NULL, takže řádek z indexu vypadne
  -- a člověk si tutéž směnu může vzít zpátky.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, notes)
  VALUES (_g1, _k.ev1, 'claimed', 200, 'instructor', _k.bri, 'TEST-jedna-role');
  PERFORM pg_temp.jako(_k.bri);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''open'', claimed_by=NULL WHERE id=%L', _g1));
  PERFORM pg_temp.tvrd(_chyba IS NULL, '10a) držitel směnu uvolní');
  PERFORM pg_temp.jako(_k.bri);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''pending'', claimed_by=%L WHERE id=%L', _k.bri, _g1));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL, '10b) a hned si ji vezme zpátky');
END $$;

DO $$
DECLARE
  _k record; _chyba text;
  _h1 uuid := '12121212-0000-0000-0000-000000000001';
BEGIN
  SELECT * INTO _k FROM t_kdo;
  PERFORM pg_temp.uklid();

  -- === 11) Schválení `pending -> claimed` — musí PROJÍT ===================
  -- === 12) Dokončení `claimed -> completed` — musí PROJÍT =================
  --
  -- PROČ TU OBOJE JE: obě cesty mění obsazení, takže kontrola BĚŽÍ, a starý
  -- řádek v tabulce už toho člověka v téže roli drží (BEFORE UPDATE vidí ještě
  -- `OLD`). Je to jediné místo v sadě, kde `id != NEW.id` rozhoduje — bez něj
  -- se kontrola potká sama se sebou a obě cesty spadnou na
  -- „Tenhle člověk už na této akci tuhle roli má." Změřeno.
  --
  -- Nejsou to teoretické cesty: 11 je `approveShift` (admin schvaluje žádost),
  -- 12 je dokončení směny, tedy PODKLAD PRO VÝPLATU. Sada je do 14. 9. 2026
  -- nepokrývala vůbec, takže by tuhle regresi propustila až k penězům.
  INSERT INTO shifts (id, event_id, status, hourly_rate, required_role, claimed_by, notes)
  VALUES (_h1, _k.ev1, 'pending', 200, 'instructor', _k.bri, 'TEST-jedna-role');

  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format('UPDATE shifts SET status=''claimed'' WHERE id=%L', _h1));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '11) admin schválí žádost (pending -> claimed) — kontrola se nepotká sama se sebou');

  PERFORM pg_temp.jako(_k.adm);
  _chyba := pg_temp.zkus(format(
    'UPDATE shifts SET status=''completed'', hours_worked=4, completed_at=now() WHERE id=%L', _h1));
  PERFORM set_config('role', 'postgres', true);
  PERFORM pg_temp.tvrd(_chyba IS NULL,
    '12) admin dokončí směnu (claimed -> completed) — výplatní cesta projde');
END $$;

-- ---------------------------------------------------------------------------
-- Kontrola, že index vůbec existuje A ŽE HLÍDÁ TO SPRÁVNÉ
-- ---------------------------------------------------------------------------
-- Bez tohohle by celá sada zůstala zelená i na databázi, kde migrace neproběhla:
-- scénáře 2 a 7 drží triggerem, 6 a 9 by pak byly jediné dvě červené — ale
-- kdyby někdo v budoucnu jejich očekávání „opravil", nepozná se to vůbec.
-- Kontrola na SAMOTNOU EXISTENCI nestačí: `CREATE INDEX IF NOT EXISTS`
-- porovnává jen jméno, takže index téhož jména s jiným klíčem by prošel tiše.
-- Hlídá se proto i definice — hlavně `required_role` (bez něj je to varianta
-- zamítnutá 1. 9. 2026) a `NULLS NOT DISTINCT` (bez něj se dvě bezrolové
-- směny přestanou srážet a scénář 9 by měřil náhodu).
DO $$
DECLARE _def text;
BEGIN
  SELECT indexdef INTO _def FROM pg_indexes
   WHERE schemaname = 'public' AND indexname = 'shifts_jedna_role_na_akci';
  PERFORM pg_temp.tvrd(_def IS NOT NULL,
    'index shifts_jedna_role_na_akci na databázi existuje');
  PERFORM pg_temp.tvrd(_def LIKE '%required_role%',
    'index má v klíči required_role (jinak by blokoval legitimní bar + instruktor)');
  PERFORM pg_temp.tvrd(_def LIKE '%NULLS NOT DISTINCT%',
    'index má NULLS NOT DISTINCT (jinak se dvě směny bez role nesrazí)');
  PERFORM pg_temp.tvrd(_def NOT LIKE '%cancelled%',
    'predikát nezahrnuje cancelled (zrušená směna nesmí blokovat novou)');
END $$;

ROLLBACK;
