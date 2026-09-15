-- =============================================================================
-- TESTY: náhled „nevyfakturované akce" vidí i fakturoidí doklady
-- Migrace 20260915110000_nevyfakturovane_akce_vidi_fakturoid.sql
-- =============================================================================
-- `nevyfakturovane_akce` se ptala jen na INTERNÍ vazbu (`reservations.invoice_id`),
-- kdežto fakturoidí cesta zapisuje do `fakturoid_invoice_reservations` a do
-- `reservations` schválně nesahá. Dialog „Faktura za akci" proto nabízel už
-- vystavenou akci donekonečna.
--
-- NEJCENNĚJŠÍ TVRZENÍ (sekce 3 a 4): po vystavení akce z náhledu ZMIZÍ, a to,
-- co náhled ukazuje, se POČTEM I SOUČTEM shoduje s tím, co by vystavila
-- `fakturoid_podklady_akce`. Druhá půlka je ta podstatná: bez ní může náhled
-- zmizet správně a přitom ukazovat jinou částku, než jaká půjde na doklad —
-- a admin odklikne číslo, které nikdy neviděl.
--
-- MUTAČNÍ ZKOUŠKA — naměřeno 15. 9. 2026, každý filtr odstraněn ZVLÁŠŤ:
--
--   fakturoidí filtr, hlavní větev    → červená sekce 5 (ČÁSTEČNÉ)
--   fakturoidí filtr, `EXISTS`        → červená sekce 6 (OBDOBÍ)
--   fakturoidí filtr, „bez akce"      → červená sekce 7 (BEZ AKCE)
--   všechny tři najednou              → červená sekce 3 (JÁDRO)
--   filtr ceny zadarmo, hlavní větev  → červená sekce 7b (ZADARMO)
--   filtr ceny zadarmo, „bez akce"    → červená sekce 7b (ZADARMO BEZ AKCE)
--
-- ⚠️ Hlavní větev sama o sobě sekci 3 NESHODÍ — filtr v `EXISTS` celou zabranou
-- akci schová i bez ní. Dřívější znění téhle poznámky jmenovalo sekce 3, 4, 6, 7;
-- neplatilo to a mátlo by to příštího člověka při mutační zkoušce.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_p boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_p, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis; RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): mělo to skončit chybou, ale prošlo', _popis;
END $$;

-- Náhled vs. to, co by se doopravdy vystavilo. Vrací počet rezervací a součet
-- z OBOU zdrojů, ať se dá porovnat jedním tvrzením.
CREATE OR REPLACE FUNCTION pg_temp.shoda_se_serverem(_sub uuid, _ev uuid, _od date, _do date)
RETURNS TABLE (nahled_pocet bigint, nahled_castka numeric, server_pocet bigint, server_castka numeric)
 LANGUAGE sql AS $$
  SELECT (SELECT n.rezervaci FROM public.nevyfakturovane_akce(_sub, _od, _do) n
           WHERE n.event_id IS NOT DISTINCT FROM _ev),
         (SELECT n.castka    FROM public.nevyfakturovane_akce(_sub, _od, _do) n
           WHERE n.event_id IS NOT DISTINCT FROM _ev),
         (SELECT count(*)      FROM public.fakturoid_podklady_akce(_ev) p),
         (SELECT sum(p.castka) FROM public.fakturoid_podklady_akce(_ev) p);
$$;

-- Totéž pro KLUBOVOU cestu. Ta jde přes `fakturoid_podklady_klub` a ta se
-- na `event_id` NEPTÁ — vystaví celé období. Náhled „Rezervace bez akce" tedy
-- svůj řádek se serverem porovnávat NEMŮŽE; porovnává se SOUČET všech řádků
-- náhledu proti tomu, co klubová cesta vystaví.
CREATE OR REPLACE FUNCTION pg_temp.klub_vs_server(_sub uuid, _od date, _do date)
RETURNS TABLE (nahled_pocet bigint, nahled_castka numeric, server_pocet bigint, server_castka numeric)
 LANGUAGE sql AS $$
  SELECT (SELECT sum(n.rezervaci) FROM public.nevyfakturovane_akce(_sub,_od,_do) n),
         (SELECT sum(n.castka)    FROM public.nevyfakturovane_akce(_sub,_od,_do) n),
         (SELECT count(*)         FROM public.fakturoid_podklady_klub(_sub,_od,_do) p),
         (SELECT sum(p.castka)    FROM public.fakturoid_podklady_klub(_sub,_od,_do) p);
