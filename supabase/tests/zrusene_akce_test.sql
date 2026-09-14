-- =============================================================================
-- TESTY: `zrusene_akce()` — zrušená akce není nadcházející (Přehled)
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/zrusene_akce_test.sql
--
-- CO TENHLE TEST HLÍDÁ NEJVÍC:
--
-- 1) ŽE NOVÁ FUNKCE UMÍ TO, CO SESTRA NEUMÍ. `zrusene_akce_se_smenami()` vrací
--    jen akce s rozpisem směn. Klubový trénink bez štábu žádnou směnu nemá,
--    takže z ní nevypadne — a právě takový zrušený trénink zůstával svítit na
--    Přehledu. Scénář 2 měří přesně tenhle rozdíl; bez něj by šlo „opravit"
--    Přehled starou funkcí a test by o tom mlčel.
--
-- 2) ŽE SE FUNKCE CHOVÁ STEJNĚ K BĚŽNÉMU ČLENOVI JAKO K ADMINOVI. `reservations`
--    mají RLS, která členovi pustí jen rezervace vlastního subjektu — u cizí
--    zrušené akce vidí NULA řádků (scénář 3 to měří, ne odhaduje). Bez obejití
--    RLS by mu vyšla prázdná množina, Přehled by nic neskryl a bug by se tiše
--    vrátil — přesně pro toho uživatele, kvůli kterému se to dělalo.
--
--    ⚠️ HISTORIE, KTEROU JE UŽITEČNÉ ZNÁT, AŤ SE TA CHYBA NEZOPAKUJE.
--    První podoba `zrusene_akce()` volala uvnitř `akce_je_zrusena()`, takže
--    v řetězu byly definery DVA a KAŽDÝ SÁM STAČIL. Změřeno 14. 9. 2026:
--
--      zrusene_akce  → INVOKER, akce_je_zrusena DEFINER   test ZELENÝ  ← maskováno
--      zrusene_akce  DEFINER, akce_je_zrusena → INVOKER   test ZELENÝ  ← maskováno
--      OBĚ           → INVOKER                            test ČERVENÝ
--
--    Mutace jedné funkce tehdy netvrdila nic — druhá ji zakryla. Po přepisu
--    těla na `GROUP BY` přes `reservations` (kvůli výkonu, viz hlavička migrace)
--    už se nic nemaskuje a každá mutace se chytá zvlášť. Přeměřeno:
--
--      zrusene_akce      → INVOKER   ČERVENÝ na 1a  (čte reservations pod RLS
--                                     volajícího, člen vidí jen svoje)
--      akce_je_zrusena   → INVOKER   ČERVENÝ na 3b  (rozejdou se definice)
--
--    Scénář 1a je přesto napsaný tak, aby měřil VÝSLEDEK (člen ty akce dostane),
--    ne kudy se k němu došlo.
--
-- 3) ŽE SE NESKRÝVÁ ŽIVÁ AKCE. Scénář 1b. Bez něj by šlo „opravit" Přehled tím,
--    že se vyprázdní celý.
--
-- 4) SMAZANOU REZERVACI TAKY (`deleted_at`), ne jen `status='cancelled'` —
--    zadání zní „zrušené i smazané" a `akce_je_zrusena` počítá obojí.
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

-- Spustí SELECT pod daným uživatelem v roli `authenticated` a vrátí počet řádků.
--
-- Schválně NE pod `postgres`: ten obchází granty i RLS, takže by test tvrdil
-- „funkce vrací zrušené akce" o funkci, ke které se běžný účet vůbec nedostane.
CREATE OR REPLACE FUNCTION pg_temp.pocet_jako(_sql text, _uziv uuid) RETURNS integer
 LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
  EXECUTE 'SELECT count(*) FROM (' || _sql || ') t' INTO _n;
  PERFORM set_config('role', 'none', true);
  RETURN _n;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('role', 'none', true);
  RAISE EXCEPTION 'Dotaz pod authenticated selhal: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- FIXTURY
