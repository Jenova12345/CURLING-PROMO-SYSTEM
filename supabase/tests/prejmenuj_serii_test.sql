-- =============================================================================
-- TESTY: přejmenování série — „jen tato akce" vs „celá série"
-- =============================================================================
-- Spuštění (nad seedovanou lokální DB, transakce se na konci ROLLBACKuje):
--   psql -h 127.0.0.1 -p 55322 -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     -f supabase/tests/prejmenuj_serii_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ
--
-- Dvě větve, které se musí lišit, a to měřitelně:
--   * „jen tato akce" (`update_booking`) sáhne PRÁVĚ NA JEDEN termín;
--   * „celá série" (`prejmenuj_serii`) sáhne na VŠECHNY BUDOUCÍ termíny.
-- Kdyby se kterákoli chovala jako ta druhá, uživatel dostane něco jiného, než
-- co zvolil — a u série se to pozná až za měsíc, až se termín objeví pod cizím
-- názvem.
--
-- Dál se měří tři hranice, které to celé drží pohromadě:
--   * MINULÉ TERMÍNY se nemění (název je na dokladu);
--   * PRÁVA jsou fail-closed (kdo nesmí na jeden, nepřejmenuje žádný);
--   * ČASU, DRAH, SAZBY ANI ODBĚRATELE se funkce nedotkne (nebyla o tom).
--
-- ČÍSLA V TOMHLE SOUBORU NEVISÍ NA CENÍKU — přejmenování cenu nemění a test to
-- tvrdí otiskem peněžních sloupců před/po, ne konkrétní částkou. Když se ceník
-- změní, tenhle soubor se opravovat nemusí.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tenhle test patří nad seedovanou vývojovou databázi, ne nad ostrá data.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _cast text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(_cast in SQLERRM) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _cast, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale PROŠLA', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.admin() RETURNS uuid LANGUAGE sql IMMUTABLE
  AS $$ SELECT '11111111-1111-1111-1111-111111111111'::uuid $$;
-- 4444… = zástupce klubu CK Ostravské kameny, tedy NEJSILNĚJŠÍ neadmin, který
-- k sérii z seedu právo MÁ. 5555… = člen téhož klubu, právo nemá.
CREATE OR REPLACE FUNCTION pg_temp.zastupce() RETURNS uuid LANGUAGE sql IMMUTABLE
  AS $$ SELECT '44444444-4444-4444-4444-444444444444'::uuid $$;
CREATE OR REPLACE FUNCTION pg_temp.clen() RETURNS uuid LANGUAGE sql IMMUTABLE
  AS $$ SELECT '55555555-5555-5555-5555-555555555555'::uuid $$;

CREATE OR REPLACE FUNCTION pg_temp.prihlas(_user uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', _user, 'role', 'authenticated')::text, true) $$;

-- Série ze seedu: „Pravidelný trénink A-tým", osm termínů, každý vlastní akce.
CREATE OR REPLACE FUNCTION pg_temp.serie() RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT r.series_id FROM public.reservations r
   WHERE r.series_id IS NOT NULL AND r.deleted_at IS NULL
   GROUP BY r.series_id ORDER BY count(*) DESC, r.series_id LIMIT 1 $$;

-- Kolik BUDOUCÍCH termínů série nese daný název.
CREATE OR REPLACE FUNCTION pg_temp.budoucich_s_nazvem(_nazev text) RETURNS int
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.reservations r JOIN public.events e ON e.id = r.event_id
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
     AND r.start_at >= now() AND e.title = _nazev $$;

CREATE OR REPLACE FUNCTION pg_temp.budoucich() RETURNS int
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL AND r.start_at >= now() $$;

-- Dráha podle pořadí v abecedě (pomocná fixtura).
CREATE OR REPLACE FUNCTION pg_temp.draha(_poradi int) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.sheets WHERE active ORDER BY name OFFSET (_poradi - 1) LIMIT 1 $$;

-- První budoucí termín série.
CREATE OR REPLACE FUNCTION pg_temp.prvni_budouci() RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT r.id FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL AND r.start_at >= now()
   ORDER BY r.start_at LIMIT 1 $$;

-- Otisk VŠEHO, čeho se přejmenování dotknout NESMÍ: časy, dráhy, peníze,
-- odběratel, typ akce, schválení. Porovnává se před a po.
CREATE OR REPLACE FUNCTION pg_temp.otisk() RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(string_agg(
           r.id::text || '|' || r.start_at::text || '|' || r.end_at::text || '|'
             || r.sheet_id::text || '|' || COALESCE(r.subject_id::text,'-') || '|'
             || COALESCE(r.amount::text,'-') || '|' || COALESCE(r.rate_per_hour::text,'-') || '|'
             || COALESCE(r.corrected_amount::text,'-') || '|' || r.cena_bez_dph::text || '|'
             || COALESCE(r.approved_at::text,'-') || '|' || e.event_type::text,
           ',' ORDER BY r.id), '')
    FROM public.reservations r LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 0) PŘÍPRAVA — série musí mít MINULÉ i BUDOUCÍ termíny
