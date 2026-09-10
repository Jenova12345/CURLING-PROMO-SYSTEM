-- =============================================================================
-- TESTY: změna odběratele (firmy) u komerční akce — `zmen_firmu_akce`
-- =============================================================================
-- Spuštění:
--   psql -p 55322 -U postgres -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/zmen_firmu_akce_test.sql
-- Celý běh je v jedné transakci, která se na konci ROLLBACKuje.
-- Test projde, když skript doběhne bez chyby a vypíše „VŠECHNY TESTY PROŠLY".
--
-- CO TENHLE SOUBOR HLÍDÁ. Funkce sahá na to, KOMU se akce naúčtuje, takže
-- nejcennější tvrzení jsou o penězích a o adresátovi:
--   • nad vystaveným dokladem (interním i fakturoidím) se změna NEPROVEDE —
--     jinak by faktura zněla na jinou firmu než „Kdo kolik dluží";
--   • změna se propíše na VŠECHNY dráhy akce, ne na jednu (jinak dvě firmy
--     u jedné akce a dva doklady);
--   • ČÁSTKA, SAZBA ANI DAŇOVÝ VÝZNAM se nehnou (není to přecenění);
--   • neadmin se k tomu nedostane — a to ani přes RPC, ani přímým zápisem.
--
-- POZOR NA ROLI: testy práv běží pod `SET LOCAL ROLE authenticated`, ne jako
-- `postgres`. Jako `postgres` projde všechno (obchází granty i RLS), takže by
-- test tvrdil zavřeno o dveřích, vedle kterých je otevřené okno — pravidla 3
-- a 9 v CLAUDE.md.
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
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale PROŠLA', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.prihlas(_user uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', _user, 'role', 'authenticated')::text, true) $$;

CREATE OR REPLACE FUNCTION pg_temp.admin() RETURNS uuid LANGUAGE sql IMMUTABLE
  AS $$ SELECT '11111111-1111-1111-1111-111111111111'::uuid $$;
-- 4444… = zástupce klubu, tedy NEJSILNĚJŠÍ neadmin. Když neprojde on, neprojde nikdo.
CREATE OR REPLACE FUNCTION pg_temp.zastupce() RETURNS uuid LANGUAGE sql IMMUTABLE
  AS $$ SELECT '44444444-4444-4444-4444-444444444444'::uuid $$;
CREATE OR REPLACE FUNCTION pg_temp.clen() RETURNS uuid LANGUAGE sql IMMUTABLE
  AS $$ SELECT '55555555-5555-5555-5555-555555555555'::uuid $$;

CREATE OR REPLACE FUNCTION pg_temp.firma(_nazev text) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.subjects WHERE name = _nazev $$;

CREATE OR REPLACE FUNCTION pg_temp.draha(_poradi int) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.sheets WHERE active ORDER BY name OFFSET (_poradi - 1) LIMIT 1 $$;

-- Kolik firem má akce doopravdy (mělo by být vždycky JEDNA).
CREATE OR REPLACE FUNCTION pg_temp.firem_na_akci(_ev uuid) RETURNS int
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT count(DISTINCT subject_id)::int FROM public.reservations
   WHERE event_id = _ev AND deleted_at IS NULL $$;

CREATE OR REPLACE FUNCTION pg_temp.firma_akce(_ev uuid) RETURNS uuid
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT subject_id FROM public.reservations
   WHERE event_id = _ev AND deleted_at IS NULL ORDER BY id LIMIT 1 $$;

CREATE OR REPLACE FUNCTION pg_temp.celkem(_ev uuid) RETURNS numeric
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0) FROM public.reservations
   WHERE event_id = _ev AND deleted_at IS NULL $$;

-- Otisk peněžních sloupců akce. Porovnává se před a po změně firmy — když se
-- liší, je to přecenění, a to tahle funkce dělat nesmí.
CREATE OR REPLACE FUNCTION pg_temp.penize(_ev uuid) RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT string_agg(
           coalesce(amount::text,'-')||'/'||coalesce(rate_per_hour::text,'-')||'/'||
           coalesce(hours::text,'-')||'/'||coalesce(cena_bez_dph::text,'-')||'/'||
           coalesce(cenove_pasma::text,'-')||'/'||coalesce(corrected_amount::text,'-'),
           '|' ORDER BY id)
    FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL $$;

-- Komerční akce na zadaném počtu drah. Zakládá se přímým zápisem (jako ve
-- `uprava_akce_test.sql`) — testuje se změna firmy, ne zakládání.
CREATE OR REPLACE FUNCTION pg_temp.zaloz_akci(_nazev text, _firma uuid, _od timestamptz, _do timestamptz,
                                              _drah int DEFAULT 1, _typ text DEFAULT 'commercial')
 RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _ev uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES (_nazev, _typ::public.event_type, _od, _do, pg_temp.admin()) RETURNING id INTO _ev;

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  SELECT pg_temp.draha(i), _firma, _ev, _od, _do, now(), pg_temp.admin()
    FROM generate_series(1, _drah) i;
  RETURN _ev;
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 1) ZMĚNA SE PROPÍŠE NA VŠECHNY DRÁHY A ČÁSTKA SE NEHNE
--
-- Jádro celého úkolu. Akce na DVOU drahách: kdyby funkce sáhla jen na jednu
-- rezervaci, měla by akce dva odběratele a rozpadla by se na dva doklady.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _pred text; _celkem_pred numeric; _v jsonb;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma dve drahy', _stara,
           '2027-09-08 16:00+02', '2027-09-08 19:00+02', 2);

  _pred        := pg_temp.penize(_ev);
  _celkem_pred := pg_temp.celkem(_ev);
  PERFORM pg_temp.tvrd(_celkem_pred > 0, 'příprava: akce má nenulovou částku (jinak by test o penězích neměřil nic)');
  PERFORM pg_temp.tvrd(pg_temp.firem_na_akci(_ev) = 1, 'příprava: akce má jednu firmu na obou drahách');

  _v := public.zmen_firmu_akce(_ev, _nova);

  PERFORM pg_temp.tvrd((_v ->> 'zmena') = 'true', 'změna firmy proběhla');
  PERFORM pg_temp.tvrd((_v ->> 'drah')::int = 2, '… a dotkla se OBOU drah (vrátila drah = 2)');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _nova, '… nová firma je na akci');
  PERFORM pg_temp.tvrd(pg_temp.firem_na_akci(_ev) = 1,
    '… a je JEDINÁ — na žádné dráze nezůstala stará (jinak dva doklady na jednu akci)');
  PERFORM pg_temp.tvrd(NOT EXISTS (SELECT 1 FROM public.reservations
                                    WHERE event_id = _ev AND deleted_at IS NULL AND subject_id = _stara),
    '… stará firma na akci nikde nezbyla');

  -- Tohle je to nejdůležitější tvrzení celého souboru.
  PERFORM pg_temp.tvrd(pg_temp.celkem(_ev) = _celkem_pred,
    format('ČÁSTKA SE NEHNULA (%s Kč před i po)', _celkem_pred));
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred,
    '… a nehnula se ANI SAZBA, hodiny, daňový význam nebo rozpis po pásmech');
