-- =============================================================================
-- PRAVIDLO 48 H — v okně před akcí zasahuje jen admin (ledař)
-- =============================================================================
-- Spuštění:
--   psql -p 55322 -U postgres -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/okno_48h_test.sql
-- Celý běh je v jedné transakci, která se na konci ROLLBACKuje → data zůstanou
-- jako po `supabase db reset`. Test projde, když skript doběhne bez chyby
-- a vypíše „VŠECHNY TESTY PROŠLY".
--
-- Co se měří (zadání): okno = MÉNĚ než 48 h před začátkem akce. Neadmin v okně
-- nesmí rezervaci vytvořit, zrušit, přesunout (ani přetažením v kalendáři) ani
-- u ní měnit dráhy. Admin smí všechno. Mimo okno (48 h a víc) se nemění nic.
--
-- POZOR NA ROLI: testy práv běží pod `SET LOCAL ROLE authenticated`, ne jako
-- `postgres`. Jako `postgres` projde všechno (obchází granty i RLS), takže by
-- test tvrdil zavřeno o dveřích, vedle kterých je otevřené okno — pravidla 3
-- a 9 v CLAUDE.md.
--
-- POZOR NA ZÁMĚNU DŮVODŮ: každá blokovaná operace se ověřuje na TEXT hlášky
-- („V okně 48 h"), ne jen na to, že něco spadlo. Kdyby se test spokojil
-- s libovolnou chybou, prošel by i tehdy, kdyby neadmin narazil na chybějící
-- práva nebo na obsazenou dráhu — a o okně by neřekl nic. Proto všechny
-- blokované rezervace patří klubu, který ten neadmin OPRAVDU spravuje, takže
-- bez guardu by operace prošla.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Uživatelé ze seedu
--   1111… admin | 4444… zástupce klubu (nejsilnější NEadmin) | 5555… člen klubu
CREATE OR REPLACE FUNCTION pg_temp.prihlas(_user uuid) RETURNS void
 LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', _user, 'role', 'authenticated')::text, true);
$$;

-- SECURITY DEFINER schválně: `authenticated` nemá SELECT na `subjects`, a test
-- by pak padal na dohledání klubu místo na tom, co měří. Obchází se jen
-- vyhledání ID — žádná brána, kterou tenhle soubor testuje.
CREATE OR REPLACE FUNCTION pg_temp.draha(_n int) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.sheets WHERE name = 'Dráha ' || _n;
$$;

-- Klub, kde je 4444… zástupce a 5555… člen — obojí ze seedu.
CREATE OR REPLACE FUNCTION pg_temp.klub() RETURNS uuid
 LANGUAGE sql IMMUTABLE AS $$ SELECT 'aaaa1111-0000-0000-0000-000000000001'::uuid; $$;

-- ---- termíny -----------------------------------------------------------------
-- V OKNĚ: zítra v _hod hodin. Zítřejší termín je od teď vždycky míň než 48 h
-- (nejhorší případ: teď 00:00, zítra 22:00 = 46 h), takže do okna spadá bez
-- ohledu na to, kdy se test pouští. Zároveň je to platný slot — celá hodina
-- uvnitř otevírací doby 7–22, která je v seedu stejná pro všechny dny.
CREATE OR REPLACE FUNCTION pg_temp.v_okne(_hod int) RETURNS timestamptz
 LANGUAGE sql STABLE AS $$
  SELECT ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
           + interval '1 day' + (_hod || ' hours')::interval)
          AT TIME ZONE 'Europe/Prague');
$$;

-- MIMO OKNO: za _za dní (_za >= 3 je od 48 h vždycky dál — nejhorší případ
-- teď 23:59, za 3 dny v 7:00 = 55 h). Vyšší čísla používáme i proto, aby si
-- testy nekolidovaly navzájem ani se seedem.
CREATE OR REPLACE FUNCTION pg_temp.mimo_okno(_za int, _hod int) RETURNS timestamptz
 LANGUAGE sql STABLE AS $$
  SELECT ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
           + (_za || ' days')::interval + (_hod || ' hours')::interval)
          AT TIME ZONE 'Europe/Prague');