--
-- Seed zakládá sérii celou do budoucna, takže by se „minulé se nemění" nedalo
-- změřit. Jeden termín se proto posune do minulosti přímým zápisem (ne přes
-- `move_booking`, ta by ho odmítla — a tady nejde o přesun, ale o fixturu).
-- -----------------------------------------------------------------------------
DO $$
DECLARE _minuly uuid; _ev uuid;
BEGIN
  PERFORM pg_temp.tvrd(pg_temp.serie() IS NOT NULL, 'příprava: v seedu je opakovaná série');
  PERFORM pg_temp.tvrd(pg_temp.budoucich() >= 3,
    format('příprava: série má aspoň tři budoucí termíny (má %s)', pg_temp.budoucich()));

  SELECT r.id, r.event_id INTO _minuly, _ev FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
   ORDER BY r.start_at DESC LIMIT 1;

  PERFORM set_config('app.trusted_booking', 'on', true);
  -- `date_trunc('hour', …)` schválně: `validate_reservation_slot` pouští jen
  -- celé hodiny a `now()` celá hodina není.
  UPDATE public.reservations
     SET start_at = date_trunc('hour', now()) - interval '14 days',
         end_at   = date_trunc('hour', now()) - interval '14 days' + interval '2 hours'
   WHERE id = _minuly;
  PERFORM set_config('app.trusted_booking', 'off', true);
  UPDATE public.events SET title = 'Trénink jak byl' WHERE id = _ev;

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r
      WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL AND r.start_at < now()) = 1,
    'příprava: jeden termín série je v minulosti (na něm se měří „minulé se nemění")');
END $$;

-- -----------------------------------------------------------------------------
-- 1) „JEN TATO AKCE" MĚNÍ PRÁVĚ JEDEN TERMÍN
--
-- Dnešní chování, které se NESMÍ změnit. `update_booking` se touhle prací
-- nedotýká vůbec — tahle kapitola to hlídá, aby se to nestalo omylem.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez uuid; _pred int;
BEGIN
  _rez := pg_temp.prvni_budouci();
  _pred := pg_temp.budoucich();

  PERFORM public.update_booking(_rez, 'JEN TENHLE TERMÍN');

  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('JEN TENHLE TERMÍN') = 1,
    format('„jen tato akce" přejmenovala PRÁVĚ JEDEN termín (z %s budoucích)', _pred));
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r JOIN public.events e ON e.id = r.event_id
      WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
        AND r.start_at >= now() AND e.title = 'Pravidelný trénink A-tým') = _pred - 1,
    '… a ostatní budoucí termíny si nechaly původní název');
END $$;

