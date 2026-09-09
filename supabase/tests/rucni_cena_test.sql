-- =============================================================================
-- RUČNÍ CELKOVÁ CENA AKCE (trénink a turnaj) — zadává jen admin
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/rucni_cena_test.sql
-- Celý běh je v jedné transakci, která se na konci ROLLBACKuje → data zůstanou
-- jako po `supabase db reset`. Test projde, když skript doběhne bez chyby a vypíše
-- „VŠECHNY TESTY PROŠLY".
--
-- Co se měří: pevná částka se ukládá napevno (nedopočítává se z hodin a
-- nepřepíšou ji pásma), rozpad na dráhy sedí na haléř, zadat ji smí JEN admin,
-- a hlavně — DÁ SE VYFAKTUROVAT, a to oběma cestami. Poslední bod je tu proto,
-- že bez něj byla celá funkce k ničemu: částka se uložila správně, ale doklad
-- se odmítl vystavit („částka 7000 Kč nesedí na 13 h × 538.46 Kč/h").
--
-- POZOR NA ROLI: testy práv běží pod `SET LOCAL ROLE authenticated`, ne jako
-- `postgres`. Jako `postgres` projde všechno (obchází granty i RLS), takže by
-- test tvrdil zavřeno o dveřích, vedle kterých je otevřené okno — pravidlo 3
-- a 9 v CLAUDE.md. Dvakrát to tady propustilo blokér.
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

-- Vyhledání testovacích ID. SECURITY DEFINER schválně: `authenticated` nemá
-- SELECT na `subjects` a test by padal na hledání klubu, ne na tom, co měří.
-- Obchází se tím jen dohledání ID podle jména — žádná brána, kterou tenhle
-- soubor testuje (ty se měří přes `create_booking` a přímý UPDATE pod rolí).
CREATE OR REPLACE FUNCTION pg_temp.draha(_n int) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT id FROM public.sheets WHERE name = 'Dráha ' || _n; $$;

-- Termín „za N dní" v pražském čase. Každý test má svůj den, aby si testy
-- navzájem nekolidovaly na dráze — běží totiž v JEDNÉ transakci.
CREATE OR REPLACE FUNCTION pg_temp.den(_za int, _hod int) RETURNS timestamptz
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

-- Klub bez vlastní sazby → ocenění z pásmového ceníku. To je ta „výchozí"
-- cena, kterou má ruční částka přebít (a kterou má naopak dostat neadmin).
CREATE OR REPLACE FUNCTION pg_temp.klub() RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.subjects
   WHERE type = 'club' AND default_rate IS NULL AND deleted_at IS NULL
   ORDER BY id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.firma() RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.subjects
   WHERE type = 'commercial' AND deleted_at IS NULL ORDER BY id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.ids(_v jsonb) RETURNS uuid[]
 LANGUAGE sql IMMUTABLE AS $$
  SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(_v->'reservation_ids') x;
$$;

-- -----------------------------------------------------------------------------
-- 1) ADMIN ZADÁ 14 000 → uloží se přesně 14 000, ať akce trvá jakkoli
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ids uuid[]; _soucet numeric; _rate numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');

  -- 8:00–21:00 = 13 h na dvou drahách. 14 000 / 13 h / 2 dráhy je 538,46 Kč/h,
  -- tedy sazba s haléři — dřív to CHECK odmítl a přesně proto změna vznikla.
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Turnaj za 14 000',
    pg_temp.den(500, 8), pg_temp.den(500, 21),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 14000));

  RESET ROLE;   -- `amount` není v SELECT grantu pro authenticated
  SELECT round(sum(r.amount), 2) INTO _soucet
    FROM public.reservations r WHERE r.id = ANY(_ids);
  PERFORM pg_temp.tvrd(array_length(_ids, 1) = 2, 'akce na dvou drahách = dvě rezervace');
  PERFORM pg_temp.tvrd(_soucet = 14000, 'součet přes dráhy je přesně 14 000 (bylo ' || _soucet || ')');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(r.cena_rucni) FROM public.reservations r WHERE r.id = ANY(_ids)),
    'obě rezervace mají příznak cena_rucni');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(r.cenove_pasma IS NULL) FROM public.reservations r WHERE r.id = ANY(_ids)),
    'pásmový rozpis se zahodil — přestal částku popisovat');

  SELECT r.rate_per_hour INTO _rate FROM public.reservations r WHERE r.id = _ids[1];
  PERFORM pg_temp.tvrd(_rate = 538.46, 'sazba je odvozený průměr s haléři (538,46 Kč/h)');

  -- ÚPRAVA NESMÍ ČÁSTKU PŘEPOČÍTAT — to je celý smysl příznaku.
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations SET end_at = end_at + interval '1 hour' WHERE id = _ids[1];
  PERFORM set_config('app.trusted_booking', 'off', true);
  SELECT round(sum(r.amount), 2) INTO _soucet
    FROM public.reservations r WHERE r.id = ANY(_ids);
  PERFORM pg_temp.tvrd(_soucet = 14000, 'po prodloužení akce je součet pořád 14 000 (bylo ' || _soucet || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 2) TICHÝ PŘEPOČET — případ, kde strážce celých korun mlčí