$$;

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

CREATE OR REPLACE FUNCTION pg_temp.ids(_v jsonb) RETURNS uuid[]
 LANGUAGE sql IMMUTABLE AS $$
  SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(_v->'reservation_ids') x;
$$;

-- První rezervace akce. Vlastní funkce proto, že `pg_temp.ids(...)[1]` je
-- syntaktická chyba — indexovat jde až závorkovaný výraz.
CREATE OR REPLACE FUNCTION pg_temp.prvni(_v jsonb) RETURNS uuid
 LANGUAGE sql IMMUTABLE AS $$ SELECT (pg_temp.ids(_v))[1]; $$;

-- Opak `ocekavej_chybu`: operace MÁ projít. Bez tohohle by pád vypadl ven jako
-- syrový `ERROR: …` a z červené by nebylo vidět, CO se čekalo — u série je
-- rozdíl mezi „přeskočit termín" a „spadnout celá" zrovna to, co se měří.
CREATE OR REPLACE FUNCTION pg_temp.ocekavej_uspech(_sql text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE _sql;
  RAISE NOTICE 'OK  %', _popis;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla projít, ale spadla: %', _popis, SQLERRM;
END $$;

-- Rezervace v okně nejde založit neadminem (o tom je celý test), takže ji
-- v přípravě zakládá admin — přesně jako v provozu, kde ji tam ledař dá.
-- Vrací id první rezervace.
CREATE OR REPLACE FUNCTION pg_temp.admin_zalozi(_sheety uuid[], _od timestamptz, _do timestamptz, _nazev text)
 RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _ids uuid[];
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _ids := pg_temp.ids(public.create_booking(
    _sheety, 'training', _nazev, _od, _do, pg_temp.klub()));
  RETURN _ids[1];
END $$;

CREATE OR REPLACE FUNCTION pg_temp.stav(_res uuid) RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT status::text FROM public.reservations WHERE id = _res;
$$;

CREATE OR REPLACE FUNCTION pg_temp.zacatek(_res uuid) RETURNS timestamptz
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT start_at FROM public.reservations WHERE id = _res;
$$;

-- `uprav_drahy_akce` bere ID AKCE, ne rezervace.
CREATE OR REPLACE FUNCTION pg_temp.akce(_res uuid) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT event_id FROM public.reservations WHERE id = _res;
$$;

CREATE OR REPLACE FUNCTION pg_temp.drahy_akce(_res uuid) RETURNS int
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.reservations r
   WHERE r.event_id = (SELECT event_id FROM public.reservations WHERE id = _res)
     AND r.status = 'confirmed' AND r.deleted_at IS NULL;
$$;

-- -----------------------------------------------------------------------------
-- 0) HRANICE OKNA — co je uvnitř a co venku
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM pg_temp.tvrd(public.v_okne_48h(now() + interval '47 hours'),
    '47 h před akcí JE v okně');
  PERFORM pg_temp.tvrd(NOT public.v_okne_48h(now() + interval '49 hours'),
    '49 h před akcí NENÍ v okně');
  PERFORM pg_temp.tvrd(NOT public.v_okne_48h(now() + interval '48 hours 1 second'),
    'přesně 48 h a víc je mimo okno (okno je „méně než 48 h")');
  PERFORM pg_temp.tvrd(public.v_okne_48h(now() - interval '1 hour'),
    'akce, která už začala, je v okně (do okna patří i minulost)');
  PERFORM pg_temp.tvrd(public.v_okne_48h(pg_temp.v_okne(7)) AND public.v_okne_48h(pg_temp.v_okne(21)),
    'zítřek je v okně po celou otevírací dobu (7:00 i 21:00)');
  PERFORM pg_temp.tvrd(NOT public.v_okne_48h(pg_temp.mimo_okno(3, 7)),
    'za tři dny v 7:00 je mimo okno');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 1) HLÁŠKA BERE JMÉNO Z NASTAVENÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _puvodni text; _h text;