END $$;

-- -----------------------------------------------------------------------------
-- 1b) ZMĚNA NA FIRMU S VLASTNÍ SAZBOU — částka se NESMÍ přepočítat
--
-- TOHLE JE TA NOHA, KTERÁ DOOPRAVDY HLÍDÁ „NEPŘECEŇUJ". Kapitola 1 běží mezi
-- dvěma firmami bez vlastní sazby, takže by případné přecenění vyšlo na TUTÉŽ
-- částku a nikdo by si ho nevšiml — naměřeno mutací 10. 9. 2026: s úmyslně
-- zapnutým `app.preceneni` zůstala kapitola 1 zelená.
--
-- Tady má nová firma dohodnutou sazbu 800 Kč/h, tedy jinou než ceníkovou. Kdyby
-- funkce přecenila, částka spadne z 15 000 na 2 400 a je to vidět na první pohled.
-- Věcně je to zároveň to, co po systému chceme: dohodnutá cena AKCE se změnou
-- adresáta nemění — sazba nové firmy platí až pro to, co si objedná sama.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _celkem_pred numeric; _pred text;
        _puv_sazba numeric;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  -- Dohodnutá sazba jen pro tenhle test — na konci kapitoly se vrací. Kapitoly stojí za sebou v jedné
  -- transakci, takže co jedna nechá rozházené, zdědí ta příští, aniž by o tom
  -- věděla. (Nález brány code review.)
  SELECT default_rate INTO _puv_sazba FROM public.subjects WHERE id = _nova;
  UPDATE public.subjects SET default_rate = 800 WHERE id = _nova;

  _ev := pg_temp.zaloz_akci('TEST firma s vlastni sazbou', _stara,
           '2027-09-15 16:00+02', '2027-09-15 19:00+02', 1);
  _celkem_pred := pg_temp.celkem(_ev);
  _pred        := pg_temp.penize(_ev);

  -- Bez tohohle by noha mohla být zelená i tehdy, kdyby se sazby náhodou
  -- shodovaly — a pak by o přecenění netvrdila nic.
  PERFORM pg_temp.tvrd(_celkem_pred IS DISTINCT FROM (800 * 3)::numeric,
    format('příprava: ceníková částka (%s Kč) se LIŠÍ od té, která by vyšla ze sazby nové firmy (2 400 Kč)',
           _celkem_pred));

  PERFORM pg_temp.tvrd((public.zmen_firmu_akce(_ev, _nova) ->> 'zmena') = 'true',
    'změna na firmu s vlastní sazbou projde');
  PERFORM pg_temp.tvrd(pg_temp.celkem(_ev) = _celkem_pred,
    format('… a částka ZŮSTALA %s Kč — nepřepočítala se na sazbu nové firmy (má %s)',
           _celkem_pred, pg_temp.celkem(_ev)));
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred,
    '… a nezměnila se ani sazba, hodiny nebo daňový význam');
  UPDATE public.subjects SET default_rate = _puv_sazba WHERE id = _nova;
END $$;

-- -----------------------------------------------------------------------------
-- 1c) AKCE NESMÍ VYPADNOUT Z FAKTURACE — razítko schválení přežije
--
-- NEJDŮLEŽITĚJŠÍ NOHA CELÉHO SOUBORU, a málem tu nebyla. `subject_id` je ve
-- výčtu, na který kouká `zrus_schvaleni_pri_uprave`, takže původní verze
-- funkce razítko shodila na NULL. Částka přitom zůstala na haléř stejná —
-- takže všech 37 tvrzení o penězích bylo zelených, zatímco akce za 10 000 Kč
-- se propadla z „Kdo kolik dluží" na nulu fakturovatelných řádků.
-- Komerční firma nemá v `subject_reps` nikoho, kdo by razítko vrátil, takže by
-- to admin musel ručně přerazit — o čemž by se nikdy nedozvěděl.
-- (Nález bezpečnostní brány, 10. 9. 2026.)
--
-- Měří se `fakturovatelne_rezervace`, tedy to, co doopravdy vstupuje do dokladu,
-- ne jen sloupec `approved_at`.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _v jsonb;
        _schvalenych_pred int; _schvalenych_po int;
        _fakt_pred int; _fakt_po int; _jen_schvalene boolean;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  SELECT invoice_only_approved INTO _jen_schvalene FROM public.billing_settings LIMIT 1;
  PERFORM pg_temp.tvrd(_jen_schvalene,
    'příprava: fakturuje se jen schválené (jinak by tahle kapitola neměřila nic)');

  _ev := pg_temp.zaloz_akci('TEST firma razitko', _stara,
           '2027-09-16 16:00+02', '2027-09-16 18:00+02', 2);

  -- Razítko schválně podepíše NĚKDO JINÝ než admin, který bude firmu měnit.
  -- Bez toho by tvrzení „razítko je podepsané tím, kdo změnu udělal" neměřilo
  -- nic: admin akci zakládá i schvaluje, takže by sedělo i tehdy, kdyby se
  -- razítko nepřerazilo vůbec. (Odhaleno mutací `approved_by = approved_by`.)
  UPDATE public.reservations SET approved_by = pg_temp.zastupce()
   WHERE event_id = _ev AND deleted_at IS NULL;
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(approved_by = pg_temp.zastupce()) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL),
    'příprava: razítko je zatím podepsané NĚKÝM JINÝM než adminem');

  SELECT count(*) FILTER (WHERE approved_at IS NOT NULL) INTO _schvalenych_pred
    FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL;
  SELECT count(*) INTO _fakt_pred
    FROM public.fakturovatelne_rezervace(_stara, '2027-09-01+02', '2027-10-01+02') f
   WHERE f.id IN (SELECT id FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL);

  PERFORM pg_temp.tvrd(_schvalenych_pred = 2, 'příprava: obě dráhy jsou schválené');
  PERFORM pg_temp.tvrd(_fakt_pred = 2,
    format('příprava: obě dráhy jsou fakturovatelné (je jich %s)', _fakt_pred));

  _v := public.zmen_firmu_akce(_ev, _nova);

  SELECT count(*) FILTER (WHERE approved_at IS NOT NULL) INTO _schvalenych_po
    FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL;
  -- POZOR: ptáme se za NOVOU firmu — po změně odběratele akce patří jí.
  SELECT count(*) INTO _fakt_po
    FROM public.fakturovatelne_rezervace(_nova, '2027-09-01+02', '2027-10-01+02') f
   WHERE f.id IN (SELECT id FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL);

  PERFORM pg_temp.tvrd(_schvalenych_po = _schvalenych_pred,
    format('razítko schválení PŘEŽILO změnu odběratele (%s → %s drah)',
           _schvalenych_pred, _schvalenych_po));
  PERFORM pg_temp.tvrd(_fakt_po = _fakt_pred,
    format('AKCE ZŮSTALA FAKTUROVATELNÁ — nevypadla z „Kdo kolik dluží" (%s → %s řádků)',
           _fakt_pred, _fakt_po));
  PERFORM pg_temp.tvrd((_v ->> 'schvaleni_prerazeno') = 'true',
    '… a funkce to volajícímu řekla (schvaleni_prerazeno)');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(approved_by = pg_temp.admin()) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL),
    '… razítko je podepsané adminem, který změnu udělal (auditní stopa sedí)');
