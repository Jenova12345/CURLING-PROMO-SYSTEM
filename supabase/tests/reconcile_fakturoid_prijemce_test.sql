-- =============================================================================
-- TESTY: fakturoidí větev kontrolního součtu se řídí PŘÍJEMCEM Z HLAVIČKY
-- Migrace 20260914210000_reconcile_fakturoid_podle_prijemce.sql
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/reconcile_fakturoid_prijemce_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ NEJVÍC:
--
-- 1) ŽE ZMIZELÝ KLUB ZŮSTANE V SESTAVĚ. Scénář 1 je ten, kvůli kterému test
--    vznikl. Doklad zní na klub A, admin přehodí rezervaci na klub B — a před
--    opravou vyšla klubu B tichá NULA, zatímco klub A ze sestavy zmizel úplně.
--    Test proto NEKONTROLUJE jen to, že je rozdíl nenulový; kontroluje i to,
--    že řádek klubu A vůbec EXISTUJE. Bez té druhé půlky by prošla oprava,
--    která rozdíl zviditelní u B a klub A dál zahazuje.
--
-- 2) ŽE SE `nas_soucet` ZAPOČÍTÁ JEDNOU ZA DOKLAD. Scénář 2: doklad přes dva
--    kluby dřív vešel do součtu dvakrát a hlásil nesoulad i tam, kde seděl.
--
-- 3) ŽE SE NEZAČALO KŘIČET NA ZDRAVÁ DATA. Scénář 3 je kontrolní vzorek:
--    doklad se správným příjemcem a správnou částkou musí dát samé nuly.
--    Kdyby zčervenal, oprava rozbila běžný provoz — a to je horší než nález,
--    který zavírá.
--
-- 4) ŽE `fakturoid_rozdil` POŘÁD MĚŘÍ SVOU VLASTNÍ OTÁZKU. Scénář 4: doklad má
--    správného příjemce, ale jeho `nas_soucet` se rozešel s rezervacemi.
--    `rozdil` u toho zůstává nula — rozejít se smí jen ten druhý sloupec.
--    Bez toho by šlo „opravit" tak, že se oba sloupce slijí v jeden.
--
-- Scénáře jsou oddělené SAVEPOINTy, takže si nesahají do kulis. Celý soubor
-- končí ROLLBACKem a nic po sobě nenechává.
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

-- ---------------------------------------------------------------------------
-- Kulisy: dvě rezervace dvou RŮZNÝCH subjektů, obě s nenulovou částkou.
--
-- KLUB A MUSÍ MÍT VE SVÉM DNI PRÁVĚ JEDNU REZERVACI. Není to kosmetika:
-- scénář 1 přehodí tu jedinou rezervaci na klub B a pak tvrdí, že klub A
-- v sestavě přesto ZŮSTAL. Kdyby měl klub A v tomtéž období ještě jinou
-- rezervaci, zůstal by tam kvůli NÍ a scénář by neměřil nic.
-- Změřeno 14. 9. 2026: s původním výběrem (prostě nejnovější rezervace) měl
-- klub A v období dvě rezervace, mutace „zruš sjednocení klíčů" prošla zeleně
-- a test si toho nevšiml.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE t_kul AS
WITH a AS (
  SELECT r.id, r.subject_id, COALESCE(r.corrected_amount, r.amount) AS castka, r.start_at
    FROM reservations r
   WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
     AND COALESCE(r.corrected_amount, r.amount) > 0
     AND NOT EXISTS (
           SELECT 1 FROM reservations r2
            WHERE r2.subject_id = r.subject_id AND r2.id <> r.id
              AND r2.status = 'confirmed' AND r2.deleted_at IS NULL
              AND r2.start_at::date = r.start_at::date
         )
   ORDER BY r.start_at DESC, r.id LIMIT 1
), b AS (
  SELECT r.id, r.subject_id, COALESCE(r.corrected_amount, r.amount) AS castka, r.start_at
    FROM reservations r, a
   WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
     AND r.subject_id <> a.subject_id
     AND COALESCE(r.corrected_amount, r.amount) > 0
   ORDER BY r.start_at DESC, r.id LIMIT 1
)
SELECT a.id AS ra, a.subject_id AS sa, a.castka AS ca,
       b.id AS rb, b.subject_id AS sb, b.castka AS cb,
       a.start_at::date AS den_a,
       least(a.start_at, b.start_at)::date AS od,
       greatest(a.start_at, b.start_at)::date AS do_
  FROM a, b;

DO $$
DECLARE _k record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.tvrd(_k.ra IS NOT NULL AND _k.rb IS NOT NULL,
    'v datech jsou dvě účtovatelné rezervace dvou různých subjektů');
  PERFORM pg_temp.tvrd(_k.sa <> _k.sb, 'a ty subjekty jsou opravdu různé');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM reservations r
      WHERE r.subject_id = _k.sa AND r.status = 'confirmed' AND r.deleted_at IS NULL
        AND r.start_at::date = _k.den_a) = 1,
    'klub A má ve svém dni PRÁVĚ JEDNU rezervaci (jinak scénář 1 neměří nic)');