-- -----------------------------------------------------------------------------
-- 28 000 / 2 dráhy = 14 000 na 14 h = přesně 1 000 Kč/h. Sazba tedy vyjde na celé
-- koruny a CHECK ani `check_reservation_money` nemají co namítnout. Kdyby se
-- příznak při úpravě ztratil, částka se přepočítá TIŠE — pozná se to teprve po
-- změně délky. Bez tohohle testu mutace „příznak se na UPDATE nedrží" projde.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ids uuid[]; _soucet numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Turnaj za 28 000',
    pg_temp.den(563, 7), pg_temp.den(563, 21),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 28000));

  RESET ROLE;
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations SET end_at = end_at + interval '1 hour' WHERE id = ANY(_ids);
  PERFORM set_config('app.trusted_booking', 'off', true);

  SELECT round(sum(r.amount), 2) INTO _soucet
    FROM public.reservations r WHERE r.id = ANY(_ids);
  PERFORM pg_temp.tvrd(_soucet = 28000,
    'pevná cena drží i tam, kde sazba vyjde na celé koruny (bylo ' || _soucet || ', hodinový přepočet by dal 30 000)');
END $$;

-- -----------------------------------------------------------------------------
-- 3) NEDĚLITELNÁ ČÁSTKA — haléř se rozdá, nezaokrouhlí stranou
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ids uuid[]; _soucet numeric; _rozdil numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  -- 3 333,33 na dvě dráhy: 1 666,665 na dráhu, tedy jeden haléř navíc musí
  -- někdo dostat. Kulatá částka (14 000/2) by tenhle rozpad neodhalila.
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'training', 'Trénink za 3 333,33',
    pg_temp.den(550, 8), pg_temp.den(550, 11),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 3333.33));

  RESET ROLE;
  SELECT round(sum(r.amount), 2), max(r.amount) - min(r.amount)
    INTO _soucet, _rozdil
    FROM public.reservations r WHERE r.id = ANY(_ids);
  PERFORM pg_temp.tvrd(_soucet = 3333.33, 'nedělitelná částka sedí na haléř (bylo ' || _soucet || ')');
  PERFORM pg_temp.tvrd(_rozdil = 0.01, 'zbylý haléř se rozdal po jednom, ne zaokrouhlil stranou');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(r.cena_rucni) FROM public.reservations r WHERE r.id = ANY(_ids)),
    'pevná cena platí i pro TRÉNINK, nejen pro turnaj');
END $$;