END $$;

-- Druhá strana téhož: NESCHVÁLENÉ rezervaci se razítko vyrobit NESMÍ. Jinak by
-- změna odběratele tiše protlačila do fakturace akci, kterou nikdo nepotvrdil —
-- tichý posun opačným směrem.
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _v jsonb;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma bez razitka','commercial','2027-09-17 16:00+02','2027-09-17 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  -- schválně BEZ approved_at
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (pg_temp.draha(1), _stara, _ev, '2027-09-17 16:00+02', '2027-09-17 18:00+02');

  _v := public.zmen_firmu_akce(_ev, _nova);
  PERFORM pg_temp.tvrd((_v ->> 'zmena') = 'true',
    'u NESCHVÁLENÉ akce změna odběratele projde');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(approved_at IS NULL) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL),
    '… ale razítko schválení jí NEVYROBILA (do fakturace se nepropašuje)');
  -- A ani to volajícímu netvrdí. `schvaleni_prerazeno` se propisuje do hlášky
  -- „potvrzení akce je nově podepsané vámi" — u akce, kterou nikdo nepotvrdil,
  -- by to byla nepravda o tom, kdo pod ní ve fakturaci stojí.
  -- (Bez tohohle tvrzení projde mutace `'schvaleni_prerazeno', true`.)
  PERFORM pg_temp.tvrd((_v ->> 'schvaleni_prerazeno') = 'false',
    '… a ani netvrdí volajícímu, že nějaké razítko přerazila');
END $$;

-- -----------------------------------------------------------------------------
-- 1d) STORNOVANÁ DRÁHA SE MĚNÍ TAKY — akce nesmí skončit se dvěma odběrateli
--
-- Vědomé rozhodnutí (viz hlavička migrace), ne náhoda — proto je změřené.
-- Kdyby stornovaná dráha zůstala na staré firmě, měla by akce dva odběratele,
-- což je přesně ten stav, kterému `zmen_firmu_akce` brání. Na peníze to vliv
-- nemá, stornovaná dráha se nefakturuje.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _smazana uuid;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma se stornem','commercial','2027-09-18 16:00+02','2027-09-18 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES (pg_temp.draha(1), _stara, _ev, '2027-09-18 16:00+02','2027-09-18 18:00+02',
          now(), pg_temp.admin());
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   status, cancelled_at, cancelled_by)
  VALUES (pg_temp.draha(2), _stara, _ev, '2027-09-18 16:00+02','2027-09-18 18:00+02',
          'cancelled', now(), pg_temp.admin());
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, deleted_at)
  VALUES (pg_temp.draha(1), _stara, _ev, '2027-09-18 19:00+02','2027-09-18 20:00+02', now())
  RETURNING id INTO _smazana;

  PERFORM public.zmen_firmu_akce(_ev, _nova);

  PERFORM pg_temp.tvrd(pg_temp.firem_na_akci(_ev) = 1,
    'akce se stornovanou dráhou má po změně JEDNU firmu, ne dvě');
  PERFORM pg_temp.tvrd(
    (SELECT subject_id FROM public.reservations
      WHERE event_id = _ev AND status = 'cancelled' AND deleted_at IS NULL) = _nova,
    '… i stornovaná dráha nese nového odběratele');

  -- SOFT-SMAZANÁ dráha je něco JINÉHO než stornovaná a měnit se NESMÍ.
  -- Filtr `deleted_at IS NULL` v UPDATE je nosný právě kvůli obchvatu
  -- popsanému v `docs/TICKET-obchvaty-zamku-fakturace.md`: když admin
  -- vyfakturovanou dráhu soft-smaže, zámek ji přestane vidět a změna projde.
  -- Dnes se tím rozejde „jen" rozvrh s dokladem. Bez toho filtru by se přepsal
  -- i záznam POD vystavenou fakturou a z „rozvrh nesedí s dokladem" by se stalo
  -- „doklad nesedí sám se sebou". (Nález brány code review, třetí kolo.)
  PERFORM pg_temp.tvrd((SELECT subject_id FROM public.reservations WHERE id = _smazana) = _stara,
    '… ale SOFT-SMAZANÁ dráha si nechala starou firmu (nesahá se pod doklad)');
END $$;