-- ---------------------------------------------------------------------------
-- Tři akce, každá BEZ JEDINÉ SMĚNY. To je záměr: kdyby měly směny, prošel by
-- test i se starou `zrusene_akce_se_smenami()` a neměřil by nic nového.
--
--   A1  živá akce                         → nesmí se objevit
--   A2  zrušená (reservations.status)      → musí se objevit
--   A3  smazaná (reservations.deleted_at)  → musí se objevit
DO $$
DECLARE _sheet uuid; _subj uuid; _kdo uuid; _typ public.event_type;
BEGIN
  SELECT r.sheet_id, r.subject_id, r.created_by INTO _sheet, _subj, _kdo
    FROM public.reservations r WHERE r.status = 'confirmed' LIMIT 1;
  SELECT e.event_type INTO _typ FROM public.events e LIMIT 1;

  INSERT INTO public.events (id, title, event_type, start_time, end_time, required_staff, created_by)
  VALUES ('00000000-0000-0000-0000-00000000e0a1', 'TEST prehled ziva', _typ,
          '2027-07-01 08:00:00+00', '2027-07-01 10:00:00+00', 0, _kdo),
         ('00000000-0000-0000-0000-00000000e0a2', 'TEST prehled zrusena', _typ,
          '2027-07-02 08:00:00+00', '2027-07-02 10:00:00+00', 0, _kdo),
         ('00000000-0000-0000-0000-00000000e0a3', 'TEST prehled smazana', _typ,
          '2027-07-03 08:00:00+00', '2027-07-03 10:00:00+00', 0, _kdo);

  INSERT INTO public.reservations (id, event_id, sheet_id, start_at, end_at, status, subject_id, created_by)
  VALUES ('00000000-0000-0000-0000-00000000e0b1', '00000000-0000-0000-0000-00000000e0a1',
          _sheet, '2027-07-01 08:00:00+00', '2027-07-01 10:00:00+00', 'confirmed', _subj, _kdo),
         ('00000000-0000-0000-0000-00000000e0b2', '00000000-0000-0000-0000-00000000e0a2',
          _sheet, '2027-07-02 08:00:00+00', '2027-07-02 10:00:00+00', 'confirmed', _subj, _kdo),
         ('00000000-0000-0000-0000-00000000e0b3', '00000000-0000-0000-0000-00000000e0a3',
          _sheet, '2027-07-03 08:00:00+00', '2027-07-03 10:00:00+00', 'confirmed', _subj, _kdo);
END $$;

UPDATE public.reservations SET status = 'cancelled', cancelled_at = now()
 WHERE id = '00000000-0000-0000-0000-00000000e0b2';
UPDATE public.reservations SET deleted_at = now()
 WHERE id = '00000000-0000-0000-0000-00000000e0b3';

SELECT pg_temp.tvrd(
  NOT EXISTS (SELECT 1 FROM public.shifts
               WHERE event_id IN ('00000000-0000-0000-0000-00000000e0a1',
                                  '00000000-0000-0000-0000-00000000e0a2',
                                  '00000000-0000-0000-0000-00000000e0a3')),
  'FIXTURA: testovací akce nemají ŽÁDNOU směnu (jinak by test měřil starou funkci)');
SELECT pg_temp.tvrd(
  public.akce_je_zrusena('00000000-0000-0000-0000-00000000e0a2')
  AND public.akce_je_zrusena('00000000-0000-0000-0000-00000000e0a3')
  AND NOT public.akce_je_zrusena('00000000-0000-0000-0000-00000000e0a1'),
  'FIXTURA: dvě akce jsou zrušené (storno + smazání), jedna žije');

-- Účty. Bez téhle kontroly by scénáře mohly projít zeleně z jiného důvodu —
-- kdyby „řadový člen" byl potichu admin, RLS by ho nikde nezastavila.
SELECT pg_temp.tvrd(
  NOT public.has_role('30e86078-5435-445b-9a87-5f0c691c388f', 'admin')
  AND public.ucet_aktivni('30e86078-5435-445b-9a87-5f0c691c388f'),
  'FIXTURA: testovací účet je aktivní a NENÍ admin');