$$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);

-- -----------------------------------------------------------------------------
-- 0) Komerční akce na OBOU dráhách — 2 rezervace, 4 h à 5 000 Kč = 2 × 20 000.
--    Dvě dráhy schválně: umožní to otestovat i ČÁSTEČNÉ zabrání (sekce 5).
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _r1 uuid; _r2 uuid; _sub uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Demo Firma s.r.o.';

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST nahled fakturoid', 'commercial',
          '2029-08-14 16:00+02', '2029-08-14 20:00+02',
          '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _ev;

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub, _ev,
          '2029-08-14 16:00+02','2029-08-14 20:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _r1;

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 2'), _sub, _ev,
          '2029-08-14 16:00+02','2029-08-14 20:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _r2;

  INSERT INTO _s VALUES ('sub',_sub::text), ('ev',_ev::text), ('r1',_r1::text), ('r2',_r2::text);
END $$;

-- -----------------------------------------------------------------------------
-- 1) PŘED vystavením: akce se nabízí, obě dráhy
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _n record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';

  SELECT * INTO _n FROM public.nevyfakturovane_akce(_sub,'2029-08-01','2029-08-31')
   WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_n.event_id IS NOT NULL, 'PŘED: akce se v náhledu nabízí');
  PERFORM pg_temp.tvrd(_n.rezervaci = 2,        'PŘED: náhled vidí obě dráhy');
  PERFORM pg_temp.tvrd(_n.castka = 40000,       'PŘED: náhled sčítá 40 000 Kč');
END $$;

-- -----------------------------------------------------------------------------
-- 2) PŘED vystavením se náhled a server shodují
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _p record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT * INTO _p FROM pg_temp.shoda_se_serverem(_sub,_ev,'2029-08-01','2029-08-31');
  PERFORM pg_temp.tvrd(_p.nahled_pocet = _p.server_pocet,
    'PŘED: počet rezervací v náhledu = počet, který by šel na doklad');
  PERFORM pg_temp.tvrd(_p.nahled_castka = _p.server_castka,
    'PŘED: částka v náhledu = částka, která by šla na doklad');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: po vystavení fakturoidího dokladu akce z náhledu ZMIZÍ
--    Tohle je ten nález. Před opravou se nabízela dál.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _r1 uuid; _r2 uuid; _pocet integer;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT hodnota::uuid INTO _r1  FROM _s WHERE klic='r1';
  SELECT hodnota::uuid INTO _r2  FROM _s WHERE klic='r2';

  PERFORM public.fakturoid_zkus_zabrat('akce-'||_ev::text, 'commercial_event', _sub, _ev,
          NULL, NULL, 40000, 2, 'koncept', ARRAY[_r1,_r2]);

  -- Kontrola předpokladu: rezervace do `reservations.invoice_id` NEDOSTALY nic.
  -- Kdyby ano, test by procházel z jiného důvodu, než kvůli kterému existuje.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations WHERE id IN (_r1,_r2) AND invoice_id IS NOT NULL) = 0,
    'PŘEDPOKLAD: fakturoidí cesta do reservations.invoice_id nezapsala nic');

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2029-08-01','2029-08-31')
   WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_pocet = 0,
    'JÁDRO: vystavená akce se v náhledu už NENABÍZÍ (bez opravy se nabízela dál)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) PO vystavení se náhled a server pořád shodují — obojí prázdné
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _p record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT * INTO _p FROM pg_temp.shoda_se_serverem(_sub,_ev,'2029-08-01','2029-08-31');
  PERFORM pg_temp.tvrd(_p.server_pocet = 0,
    'PO: fakturoid_podklady_akce už nevrací nic (server odmítne)');
  PERFORM pg_temp.tvrd(_p.nahled_pocet IS NULL,
    'PO: náhled taky nic — UI a server říkají totéž');
END $$;