END $$;

-- Založí fakturoidí doklad. `_suma` je to, co se pošle jako `nas_soucet` —
-- schválně parametr, aby šlo zkusit i doklad, který se s podkladem rozešel.
CREATE OR REPLACE FUNCTION pg_temp.doklad(_id uuid, _prijemce uuid, _suma numeric, _rez uuid[])
 RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO fakturoid_invoices (id, idempotency_key, druh, subject_id, nas_soucet,
         radku, rezervace, rezim, provider_invoice_id, cislo, vystaveno_at)
  VALUES (_id, 'TEST-prijemce-' || _id::text, 'club_monthly', _prijemce, round(_suma, 0),
          cardinality(_rez), _rez, 'koncept', 'PROV-' || left(_id::text, 8),
          'T-' || left(_id::text, 8), now());
  INSERT INTO fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
  SELECT _id, r FROM unnest(_rez) AS r;
END $$;

-- ===========================================================================
-- 1) DOKLAD ZNÍ NA KLUB A, REZERVACE SE PŘEHODÍ NA KLUB B
-- ===========================================================================
SAVEPOINT s1;
DO $$
DECLARE _k record; _a record; _b record; _radku int;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000001', _k.sa, _k.ca, ARRAY[_k.ra]);
  -- Tohle adminovi nic nebrání: fakturoidí cesta do `reservations.invoice_id`
  -- z rozhodnutí PM nezapisuje, takže guard `trg_reservations_jeden_doklad`
  -- se na ni nevztahuje. Zámek je samostatný ticket — tady jde o VIDITELNOST.
  UPDATE reservations SET subject_id = _k.sb WHERE id = _k.ra;

  SELECT count(*) INTO _radku FROM billing_reconcile(_k.den_a, _k.den_a) WHERE subject_id = _k.sa;
  PERFORM pg_temp.tvrd(_radku = 1,
    '1a) klub z HLAVIČKY dokladu zůstal v sestavě, i když už nemá žádnou rezervaci');

  SELECT * INTO _a FROM billing_reconcile(_k.den_a, _k.den_a) WHERE subject_id = _k.sa;
  -- Důkaz, že se tam dostal DOKLADEM, ne rezervací. Bez tohohle by scénář
  -- prošel i tehdy, když klub A v období shodou okolností jinou rezervaci má.
  PERFORM pg_temp.tvrd(_a.rezervaci = 0,
    '1a2) a je tam čistě kvůli dokladu — žádnou rezervaci v období nemá');
  PERFORM pg_temp.tvrd(_a.fakturoid = round(_k.ca, 0),
    '1b) částka dokladu se přičetla klubu z hlavičky, ne majiteli rezervace');
  PERFORM pg_temp.tvrd(_a.rozdil <> 0,
    '1c) a hlásí to nenulovým rozdílem (dřív tu byla tichá nula)');

  SELECT * INTO _b FROM billing_reconcile(_k.den_a, _k.den_a) WHERE subject_id = _k.sb;
  PERFORM pg_temp.tvrd(_b.fakturoid = 0,
    '1d) klubu, na který se rezervace přehodila, se doklad NEpřipsal');
  PERFORM pg_temp.tvrd(_b.rozdil <> 0,
    '1e) a nenulový rozdíl hlásí i on');
END $$;
ROLLBACK TO s1;

-- ===========================================================================
-- 2) JEDEN DOKLAD NESE REZERVACE DVOU KLUBŮ
-- ===========================================================================
-- Doklad zní na klub A a je na něm správná celková částka. Dřív se `nas_soucet`
-- započetl jednou za KAŽDÝ subjekt, takže `fakturoid_rozdil` křičel u obou,
-- přestože doklad se svým podkladem seděl.
SAVEPOINT s2;
DO $$
DECLARE _k record; _a record; _b record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000002', _k.sa,
                         _k.ca + _k.cb, ARRAY[_k.ra, _k.rb]);

  SELECT * INTO _a FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sa;
  PERFORM pg_temp.tvrd(_a.fakturoid_rozdil = 0,
    '2a) doklad přes dva kluby SEDÍ se svým podkladem — nas_soucet se počítá jednou');
  PERFORM pg_temp.tvrd(_a.fakturoid = round(_k.ca, 0) + round(_k.cb, 0),
    '2b) celá částka dokladu visí na klubu z hlavičky');

  SELECT * INTO _b FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sb;
  PERFORM pg_temp.tvrd(_b.fakturoid_rozdil = 0,
    '2c) druhému klubu se cizí doklad nepřipisuje ani jako rozdíl dokladů');
  PERFORM pg_temp.tvrd(_b.rozdil <> 0,
    '2d) ale že jeho rezervaci platí někdo jiný, je vidět na „Rozdíl"');