-- Fixtura bere `subject_id` z první confirmed rezervace (`LIMIT 1` bez ORDER BY).
-- Kdyby to náhodou byl subjekt testovacího člena, viděl by na ty rezervace
-- i pod svou RLS — a scénáře 1a a 3 by prošly zeleně, i kdyby funkce žádnou
-- RLS neobcházela. Test by pak měřil pořadí řádků, ne bránu.
-- Ptá se přímo na `subject_reps`, ne přes `is_subject_member` — ta funkce se
-- ptá na `auth.uid()`, které je tady (běh jako postgres) NULL, takže by vracela
-- false pro každý subjekt a tvrzení by bylo vždycky zeleně bezcenné.
SELECT pg_temp.tvrd(
  NOT EXISTS (
    SELECT 1
      FROM public.reservations r
      JOIN public.subject_reps sr ON sr.subject_id = r.subject_id
     WHERE r.id = '00000000-0000-0000-0000-00000000e0b2'
       AND sr.user_id = '30e86078-5435-445b-9a87-5f0c691c388f'
  ),
  'FIXTURA: fixturní subjekt NENÍ subjektem testovacího člena (jinak by 1a a 3 měřily náhodu)');

-- ---------------------------------------------------------------------------
-- 1) `zrusene_akce()` vrací zrušené a smazané, živou ne — pod authenticated
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.zrusene_akce() z
   WHERE z IN ('00000000-0000-0000-0000-00000000e0a2',
               '00000000-0000-0000-0000-00000000e0a3')
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 2,
  '1a) řadový člen dostane OBĚ zrušené akce (storno i smazání)');

SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.zrusene_akce() z
   WHERE z = '00000000-0000-0000-0000-00000000e0a1'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '1b) živá akce se mezi zrušenými NEOBJEVÍ (Přehled se nesmí vyprázdnit)');

-- ---------------------------------------------------------------------------
-- 2) PROČ NOVÁ FUNKCE: sestra tyhle akce nevrací, protože nemají směny
-- ---------------------------------------------------------------------------
-- Tohle je jádro celé změny. Kdyby se Přehled napojil na `zrusene_akce_se_smenami()`,
-- zrušený trénink bez štábu by na něm zůstal — a nikdo by to nepoznal.
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.zrusene_akce_se_smenami() z
   WHERE z IN ('00000000-0000-0000-0000-00000000e0a2',
               '00000000-0000-0000-0000-00000000e0a3')
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '2) sestra zrusene_akce_se_smenami() je NEVRACÍ — proto nová funkce existuje');

-- ---------------------------------------------------------------------------
-- 3) PROČ TO VŮBEC MUSÍ JÍT PŘES RPC: na ty rezervace týž účet nevidí
-- ---------------------------------------------------------------------------
-- Měřené, ne odhadnuté. Kdyby si Přehled počítal zrušení sám z `reservations`
-- (nebo kdyby celý řetěz běžel jako INVOKER — viz hlavička, mutace D), vyšlo by
-- mu nula řádků, tedy „akce neexistuje" — a filtr by neskryl nic.
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.reservations r
   WHERE r.event_id IN ('00000000-0000-0000-0000-00000000e0a2',
                        '00000000-0000-0000-0000-00000000e0a3')
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '3) týž účet na ty rezervace NEVIDÍ — bez obejití RLS by filtr neskryl nic');