BEGIN
  SELECT ledar_jmeno INTO _puvodni FROM public.settings LIMIT 1;
  PERFORM pg_temp.tvrd(_puvodni = 'Jirka – Ledař',
    'výchozí jméno ledaře je „Jirka – Ledař" (má ' || _puvodni || ')');

  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  _h := public.hlaska_okna_48h('vytvořit');
  RESET ROLE;
  PERFORM pg_temp.tvrd(
    _h = 'V okně 48 h před akcí může rezervaci vytvořit jen Jirka – Ledař.',
    'hláška má přesně zadaný text (má „' || _h || '")');

  -- Změna v Nastavení se musí projevit v hlášce — jinak by to bylo natvrdo
  -- napsané jméno a pole v Nastavení by lhalo.
  UPDATE public.settings SET ledar_jmeno = 'Pepa Ledovec';
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  _h := public.hlaska_okna_48h('zrušit');
  RESET ROLE;
  PERFORM pg_temp.tvrd(_h = 'V okně 48 h před akcí může rezervaci zrušit jen Pepa Ledovec.',
    'hláška se řídí jménem z Nastavení (má „' || _h || '")');

  UPDATE public.settings SET ledar_jmeno = _puvodni;
END $$;

-- -----------------------------------------------------------------------------
-- 2) NEADMIN V OKNĚ NESMÍ VYTVOŘIT
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  -- zástupce klubu = nejsilnější neadmin
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM pg_temp.ocekavej_chybu($q$
    SELECT public.create_booking(ARRAY[pg_temp.draha(1)], 'training', 'Zítřejší trénink',
      pg_temp.v_okne(8), pg_temp.v_okne(9), pg_temp.klub())$q$,
    'V okně 48 h před akcí může rezervaci vytvořit jen',
    'zástupce klubu nezaloží rezervaci v okně');

  -- člen klubu
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');
  PERFORM pg_temp.ocekavej_chybu($q$
    SELECT public.create_booking(ARRAY[pg_temp.draha(1)], 'training', 'Zítřejší trénink člena',
      pg_temp.v_okne(8), pg_temp.v_okne(9), pg_temp.klub())$q$,
    'V okně 48 h před akcí může rezervaci vytvořit jen',
    'člen klubu nezaloží rezervaci v okně');