-- -----------------------------------------------------------------------------
-- 4) DVA DNY = DVĚ AKCE (rezervace nesmí přesáhnout půlnoc)
-- -----------------------------------------------------------------------------
-- `validate_reservation_slot` nepustí rezervaci přes půlnoc, takže dvoudenní
-- turnaj jsou dvě samostatné akce a pevná cena se zadává na den. Test hlídá, že
-- se ani jedna z nich cestou nepřepočítá: 14 000 + 12 000 = 26 000.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _vse uuid[]; _soucet numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _vse := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Dvoudenní turnaj — den 1',
    pg_temp.den(510, 8), pg_temp.den(510, 21),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 14000));
  _vse := _vse || pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Dvoudenní turnaj — den 2',
    pg_temp.den(511, 9), pg_temp.den(511, 18),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 12000));

  RESET ROLE;
  SELECT round(sum(r.amount), 2) INTO _soucet
    FROM public.reservations r WHERE r.id = ANY(_vse);
  PERFORM pg_temp.tvrd(_soucet = 26000,
    'dva dny s různou délkou dají dohromady přesně 26 000 (bylo ' || _soucet || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 5) PEVNOU CENU SMÍ ZADAT JEN ADMIN
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ids uuid[]; _amount numeric;
BEGIN
  -- 4444… je ZÁSTUPCE klubu, tedy nejsilnější neadmin — smí za klub rezervovat.
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1)], 'tournament', 'Neadmin zkouší podstrčit cenu',
    pg_temp.den(520, 8), pg_temp.den(520, 10),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 1));   -- ← chce platit 1 Kč

  RESET ROLE;
  SELECT r.amount INTO _amount FROM public.reservations r WHERE r.id = _ids[1];
  PERFORM pg_temp.tvrd(_amount <> 1, 'neadminovi se podstrčená cena 1 Kč zahodila (má ' || _amount || ')');
  PERFORM pg_temp.tvrd(
    NOT (SELECT r.cena_rucni FROM public.reservations r WHERE r.id = _ids[1]),
    'neadmin si nenastavil příznak cena_rucni');
  PERFORM pg_temp.tvrd(
    (SELECT r.cenove_pasma IS NOT NULL FROM public.reservations r WHERE r.id = _ids[1]),
    'neadmin dostal cenu z pásmového ceníku');
END $$;

-- Totéž pro SAZBU: neadmin ji poslat může, engine ji stejně zahodí.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ids uuid[]; _rate numeric;
BEGIN
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1)], 'training', 'Neadmin posílá sazbu',
    pg_temp.den(570, 8), pg_temp.den(570, 10),
    pg_temp.klub(), NULL, '{}'::jsonb, 1, false, NULL, NULL));   -- ← 1 Kč/h

  RESET ROLE;
  SELECT r.rate_per_hour INTO _rate FROM public.reservations r WHERE r.id = _ids[1];
  PERFORM pg_temp.tvrd(_rate <> 1, 'neadminovi se podstrčená sazba 1 Kč/h zahodila (má ' || _rate || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 6) SAZBA A CELKOVÁ CENA NAJEDNOU = ROZPOR, musí se odmítnout
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.ocekavej_chybu(format(
    $q$ SELECT public.create_booking(ARRAY[%L::uuid], 'tournament', 'Obojí najednou',
          %L::timestamptz, %L::timestamptz, %L::uuid, NULL, '{}'::jsonb, 500, false, NULL, 14000) $q$,
    pg_temp.draha(1), pg_temp.den(540, 8), pg_temp.den(540, 10), pg_temp.klub()),
    'buď sazbu za hodinu, nebo celkovou cenu',
    'sazba i celková cena najednou se odmítnou');
END $$;

-- -----------------------------------------------------------------------------
-- 7) PŘÍMÝ ZÁPIS: neadmin nesmí přepsat `amount` mimo RPC
-- -----------------------------------------------------------------------------
-- `reservations` má tabulkové UPDATE granty včetně sloupce `amount`, takže tohle
-- hlídá jedině guard trigger. U pevné ceny se `amount` nedopočítává, takže kdyby
-- guard pustil, přepsaná částka by tam prostě zůstala.
DO $$
DECLARE _ids uuid[]; _amount numeric;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1)], 'tournament', 'Rezervace s pevnou cenou',
    pg_temp.den(530, 8), pg_temp.den(530, 10),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 9000));

  -- a teď se ji zástupce TÉHOŽ klubu pokusí přecenit přímým zápisem
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET amount = 1 WHERE id = %L', _ids[1]),
    'amount', 'zástupce klubu nepřepíše amount přímým zápisem');
  RESET ROLE;

  SELECT r.amount INTO _amount FROM public.reservations r WHERE r.id = _ids[1];
  PERFORM pg_temp.tvrd(_amount = 9000, 'částka zůstala 9 000 (má ' || _amount || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 8) DÁ SE TO VYFAKTUROVAT — obě cesty
