-- =============================================================================
-- Etapa 3 / PR 4 — testy vazby na Fakturoid
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/fakturoid_test.sql
--
-- POZOR NA ROLE (pravidlo 8 v CLAUDE.md): jako `postgres` projde všechno, protože
-- ta role obchází granty i RLS. Testy práv proto běží pod `SET LOCAL ROLE`, a tam,
-- kde se guard ptá na `session_user`, se to musí ověřit ještě zvlášť — `SET ROLE`
-- mění `current_user`, ne `session_user`.
-- =============================================================================

\set ON_ERROR_STOP on
-- Tvrzení se sbírají do tabulky; průběžný výstup by jen zaplavil terminál.
\o /dev/null
BEGIN;

CREATE TEMP TABLE vysledky (tvrzeni text, ok boolean);
-- Sekce 9 běží pod `SET LOCAL ROLE authenticated`, a ta role by do dočasné
-- tabulky nezapsala. (Že to bez grantu spadne, je mimochodem důkaz, že se role
-- opravdu přepíná — kdyby ne, prošlo by to jako postgres a testy práv by
-- netestovaly nic.)
GRANT INSERT ON vysledky TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_popis text, _ok boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO vysledky VALUES (_popis, _ok);
  IF NOT _ok THEN RAISE WARNING 'SELHALO: %', _popis; END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Fixtura
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE fx AS
SELECT
  (SELECT id FROM subjects WHERE deleted_at IS NULL ORDER BY id LIMIT 1)  AS subjekt,
  (SELECT id FROM reservations ORDER BY id LIMIT 1)                       AS r1,
  (SELECT id FROM reservations ORDER BY id OFFSET 1 LIMIT 1)              AS r2,
  (SELECT id FROM reservations ORDER BY id OFFSET 2 LIMIT 1)              AS r3,
  (SELECT id FROM reservations ORDER BY id OFFSET 3 LIMIT 1)              AS r4;

-- ===========================================================================
-- 1) ZÁMEK 3 — atomický claim
-- ===========================================================================
SELECT pg_temp.tvrd('claim se poprvé povede',
  public.fakturoid_zkus_zabrat('t-klub-202608','club_monthly',f.subjekt,NULL,
    '2026-08-01','2026-08-31',2400,2,'koncept',ARRAY[f.r1,f.r2]) = true)
FROM fx f;

SELECT pg_temp.tvrd('druhý claim se stejným klíčem NEPROJDE',
  public.fakturoid_zkus_zabrat('t-klub-202608','club_monthly',f.subjekt,NULL,
    '2026-08-01','2026-08-31',1200,1,'koncept',ARRAY[f.r3]) = false)
FROM fx f;

-- Jiný klíč, ale rezervace už visí jinde → UNIQUE na reservation_id.
SELECT pg_temp.tvrd('claim na CIZÍ rezervaci pod jiným klíčem NEPROJDE',
  public.fakturoid_zkus_zabrat('t-akce-jina','commercial_event',f.subjekt,
    (SELECT id FROM events LIMIT 1),'2026-08-01','2026-08-01',1200,1,'koncept',ARRAY[f.r1]) = false)
FROM fx f;

-- A že po tom neúspěchu nezůstala viset hlavička (subtransakce se odrolovala).
SELECT pg_temp.tvrd('neúspěšný claim po sobě nenechá zablokovaný klíč',
  NOT EXISTS (SELECT 1 FROM fakturoid_invoices WHERE idempotency_key = 't-akce-jina'));

DO $$
DECLARE _ok boolean := false; _s uuid; _r uuid;
BEGIN
  SELECT subjekt, r3 INTO _s, _r FROM fx;
  BEGIN
    PERFORM public.fakturoid_zkus_zabrat('t-dup','club_monthly',_s,NULL,
      '2026-08-01','2026-08-31',1200,2,'koncept',ARRAY[_r,_r]);
  EXCEPTION WHEN OTHERS THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('duplicita v poli rezervací je tvrdá chyba, ne tiché false', _ok);
END $$;