END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 2b) SÉRIE: termín v okně se PŘESKOČÍ, zbytek série vznikne
--
-- Rozhodnutí zákazníka (10. 9. 2026). „Začíná to zítra" je důvod vázaný na
-- JEDEN termín, ne na celé zadání — dřív guard hlásil obyčejný P0001, ten
-- prošel skrz `create_booking_series` a shodil CELOU sérii: zástupci klubu se
-- kvůli zítřku nezaložil ani jeden z pětadvaceti pozdějších termínů. Guard
-- proto hlásí U0003, vedle U0001 (obsazeno) a U0002 (mimo otevírací dobu).
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _preskoceno jsonb; _duvod text;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');

  -- Denní série od zítřka na týden: první termín je v okně, zbytek ne.
  --
  -- Nejdřív se tvrdí, že to VŮBEC PROJDE — to je celé jádro téhle kapitoly.
  -- Bez `ocekavej_uspech` by se pád (tedy návrat k „série spadne celá") ukázal
  -- jako syrový ERROR odněkud z útrob `create_booking_series` a z červené by
  -- nebylo poznat, že měla přeskočit, ne spadnout.
  PERFORM pg_temp.ocekavej_uspech($q$
    SELECT public.create_booking_series(
      ARRAY[pg_temp.draha(1)], 'training', 'Série přes okno',
      pg_temp.v_okne(20), pg_temp.v_okne(21),
      ARRAY[1, 2, 3, 4, 5, 6, 7],
      (pg_temp.mimo_okno(7, 20) AT TIME ZONE 'Europe/Prague')::date,
      pg_temp.klub())$q$,
    'série s termínem v okně vůbec projde (nespadne celá)');

  -- a teď totéž znovu, ať se dá sáhnout na výsledek. Jiný název kvůli kolizi
  -- s tím, co právě vzniklo; termín je o hodinu vedle.
  _v := public.create_booking_series(
    ARRAY[pg_temp.draha(2)], 'training', 'Série přes okno 2',
    pg_temp.v_okne(20), pg_temp.v_okne(21),
    ARRAY[1, 2, 3, 4, 5, 6, 7],
    (pg_temp.mimo_okno(7, 20) AT TIME ZONE 'Europe/Prague')::date,
    pg_temp.klub());
  RESET ROLE;

  SELECT x INTO _preskoceno
    FROM jsonb_array_elements(COALESCE(_v->'skipped', '[]'::jsonb)) x
   WHERE x->>'duvod' = 'okno_48h' LIMIT 1;

  PERFORM pg_temp.tvrd(_preskoceno IS NOT NULL,
    'termín v okně se v sérii přeskočil s vlastním důvodem okno_48h');
  PERFORM pg_temp.tvrd(
    position('V okně 48 h' in COALESCE(_preskoceno->>'reason', '')) > 0,
    'u přeskočeného termínu je vidět proč (text hlášky o okně)');
  PERFORM pg_temp.tvrd((_v->>'created')::int >= 5,
    'zbytek série se založil, nespadla celá (založeno ' || (_v->>'created') || ')');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.reservations r
                 WHERE r.series_id = (_v->>'series_id')::uuid
                   AND r.status = 'confirmed'
                   AND public.v_okne_48h(r.start_at)),
    'v sérii nezůstal ani jeden potvrzený termín uvnitř okna');

  -- A PROTIZKOUŠKA: důvod nesmí splynout se zavřenou halou ani s kolizí,
  -- protože uživatel je řeší úplně jinak.
  SELECT x->>'duvod' INTO _duvod
    FROM jsonb_array_elements(COALESCE(_v->'skipped', '[]'::jsonb)) x
   WHERE position('V okně 48 h' in COALESCE(x->>'reason','')) > 0 LIMIT 1;
  PERFORM pg_temp.tvrd(_duvod = 'okno_48h',
    'důvod se nevydává za „mimo otevírací dobu" ani za kolizi (má ' || COALESCE(_duvod,'NULL') || ')');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 3) NEADMIN V OKNĚ NESMÍ ZRUŠIT — akce zůstává a naúčtuje se v plné výši
-- -----------------------------------------------------------------------------
DO $$
DECLARE _jedna uuid; _obe uuid; _clenova uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  _jedna := pg_temp.admin_zalozi(ARRAY[pg_temp.draha(1)], pg_temp.v_okne(9), pg_temp.v_okne(10),
                                 'Zítřejší trénink k nezrušení');
  _obe   := pg_temp.admin_zalozi(ARRAY[pg_temp.draha(1), pg_temp.draha(2)],
                                 pg_temp.v_okne(10), pg_temp.v_okne(11), 'Zítřejší akce na obou drahách');

  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L, %L)', _jedna, 'single'),
    'V okně 48 h před akcí může rezervaci zrušit jen',
    'zástupce klubu nezruší rezervaci v okně (scope single)');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L, %L)', _obe, 'event'),
    'V okně 48 h před akcí může rezervaci zrušit jen',
    'zástupce klubu nezruší celou akci v okně (scope event)');

  -- Člen klubu smí sahat jen na to, co sám založil — a v okně založit nemůže.
  -- Reálná cesta do téhle situace je čas: rezervoval si termín dopředu a do
  -- okna se dostal tím, že se termín přiblížil. Simulujeme to posunem času
  -- rezervace jako `postgres` (obchází guardy schválně — je to příprava dat,
  -- ne měřená operace).
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');
  _clenova := pg_temp.prvni(public.create_booking(
    ARRAY[pg_temp.draha(2)], 'training', 'Trénink člena, který se přiblížil',
    pg_temp.mimo_okno(56, 12), pg_temp.mimo_okno(56, 13), pg_temp.klub()));
  RESET ROLE;

  -- `guard_reservation_rep_changes` pouští přímý zápis času jen pod databázovou
  -- rolí BEZ přihlášeného uživatele, takže se claim musí odložit (jinak spadne
  -- na „Čas a dráhu měňte přesunem rezervace"). Guard se neobchází — jen se
  -- říká, že tohle je servisní příprava dat, ne uživatelská operace.
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.reservations
     SET start_at = pg_temp.v_okne(12), end_at = pg_temp.v_okne(13)
   WHERE id = _clenova;

  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L, %L)', _clenova, 'single'),
    'V okně 48 h před akcí může rezervaci zrušit jen',
    'člen klubu nezruší v okně ani vlastní rezervaci');
  RESET ROLE;

  PERFORM pg_temp.tvrd(pg_temp.stav(_clenova) = 'confirmed',
    'vlastní rezervace člena po odmítnutém storno zůstává potvrzená');

  PERFORM pg_temp.tvrd(pg_temp.stav(_jedna) = 'confirmed',
    'akce po odmítnutém storno zůstává potvrzená (a tedy k zaplacení)');
  PERFORM pg_temp.tvrd(pg_temp.drahy_akce(_obe) = 2,
    'akci na dvou drahách neubyla ani jedna dráha');