-- -----------------------------------------------------------------------------
-- Tohle je ten bod, na kterém funkce původně padala. Podklady musí vedle částky
-- poslat i informaci, ŽE JE PEVNÁ; jinak mapovací vrstva doklad odmítne, protože
-- `castka` nesedí na `hodiny × sazba` (7 000 ≠ 13 × 538,46 = 6 999,98).
--
-- Klubový turnaj je oceněný S DPH → patří na MĚSÍČNÍ klubový doklad.
-- Turnaj pro firmu je BEZ DPH → patří na DOKLAD ZA AKCI. Proto dva testy.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ids uuid[]; _den date; _pocet int; _rucnich int; _soucet numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _den := (pg_temp.den(580, 8) AT TIME ZONE 'Europe/Prague')::date;
  _ids := pg_temp.ids(public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Klubový turnaj 14 000',
    pg_temp.den(580, 8), pg_temp.den(580, 21),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 14000));

  SELECT count(*), count(*) FILTER (WHERE p.cena_rucni), round(sum(p.castka), 2)
    INTO _pocet, _rucnich, _soucet
    FROM public.fakturoid_podklady_klub(
           pg_temp.klub(),
           date_trunc('month', _den)::date,
           (date_trunc('month', _den) + interval '1 month - 1 day')::date) p
   WHERE p.id = ANY(_ids);

  PERFORM pg_temp.tvrd(_pocet = 2, 'měsíční klubová cesta vrátila obě rezervace');
  PERFORM pg_temp.tvrd(_rucnich = 2, 'oba řádky nesou příznak pevné ceny (jinak by se doklad nevystavil)');
  PERFORM pg_temp.tvrd(_soucet = 14000, 'měsíční klubový podklad dává 14 000 (bylo ' || _soucet || ')');
END $$;

SET LOCAL ROLE authenticated;
DO $$
DECLARE _v jsonb; _pocet int; _rucnich int; _soucet numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _v := public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Firemní turnaj 14 000',
    pg_temp.den(590, 8), pg_temp.den(590, 21),
    pg_temp.firma(), NULL, '{}'::jsonb, NULL, false, NULL, 14000);

  SELECT count(*), count(*) FILTER (WHERE p.cena_rucni), round(sum(p.castka), 2)
    INTO _pocet, _rucnich, _soucet
    FROM public.fakturoid_podklady_akce((_v->>'event_id')::uuid) p;

  PERFORM pg_temp.tvrd(_pocet = 2, 'doklad za akci vrátil obě rezervace');
  PERFORM pg_temp.tvrd(_rucnich = 2, 'oba řádky nesou příznak pevné ceny');
  PERFORM pg_temp.tvrd(_soucet = 14000, 'podklad za akci dává 14 000 (bylo ' || _soucet || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 9) KOREKCE HODIN PEVNOU CENU RUŠÍ — a podklady to musí říct