-- -----------------------------------------------------------------------------
-- 1e) AKCE S PEVNOU CELKOVOU CENOU — částka musí zůstat i u ní
--
-- `cena_rucni` je vlastní větev `set_reservation_pricing`, která se chová jinak
-- než ceníková cena: drží `amount` a sazbu si z ní dopočítá zpátky. Změna
-- odběratele jí tedy prochází JINOU cestou než všechno ostatní v tomhle
-- souboru, a bez téhle nohy by ji příští zásah do triggeru rozbil mlčky.
-- (Nález brány code review, 10. 9. 2026.)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _pred text; _celkem numeric;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma pevna cena','commercial','2027-09-20 16:00+02','2027-09-20 19:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;

  -- Pevnou cenu zapíná marker, ke kterému se z API nedá dostat — v testu je to
  -- příprava stavu, ne to, co se měří (viz pravidlo 8 v CLAUDE.md).
  PERFORM set_config('app.rucni_cena', 'on', true);
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   amount, approved_at, approved_by)
  VALUES (pg_temp.draha(1), _stara, _ev, '2027-09-20 16:00+02','2027-09-20 19:00+02',
          9999, now(), pg_temp.admin());
  PERFORM set_config('app.rucni_cena', 'off', true);

  _celkem := pg_temp.celkem(_ev);
  _pred   := pg_temp.penize(_ev);
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(cena_rucni) FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL),
    'příprava: akce má opravdu pevnou celkovou cenu (cena_rucni)');
  PERFORM pg_temp.tvrd(_celkem = 9999, format('příprava: stojí 9 999 Kč (má %s)', _celkem));

  PERFORM pg_temp.tvrd((public.zmen_firmu_akce(_ev, _nova) ->> 'zmena') = 'true',
    'u akce s pevnou cenou změna odběratele projde');
  PERFORM pg_temp.tvrd(pg_temp.celkem(_ev) = 9999,
    format('… a pevná částka zůstala 9 999 Kč (má %s)', pg_temp.celkem(_ev)));
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred,
    '… i s dopočítanou sazbou a daňovým významem, beze změny');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(approved_at IS NOT NULL) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL),
    '… a razítko schválení přežilo i u ní');
END $$;

-- -----------------------------------------------------------------------------
-- 2) NEADMIN NESMÍ — ani zástupce klubu, ani člen, ani přímým zápisem
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid;
BEGIN
  RESET ROLE;
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');
  PERFORM pg_temp.prihlas(pg_temp.admin());
  _ev := pg_temp.zaloz_akci('TEST firma prava', _stara,
           '2027-09-09 16:00+02', '2027-09-09 18:00+02', 1);
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.prihlas(pg_temp.zastupce());
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'jen správce haly', 'zástupce klubu NEZMĚNÍ odběratele akce');

  PERFORM pg_temp.prihlas(pg_temp.clen());
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'jen správce haly', 'člen klubu NEZMĚNÍ odběratele akce');

  -- DRUHÉ DVEŘE: `reservations` má pro `authenticated` tabulkové UPDATE granty,
  -- takže by se dal odběratel přepsat úplně mimo RPC.
  --
  -- POZOR NA TO, CO SE TU DOOPRAVDY MĚŘÍ. Na CIZÍ (komerční) akci ten UPDATE
  -- neskončí chybou — RLS zástupce k řádku vůbec nepustí, takže zasáhne NULA
  -- řádků a `UPDATE` nula řádků je úspěch. Naměřeno 10. 9. 2026: test, který tu
  -- čekal chybu, selhal, přestože dveře zavřené JSOU. Tvrdí se proto výsledek
  -- (odběratel se nezměnil), ne způsob, jakým se to nepovedlo.
  PERFORM pg_temp.prihlas(pg_temp.zastupce());
  EXECUTE format('UPDATE public.reservations SET subject_id = %L WHERE event_id = %L', _nova, _ev);
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _stara,
    'přímý zápis zástupce klubu na CIZÍ akci odběratele nezměnil (RLS ho k řádku nepustí)');
  PERFORM pg_temp.tvrd(pg_temp.firem_na_akci(_ev) = 1, '… a akce má pořád jednu firmu');
END $$;
RESET ROLE;

-- Druhá půlka téhož rohu: na VLASTNÍ akci klubu RLS zástupce k řádku PUSTÍ,
-- takže tady se měří guard `guard_reservation_rep_changes` a ten musí spadnout
-- hlasitě. Bez téhle nohy by kapitola výš prošla i tehdy, kdyby guard sloupec
-- `subject_id` vůbec nehlídal.
DO $$
DECLARE _ev uuid; _klub uuid; _firma uuid;
BEGIN
  PERFORM pg_temp.prihlas(pg_temp.admin());
  _klub  := pg_temp.firma('CK Ostravské kameny');
  _firma := pg_temp.firma('Demo Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma vlastni klub', _klub,
           '2027-09-09 19:00+02', '2027-09-09 21:00+02', 1, 'training');

  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.prihlas(pg_temp.zastupce());
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET subject_id = %L WHERE event_id = %L', _firma, _ev),
    'smí měnit jen správce',
    'zástupce klubu NEPŘEPÍŠE odběratele ani na VLASTNÍ akci, kam RLS pouští');
  RESET ROLE;
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _klub, '… a klub na akci zůstal');
END $$;

-- -----------------------------------------------------------------------------
-- 3) FAIL-CLOSED NAD VYSTAVENÝM DOKLADEM
--
-- Tohle je ta ochrana „Kdo kolik dluží", která selhat nesmí. Kdyby změna
-- prošla, faktura by zněla na jednu firmu a dluh by se evidoval druhé.
-- Testuje se OBOJÍ cesta dokladu zvlášť — interní i z Fakturoidu.
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _ev uuid; _rez uuid; _stara uuid; _nova uuid; _dok uuid; _celkem numeric;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma fakturoid', _stara,
           '2027-09-10 16:00+02', '2027-09-10 18:00+02', 1);
  SELECT id INTO _rez FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL LIMIT 1;
  _celkem := pg_temp.celkem(_ev);

  -- Doklad z Fakturoidu, jak ho zakládá `zapisDoklad` — pro test stačí vazba.
  INSERT INTO public.fakturoid_invoices
    (idempotency_key, druh, subject_id, event_id, nas_soucet, radku, rezervace, cislo)
  VALUES ('firma-test-'||_ev::text, 'commercial_event', _stara, _ev, _celkem, 1, ARRAY[_rez], '2027-0009')
  RETURNING id INTO _dok;
  INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
  VALUES (_dok, _rez);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'na vystaveném dokladu', 'akci s dokladem z FAKTUROIDU nejde přepsat odběratele');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _stara,
    '… a na akci zůstala firma, na kterou doklad zní');
  PERFORM pg_temp.tvrd(pg_temp.celkem(_ev) = _celkem,
    '… a částka se nehnula (doklad na ni pořád sedí)');
END $$;