-- -----------------------------------------------------------------------------
-- 2) „CELÁ SÉRIE" MĚNÍ VŠECHNY BUDOUCÍ TERMÍNY
--
-- Jádro úkolu. Měří se počet termínů s NOVÝM názvem, ne jen návratová hodnota —
-- funkce by mohla vrátit správné číslo a zapsat jinam.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _pred int; _otisk_pred text;
BEGIN
  _pred := pg_temp.budoucich();
  _otisk_pred := pg_temp.otisk();

  PERFORM pg_temp.prihlas(pg_temp.admin());
  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), 'CELÁ SÉRIE NOVĚ');

  PERFORM pg_temp.tvrd((_v ->> 'zmena') = 'true', 'funkce hlásí, že změna proběhla');
  PERFORM pg_temp.tvrd((_v ->> 'terminu')::int = _pred,
    format('… a hlásí všech %s budoucích termínů (vrátila %s)', _pred, _v ->> 'terminu'));
  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('CELÁ SÉRIE NOVĚ') = _pred,
    format('VŠECHNY budoucí termíny série nesou nový název (%s z %s)',
           pg_temp.budoucich_s_nazvem('CELÁ SÉRIE NOVĚ'), _pred));
  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('JEN TENHLE TERMÍN') = 0,
    '… včetně toho, který byl před chvílí přejmenovaný jednotlivě');

  -- 2b) MINULÝ TERMÍN SE NEZMĚNIL. Tohle je ta noha, kvůli které je
  -- „jen budoucí" rozhodnutím: název akce se tiskne na doklad.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r JOIN public.events e ON e.id = r.event_id
      WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
        AND r.start_at < now() AND e.title = 'Trénink jak byl') = 1,
    'MINULÝ termín si nechal název, pod kterým proběhl (je na dokladu)');

  -- 2c) ČASŮ, DRAH, PENĚZ, ODBĚRATELE ANI SCHVÁLENÍ SE TO NEDOTKLO.
  -- Přejmenování o nich nebylo a hromadný přesun série se vědomě nestaví.
  PERFORM pg_temp.tvrd(pg_temp.otisk() = _otisk_pred,
    '… a časy, dráhy, sazby, částky, odběratel, typ akce i schválení zůstaly BEZE ZMĚNY');

  -- MARKER SE PO ZÁPISU ZASE VYPÍNÁ. `guard_reservation_rep_changes` u něj
  -- výslovně stojí na tom, že „RPC funkce ho po svých zápisech samy vypínají,
  -- aby zvýšené oprávnění neplatilo pro zbytek transakce" — je to tedy vědomá
  -- konvence, na které stojí brána z pravidla 8 v CLAUDE.md, a do dneška
  -- neměla jedinou kontrolu. Bez tohohle tvrzení projde vypuštění závěrečného
  -- `set_config(..., 'off', ...)` zeleně. (Nález brány code review, 11. 9. 2026.)
  PERFORM pg_temp.tvrd(
    COALESCE(current_setting('app.trusted_booking', true), 'off') = 'off',
    '… a app.trusted_booking se po zápisu zase VYPNULO (nezůstalo na transakci)');
END $$;