-- -----------------------------------------------------------------------------
-- 5) ČÁSTEČNÉ zabrání: doklad jen na jednu dráhu ⇒ akce se nabízí DÁL,
--    ale jen tou zbývající — a zase shodně se serverem.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _r1 uuid; _r2 uuid; _p record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT hodnota::uuid INTO _r1  FROM _s WHERE klic='r1';
  SELECT hodnota::uuid INTO _r2  FROM _s WHERE klic='r2';

  -- Uvolníme celý claim a zabereme znovu jen Dráhu 1. Obojí s tvrzením na
  -- návratovou hodnotu — bez něj by tichý neúspěch uvolnění vypadal jako
  -- úspěšné částečné zabrání a zbytek sekce by měřil něco jiného, než tvrdí.
  PERFORM pg_temp.tvrd(
    public.fakturoid_uvolni_zabrani('akce-'||_ev::text, 'test — částečné zabrání'),
    'ČÁSTEČNÉ: původní claim se podařilo uvolnit');
  PERFORM pg_temp.tvrd(
    public.fakturoid_zkus_zabrat('akce-cast-'||_ev::text, 'commercial_event', _sub, _ev,
          NULL, NULL, 20000, 1, 'koncept', ARRAY[_r1]),
    'ČÁSTEČNÉ: zabrání jen Dráhy 1 prošlo');

  SELECT * INTO _p FROM pg_temp.shoda_se_serverem(_sub,_ev,'2029-08-01','2029-08-31');
  PERFORM pg_temp.tvrd(_p.nahled_pocet = 1,
    'ČÁSTEČNÉ: náhled ukazuje jen nezabranou dráhu');
  PERFORM pg_temp.tvrd(_p.nahled_pocet = _p.server_pocet,
    'ČÁSTEČNÉ: počet v náhledu = počet na dokladu');
  PERFORM pg_temp.tvrd(_p.nahled_castka = _p.server_castka,
    'ČÁSTEČNÉ: částka v náhledu = částka na dokladu (20 000, ne 40 000)');

  PERFORM public.fakturoid_uvolni_zabrani('akce-cast-'||_ev::text, 'test — úklid');
END $$;

-- -----------------------------------------------------------------------------
-- 6) VĚTEV VÝBĚRU OBDOBÍ (`EXISTS`). Akce, jejíž JEDINÁ rezervace v období
--    je zabraná, se do výběru nesmí dostat — ani přes rezervaci mimo období.
--    Bez filtru v `EXISTS` by akce vyskočila zpátky.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _rv uuid; _rz uuid; _pocet integer;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST nahled pres mesic', 'commercial',
          '2029-09-30 16:00+02', '2029-10-01 20:00+02',
          '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _ev;

  -- v ZÁŘÍ (to je zobrazené období)
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub, _ev,
          '2029-09-30 16:00+02','2029-09-30 20:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rz;
  -- v ŘÍJNU (mimo zobrazené období)
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub, _ev,
          '2029-10-01 16:00+02','2029-10-01 20:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rv;

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2029-09-01','2029-09-30')
   WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_pocet = 1, 'OBDOBÍ: dokud je zářijová rezervace volná, akce se v září nabízí');

  -- Zabereme JEN zářijovou. Říjnová zůstává volná.
  PERFORM public.fakturoid_zkus_zabrat('akce-zari-'||_ev::text, 'commercial_event', _sub, _ev,
          NULL, NULL, 20000, 1, 'koncept', ARRAY[_rz]);

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2029-09-01','2029-09-30')
   WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_pocet = 0,
    'OBDOBÍ: se zabranou zářijovou rezervací už akci ZÁŘÍ nenabízí (filtr v EXISTS)');

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2029-10-01','2029-10-31')
   WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_pocet = 1,
    'OBDOBÍ: v říjnu se akce nabízí dál — volná rezervace tam pořád je');
END $$;

-- -----------------------------------------------------------------------------
-- 7) VĚTEV „REZERVACE BEZ AKCE" — táž věc, jen bez `event_id`.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _r uuid; _pocet integer;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Testovací Firma s.r.o.';

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 2'), _sub, NULL,
          '2029-11-05 16:00+02','2029-11-05 18:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _r;

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2029-11-01','2029-11-30')
   WHERE event_id IS NULL;
  PERFORM pg_temp.tvrd(_pocet = 1, 'BEZ AKCE: řádek „Rezervace bez akce" se nabízí');

  PERFORM public.fakturoid_zkus_zabrat('klub-'||_sub::text||'-202911', 'club_monthly', _sub, NULL,
          '2029-11-01','2029-11-30', 10000, 1, 'koncept', ARRAY[_r]);

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2029-11-01','2029-11-30')
   WHERE event_id IS NULL;
  PERFORM pg_temp.tvrd(_pocet = 0,
    'BEZ AKCE: po vystavení řádek zmizel (třetí ze tří filtrů)');