END $$;

-- -----------------------------------------------------------------------------
-- 4) NEADMIN V OKNĚ NESMÍ MĚNIT ČAS ANI DRÁHU (a to ani přetažením)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v_okne uuid; _mimo uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  _v_okne := pg_temp.admin_zalozi(ARRAY[pg_temp.draha(1)], pg_temp.v_okne(11), pg_temp.v_okne(12),
                                  'Zítřejší trénink k nepřesunutí');

  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');

  -- Přesun uvnitř okna. `move_booking` je táž funkce, kterou volá drag & drop
  -- v kalendáři (`useReservations.moveBooking`), takže tenhle test kryje obojí.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L, %L, %L)', _v_okne, pg_temp.v_okne(13), pg_temp.v_okne(14)),
    'V okně 48 h před akcí může rezervaci přesunout jen',
    'zástupce klubu nepřesune rezervaci, která začíná v okně');

  -- Přetažení VEN z okna — pořád zásah do akce v okně, pořád blokované.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L, %L, %L)', _v_okne, pg_temp.mimo_okno(50, 11), pg_temp.mimo_okno(50, 12)),
    'V okně 48 h před akcí může rezervaci přesunout jen',
    'zástupce klubu nepřetáhne rezervaci z okna pryč');

  -- Změna dráhy (drag na druhou dráhu) je taky `move_booking`.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L, %L, %L, %L)', _v_okne,
           pg_temp.v_okne(11), pg_temp.v_okne(12), pg_temp.draha(2)),
    'V okně 48 h před akcí může rezervaci přesunout jen',
    'zástupce klubu nepřetáhne rezervaci v okně na druhou dráhu');

  -- Přetažení ZVENKU DOVNITŘ okna: stará i nová poloha se kontroluje, jinak by
  -- se pravidlo dalo obejít založením termínu mimo okno a přetažením do něj.
  RESET ROLE;
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  _mimo := pg_temp.prvni(public.create_booking(
    ARRAY[pg_temp.draha(2)], 'training', 'Vzdálený trénink',
    pg_temp.mimo_okno(51, 16), pg_temp.mimo_okno(51, 17), pg_temp.klub()));

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L, %L, %L)', _mimo, pg_temp.v_okne(14), pg_temp.v_okne(15)),
    'V okně 48 h před akcí může rezervaci přesunout jen',
    'zástupce klubu nepřetáhne rezervaci zvenku DO okna');
  RESET ROLE;

  PERFORM pg_temp.tvrd(pg_temp.zacatek(_v_okne) = pg_temp.v_okne(11),
    'rezervace v okně zůstala na svém čase');
  PERFORM pg_temp.tvrd(pg_temp.zacatek(_mimo) = pg_temp.mimo_okno(51, 16),
    'rezervace mimo okno zůstala na svém čase');
END $$;