-- -----------------------------------------------------------------------------
-- Korekce („nedorazili, účtujeme 2 h ze 3") částku znovu odvodí z hodin a
-- průměrné sazby, takže od té chvíle paušál neplatí a součin zase sedí. Kdyby
-- podklady příznak posílaly i u korekce, doklad by zněl na původní paušál,
-- přestože se fakturuje krácená částka.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _v jsonb; _ids uuid[]; _rucnich int; _castka numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _v := public.create_booking(
    ARRAY[pg_temp.draha(1)], 'tournament', 'Firemní turnaj s korekcí',
    pg_temp.den(595, 8), pg_temp.den(595, 21),
    pg_temp.firma(), NULL, '{}'::jsonb, NULL, false, NULL, 7000);
  _ids := pg_temp.ids(_v);

  RESET ROLE;
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET corrected_hours = 10, correction_reason = 'Nedorazili, hráli jen 10 h'
   WHERE id = _ids[1];
  PERFORM set_config('app.trusted_booking', 'off', true);

  SELECT count(*) FILTER (WHERE p.cena_rucni), sum(p.castka)
    INTO _rucnich, _castka
    FROM public.fakturoid_podklady_akce((_v->>'event_id')::uuid) p;

  PERFORM pg_temp.tvrd(_rucnich = 0, 'po korekci hodin se příznak pevné ceny už neposílá');
  PERFORM pg_temp.tvrd(_castka = round(10 * 538.46, 2),
    'po korekci se fakturuje krácená částka z hodin (' || _castka || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 10) MUTAČNÍ CESTY JSOU ZAVŘENÉ — a to i adminovi
-- -----------------------------------------------------------------------------
-- Pevná cena je vlastnost AKCE, ale uložená po řádcích, a event-level RPC o ní
-- nevěděly. Každá z nich dřív vracela ÚSPĚCH: `uprav_sazbu_akce` neudělala nic
-- a hlásila novou sazbu, `uprav_drahy_akce` při ubrání dráhy tiše snížila cenu
-- ze 14 000 na 7 000, `move_booking` pustila zástupce klubu roztáhnout akci
-- z 2 na 13 hodin za stejné peníze. Tichý no-op je u peněz horší než chyba.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _v jsonb; _ids uuid[]; _ev uuid; _amount numeric; _pred numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _v := public.create_booking(
    ARRAY[pg_temp.draha(1)], 'tournament', 'Zavřené cesty',
    pg_temp.den(600, 8), pg_temp.den(600, 10),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 5000);
  _ev := (_v->>'event_id')::uuid;
  _ids := pg_temp.ids(_v);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L::uuid, 900)', _ev),
    'pevně zadanou celkovou cenu', 'přecenění sazbou je zavřené');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_typ_akce(%L::uuid, ''commercial'')', _ev),
    'pevně zadanou celkovou cenu', 'změna typu akce je zavřená');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L::uuid, %L::timestamptz, %L::timestamptz, NULL)',
           _ids[1], pg_temp.den(600, 8), pg_temp.den(600, 20)),
    'pevně zadanou celkovou cenu', 'prodloužení akce je zavřené');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_drahy_akce(%L::uuid, ARRAY[%L::uuid, %L::uuid])',
           _ev, pg_temp.draha(1), pg_temp.draha(2)),
    'pevně zadanou celkovou cenu', 'přidání dráhy je zavřené');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.update_booking(%L::uuid, NULL, NULL, 900)', _ids[1]),
    'pevně zadanou celkovou cenu', 'změna sazby přes update_booking je zavřená');

  -- ČÁSTKA SE PŘITOM NESMÍ POHNOUT
  RESET ROLE;
  SELECT round(sum(r.amount), 2) INTO _amount
    FROM public.reservations r WHERE r.id = ANY(_ids);
  PERFORM pg_temp.tvrd(_amount = 5000, 'po všech zavřených pokusech je částka pořád 5 000 (má ' || _amount || ')');
  SET LOCAL ROLE authenticated;

  -- ÚPRAVA NÁZVU MUSÍ PROJÍT — jinak nejde opravit ani překlep
  PERFORM public.update_booking(_ids[1], 'Opravený název', NULL, NULL);
  PERFORM pg_temp.tvrd(
    (SELECT e.title FROM public.events e WHERE e.id = _ev) = 'Opravený název',
    'název akce jde opravit i u pevné ceny (cenou to nehýbe)');

  -- STORNO CELÉ AKCE MUSÍ PROJÍT — cenu nepůlí, ruší ji celou.
  PERFORM public.cancel_booking(_ids[1], 'event', 'zkouška');
  RESET ROLE;
  PERFORM pg_temp.tvrd(
    (SELECT r.status FROM public.reservations r WHERE r.id = _ids[1])::text = 'cancelled',
    'storno pevně oceněné akce projde (je to jediná cesta ven)');