DO $$
DECLARE _ev uuid; _rez uuid; _stara uuid; _nova uuid; _fak uuid;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma interni doklad', _stara,
           '2027-09-11 16:00+02', '2027-09-11 18:00+02', 1);
  SELECT id INTO _rez FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL LIMIT 1;

  -- Interní doklad (Etapa 2). Vazba je přes `reservations.invoice_id`.
  -- Vystavený doklad musí mít číslo (CHECK `invoices_cislo_dle_stavu`) — a je
  -- to tak správně: o vystaveném dokladu bez čísla by tenhle test nic netvrdil.
  INSERT INTO public.invoices
    (kind, status, cislo, variabilni_symbol, datum_vystaveni, datum_splatnosti,
     dodavatel_nazev, odberatel_nazev, pdf_status, subject_id, event_id, obdobi_od, obdobi_do,
     subtotal, total, total_rounded, rounding_amount, vat_mode, created_by, issued_at, issued_by)
  VALUES ('komercni', 'vystaveno', '2027-9911', '20279911', '2027-09-11', '2027-09-25',
          'Curling Promo Ostrava', 'Testovací Firma s.r.o.', 'pending', _stara, _ev,
          '2027-09-11', '2027-09-11',
          pg_temp.celkem(_ev), pg_temp.celkem(_ev), pg_temp.celkem(_ev), 0, 'neplatce', pg_temp.admin(),
          now(), pg_temp.admin())
  RETURNING id INTO _fak;
  -- Vazbu na fakturu hlídá `guard_reservation_rep_changes` („mění jen fakturační
  -- funkce, ne přímý zápis") — a hlídá ji i tady, protože `auth.uid()` je
  -- nastavené. Příprava testu proto sáhne po témž markeru, jaký používají
  -- fakturační RPC. Je to jen PŘÍPRAVA stavu, ne to, co se měří.
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations SET invoice_id = _fak, invoiced_at = now() WHERE id = _rez;
  PERFORM set_config('app.trusted_booking', 'off', true);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'na vystaveném dokladu', 'akci s INTERNÍM dokladem nejde přepsat odběratele');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _stara,
    '… a na akci zůstala firma, na kterou doklad zní');
END $$;

-- -----------------------------------------------------------------------------
-- 3b) DOKLAD NA *STORNOVANÉ* DRÁZE BLOKUJE TAKY
--
-- Přímý důsledek rozhodnutí, že se odběratel přepisuje i u stornovaných drah
-- (kapitola 1d): když se stornovaná dráha přepisuje, musí ji stejně tak
-- pokrývat i zámek fakturace. Jinak by šlo přepsat odběratele na dráze, na
-- kterou už zní vystavený doklad — a faktura by mířila na jinou firmu než
-- záznam pod ní.
--
-- Rozhodnutí zákazníka, 10. 9. 2026: JAKÁKOLI dráha akce na dokladu → změna
-- se zablokuje. Ne „jen ta živá".
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _ziva uuid; _storno uuid; _stara uuid; _nova uuid; _dok uuid;
        _penize_pred text;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma storno na dokladu','commercial','2027-09-21 16:00+02','2027-09-21 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  -- živá dráha BEZ dokladu…
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES (pg_temp.draha(1), _stara, _ev, '2027-09-21 16:00+02','2027-09-21 18:00+02',
          now(), pg_temp.admin())
  RETURNING id INTO _ziva;
  -- …a stornovaná dráha, která JE na dokladu
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   status, cancelled_at, cancelled_by)
  VALUES (pg_temp.draha(2), _stara, _ev, '2027-09-21 16:00+02','2027-09-21 18:00+02',
          'cancelled', now(), pg_temp.admin())
  RETURNING id INTO _storno;

  -- Součet z dokladu se bere z rezervací, ne od oka — kdyby se pak částka akce
  -- hnula, byl by to rozdíl PROTI DOKLADU, a ten se má poznat.
  _penize_pred := pg_temp.penize(_ev);
  INSERT INTO public.fakturoid_invoices
    (idempotency_key, druh, subject_id, event_id, nas_soucet, radku, rezervace, cislo)
  VALUES ('firma-storno-'||_ev::text, 'commercial_event', _stara, _ev,
          pg_temp.celkem(_ev), 1, ARRAY[_storno], '2027-0021')
  RETURNING id INTO _dok;
  INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
  VALUES (_dok, _storno);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'na vystaveném dokladu',
    'doklad na STORNOVANÉ dráze zablokuje změnu odběratele celé akce');
  -- Pozor, čím tyhle dvě tvrzení JSOU a čím NEJSOU: samotné zablokování měří
  -- `ocekavej_chybu` výš — výjimka shodí podtransakci, takže se sem stejně nic
  -- zapsat nemůže. Tohle je levná pojistka na budoucí refaktor, který by bránu
  -- schoval do vlastního EXCEPTION bloku a výjimku spolkl. Kdyby někdy zbyla
  -- v souboru jako jediná obrana proti zápisu, je to málo.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL AND subject_id = _stara) = 2,
    '… obě dráhy akce (živá i stornovaná) zůstaly na firmě, na kterou doklad zní');
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _penize_pred,
    '… a nehnula se ani částka, ani razítko schválení (brána padla PŘED zápisem)');
END $$;

-- Totéž druhou cestou dokladu: interní `invoice_id` na stornované dráze.
DO $$
DECLARE _ev uuid; _storno uuid; _stara uuid; _nova uuid; _fak uuid; _castka numeric;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma storno interni doklad','commercial','2027-09-22 16:00+02','2027-09-22 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   status, cancelled_at, cancelled_by)
  VALUES (pg_temp.draha(1), _stara, _ev, '2027-09-22 16:00+02','2027-09-22 18:00+02',
          'cancelled', now(), pg_temp.admin())
  RETURNING id INTO _storno;

  _castka := pg_temp.celkem(_ev);
  INSERT INTO public.invoices
    (kind, status, cislo, variabilni_symbol, datum_vystaveni, datum_splatnosti,
     dodavatel_nazev, odberatel_nazev, pdf_status, subject_id, event_id, obdobi_od, obdobi_do,
     subtotal, total, total_rounded, rounding_amount, vat_mode, created_by, issued_at, issued_by)
  VALUES ('komercni', 'vystaveno', '2027-9922', '20279922', '2027-09-22', '2027-10-06',
          'Curling Promo Ostrava', 'Testovací Firma s.r.o.', 'pending', _stara, _ev,
          '2027-09-22', '2027-09-22', _castka, _castka, _castka, 0, 'neplatce', pg_temp.admin(),
          now(), pg_temp.admin())
  RETURNING id INTO _fak;

  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations SET invoice_id = _fak, invoiced_at = now() WHERE id = _storno;
  PERFORM set_config('app.trusted_booking', 'off', true);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'na vystaveném dokladu',
    'interní doklad na STORNOVANÉ dráze zablokuje změnu taky');
  PERFORM pg_temp.tvrd(
    (SELECT subject_id FROM public.reservations WHERE id = _storno) = _stara,
    '… a odběratel se nezměnil');