-- -----------------------------------------------------------------------------
-- 2d) POZNÁMKA SE PROPÍŠE TAKY — a jen na termíny ze série
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _pred int; _otisk_pred text;
BEGIN
  _pred := pg_temp.budoucich();
  _otisk_pred := pg_temp.otisk();
  PERFORM pg_temp.prihlas(pg_temp.admin());
  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), NULL, 'Sraz o čtvrt hodiny dřív');

  PERFORM pg_temp.tvrd((_v ->> 'poznamek')::int = _pred,
    format('poznámka se propsala na všech %s budoucích termínů', _pred));
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r
      WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
        AND r.start_at >= now() AND r.note = 'Sraz o čtvrt hodiny dřív') = _pred,
    '… a sedí i v datech, ne jen v návratové hodnotě');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r
      WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
        AND r.start_at < now() AND COALESCE(r.note,'') = 'Sraz o čtvrt hodiny dřív') = 0,
    '… a minulému termínu se poznámka nezměnila');
  -- Název se přitom NEZMĚNIL — `_title = NULL` znamená „neměň", ne „smaž".
  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('CELÁ SÉRIE NOVĚ') = _pred,
    '… a název zůstal (NULL u názvu znamená „neměň", ne „vymaž")');
  PERFORM pg_temp.tvrd((_v ->> 'akci')::int = 0, '… což funkce i hlásí (akci = 0)');

  -- TOHLE JE TA KAPITOLA, KDE SE PENÍZE MĚŘIT MUSÍ.
  -- Poznámková větev je JEDINÁ, která zapisuje do `reservations` — a všechny
  -- peníze leží tam. Bez tohohle otisku prošla mutace
  -- `SET note = …, rate_per_hour = rate_per_hour + 1` celým souborem zeleně
  -- (součet sazeb série 7 600 → 7 608 Kč, a test vypsal „VŠECHNY TESTY PROŠLY").
  -- Otisk v kapitole 2 na to nestačí: tam se zapisuje do `events`, ne sem.
  -- (Nález brány code review, 11. 9. 2026.)
  PERFORM pg_temp.tvrd(pg_temp.otisk() = _otisk_pred,
    '… a časy, dráhy, sazby, částky, odběratel ani schválení se NEHNULY');

  -- KONTRAKT „'' = SMAŽ POZNÁMKU" — a je to kontrakt, na kterém VISÍ FRONTEND:
  -- dialog posílá `''` právě tehdy, když uživatel poznámku vymazal. Kdyby se
  -- místo smazání uložil prázdný řetězec, bylo by to tiché a napříč celou
  -- sérií. Bez tohohle tvrzení projde mutace `SET note = _note` zeleně.
  -- Proto se tvrdí `note IS NULL`, ne `note = ''`. (Nález brány code review.)
  PERFORM public.prejmenuj_serii(pg_temp.prvni_budouci(), NULL, '');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r
      WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
        AND r.start_at >= now() AND r.note IS NOT NULL) = 0,
    'prázdný řetězec poznámku SMAŽE (note IS NULL), neuloží se jako „"');
END $$;

-- -----------------------------------------------------------------------------
-- 2f) SOFT-SMAZANÝ TERMÍN SÉRIE SE NEPŘEJMENUJE
--
-- Filtr `deleted_at IS NULL` v podotázce nad `events`. Bez tohohle tvrzení je
-- dekorativní — mutace, která ho smaže, projde zeleně. Dopad je malý (termín
-- je smazaný), ale filtr, který nic nedrží, je horší než žádný: příště se o něj
-- někdo opře. (Nález brány code review, 11. 9. 2026.)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _smazany uuid; _ev uuid;
BEGIN
  PERFORM pg_temp.prihlas(pg_temp.admin());

  -- Vlastní termín série, který se rovnou soft-smaže. Vlastní akce schválně:
  -- kdyby sdílel `event_id` s živým termínem, přepsal by se název přes něj
  -- a tvrzení by měřilo něco jiného, než co má.
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('SMAZANÝ ZŮSTÁVÁ', 'training',
          date_trunc('hour', now()) + interval '40 days',
          date_trunc('hour', now()) + interval '40 days 2 hours', pg_temp.admin())
  RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, series_id,
                                   start_at, end_at, deleted_at)
  SELECT pg_temp.draha(1), r.subject_id, _ev, pg_temp.serie(),
         date_trunc('hour', now()) + interval '40 days',
         date_trunc('hour', now()) + interval '40 days 2 hours', now()
    FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL LIMIT 1
  RETURNING id INTO _smazany;

  PERFORM public.prejmenuj_serii(pg_temp.prvni_budouci(), 'ŽIVÉ TERMÍNY');

  PERFORM pg_temp.tvrd(
    (SELECT e.title FROM public.events e WHERE e.id = _ev) = 'SMAZANÝ ZŮSTÁVÁ',
    'SOFT-SMAZANÝ termín série se nepřejmenoval (filtr deleted_at drží)');

  -- A totéž pro POZNÁMKU. Jsou to dva různé `UPDATE` nad dvěma tabulkami,
  -- každý s vlastním filtrem — tvrzení o názvu tedy o poznámce neříká nic
  -- a mutace filtru v poznámkové větvi bez tohohle prochází zeleně.
  PERFORM public.prejmenuj_serii(pg_temp.prvni_budouci(), NULL, 'poznámka živým');
  PERFORM pg_temp.tvrd(
    (SELECT note FROM public.reservations WHERE id = _smazany) IS DISTINCT FROM 'poznámka živým',
    '… a nedostal ani novou poznámku (filtr drží v OBOU větvích, ne jen u názvu)');