END $$;

-- -----------------------------------------------------------------------------
-- 11) UBRÁNÍ DRÁHY NESMÍ TIŠE ZLEVNIT
-- -----------------------------------------------------------------------------
-- Tohle je ta horší půlka nálezu: přidání dráhy padalo hlasitě, ubrání prošlo
-- a cena spadla na polovinu, aniž by o tom kdokoli věděl.
SET LOCAL ROLE authenticated;
DO $$
DECLARE _v jsonb; _ids uuid[]; _ev uuid; _amount numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _v := public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'tournament', 'Ubrání dráhy',
    pg_temp.den(601, 8), pg_temp.den(601, 21),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 14000);
  _ev := (_v->>'event_id')::uuid;
  _ids := pg_temp.ids(_v);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_drahy_akce(%L::uuid, ARRAY[%L::uuid])', _ev, pg_temp.draha(1)),
    'pevně zadanou celkovou cenu', 'ubrání dráhy je zavřené');

  RESET ROLE;
  SELECT round(sum(r.amount), 2) INTO _amount
    FROM public.reservations r WHERE r.id = ANY(_ids) AND r.deleted_at IS NULL;
  PERFORM pg_temp.tvrd(_amount = 14000,
    'po pokusu o ubrání dráhy je cena pořád 14 000, ne 7 000 (má ' || _amount || ')');
  SET LOCAL ROLE authenticated;

  -- TÁŽ CENA, DRUHÁ CESTA: storno jedné dráhy (nález bezpečnostní brány).
  --
  -- `uprav_drahy_akce` výš padá hlasitě, ale `cancel_booking` se `p_scope`
  -- „single" vyrobí přesně týž výsledek — 14 000 → 7 000 — a bez jediné chyby.
  -- Navíc to nepotřebuje admina: `can_manage_reservation` pustí zástupce klubu
  -- na vlastní rezervaci. Kdyby zůstala otevřená jen tahle cesta, celý guard
  -- v `uprav_drahy_akce` je k ničemu.
  -- Kdo na rezervaci právo nemá, padá dřív — na `can_manage_reservation`.
  -- Guard pevné ceny je AŽ ZA touhle kontrolou, takže pro toho, kdo právo MÁ
  -- (autor rezervace, zástupce svého klubu), platí stejně jako pro admina níž.
  PERFORM pg_temp.prihlas('22222222-2222-2222-2222-222222222222');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L::uuid, ''single'', ''nepotřebujeme'')', _ids[2]),
    'nemáte právo stornovat',
    'cizí člověk se k dráze pevně oceněné akce nedostane ani stornem');

  -- ADMIN právo MÁ — a přesto neprojde. Editor paušálu je pozdější ticket.
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L::uuid, ''single'', ''nepotřebujeme'')', _ids[2]),
    'pevně zadanou celkovou cenu',
    'ani admin nevyjme jednu dráhu z pevně oceněné akce stornem');

  RESET ROLE;
  SELECT round(sum(r.amount), 2) INTO _amount
    FROM public.reservations r
   WHERE r.id = ANY(_ids) AND r.status = 'confirmed' AND r.deleted_at IS NULL;
  PERFORM pg_temp.tvrd(_amount = 14000,
    'ani po stornu jedné dráhy se cena nezpůlila, k fakturaci je 14 000 (má '
    || _amount || ')');
  SET LOCAL ROLE authenticated;

  -- STORNO CELÉ AKCE ale projít MUSÍ — cenu nepůlí, ruší ji celou.
  -- Kdyby padalo i tohle, nešlo by pevně oceněnou akci zrušit vůbec.
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM public.cancel_booking(_ids[1], 'event', 'ruší se celá');
  RESET ROLE;
  SELECT count(*) INTO _amount
    FROM public.reservations r
   WHERE r.id = ANY(_ids) AND r.status = 'confirmed' AND r.deleted_at IS NULL;
  PERFORM pg_temp.tvrd(_amount = 0,
    'storno CELÉ pevně oceněné akce projde (je to cesta ven)');

  -- A GUARD NESMÍ ZAVŘÍT VÍC, NEŽ MÁ.
  --
  -- U JEDNODRÁHOVÉ akce je `single` totéž co `event` — cenu nepůlí, ruší ji
  -- celou — takže tahle cesta zůstat otevřená MUSÍ. Bez téhle kontroly projde
  -- i guard zúžený na `p_scope = 'single' AND _res.cena_rucni`, po kterém se
  -- jednodráhový paušál nedá stornovat vůbec. Testovat jen zavřený směr
  -- nestačí. (Nález brány migrací.)
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _v := public.create_booking(
    ARRAY[pg_temp.draha(1)], 'tournament', 'Paušál na jedné dráze',
    pg_temp.den(602, 8), pg_temp.den(602, 10),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 3000);
  _ids := pg_temp.ids(_v);
  PERFORM public.cancel_booking(_ids[1], 'single', 'jednodráhová jde');
  RESET ROLE;
  PERFORM pg_temp.tvrd(
    (SELECT r.status FROM public.reservations r WHERE r.id = _ids[1])::text = 'cancelled',
    'jednodráhový paušál jde stornovat i přes „single" (guard nezavřel víc, než měl)');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 11b) NaN A NEKONEČNO DOSTANOU ČESKOU HLÁŠKU, NE SYROVOU CHYBU