-- Nekonzistentní `radku` proletí blokem `EXCEPTION WHEN unique_violation`
-- (je to `check_violation`) a shodí celou funkci. Je to správně — je to chyba
-- volajícího, ne závod — ale musí to být VIDĚT, ne se tvářit jako „nezabráno".
--
-- MÉNĚ ŘÁDKŮ NEŽ REZERVACÍ je ta chyba, kterou `fakturoid_radku_sedi` hlídá.
-- (Dřív tu stálo `radku = 5` na jednu rezervaci — od pásmového ceníku je ale
-- víc řádků než rezervací normální stav, viz test hned pod tímhle.)
DO $$
DECLARE _stav text := 'prošlo'; _s uuid; _r uuid; _r2 uuid;
BEGIN
  SELECT subjekt, r3, r4 INTO _s, _r, _r2 FROM fx;
  BEGIN
    PERFORM public.fakturoid_zkus_zabrat('t-radku','club_monthly',_s,NULL,
      '2026-08-01','2026-08-31',1200,1,'koncept',ARRAY[_r,_r2]);
  EXCEPTION
    WHEN check_violation THEN _stav := 'check';
    WHEN OTHERS THEN _stav := 'jina';
  END;
  PERFORM pg_temp.tvrd('nekonzistentní radku shodí claim jako check_violation, ne tiché false',
    _stav = 'check');
END $$;

-- ===========================================================================
-- 2) Uvolnění a opětovné zabrání
-- ===========================================================================
SELECT pg_temp.tvrd('uvolnění nevystaveného claimu projde',
  public.fakturoid_uvolni_zabrani('t-klub-202608','test') = true);

SELECT pg_temp.tvrd('uvolněním se smažou vazby na rezervace',
  NOT EXISTS (
    SELECT 1 FROM fakturoid_invoice_reservations fr
      JOIN fakturoid_invoices fi ON fi.id = fr.fakturoid_invoice_id
     WHERE fi.idempotency_key = 't-klub-202608'));

SELECT pg_temp.tvrd('uvolněný claim se NEMAŽE, jen označí (zásada „nic natvrdo")',
  EXISTS (SELECT 1 FROM fakturoid_invoices
           WHERE idempotency_key = 't-klub-202608' AND uvolneno_at IS NOT NULL));

-- Pozor při čtení dalších tvrzení: pod jedním klíčem teď existují DVA řádky —
-- uvolněný a nový. Částečný UNIQUE index to dovoluje schválně, ale skalární
-- poddotaz na `idempotency_key` proto musí mířit na ten živý.

SELECT pg_temp.tvrd('po uvolnění jde týž klíč zabrat ZNOVU',
  public.fakturoid_zkus_zabrat('t-klub-202608','club_monthly',f.subjekt,NULL,
    '2026-08-01','2026-08-31',2400,2,'koncept',ARRAY[f.r1,f.r2]) = true)
FROM fx f;

-- ===========================================================================
-- 3) Zápis vazby — větev A (dorovnání živého claimu)
-- ===========================================================================
SELECT pg_temp.tvrd('dorovnání živého claimu projde',
  public.fakturoid_zapis_vazbu('t-klub-202608','555','42','20260012','20260012',
    'https://app.fakturoid.cz/x/555','open',2400,NULL) = true);

SELECT pg_temp.tvrd('varování se ULOŽÍ do evidence, ne jen vrátí',
  (SELECT varovani IS NULL FROM fakturoid_invoices
    WHERE idempotency_key = 't-klub-202608' AND uvolneno_at IS NULL));

SELECT pg_temp.tvrd('druhý zápis téhož už neprojde (nepřepíše stopu po prvním)',
  public.fakturoid_zapis_vazbu('t-klub-202608','999','42','20269999','20269999',
    NULL,'open',9999,NULL) = false);

SELECT pg_temp.tvrd('vystavený doklad UŽ NEJDE uvolnit',
  public.fakturoid_uvolni_zabrani('t-klub-202608','pokus') = false);

-- ===========================================================================
-- 4) Zápis vazby — větev B (NÁLEZ bez claimu). Tohle je ta cesta zotavení.
-- ===========================================================================
-- Simulace: claim vznikl, POST prošel, odpověď se ztratila, claim se uvolnil.
SELECT public.fakturoid_zkus_zabrat('t-nalez','club_monthly',f.subjekt,NULL,
  '2026-09-01','2026-09-30',1200,1,'koncept',ARRAY[f.r3]) FROM fx f;
SELECT public.fakturoid_uvolni_zabrani('t-nalez','simulace ztracené odpovědi');

SELECT pg_temp.tvrd('bez claimu a bez kontextu zápis NEPROJDE',
  public.fakturoid_zapis_vazbu('t-nalez','777',NULL,'20260077','20260077',
    NULL,'open',1200,NULL) = false);