END $$;

-- -----------------------------------------------------------------------------
-- 7b) CENA ZADARMO. Server ji nefakturuje (`akce za nulu se nefakturuje`),
--     takže ji náhled nesmí nabízet — jinak `presna` ve frontendu lže
--     a u akce CELÉ zadarmo admin klikne a dostane „není co fakturovat".
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _p record;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Demo Firma s.r.o.';

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST zdarma mix','commercial','2032-05-04 16:00+02','2032-05-04 22:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  -- placená dráha
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub,_ev,
          '2032-05-04 16:00+02','2032-05-04 20:00+02', now(),'11111111-1111-1111-1111-111111111111');
  -- dráha ZADARMO (ukázková hodina, protislužba) — sazba 0
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, rate_per_hour, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 2'), _sub,_ev,
          '2032-05-04 16:00+02','2032-05-04 20:00+02', 0, now(),'11111111-1111-1111-1111-111111111111');

  SELECT * INTO _p FROM pg_temp.shoda_se_serverem(_sub,_ev,'2032-05-01','2032-05-31');
  PERFORM pg_temp.tvrd(_p.nahled_pocet = _p.server_pocet,
    'ZADARMO: náhled nepočítá dráhu za 0 Kč — shoduje se se serverem (bez opravy 2 vs 1)');
  PERFORM pg_temp.tvrd(_p.nahled_castka = _p.server_castka,
    'ZADARMO: a částka sedí taky');
END $$;

-- Akce CELÁ zadarmo se nesmí nabídnout vůbec.
DO $$
DECLARE _sub uuid; _ev uuid; _pocet integer;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Demo Firma s.r.o.';
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST cela zdarma','commercial','2032-06-04 16:00+02','2032-06-04 20:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, rate_per_hour, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub,_ev,
          '2032-06-04 16:00+02','2032-06-04 20:00+02', 0, now(),'11111111-1111-1111-1111-111111111111');

  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(_sub,'2032-06-01','2032-06-30')
   WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_pocet = 0,
    'ZADARMO: akce celá za 0 Kč se v náhledu vůbec nenabízí (klik by vrátil „prazdne")');
END $$;

-- Cena zadarmo BEZ AKCE. Vlastní scénář, protože větev „rezervace bez akce"
-- má svůj vlastní filtr — mutace, která ho smaže, zůstala bez tohohle testu
-- ZELENÁ (ověřeno 15. 9. 2026).
DO $$
DECLARE _sub uuid; _rp uuid; _p record; _bez record;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'HC Ostrava';

  -- placená rezervace bez akce
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub, NULL,
          '2032-08-03 16:00+02','2032-08-03 18:00+02', now(),'11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rp;
  -- rezervace bez akce ZADARMO
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, rate_per_hour, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 2'), _sub, NULL,
          '2032-08-03 16:00+02','2032-08-03 18:00+02', 0, now(),'11111111-1111-1111-1111-111111111111');

  SELECT * INTO _bez FROM public.nevyfakturovane_akce(_sub,'2032-08-01','2032-08-31')
   WHERE event_id IS NULL;
  PERFORM pg_temp.tvrd(_bez.rezervaci = 1,
    'ZADARMO BEZ AKCE: řádek „bez akce" nepočítá rezervaci za 0 Kč (bez opravy 2)');

  SELECT * INTO _p FROM pg_temp.klub_vs_server(_sub,'2032-08-01','2032-08-31');
  PERFORM pg_temp.tvrd(_p.nahled_pocet = _p.server_pocet,
    'ZADARMO BEZ AKCE: náhled i server počítají stejně');
  PERFORM pg_temp.tvrd(_p.nahled_castka = _p.server_castka,
    'ZADARMO BEZ AKCE: a částky taky');
END $$;