-- -----------------------------------------------------------------------------
-- PostgREST umí `p_celkem` poslat jako řetězec, takže „NaN" i „Infinity" se do
-- numeric dostanou. Obě proklouznou kontrolám na zápornou částku i na haléře
-- (`NaN < 0` a `NaN <> round(NaN, 2)` jsou v Postgresu obě false, protože
-- `NaN = NaN` je pravda) a spadly by až na `NaN::int` v rozpadu částky.
-- Odmítnuté to bylo i předtím, ale hláškou „cannot convert NaN to integer".
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], ''tournament'', ''NaN'','
           || ' %L::timestamptz, %L::timestamptz, %L::uuid, NULL, ''{}''::jsonb,'
           || ' NULL, false, NULL, ''NaN''::numeric)',
           pg_temp.draha(1), pg_temp.den(603, 8), pg_temp.den(603, 10), pg_temp.klub()),
    'musí být číslo', 'NaN dostane českou hlášku, ne syrovou chybu z rozpadu částky');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], ''tournament'', ''Inf'','
           || ' %L::timestamptz, %L::timestamptz, %L::uuid, NULL, ''{}''::jsonb,'
           || ' NULL, false, NULL, ''Infinity''::numeric)',
           pg_temp.draha(1), pg_temp.den(603, 8), pg_temp.den(603, 10), pg_temp.klub()),
    'musí být číslo', 'nekonečno dostane českou hlášku taky');

  -- a záporné nekonečno chytne až kontrola na zápornou částku — jiná hláška,
  -- ale pořád česká a pořád odmítnuté
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], ''tournament'', ''-Inf'','
           || ' %L::timestamptz, %L::timestamptz, %L::uuid, NULL, ''{}''::jsonb,'
           || ' NULL, false, NULL, ''-Infinity''::numeric)',
           pg_temp.draha(1), pg_temp.den(603, 8), pg_temp.den(603, 10), pg_temp.klub()),
    'nemůže být záporná', 'záporné nekonečno spadne na kontrolu záporné částky');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 12) `anon` NEMÁ EXECUTE NA PENĚŽNÍCH FUNKCÍCH