END $$;

-- -----------------------------------------------------------------------------
-- 4) NOVÝ SUBJEKT MUSÍ BÝT KOMERČNÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _klub uuid; _smazana uuid;
BEGIN
  _stara   := pg_temp.firma('Testovací Firma s.r.o.');
  _klub    := pg_temp.firma('CK Ostravské kameny');
  _smazana := pg_temp.firma('Demo Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma jen komercni subjekt', _stara,
           '2027-09-12 16:00+02', '2027-09-12 18:00+02', 1);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _klub),
    'jen firma, ne klub', 'odběratelem komerční akce nejde nastavit KLUB');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, gen_random_uuid()),
    'Firma nenalezena', 'neexistující firma skončí srozumitelnou hláškou');

  -- SMAZANÁ firma je pro `subjects` pořád řádek — jen s `deleted_at`. Kdyby
  -- funkce filtr vynechala, dala by se akce přepsat na odběratele, který
  -- v systému oficiálně není, a doklad by pak zněl na někoho vyřazeného.
  UPDATE public.subjects SET deleted_at = now() WHERE id = _smazana;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _smazana),
    'Firma nenalezena', 'SMAZANÁ firma se odběratelem stát nemůže');
  UPDATE public.subjects SET deleted_at = NULL WHERE id = _smazana;

  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _stara, '… a odběratel se nezměnil');
END $$;

-- -----------------------------------------------------------------------------
-- 4b) AKCE SE SMÍŠENÝMI ODBĚRATELI SE ODMÍTNE
--
-- Existovat nemá, ale `create_invoice_draft_commercial` na ni umí narazit. Vzít z ní „toho
-- prvního podle id" by znamenalo udělat daňovou kontrolu proti jednomu
-- odběrateli a druhého tiše přepsat — u akce, která je rozbitá už teď.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _f1 uuid; _f2 uuid;
BEGIN
  _f1 := pg_temp.firma('Testovací Firma s.r.o.');
  _f2 := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma smisena akce','commercial','2027-09-19 16:00+02','2027-09-19 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  -- dvě dráhy, každá jiná firma
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (pg_temp.draha(1), _f1, _ev, '2027-09-19 16:00+02','2027-09-19 18:00+02'),
         (pg_temp.draha(2), _f2, _ev, '2027-09-19 16:00+02','2027-09-19 18:00+02');

  PERFORM pg_temp.tvrd(pg_temp.firem_na_akci(_ev) = 2, 'příprava: akce má vážně dva odběratele');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _f2),
    'každá jiného odběratele', 'akci se smíšenými odběrateli funkce ODMÍTNE');
  PERFORM pg_temp.tvrd(pg_temp.firem_na_akci(_ev) = 2,
    '… a nic na ní nepřepsala (nechala rozbitý stav tak, jak byl)');
END $$;

-- -----------------------------------------------------------------------------
-- 1f) PENĚŽNÍ SÍŤ FUNKCE OPRAVDU CHYTÁ
--
-- `zmen_firmu_akce` si po vlastním UPDATE přeměří součet částek a počet
-- schválených drah a při rozdílu se shodí. Ty dvě kontroly jsou zálohou pro
-- případ, že se pod funkci připlete cizí trigger — přesně tak vznikl blokér,
-- kvůli kterému tenhle soubor má kapitolu 1c: `zrus_schvaleni_pri_uprave`
-- shodil razítko a částka přitom seděla na haléř.
--
-- Bez téhle kapitoly ty dvě kontroly nehlídaly nic měřitelného: mutace
-- `IF _celkem_po IS DISTINCT FROM _celkem_pred THEN` → `IF false THEN` prošla
-- celým souborem zeleně, protože ostatní kapitoly měří VÝSLEDEK, ne síť pod ním.
-- (Nález brány code review, druhé kolo.) Cizí trigger se tu proto nasimuluje.
--
-- DŮVOD NAVÍC NEPOUŠTĚT TENHLE SOUBOR PROTI NIČEMU SDÍLENÉMU: `CREATE TRIGGER`
-- si na `public.reservations` bere `ShareRowExclusiveLock` a `DROP TRIGGER`
-- dokonce `AccessExclusiveLock`, obojí drží do konce transakce. Nad seedovanou
-- lokální databází je to jedno, nad čímkoli, co používá ještě někdo jiný, ne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.cizi_trigger_penize() RETURNS trigger
 LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.subject_id IS DISTINCT FROM OLD.subject_id THEN
    NEW.amount := NEW.amount + 1;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cizi_trigger_razitko() RETURNS trigger
 LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.subject_id IS DISTINCT FROM OLD.subject_id THEN
    NEW.approved_at := NULL;
  END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _pred text;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');

  -- Jméno `trg_zzz_…` schválně: triggery se pouští podle abecedy, takže tenhle
  -- se dostane ke slovu AŽ po všech ostrých, včetně `check_reservation_money`.
  -- Simuluje se tím trigger, který si částku posune až úplně na konci.
  _ev := pg_temp.zaloz_akci('TEST firma sit penize', _stara,
           '2027-11-06 16:00+02', '2027-11-06 18:00+02', 1);
  _pred := pg_temp.penize(_ev);
  CREATE TRIGGER trg_zzz_test_penize BEFORE UPDATE ON public.reservations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.cizi_trigger_penize();
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'posunula částka akce',
    'kdyby se pod funkcí hnula ČÁSTKA, funkce se shodí a nic nezapíše');
  DROP TRIGGER trg_zzz_test_penize ON public.reservations;
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred, '… a peníze zůstaly nedotčené');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _stara, '… a odběratel taky');

  _ev := pg_temp.zaloz_akci('TEST firma sit razitko', _stara,
           '2027-11-07 16:00+02', '2027-11-07 18:00+02', 1);
  CREATE TRIGGER trg_zzz_test_razitko BEFORE UPDATE ON public.reservations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.cizi_trigger_razitko();
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'vypadla z fakturace',
    'a kdyby se pod ní shodilo RAZÍTKO, shodí se taky (to je ten blokér z 1c)');
  DROP TRIGGER trg_zzz_test_razitko ON public.reservations;
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(approved_at IS NOT NULL) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL),
    '… a razítko na akci zůstalo');