-- -----------------------------------------------------------------------------
-- 7c) KLUBOVÁ CESTA vystaví CELÉ OBDOBÍ, akce v něm včetně.
--     Nález bezpečnostní brány 15. 9. 2026: řádek „Rezervace bez akce" posílal
--     do potvrzovacího dialogu čísla SVÉHO řádku, ale vystavilo se všechno.
--     Tenhle test tu asymetrii PŘIŠPENDLUJE, ať se na ni ve frontendu nezapomene.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _p record; _bez record;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Testovací Firma s.r.o.';

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST klub vs akce','commercial','2032-07-06 16:00+02','2032-07-06 20:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 1'), _sub,_ev,
          '2032-07-06 16:00+02','2032-07-06 20:00+02', now(),'11111111-1111-1111-1111-111111111111');
  -- a k tomu rezervace BEZ akce
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE name='Dráha 2'), _sub, NULL,
          '2032-07-12 16:00+02','2032-07-12 18:00+02', now(),'11111111-1111-1111-1111-111111111111');

  SELECT * INTO _bez FROM public.nevyfakturovane_akce(_sub,'2032-07-01','2032-07-31')
   WHERE event_id IS NULL;
  SELECT * INTO _p FROM pg_temp.klub_vs_server(_sub,'2032-07-01','2032-07-31');

  PERFORM pg_temp.tvrd(_bez.rezervaci < _p.server_pocet,
    'KLUB: řádek „bez akce" je MENŠÍ než co klubová cesta vystaví — proto se jeho '
    || 'čísla nesmí posílat do potvrzovacího dialogu (nález brány)');
  PERFORM pg_temp.tvrd(_p.nahled_pocet = _p.server_pocet,
    'KLUB: SOUČET všech řádků náhledu = co klubová cesta vystaví');
  PERFORM pg_temp.tvrd(_p.nahled_castka = _p.server_castka,
    'KLUB: a součet částek taky');
END $$;

-- -----------------------------------------------------------------------------
-- 8) PRÁVA — pod `SET LOCAL ROLE authenticated`, ne jako postgres.
--    Jako `postgres` projde všechno (obchází granty i RLS), takže by test
--    tvrdil zavřeno o dveřích, vedle kterých je otevřené okno.
-- -----------------------------------------------------------------------------
SAVEPOINT prava;
SET LOCAL ROLE authenticated;

-- Běžný člen (clen@test.local) není admin.
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$ SELECT * FROM public.nevyfakturovane_akce(
          (SELECT id FROM public.subjects WHERE name='Demo Firma s.r.o.'),
          '2029-08-01','2029-08-31') $q$,
    'jen správce haly',
    'PRÁVA: běžný člen náhled nedostane');
END $$;

-- Admin ho dostane i pod rolí `authenticated` (grant EXECUTE drží).
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
DO $$
DECLARE _pocet integer;
BEGIN
  SELECT count(*) INTO _pocet FROM public.nevyfakturovane_akce(
    (SELECT id FROM public.subjects WHERE name='Demo Firma s.r.o.'), '2029-08-01','2029-08-31');
  -- `>= 1`, ne `>= 0`: nula by prošla i tehdy, kdyby funkce vracela prázdno
  -- z jiného důvodu, a tvrzení by dokazovalo jen to, že volání nespadlo.
  PERFORM pg_temp.tvrd(_pocet >= 1, 'PRÁVA: admin pod rolí authenticated náhled opravdu VIDÍ');
END $$;

RESET ROLE;
ROLLBACK TO SAVEPOINT prava;

-- `anon` nesmí mít EXECUTE vůbec.
DO $$
DECLARE _prava text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO _prava
    FROM pg_proc WHERE oid = 'public.nevyfakturovane_akce(uuid,date,date)'::regprocedure;
  PERFORM pg_temp.tvrd(_prava NOT LIKE '%anon=%',         'PRÁVA: anon nemá EXECUTE');
  PERFORM pg_temp.tvrd(_prava NOT LIKE '%service_role=%', 'PRÁVA: service_role nemá EXECUTE');
END $$;

DO $$ BEGIN RAISE NOTICE '=== nevyfakturovane_akce + Fakturoid: VŠECHNA TVRZENÍ PROŠLA ==='; END $$;

ROLLBACK;