END $$;

-- -----------------------------------------------------------------------------
-- 2e) STORNOVANÝ BUDOUCÍ TERMÍN SE PŘEJMENUJE TAKY
--
-- Vědomé rozhodnutí, ne náhoda — proto je změřené. Stornovaný termín do série
-- patří a má se jmenovat stejně jako zbytek; je to shodné s `zmen_firmu_akce`,
-- kde se odběratel přepisuje i u stornovaných drah. Zároveň se tím liší od
-- `cancel_booking`, která bere jen `status = 'confirmed'` — takže kdyby to
-- někdo „sjednotil" podle sesterské funkce, tahle kapitola zčervená a donutí
-- ho rozhodnout znovu, místo aby to udělal mlčky.
--
-- Důvod storna tím netrpí: ten žije v `cancel_reason`, ne v `note`. Tvrdí se
-- to tady, ne jen v komentáři migrace.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _storno uuid; _duvod text; _v jsonb;
BEGIN
  PERFORM pg_temp.prihlas(pg_temp.admin());

  SELECT r.id INTO _storno FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL AND r.start_at >= now()
   ORDER BY r.start_at DESC LIMIT 1;
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET status = 'cancelled', cancelled_at = now(), cancelled_by = pg_temp.admin(),
         cancel_reason = 'Nemocná polovina týmu'
   WHERE id = _storno;
  PERFORM set_config('app.trusted_booking', 'off', true);

  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.reservations WHERE id = _storno) = 'cancelled',
    'příprava: jeden budoucí termín série je stornovaný');

  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), 'SE STORNEM', 'nová poznámka');

  PERFORM pg_temp.tvrd(
    (SELECT e.title FROM public.events e JOIN public.reservations r ON r.event_id = e.id
      WHERE r.id = _storno) = 'SE STORNEM',
    'STORNOVANÝ budoucí termín se přejmenoval taky (patří do série)');
  PERFORM pg_temp.tvrd(
    (SELECT cancel_reason FROM public.reservations WHERE id = _storno) = 'Nemocná polovina týmu',
    '… a DŮVOD STORNA to nepřepsalo (žije v cancel_reason, ne v note)');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.reservations WHERE id = _storno) = 'cancelled',
    '… a termín zůstal stornovaný (přejmenování ho nevzkřísilo)');
END $$;