END $$;

-- -----------------------------------------------------------------------------
-- 4c) DAŇOVÝ VÝZNAM ZAPSANÉ ČÁSTKY SE NESMÍ POSUNOUT
--
-- Brána, kterou postavily předchozí revizní brány a která do 10. 9. 2026 neměla
-- ANI JEDNO tvrzení: mutace `IF false THEN` na `cena_je_bez_dph` prošla celým
-- souborem zeleně. (Nález brány code review, druhé kolo.)
--
-- Roh je dosažitelný: klub s dohodnutou sazbou na KOMERČNÍ akci má
-- `cena_je_bez_dph('club','commercial',900) = false`, tedy „v částce už daň je".
-- Nový odběratel je vždycky firma a pro tu vychází `true` bez ohledu na sazbu.
-- Bez brány by se částka nehnula ani o haléř, jen by od té chvíle znamenala něco
-- jiného — daň odvedená z jiného základu. Přesně ten vadný stav popisuje migrace
-- `20260902264000_dph_i_pri_rucni_sazbe.sql`.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _firma uuid; _pred text; _puv_sazba numeric;
BEGIN
  _klub  := pg_temp.firma('CK Ostravské kameny');
  _firma := pg_temp.firma('Demo Firma s.r.o.');

  SELECT default_rate INTO _puv_sazba FROM public.subjects WHERE id = _klub;
  UPDATE public.subjects SET default_rate = 900 WHERE id = _klub;
  _ev := pg_temp.zaloz_akci('TEST firma dph roh', _klub,
           '2027-10-05 16:00+02', '2027-10-05 18:00+02', 1);

  PERFORM pg_temp.tvrd(
    (SELECT bool_and(NOT cena_bez_dph) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL),
    'příprava: částka je vedená S daní — jinak by tahle kapitola neměřila nic');

  _pred := pg_temp.penize(_ev);
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _firma),
    'nesedí daňový význam',
    'změna na firmu, u které by částka znamenala něco jiného, se ODMÍTNE');
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred,
    '… a na penězích se nezměnilo nic (ani na haléř, ani na příznaku DPH)');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _klub,
    '… a odběratel zůstal ten původní');
  UPDATE public.subjects SET default_rate = _puv_sazba WHERE id = _klub;
END $$;

-- -----------------------------------------------------------------------------
-- 4d) DRÁHY S RŮZNÝM DAŇOVÝM VÝZNAMEM SE ODMÍTNOU TAKY
--
-- POZOR, ČÍM TAHLE KAPITOLA JE A ČÍM NENÍ. `_ruznych_dph > 1` NEDRŽÍ DVEŘE —
-- změna neprojde ani bez ní, chytne ji následující daňová kontrola. Není to
-- náhoda dat: `min(cena_bez_dph::int)::boolean` je u smíšené sady vždycky
-- `false` a `cena_je_bez_dph` pro komerční subjekt vrací `true` bezpodmínečně
-- (obě větve končí na `_subject_type = 'commercial'`). Ta brána drží PŘESNOST
-- DIAGNÓZY: bez ní admin dostane hlášku „nesedí daňový význam částky
-- s odběratelem X", vypraví se spravovat vztah k odběrateli — a přitom je
-- rozbitá akce, každá dráha jinak. Špatná hláška ho pošle opravovat něco
-- jiného, než co je vadné, a to je pořád co měřit.
-- (Rozdíl doměřila brána code review; původní znění téhle hlavičky tvrdilo, že
-- bez brány by změna prošla. Netvrdilo pravdu.)
--
-- Existovat takový stav nemá, ale `create_invoice_draft_commercial` na něj umí
-- narazit — a vzít z něj „ten první snímek podle id" by znamenalo udělat
-- daňovou kontrolu proti jedné dráze a druhou tiše přepsat.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _nova uuid; _pred text; _puv_sazba numeric;
BEGIN
  _klub := pg_temp.firma('CK Ostravské kameny');
  _nova := pg_temp.firma('Demo Firma s.r.o.');

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma smiseny dph','commercial','2027-10-06 16:00+02','2027-10-06 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;

  -- Rozporný stav se NEDÁ vyrobit přímým zápisem — `set_reservation_pricing`
  -- `cena_bez_dph` u UPDATE přepíše zpátky ze staré hodnoty, je to odvozený
  -- sloupec, ne vstup. Vyrobí se tak, jak by vznikl doopravdy: klub bez
  -- dohodnuté sazby má na komerční akci `cena_bez_dph = true`, klub se sazbou
  -- `false` (individuální sazba přebíjí typ akce) — a mezi založením první
  -- a druhé dráhy někdo klubu sazbu doplní.
  SELECT default_rate INTO _puv_sazba FROM public.subjects WHERE id = _klub;
  UPDATE public.subjects SET default_rate = NULL WHERE id = _klub;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   approved_at, approved_by)
  VALUES (pg_temp.draha(1), _klub, _ev, '2027-10-06 16:00+02','2027-10-06 18:00+02',
          now(), pg_temp.admin());
  UPDATE public.subjects SET default_rate = 900 WHERE id = _klub;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   approved_at, approved_by)
  VALUES (pg_temp.draha(2), _klub, _ev, '2027-10-06 16:00+02','2027-10-06 18:00+02',
          now(), pg_temp.admin());

  PERFORM pg_temp.tvrd(
    (SELECT count(DISTINCT cena_bez_dph) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL) = 2,
    'příprava: dráhy akce mají vážně různý daňový význam částky');

  _pred := pg_temp.penize(_ev);
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _nova),
    'různý daňový význam',
    'akci s rozporným daňovým významem drah funkce ODMÍTNE');
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred,
    '… a nic na ní nepřepsala (nechala rozbitý stav tak, jak byl)');
  UPDATE public.subjects SET default_rate = _puv_sazba WHERE id = _klub;
END $$;