-- -----------------------------------------------------------------------------
-- 5) NEADMIN V OKNĚ NESMÍ MĚNIT DRÁHY AKCE
-- -----------------------------------------------------------------------------
DO $$
DECLARE _res uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  _res := pg_temp.admin_zalozi(ARRAY[pg_temp.draha(1)], pg_temp.v_okne(15), pg_temp.v_okne(16),
                               'Zítřejší trénink s jednou dráhou');

  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_drahy_akce(%L, ARRAY[%L::uuid, %L::uuid])',
           pg_temp.akce(_res), pg_temp.draha(1), pg_temp.draha(2)),
    'V okně 48 h před akcí může rezervaci změnit jen',
    'zástupce klubu nepřidá akci v okně druhou dráhu');
  RESET ROLE;

  PERFORM pg_temp.tvrd(pg_temp.drahy_akce(_res) = 1, 'akce v okně má pořád jednu dráhu');
END $$;

-- -----------------------------------------------------------------------------
-- 6) ADMIN V OKNĚ SMÍ VŠECHNO
-- -----------------------------------------------------------------------------
DO $$
DECLARE _res uuid; _presun uuid; _drahy uuid; _storno uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');

  -- vytvoření
  _res := pg_temp.prvni(public.create_booking(
    ARRAY[pg_temp.draha(1)], 'training', 'Ledař zakládá na zítra',
    pg_temp.v_okne(16), pg_temp.v_okne(17), pg_temp.klub()));
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.stav(_res) = 'confirmed', 'admin založil rezervaci v okně');

  -- přesun (i drag & drop)
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM public.move_booking(_res, pg_temp.v_okne(17), pg_temp.v_okne(18));
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.zacatek(_res) = pg_temp.v_okne(17), 'admin přesunul rezervaci v okně');

  -- změna drah
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM public.uprav_drahy_akce(pg_temp.akce(_res), ARRAY[pg_temp.draha(1), pg_temp.draha(2)]);
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.drahy_akce(_res) = 2, 'admin přidal akci v okně druhou dráhu');

  -- zrušení
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM public.cancel_booking(_res, 'event');
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.stav(_res) = 'cancelled', 'admin zrušil akci v okně');
END $$;

-- -----------------------------------------------------------------------------
-- 7) MIMO OKNO SE NEMĚNÍ NIC — neadminovi projde všechno jako dřív
-- -----------------------------------------------------------------------------
DO $$
DECLARE _res uuid; _druha uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');

  _res := pg_temp.prvni(public.create_booking(
    ARRAY[pg_temp.draha(1)], 'training', 'Trénink za měsíc',
    pg_temp.mimo_okno(60, 16), pg_temp.mimo_okno(60, 18), pg_temp.klub()));
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.stav(_res) = 'confirmed',
    'zástupce klubu založí rezervaci mimo okno');

  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM public.move_booking(_res, pg_temp.mimo_okno(61, 16), pg_temp.mimo_okno(61, 18));
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.zacatek(_res) = pg_temp.mimo_okno(61, 16),
    'zástupce klubu přesune rezervaci mimo okno');

  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM public.uprav_drahy_akce(pg_temp.akce(_res), ARRAY[pg_temp.draha(1), pg_temp.draha(2)]);
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.drahy_akce(_res) = 2,
    'zástupce klubu přidá dráhu akci mimo okno');

  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM public.cancel_booking(_res, 'event');
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.stav(_res) = 'cancelled',
    'zástupce klubu zruší akci mimo okno');

  -- a totéž pro obyčejného člena klubu (vlastní rezervaci)
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');
  _druha := pg_temp.prvni(public.create_booking(
    ARRAY[pg_temp.draha(2)], 'training', 'Trénink člena za měsíc',
    pg_temp.mimo_okno(62, 16), pg_temp.mimo_okno(62, 18), pg_temp.klub()));
  PERFORM public.cancel_booking(_druha, 'single');
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.stav(_druha) = 'cancelled',
    'člen klubu založí i zruší svou rezervaci mimo okno');
END $$;