-- -----------------------------------------------------------------------------
-- 2g) TERMÍN NA DVOU DRAHÁCH = JEDNA AKCE, DVĚ REZERVACE
--
-- `terminu` a `akci` nejsou dvě jména pro totéž číslo a celá hláška ve
-- frontendu stojí na tom rozdílu: uživatel v kalendáři počítá AKCE (blok
-- „jedna akce přes dvě dráhy" je jeden), ne řádky na drahách. Dokud se do
-- hlášky posílalo `terminu`, tvrdila série o 27 termínech na dvou drahách
-- „54 budoucích termínů" — dvojnásobek toho, co je vidět (změřeno
-- v prohlížeči 11. 9. 2026 na sérii „MBL mix boomer liga").
--
-- Bez téhle kapitoly ten význam neměří NIC: jediné dosavadní tvrzení o `akci`
-- je `akci = 0` ve větvi bez názvu, a frontendová brána hlídá jen JMÉNO pole.
-- Kdyby se `akci` začalo počítat nad rezervacemi, obě brány zůstanou zelené
-- a uživatel zase uvidí dvojnásobek. (Nález brány code review, 11. 9. 2026.)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez public.reservations%ROWTYPE; _druha_draha uuid; _nazev_pred text;
        _v jsonb; _terminu int; _akci int; _rezervaci int; _dvojcat int := 0;
BEGIN
  PERFORM pg_temp.prihlas(pg_temp.admin());

  -- Název se ČTE, ne píše natvrdo. Kapitola 3 níž počítá termíny podle názvu,
  -- který nastavila kapitola 2e — kdyby si ho úklid pamatoval jako literál,
  -- rozbil by ji každý, kdo přejmenuje 2e. (Bezpečné je to tady jen proto, že
  -- 2e nechává všechny budoucí termíny pojmenované stejně.)
  SELECT e.title INTO _nazev_pred
    FROM public.reservations r JOIN public.events e ON e.id = r.event_id
   WHERE r.id = pg_temp.prvni_budouci();
  PERFORM pg_temp.tvrd(_nazev_pred IS NOT NULL, 'příprava: původní název série se přečetl');

  -- DVĚ dvojčata, ne jedno. S jedním jsou „počítej akce" a „odečti jedničku"
  -- nerozlišitelné a mutace `_akci := _terminu - 1` projde zeleně (změřeno).
  -- Se dvěma ta třída mutantů padne a tvrzení měří vztah, ne konstantu.
  FOR _rez IN
    SELECT r.* FROM public.reservations r
     WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL
       AND r.start_at >= now() ORDER BY r.start_at LIMIT 2
  LOOP
    SELECT CASE WHEN pg_temp.draha(1) = _rez.sheet_id THEN pg_temp.draha(2)
                ELSE pg_temp.draha(1) END INTO _druha_draha;
    PERFORM pg_temp.tvrd(_druha_draha IS DISTINCT FROM _rez.sheet_id,
      'příprava: druhá dráha je opravdu jiná než ta, na které termín stojí');

    -- Tentýž `event_id` i `series_id` schválně — přesně to zakládá
    -- `create_booking` u dvoudráhové rezervace série (jedna akce, dva řádky).
    PERFORM set_config('app.trusted_booking', 'on', true);
    INSERT INTO public.reservations (sheet_id, subject_id, event_id, series_id,
                                     start_at, end_at, rate_per_hour, amount, cena_bez_dph)
    VALUES (_druha_draha, _rez.subject_id, _rez.event_id, _rez.series_id,
            _rez.start_at, _rez.end_at, _rez.rate_per_hour, _rez.amount, _rez.cena_bez_dph);
    PERFORM set_config('app.trusted_booking', 'off', true);
    _dvojcat := _dvojcat + 1;
  END LOOP;

  PERFORM pg_temp.tvrd(_dvojcat = 2,
    format('příprava: série má DVA dvoudráhové termíny (vyrobeno %s)', _dvojcat));

  _rezervaci := pg_temp.budoucich();
  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), 'DVĚ DRÁHY JEDNA AKCE');
  _terminu := (_v ->> 'terminu')::int;
  _akci    := (_v ->> 'akci')::int;

  PERFORM pg_temp.tvrd(_terminu = _rezervaci,
    format('`terminu` počítá REZERVACE — řádky na drahách (%s)', _terminu));
  PERFORM pg_temp.tvrd(_akci = _rezervaci - _dvojcat,
    format('`akci` počítá AKCE — každý dvoudráhový termín je JEDNA (%s akcí proti %s rezervacím)',
           _akci, _terminu));
  PERFORM pg_temp.tvrd(_akci < _terminu,
    'u termínů na dvou drahách je akcí MÍŇ než rezervací — to je celý ten rozdíl, '
    'na kterém stojí hláška ve frontendu');
  -- A obě dráhy opravdu nesou nový název, ať se „míň akcí" nedá splnit tím,
  -- že by se jedna dráha přejmenovat zapomněla.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r JOIN public.events e ON e.id = r.event_id
      WHERE r.deleted_at IS NULL AND e.title = 'DVĚ DRÁHY JEDNA AKCE'
        AND r.event_id IN (SELECT r2.event_id FROM public.reservations r2
                            WHERE r2.series_id = pg_temp.serie() AND r2.deleted_at IS NULL
                              AND r2.start_at >= now()
                            GROUP BY r2.event_id HAVING count(*) = 2)) = 2 * _dvojcat,
    '… a přejmenovaly se OBĚ dráhy každé takové akce (jeden zápis, dva viditelné řádky)');

  -- ÚKLID: název zpátky na ten, se kterým počítá kapitola 3. Dvoudráhové
  -- termíny se schválně NEMAŽOU — zůstávají jako fixtura i pro kapitoly níž,
  -- ať se práva a fail-closed měří i nad akcí přes dvě dráhy.
  PERFORM public.prejmenuj_serii(pg_temp.prvni_budouci(), _nazev_pred);