-- -----------------------------------------------------------------------------
-- `anon` není `PUBLIC`, takže `REVOKE ALL … FROM PUBLIC` ho nesundá — a Supabase
-- mu grant vrací přes ALTER DEFAULT PRIVILEGES při každém CREATE. Migrace tyhle
-- tři funkce zakládá přes DROP+CREATE, takže bez `, anon` v REVOKE by se obrana
-- ztratila.
RESET ROLE;
DO $$
DECLARE _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.create_booking(uuid[],text,text,timestamptz,timestamptz,uuid,text,jsonb,numeric,boolean,uuid,numeric)',
    'public.fakturoid_podklady_akce(uuid)',
    'public.fakturoid_podklady_klub(uuid,date,date)'
  ] LOOP
    PERFORM pg_temp.tvrd(NOT has_function_privilege('anon', _fn, 'EXECUTE'),
      'anon nemá EXECUTE na ' || split_part(_fn, '(', 1));
    PERFORM pg_temp.tvrd(has_function_privilege('authenticated', _fn, 'EXECUTE'),
      'authenticated EXECUTE má (jinak by se nedalo rezervovat ani fakturovat)');
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 13) PŘECENĚNÍ OBNOVÍ DAŇOVÝ REŽIM I U PEVNÉ CENY
-- -----------------------------------------------------------------------------
-- Větev pevné ceny končí `RETURN NEW` ještě před přeceňovacím blokem, takže je
-- to JEDINÉ místo, kde se u ní `cena_bez_dph` může přepočítat. Dokud tam byla
-- podmínka jen `TG_OP = 'INSERT'`, zůstal snapshot ze starého typu akce:
-- klubový turnaj (cena S daní) přepnutý na komerční (ceny BEZ daně) si nechal
-- `false` → doklad za akci ho odmítl vystavit, zatímco měsíční klubový doklad
-- ho vzal a hala by odvedla daň z částky, kterou nevybrala.
--
-- Cesta `zmen_typ_akce` je dnes u pevné ceny ZAVŘENÁ (test 10), takže se měří
-- přímo přes marker `app.preceneni` — tedy tak, jak přecenění teče uvnitř.
-- Je to obrana do hloubky: až editor paušálu vznikne, musí počítat správně.
RESET ROLE;
DO $$
DECLARE _v jsonb; _ids uuid[]; _pred boolean; _po boolean; _amount numeric;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  SET LOCAL ROLE authenticated;
  _v := public.create_booking(
    ARRAY[pg_temp.draha(1)], 'tournament', 'Daňový režim u pevné ceny',
    pg_temp.den(610, 8), pg_temp.den(610, 10),
    pg_temp.klub(), NULL, '{}'::jsonb, NULL, false, NULL, 5000);
  _ids := pg_temp.ids(_v);
  RESET ROLE;

  SELECT r.cena_bez_dph INTO _pred FROM public.reservations r WHERE r.id = _ids[1];
  PERFORM pg_temp.tvrd(_pred = false,
    'klubový turnaj má cenu VČETNĚ daně (cena_bez_dph = false)');

  -- Přecenění na komerční typ — přesně to, co uvnitř dělá `zmen_typ_akce`.
  UPDATE public.events SET event_type = 'commercial'
   WHERE id = (_v->>'event_id')::uuid;
  PERFORM set_config('app.trusted_booking', 'on', true);
  PERFORM set_config('app.preceneni', 'on', true);
  UPDATE public.reservations SET rate_per_hour = NULL, cenove_pasma = NULL
   WHERE id = _ids[1];
  PERFORM set_config('app.preceneni', 'off', true);
  PERFORM set_config('app.trusted_booking', 'off', true);

  SELECT r.cena_bez_dph, r.amount INTO _po, _amount
    FROM public.reservations r WHERE r.id = _ids[1];
  PERFORM pg_temp.tvrd(_po = true,
    'po přecenění na komerční akci je cena BEZ daně (cena_bez_dph = true) — jinak by doklad nešel vystavit');
  PERFORM pg_temp.tvrd(_amount = 5000,
    'přecenění změnilo jen daňový význam, částka zůstala pevná (má ' || _amount || ')');
END $$;

RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