-- -----------------------------------------------------------------------------
-- 7b) PŘÍMÝ ZÁPIS DO TABULKY — druhé dveře, ne jen RPC
--
-- `authenticated` má na `public.reservations` tabulkové INSERT/UPDATE granty
-- a RLS je členovi i zástupci klubu povoluje, takže rezervace jde založit
-- i zrušit úplně mimo `create_booking`/`cancel_booking` — prostým POST/PATCH
-- z prohlížeče. Kdyby pravidlo drželo jen v RPC, byla by to obchvatná cesta:
-- bezpečnostní brána (10. 9. 2026) jí takhle sundala akci za 2 000 Kč
-- z fakturace, zatímco RPC na téže rezervaci správně odmítlo.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _res uuid; _mimo uuid; _n int;
BEGIN
  SET LOCAL ROLE authenticated;
  _res := pg_temp.admin_zalozi(ARRAY[pg_temp.draha(1)], pg_temp.v_okne(18), pg_temp.v_okne(19),
                               'Zítřejší trénink k neobejití');

  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');

  -- (a) založení v okně přímým INSERTem
  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, note)
              VALUES (%L, %L, %L, %L, 'obchvat RPC')$q$,
           pg_temp.draha(2), pg_temp.klub(), pg_temp.v_okne(18), pg_temp.v_okne(19)),
    'V okně 48 h před akcí může rezervaci vytvořit jen',
    'zástupce klubu nezaloží rezervaci v okně ani přímým INSERTem');

  -- (b) storno v okně přímým UPDATE (PATCH z PostgRESTu)
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET status = %L WHERE id = %L', 'cancelled', _res),
    'V okně 48 h před akcí může rezervaci zrušit jen',
    'zástupce klubu nezruší rezervaci v okně ani přímým UPDATE');

  -- (c) ani oklikou přes cancelled_* bez sáhnutí na status
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET cancel_reason = %L WHERE id = %L', 'jdeme domů', _res),
    'V okně 48 h před akcí může rezervaci zrušit jen',
    'ani samotné razítko storna v okně neprojde');
  RESET ROLE;

  PERFORM pg_temp.tvrd(pg_temp.stav(_res) = 'confirmed',
    'rezervace v okně po všech třech pokusech pořád stojí (a naúčtuje se)');

  -- MIMO OKNO ZŮSTÁVÁ PŘÍMÝ ZÁPIS OTEVŘENÝ PŘESNĚ JAKO DŘÍV.
  -- Bez tohohle by se dalo „opravit" pravidlo tím, že se přímý zápis zakáže
  -- úplně — a rozbil by se tím zbytek aplikace, aniž by to test poznal.
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, note)
  VALUES (pg_temp.draha(2), pg_temp.klub(), pg_temp.mimo_okno(70, 16), pg_temp.mimo_okno(70, 17),
          'mimo okno se nic nemění')
  RETURNING id INTO _mimo;
  UPDATE public.reservations SET status = 'cancelled' WHERE id = _mimo;
  GET DIAGNOSTICS _n = ROW_COUNT;
  RESET ROLE;

  PERFORM pg_temp.tvrd(_mimo IS NOT NULL,
    'zástupce klubu mimo okno přímý INSERT pořád svede');
  PERFORM pg_temp.tvrd(_n = 1 AND pg_temp.stav(_mimo) = 'cancelled',
    'zástupce klubu mimo okno přímým UPDATE pořád zruší');
END $$;

-- -----------------------------------------------------------------------------
-- 8) PRÁVA NA POMOCNÉ FUNKCE — `anon` se k nim nedostane
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.v_okne_48h(timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.hlaska_okna_48h(text)', 'EXECUTE'),
    'anon nemá EXECUTE na v_okne_48h ani hlaska_okna_48h');
  PERFORM pg_temp.tvrd(
    has_function_privilege('authenticated', 'public.v_okne_48h(timestamptz)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.hlaska_okna_48h(text)', 'EXECUTE'),
    'authenticated na obě funkce EXECUTE má');
END $$;

RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