END $$;

-- -----------------------------------------------------------------------------
-- 3) PRÁVA: FAIL-CLOSED NA CELOU SÉRII
--
-- Rozhodnutí zákazníka 11. 9. 2026: kdo nesmí na jediný termín, nepřejmenuje
-- žádný. Alternativa „přejmenuj, na co máš právo" by tiše vyrobila sérii se
-- dvěma názvy — a série je právě to, u čeho se na jednotlivé termíny nekouká.
--
-- MĚŘÍ SE POD `SET LOCAL ROLE authenticated` (CLAUDE.md, pravidlo 3 a 9): jako
-- `postgres` projde všechno, takže by test tvrdil zavřeno o otevřených dveřích.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _pocet int;
BEGIN
  _pocet := pg_temp.budoucich();

  -- Člen klubu, který sérii nezaložil: nesmí ani jeden termín.
  PERFORM pg_temp.prihlas(pg_temp.clen());
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prejmenuj_serii(%L, %L)', pg_temp.prvni_budouci(), 'ČLEN TO NESMÍ'),
    'nemáte právo', 'ČLEN klubu sérii NEPŘEJMENUJE');
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('ČLEN TO NESMÍ') = 0,
    '… a nepřejmenoval ANI JEDEN termín (fail-closed, ne „co smíš")');
  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('SE STORNEM') = _pocet,
    format('… všech %s termínů drží původní název', _pocet));
END $$;

-- 3b) Zástupce klubu, kterému série PATŘÍ, projít MUSÍ — jinak by fail-closed
--     znamenal „nikdo kromě admina" a to by práva zúžilo, ne zachovalo.
DO $$
DECLARE _pocet int; _v jsonb; _otisk_pred text;
BEGIN
  _pocet := pg_temp.budoucich();
  _otisk_pred := pg_temp.otisk();
  PERFORM pg_temp.prihlas(pg_temp.zastupce());
  EXECUTE 'SET LOCAL ROLE authenticated';
  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), 'ZÁSTUPCE SMÍ');
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('ZÁSTUPCE SMÍ') = _pocet,
    format('ZÁSTUPCE klubu, kterému série patří, ji přejmenovat SMÍ (všech %s termínů)', _pocet));
  PERFORM pg_temp.tvrd((_v ->> 'terminu')::int = _pocet, '… a sedí i návratová hodnota');
  PERFORM pg_temp.tvrd(pg_temp.otisk() = _otisk_pred,
    '… a ani zástupci se pod rukama nehnuly peníze, časy ani dráhy');
END $$;

-- 3c) Právo se měří na KAŽDÉM termínu, ne jen na tom, ze kterého se volá.
--     Bez toho by stačilo otevřít termín, na který právo mám, a přejmenovat
--     tím i termíny, na které nemám.
DO $$
DECLARE _cizi uuid; _cizi_subjekt uuid; _pocet int;
BEGIN
  _pocet := pg_temp.budoucich();
  SELECT id INTO _cizi_subjekt FROM public.subjects
   WHERE type = 'commercial' AND deleted_at IS NULL LIMIT 1;

  -- Jednomu budoucímu termínu série se podstrčí CIZÍ odběratel, takže na něj
  -- zástupce klubu právo nemá — zbytek série mu zůstává.
  SELECT r.id INTO _cizi FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL AND r.start_at >= now()
   ORDER BY r.start_at DESC LIMIT 1;
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations SET subject_id = _cizi_subjekt WHERE id = _cizi;
  PERFORM set_config('app.trusted_booking', 'off', true);

  PERFORM pg_temp.prihlas(pg_temp.zastupce());
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prejmenuj_serii(%L, %L)', pg_temp.prvni_budouci(), 'JEDEN CIZÍ STAČÍ'),
    'nemáte právo',
    'JEDINÝ termín bez práva zablokuje celou sérii (právo se měří na každém)');
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('JEDEN CIZÍ STAČÍ') = 0,
    '… a nepřejmenoval se ani ten, na který právo MÁ');
  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('ZÁSTUPCE SMÍ') = _pocet,
    format('… celá série drží předchozí název (%s termínů)', _pocet));

  -- uklidit fixturu, ať další kapitoly měří čistý stav
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations r SET subject_id = (
    SELECT r2.subject_id FROM public.reservations r2
     WHERE r2.series_id = pg_temp.serie() AND r2.id <> _cizi AND r2.subject_id IS NOT NULL
     LIMIT 1) WHERE r.id = _cizi;
  PERFORM set_config('app.trusted_booking', 'off', true);