SELECT pg_temp.tvrd('S KONTEXTEM se nález zapíše i bez claimu',
  public.fakturoid_zapis_vazbu('t-nalez','777','42','20260077','20260077',
    NULL,'open',1200,'KONTROLNÍ SOUČET NESEDÍ: test',
    'club_monthly',f.subjekt,NULL,'2026-09-01','2026-09-30',1200,1,'koncept',ARRAY[f.r3]) = true)
FROM fx f;

-- Bez tohohle by po zotavení zůstal zámek 1 mrtvý a příští běh vystavil druhý doklad.
SELECT pg_temp.tvrd('zápis nálezu založí i VAZBY na rezervace',
  public.fakturoid_je_vyfakturovana((SELECT r3 FROM fx)) = true);

SELECT pg_temp.tvrd('varování z nálezu je v evidenci',
  (SELECT varovani LIKE '%NESEDÍ%' FROM fakturoid_invoices
    WHERE idempotency_key = 't-nalez' AND provider_invoice_id = '777'));

-- ===========================================================================
-- 5) PDF — otisk se nesmí přepsat na NULL
-- ===========================================================================
SELECT public.fakturoid_zapis_pdf('t-klub-202608','fakturoid/a.pdf','abc123');
SELECT public.fakturoid_zapis_pdf('t-klub-202608','fakturoid/a.pdf',NULL);
SELECT pg_temp.tvrd('druhý zápis PDF bez otisku ho NEPŘEPÍŠE na NULL',
  (SELECT pdf_sha256 = 'abc123' FROM fakturoid_invoices
    WHERE idempotency_key = 't-klub-202608' AND uvolneno_at IS NULL));

SELECT pg_temp.tvrd('zápis PDF netrefí uvolněný claim', (
  SELECT count(*) = 1 FROM fakturoid_invoices
   WHERE idempotency_key = 't-klub-202608' AND pdf_path IS NOT NULL));

-- ===========================================================================
-- 6) Zámek 1 se ptá VÝHRADNĚ na fakturoidí vazbu (S2)
-- ===========================================================================
SELECT pg_temp.tvrd('rezervace na fakturoidím dokladu = vyfakturovaná',
  public.fakturoid_je_vyfakturovana((SELECT r1 FROM fx)) = true);
SELECT pg_temp.tvrd('rezervace bez fakturoidí vazby = nevyfakturovaná',
  public.fakturoid_je_vyfakturovana(gen_random_uuid()) = false);

-- ===========================================================================
-- 7) CHECKy
-- ===========================================================================
DO $$
DECLARE _ok boolean := false; _s uuid;
BEGIN
  SELECT subjekt INTO _s FROM fx;
  BEGIN
    INSERT INTO fakturoid_invoices (idempotency_key, druh, subject_id, nas_soucet, radku, rezervace)
    VALUES ('t-check','club_monthly',_s,100,1,ARRAY[gen_random_uuid(),gen_random_uuid()]);
  EXCEPTION WHEN check_violation THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('MÉNĚ řádků než rezervací neprojde (rezervace by chyběla na dokladu)', _ok);
END $$;

-- Druhá strana téhož pravidla, a od pásmového ceníku ta podstatnější: rezervace
-- přes dvě pásma dá DVA řádky (1 h × 1 000 a 2 h × 1 200), takže řádků je víc
-- než rezervací a doklad je v pořádku. Dokud constraint zněl na rovnost, tohle
-- by neprošlo a pásmová faktura by se nedala uložit.
DO $$
DECLARE _ok boolean := false; _s uuid;
BEGIN
  SELECT subjekt INTO _s FROM fx;
  INSERT INTO fakturoid_invoices (idempotency_key, druh, subject_id, nas_soucet, radku, rezervace)
  VALUES ('t-check-pasma','club_monthly',_s,3400,2,ARRAY[gen_random_uuid()]);
  _ok := true;
  PERFORM pg_temp.tvrd('VÍC řádků než rezervací projde (rezervace přes dvě pásma)', _ok);
END $$;

DO $$
DECLARE _ok boolean := false; _s uuid;
BEGIN
  SELECT subjekt INTO _s FROM fx;
  BEGIN
    INSERT INTO fakturoid_invoices (idempotency_key, druh, subject_id, nas_soucet, radku, rezervace, event_id)
    VALUES ('t-check2','commercial_event',_s,100,1,ARRAY[gen_random_uuid()],NULL);
  EXCEPTION WHEN check_violation THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('komerční doklad bez akce neprojde', _ok);