-- ---------------------------------------------------------------------------
-- 3b) Funkce se SHODUJE s `akce_je_zrusena` na KAŽDÉ akci v databázi
-- ---------------------------------------------------------------------------
-- „Zrušená akce" má v tomhle repu jedinou definici — `akce_je_zrusena`. Brány
-- u směn se opírají o ni, Přehled o `zrusene_akce()`. Ty dvě dnes NESDÍLEJÍ KÓD
-- (`zrusene_akce()` má kvůli výkonu vlastní `GROUP BY` formulaci), takže je to
-- jediné místo, kde se případný rozchod projeví dřív než u klienta.
--
-- ROZSAH TOHOHLE TVRZENÍ, ať neslibuje víc, než umí: platí PRO AKTIVNÍ ÚČET.
-- `akce_je_zrusena` se na stav účtu neptá, `zrusene_akce()` ano (gate
-- `ucet_aktivni()`), takže pro neaktivního volajícího se ty dvě definice
-- rozcházejí schválně — a měří to scénář 3c, ne tenhle.
-- ⚠️ MUSÍ BĚŽET POD PŘIHLÁŠENÝM ÚČTEM, a schválně pod výslovně nastaveným.
-- Napoprvé tu stálo holé `SELECT ... FROM events`, spouštěné jako `postgres` —
-- a prošlo to, ačkoli `zrusene_akce()` vrací `postgres`u PRÁZDNO (gate
-- `ucet_aktivni()` je pro `auth.uid() IS NULL` false, změřeno). Prošlo to jen
-- proto, že `set_config('request.jwt.claims', …, true)` z předchozího scénáře
-- platí do konce transakce, takže se test tiše vezl na cizím přihlášení.
-- Je to táž past jako s `now()` u dedupu notifikací (viz ETAPA3-STAV.md 2c):
-- zelená z jiného důvodu, než jaký test tvrdí. Identita se proto nastavuje tady
-- a explicitně.
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.events e
   WHERE public.akce_je_zrusena(e.id) <> (e.id IN (SELECT * FROM public.zrusene_akce()))
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '3b) zrusene_akce() dává na KAŽDÉ akci totéž co akce_je_zrusena() (žádný drift)');

-- ---------------------------------------------------------------------------
-- 3c) Účet, kterého ještě nikdo nepustil dovnitř, nedostane nic
-- ---------------------------------------------------------------------------
-- Nález bezpečnostní brány ze 14. 9. 2026. Funkce byla jediný článek řetězu
-- bez default-deny brány z bloku C: `events` i `reservations_calendar` vrátily
-- deaktivovanému účtu nula řádků, RPC 52 UUID. Mutace (odebrat `ucet_aktivni()`
-- z těla funkce) musí tenhle scénář shodit — jinak nehlídá nic.
DO $$
DECLARE _puvodni text;
BEGIN
  SELECT stav::text INTO _puvodni FROM public.profiles
   WHERE user_id = '30e86078-5435-445b-9a87-5f0c691c388f';
  UPDATE public.profiles SET stav = 'ceka'
   WHERE user_id = '30e86078-5435-445b-9a87-5f0c691c388f';

  IF pg_temp.pocet_jako($sql$SELECT 1 FROM public.zrusene_akce()$sql$,
                        '30e86078-5435-445b-9a87-5f0c691c388f') <> 0 THEN
    RAISE EXCEPTION 'TEST SELHAL: 3c) neaktivní účet dostal seznam zrušených akcí';
  END IF;
  RAISE NOTICE '  OK  3c) neaktivní (neschválený) účet seznam zrušených akcí NEDOSTANE';

  EXECUTE format('UPDATE public.profiles SET stav = %L WHERE user_id = %L',
                 _puvodni, '30e86078-5435-445b-9a87-5f0c691c388f');
END $$;

-- ---------------------------------------------------------------------------
-- 4) Práva: nepřihlášený se k funkci nedostane
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(
  has_function_privilege('authenticated', 'public.zrusene_akce()', 'EXECUTE'),
  '4a) authenticated má EXECUTE');
SELECT pg_temp.tvrd(
  NOT has_function_privilege('anon', 'public.zrusene_akce()', 'EXECUTE'),
  '4b) anon EXECUTE NEMÁ');

-- Chybějící grant pro `service_role` je ROZHODNUTÍ, ne opomenutí — gate stojí
-- na `auth.uid()`, které volání se service key nemá, takže by funkce vracela
-- prázdno a filtr by se tiše choval fail-open. Tvrzení je tu proto, aby to
-- někdo příště „nedoplnil" v dobré víře.
SELECT pg_temp.tvrd(
  NOT has_function_privilege('service_role', 'public.zrusene_akce()', 'EXECUTE'),
  '4c) service_role EXECUTE NEMÁ — vědomě, grant by sliboval nefunkční právo');

ROLLBACK;