END $$;
ROLLBACK TO s2;

-- ===========================================================================
-- 3) KONTROLNÍ VZOREK: zdravý doklad musí dát samé nuly
-- ===========================================================================
SAVEPOINT s3;
DO $$
DECLARE _k record; _a record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000003', _k.sa, _k.ca, ARRAY[_k.ra]);
  SELECT * INTO _a FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sa;
  PERFORM pg_temp.tvrd(_a.fakturoid_rozdil = 0, '3a) zdravý doklad: rozdíl dokladů je nula');
  PERFORM pg_temp.tvrd(_a.rozdil = 0,           '3b) zdravý doklad: rozdíl je nula');
  PERFORM pg_temp.tvrd(_a.fakturoid = round(_k.ca, 0),
    '3c) a rezervace se z „k fakturaci" odečetla do „Fakturoid"');
END $$;
ROLLBACK TO s3;

-- ===========================================================================
-- 4) SPRÁVNÝ PŘÍJEMCE, ŠPATNÁ ČÁSTKA — rozejít se smí JEN `fakturoid_rozdil`
-- ===========================================================================
SAVEPOINT s4;
DO $$
DECLARE _k record; _a record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  -- `nas_soucet` o 100 Kč vedle proti tomu, co rezervace nesou.
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000004', _k.sa,
                         _k.ca + 100, ARRAY[_k.ra]);
  SELECT * INTO _a FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sa;
  PERFORM pg_temp.tvrd(_a.fakturoid_rozdil = 100,
    '4a) rozejitá částka dokladu se ukáže na „Rozdíl dokladů"');
  PERFORM pg_temp.tvrd(_a.rozdil = 0,
    '4b) a „Rozdíl" u toho zůstává nula — jsou to dvě různé otázky');
END $$;
ROLLBACK TO s4;

-- ===========================================================================
-- 5) SJEDNOCENÍ KLÍČŮ SMÍ BÝT JEN `UNION`, NIKDY `UNION ALL`
--
-- Tenhle scénář tu je kvůli konkrétní mutaci, kterou sada 14. 9. 2026
-- PROPUSTILA: `UNION` → `UNION ALL`. Subjekt, který má v období rezervaci
-- (je v `souhrn`) i fakturoidí doklad (je v `fakt_doklady`), se pak do
-- sestavy dostane DVAKRÁT. Scénáře 1–4 to nechytily, protože všechny
-- čtou přes `SELECT … INTO`, které si z víc řádků beze slova vezme první.
-- Kontrolní součet by tím nafoukl každou částku toho subjektu na dvojnásobek
-- a „Dluží" by v UI lhalo — u peněz nepřijatelné.
-- ===========================================================================
SAVEPOINT s5;
DO $$
DECLARE _k record; _radku int; _celkem int; _duplicit int;
BEGIN
  SELECT * INTO _k FROM t_kul;
  -- Zdravý doklad na klub A, který má v tomtéž období i svou rezervaci —
  -- tedy přesně ten případ, kdy stojí v OBOU větvích sjednocení.
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000005', _k.sa, _k.ca, ARRAY[_k.ra]);

  SELECT count(*) INTO _radku
    FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sa;
  PERFORM pg_temp.tvrd(_radku = 1,
    '5a) subjekt s rezervací I dokladem je v sestavě PRÁVĚ JEDNOU (UNION, ne UNION ALL)');

  -- Ještě jednou a bez vazby na konkrétní subjekt: v celé sestavě se
  -- žádný subject_id nesmí opakovat. Kdyby `UNION ALL` proteklo jinudy
  -- (třeba dalším sjednocením přidaným později), spadne to tady.
  SELECT count(*), count(DISTINCT subject_id) INTO _celkem, _duplicit
    FROM billing_reconcile(_k.od, _k.do_);
  PERFORM pg_temp.tvrd(_celkem = _duplicit,
    '5b) v celé sestavě není ani jeden subjekt dvakrát');

  -- A pojistka, že 5a/5b nejsou zelené jen proto, že sestava je prázdná.
  PERFORM pg_temp.tvrd(_celkem >= 2,
    '5c) sestava vůbec něco vrací (jinak by 5a/5b neměřily nic)');
END $$;
ROLLBACK TO s5;