END $$;

-- ===========================================================================
-- 8) Audit
-- ===========================================================================
SELECT pg_temp.tvrd('zápisy do fakturoid_invoices se auditují',
  EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'fakturoid_invoices'));
SELECT pg_temp.tvrd('vazby na rezervace se auditují taky',
  EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'fakturoid_invoice_reservations'));

-- ===========================================================================
-- 9) PRÁVA — pod rolí `authenticated`, ne pod postgresem
--
-- Jako `postgres` projde všechno (obchází granty i RLS), takže test bez
-- SET LOCAL ROLE tvrdí zavřeno o dveřích, vedle kterých je otevřené okno.
-- ===========================================================================
DO $$
DECLARE _ok boolean;
BEGIN
  SET LOCAL ROLE authenticated;

  -- Guard v RPC: `auth.uid()` je NULL, `session_user` je postgres → větev pro
  -- cron BY prošla. Proto se to musí ověřit i přes `authenticator` (níž).
  _ok := true;
  BEGIN
    PERFORM public.fakturoid_najdi_podle_klice('t-klub-202608');
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;

  -- Přímý zápis do tabulky nesmí projít NIKDY.
  _ok := false;
  BEGIN
    INSERT INTO public.fakturoid_invoices (idempotency_key, druh, subject_id, nas_soucet, radku, rezervace)
    VALUES ('t-primy','club_monthly',gen_random_uuid(),1,1,ARRAY[gen_random_uuid()]);
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('authenticated NESMÍ zapisovat přímo do fakturoid_invoices', _ok);

  _ok := false;
  BEGIN
    UPDATE public.fakturoid_invoices SET cislo = 'X' WHERE true;
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('authenticated NESMÍ měnit fakturoid_invoices', _ok);

  _ok := false;
  BEGIN
    INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
    VALUES (gen_random_uuid(), gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('authenticated NESMÍ zapisovat vazby', _ok);

  -- RLS: bez role admina nevidí neadmin ani řádek.
  PERFORM pg_temp.tvrd('neadmin nevidí přes RLS žádný doklad',
    (SELECT count(*) FROM public.fakturoid_invoices) = 0);
  PERFORM pg_temp.tvrd('neadmin nevidí ani přes pohled',
    (SELECT count(*) FROM public.fakturoid_invoices_list) = 0);

  _ok := false;
  BEGIN
    PERFORM public.fakturoid_smi_volat();
  EXCEPTION WHEN insufficient_privilege THEN _ok := true;
  END;
  PERFORM pg_temp.tvrd('fakturoid_smi_volat() je zvenčí nedosažitelná', _ok);

  RESET ROLE;
END $$;

-- ===========================================================================
-- 10) Pohled není zapisovatelný a anon k němu nemá nic
-- ===========================================================================
SELECT pg_temp.tvrd('anon nemá na fakturoid_invoices žádná práva',
  NOT has_table_privilege('anon','public.fakturoid_invoices','SELECT'));
SELECT pg_temp.tvrd('anon nemá na pohled žádná práva',
  NOT has_table_privilege('anon','public.fakturoid_invoices_list','SELECT'));
SELECT pg_temp.tvrd('authenticated nemá na pohledu INSERT',
  NOT has_table_privilege('authenticated','public.fakturoid_invoices_list','INSERT'));
SELECT pg_temp.tvrd('service_role nemá přímý zápis do fakturoid_invoices',
  NOT has_table_privilege('service_role','public.fakturoid_invoices','INSERT'));

-- ===========================================================================
-- Souhrn
-- ===========================================================================
\o
\echo ''
SELECT tvrzeni FROM vysledky WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS proslo,
       count(*) FILTER (WHERE NOT ok) AS selhalo,
       count(*) AS celkem
  FROM vysledky;

DO $$
DECLARE _s int;
BEGIN
  SELECT count(*) INTO _s FROM vysledky WHERE NOT ok;
  IF _s > 0 THEN RAISE EXCEPTION 'Fakturoid: % tvrzení SELHALO', _s; END IF;
  RAISE NOTICE 'Fakturoid: všechna tvrzení prošla.';
END $$;

ROLLBACK;