-- -----------------------------------------------------------------------------
-- 4e) AKCE BEZ ODBĚRATELE — DVA RŮZNÉ DŮVODY, DVĚ RŮZNÉ HLÁŠKY
--
-- Funkce rozlišuje „akce nemá žádnou živou rezervaci" od „rezervace má, ale
-- není na nich plátce". Je to oprava, kterou si vyžádala migrační brána, a do
-- 10. 9. 2026 neměla ani jedno tvrzení: mutace, která vnitřní `IF EXISTS` i
-- s jeho `RAISE` smaže a nechá jen jednu hlášku, prošla celým souborem zeleně.
-- (Nález brány code review, třetí kolo.)
--
-- Peníze ani dveře se tím nehnou — obě větve akci odmítnou. Měří se PŘESNOST
-- HLÁŠKY: bez rozlišení systém adminovi řekne „nemáš živou rezervaci" u akce,
-- která rezervace má, jen na nich není plátce, a admin je jde hledat jinam.
--
-- Roh je dosažitelný: `reservations_subject_or_event` je
-- `CHECK (subject_id IS NOT NULL OR event_id IS NOT NULL)`, takže rezervace
-- s `event_id` a bez odběratele legálně existuje (`set_reservation_pricing` jí
-- nechá `amount` NULL). Doplnit jí plátce tímhle způsobem funkce ZÁMĚRNĚ neumí
-- — bez odběratele není co přepsat, bylo by to ocenění, ne oprava adresáta.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _firma uuid; _rez uuid;
BEGIN
  _firma := pg_temp.firma('Demo Firma s.r.o.');

  -- (a) rezervace JE, odběratel na ní není
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma bez platce','commercial','2027-10-07 16:00+02','2027-10-07 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, event_id, start_at, end_at)
  VALUES (pg_temp.draha(1), _ev, '2027-10-07 16:00+02','2027-10-07 18:00+02');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL) = 1,
    'příprava: akce MÁ živou rezervaci, jen na ní není plátce');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _firma),
    'nemá žádného odběratele',
    'akce s rezervací BEZ plátce dostane hlášku o chybějícím odběrateli');

  -- (b) rezervace byla, ale je soft-smazaná → jiný důvod, jiná hláška
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma bez zive rezervace','commercial','2027-10-08 16:00+02','2027-10-08 18:00+02',
          pg_temp.admin()) RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, deleted_at)
  VALUES (pg_temp.draha(1), pg_temp.firma('Testovací Firma s.r.o.'), _ev,
          '2027-10-08 16:00+02','2027-10-08 18:00+02', now())
  RETURNING id INTO _rez;

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL) = 0,
    'příprava: tahle akce žádnou živou rezervaci nemá');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _firma),
    'žádnou živou rezervaci',
    '… kdežto akce bez živé rezervace dostane hlášku JINOU');
  -- Pojistka, ne důkaz: `ocekavej_chybu` výš shodí podtransakci, takže se sem
  -- zapsat stejně nic nemůže. Platí totéž, co je napsané u kapitoly 3b.
  PERFORM pg_temp.tvrd(
    (SELECT subject_id FROM public.reservations WHERE id = _rez) <> _firma,
    '… a ani na smazané dráze se nic nepřepsalo');
END $$;

-- -----------------------------------------------------------------------------
-- 5) JEN U KOMERČNÍ AKCE
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _firma uuid;
BEGIN
  _klub  := pg_temp.firma('CK Ostravské kameny');
  _firma := pg_temp.firma('Demo Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma trenink', _klub,
           '2027-09-13 16:00+02', '2027-09-13 18:00+02', 1, 'training');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', _ev, _firma),
    'jen u komerční akce', 'u TRÉNINKU odběratele měnit nejde');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _klub, '… a klub na tréninku zůstal');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_firmu_akce(%L, %L)', gen_random_uuid(), _firma),
    'Akce nenalezena', 'neexistující akce skončí srozumitelnou hláškou');
END $$;

-- -----------------------------------------------------------------------------
-- 6) MINULÉ AKCE JDOU TAKY — právě kvůli nim to vzniklo
--
-- Opravuje se adresát faktury, která se teprve vystaví. Kdyby to šlo jen
-- dopředu, nedala by se opravit akce, která už proběhla a čeká na fakturaci.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _nova uuid; _celkem numeric;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _nova  := pg_temp.firma('Demo Firma s.r.o.');
  -- loni, tedy hluboko v minulosti
  _ev := pg_temp.zaloz_akci('TEST firma minula akce', _stara,
           '2025-11-04 16:00+02', '2025-11-04 18:00+02', 1);
  _celkem := pg_temp.celkem(_ev);

  PERFORM pg_temp.tvrd((public.zmen_firmu_akce(_ev, _nova) ->> 'zmena') = 'true',
    'u MINULÉ akce změna odběratele projde');
  PERFORM pg_temp.tvrd(pg_temp.firma_akce(_ev) = _nova, '… a nová firma na ní opravdu je');
  PERFORM pg_temp.tvrd(pg_temp.celkem(_ev) = _celkem, '… a částka se nehnula ani u ní');
END $$;

-- -----------------------------------------------------------------------------
-- 7) TÁŽ FIRMA = NIC SE NEDĚJE (a nehlásí se to jako změna)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _stara uuid; _v jsonb; _pred text;
BEGIN
  _stara := pg_temp.firma('Testovací Firma s.r.o.');
  _ev := pg_temp.zaloz_akci('TEST firma beze zmeny', _stara,
           '2027-09-14 16:00+02', '2027-09-14 18:00+02', 1);
  _pred := pg_temp.penize(_ev);

  _v := public.zmen_firmu_akce(_ev, _stara);
  PERFORM pg_temp.tvrd((_v ->> 'zmena') = 'false', 'nastavení TÉŽE firmy se hlásí jako „beze změny"');
  PERFORM pg_temp.tvrd(pg_temp.penize(_ev) = _pred, '… a na penězích se nezměnilo nic');
END $$;

-- -----------------------------------------------------------------------------
-- 8) PRÁVA NA FUNKCI — `anon` se k ní nedostane
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.zmen_firmu_akce(uuid, uuid)', 'EXECUTE'),
    'anon NEMÁ EXECUTE na zmen_firmu_akce');
  PERFORM pg_temp.tvrd(
    has_function_privilege('authenticated', 'public.zmen_firmu_akce(uuid, uuid)', 'EXECUTE'),
    'authenticated EXECUTE má (roli si funkce ověří sama)');
END $$;

\echo ''
\echo '======================================================'
\echo ' VŠECHNY TESTY PROŠLY'
\echo '======================================================'
ROLLBACK;