-- ===========================================================================
-- 6) DVA DOKLADY JEDNOHO SUBJEKTU — rozdíly se SČÍTAJÍ, nenásobí
--
-- Další konkrétní mutace, kterou sada 14. 9. 2026 propustila:
-- `sum(nas_soucet - suma)` → `sum(nas_soucet - suma) * count(*)`.
-- Scénáře 1–5 jí nemohly přijít na kloub, protože každý z nich zakládá
-- subjektu JEDINÝ doklad, a tam je `count(*) = 1`, takže mutace nic nedělá.
-- Jenže právě víc dokladů na subjekt je v provozu normální stav (měsíční
-- fakturace + doúčtování) a tam by chyba rostla s jejich počtem.
-- ===========================================================================
SAVEPOINT s6;
DO $$
DECLARE _k record; _a record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  -- Dva doklady TÉHOŽ klubu A v tomtéž období: jeden sedící, druhý o 100 vedle.
  -- Každý nese jinou rezervaci, aby si navzájem nepřepisovaly podklad.
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000006', _k.sa, _k.ca,       ARRAY[_k.ra]);
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000007', _k.sa, _k.cb + 100, ARRAY[_k.rb]);

  SELECT * INTO _a FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sa;

  -- Klíč celého scénáře: PŘESNĚ 100, ne 200. Při `* count(*)` by tu bylo 200.
  PERFORM pg_temp.tvrd(_a.fakturoid_rozdil = 100,
    '6a) rozdíly dvou dokladů se SEČTOU (100), nenásobí se jejich počtem');

  -- A druhá strana téže mince: částky se sečtou přes oba doklady.
  PERFORM pg_temp.tvrd(_a.fakturoid = round(_k.ca, 0) + round(_k.cb, 0),
    '6b) „Fakturoid" nese součet obou dokladů');
END $$;
ROLLBACK TO s6;

-- ===========================================================================
-- 7) HALÉŘE: `nas_soucet` je celé koruny, podklad nemusí být
--
-- Třetí mutace, kterou sada propustila: `round(fd.suma, 0)` → `fd.suma`.
-- Scénáře 1–6 ji nemohly vidět, protože jejich částky jsou celé koruny,
-- a tam je `round()` bez účinku.
--
-- `nas_soucet` plní pipeline přes `roundCzk` (`scripts/fakturoid-akce.ts`),
-- tedy CELÉ KORUNY; `corrected_amount` na rezervaci je proti tomu
-- `round(corrected_hours * rate_per_hour, 2)`, tedy haléře. Stačí sazba,
-- která haléře nese — v datech taková je (938,46 Kč/h). Bez `round()` v
-- porovnání by KAŽDÝ takový doklad hlásil rozdíl v haléřích, čili červenou
-- buňku a „nefakturuj dál" nad dokladem, který je v pořádku.
--
-- Haléře se schválně NEVNUCUJÍ přímým UPDATEm `corrected_amount` — ten
-- trigger `set_reservation_pricing` beze slova přepíše (změřeno 14. 9. 2026:
-- hodnota skončila jako NULL a kulisa tiše nic neměřila). Jde se cestou,
-- kterou systém opravdu dovoluje: korekce hodin + důvod.
-- ===========================================================================
SAVEPOINT s7;
DO $$
DECLARE _k record; _a record; _r uuid; _castka numeric;
BEGIN
  SELECT * INTO _k FROM t_kul;

  -- Rezervace se sazbou, která nese haléře. Když taková v datech není,
  -- scénář se NEPŘESKOČÍ potichu — spadne, ať je vidět, že neměří.
  SELECT r.id INTO _r
    FROM reservations r
   WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
     AND r.rate_per_hour IS NOT NULL
     AND r.rate_per_hour <> round(r.rate_per_hour, 0)
   ORDER BY r.id LIMIT 1;
  PERFORM pg_temp.tvrd(_r IS NOT NULL,
    '7-kulisa) v datech je sazba s haléři (bez ní scénář neměří nic)');

  -- Korekce na 1 h → corrected_amount = round(1 × sazba, 2), tedy haléře.
  UPDATE reservations
     SET corrected_hours = 1.00,
         correction_reason = 'TEST zaokrouhlení kontrolního součtu'
   WHERE id = _r;

  SELECT COALESCE(corrected_amount, amount), subject_id, start_at::date
    INTO _castka, _k.sa, _k.od
    FROM reservations WHERE id = _r;
  _k.do_ := _k.od;

  PERFORM pg_temp.tvrd(_castka <> round(_castka, 0),
    '7b) kulisa opravdu nese haléře (jinak 7a neměří nic)');

  -- Doklad v celých korunách, přesně jak ho zakládá pipeline.
  PERFORM pg_temp.doklad('0fa00000-0000-0000-0000-000000000008', _k.sa, _castka, ARRAY[_r]);

  SELECT * INTO _a FROM billing_reconcile(_k.od, _k.do_) WHERE subject_id = _k.sa;
  PERFORM pg_temp.tvrd(_a.fakturoid_rozdil = 0,
    '7a) doklad v celých korunách nad podkladem s haléři NEhlásí rozdíl');
END $$;
ROLLBACK TO s7;

ROLLBACK;