END $$;

-- -----------------------------------------------------------------------------
-- 4) ROHY
-- -----------------------------------------------------------------------------
DO $$
DECLARE _bez_serie uuid; _v jsonb;
BEGIN
  PERFORM pg_temp.prihlas(pg_temp.admin());

  -- 4a) rezervace, která v sérii NENÍ
  SELECT r.id INTO _bez_serie FROM public.reservations r
   WHERE r.series_id IS NULL AND r.deleted_at IS NULL LIMIT 1;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prejmenuj_serii(%L, %L)', _bez_serie, 'NENÍ SÉRIE'),
    'není součástí opakované série',
    'rezervace mimo sérii dostane srozumitelnou hlášku, ne ticho');

  -- 4b) neexistující rezervace
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prejmenuj_serii(%L, %L)', gen_random_uuid(), 'NIC'),
    'Rezervace nenalezena', 'neexistující rezervace skončí srozumitelnou hláškou');

  -- 4c) nic k zápisu = žádná změna, a funkce to PŘIZNÁ (nehlásí úspěch nad nulou)
  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), NULL, NULL);
  PERFORM pg_temp.tvrd((_v ->> 'zmena') = 'false',
    'prázdné zadání se nehlásí jako úspěšná změna');
  PERFORM pg_temp.tvrd((_v ->> 'terminu')::int = 0, '… a hlásí nula dotčených termínů');

  -- 4d) samý bílý znak je totéž co prázdno (název se NEVYMAŽE na mezeru)
  _v := public.prejmenuj_serii(pg_temp.prvni_budouci(), '   ');
  PERFORM pg_temp.tvrd((_v ->> 'zmena') = 'false',
    'název ze samých mezer se bere jako „nezadáno", ne jako nový název');
  PERFORM pg_temp.tvrd(pg_temp.budoucich_s_nazvem('   ') = 0,
    '… a žádný termín se nejmenuje „   "');
END $$;

-- 4e) Série BEZ budoucích termínů — hromadně není co dělat a řekne se to.
DO $$
DECLARE _rez uuid;
BEGIN
  PERFORM pg_temp.prihlas(pg_temp.admin());
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET start_at = start_at - interval '400 days', end_at = end_at - interval '400 days'
   WHERE series_id = pg_temp.serie() AND deleted_at IS NULL AND start_at >= now();
  PERFORM set_config('app.trusted_booking', 'off', true);

  SELECT r.id INTO _rez FROM public.reservations r
   WHERE r.series_id = pg_temp.serie() AND r.deleted_at IS NULL ORDER BY r.start_at DESC LIMIT 1;
  PERFORM pg_temp.tvrd(pg_temp.budoucich() = 0, 'příprava: série nemá žádný budoucí termín');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prejmenuj_serii(%L, %L)', _rez, 'POZDĚ'),
    'žádný budoucí termín',
    'série bez budoucích termínů to řekne, místo aby tiše nic neudělala');
END $$;

-- -----------------------------------------------------------------------------
-- 5) ANON NEMÁ EXECUTE
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.prejmenuj_serii(uuid,text,text)', 'EXECUTE'),
    'anon nemá EXECUTE na prejmenuj_serii');
  PERFORM pg_temp.tvrd(
    has_function_privilege('authenticated', 'public.prejmenuj_serii(uuid,text,text)', 'EXECUTE'),
    'authenticated EXECUTE má (jinak by RPC z aplikace nešlo zavolat)');
END $$;

\echo ''
\echo '======================================================'
\echo ' VŠECHNY TESTY PROŠLY'
\echo '======================================================'
ROLLBACK;
