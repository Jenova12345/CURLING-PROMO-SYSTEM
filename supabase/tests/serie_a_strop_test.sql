-- =============================================================================
-- TESTY: série jako jedna zpráva + strop odchozí pošty
-- Migrace 20260912160000_serie_jednou_a_strop.sql
-- =============================================================================
-- OBOJE JE PODMÍNKA PRO ZAPNUTÍ `email_notifications_enabled`.
--
-- CO SE ZMĚŘILO PŘED OPRAVOU (12. 9. 2026, ne odhad):
--   série 8 tréninků, založení → 2 e-maily  ✔
--   série 8 tréninků, zrušení  → 8 e-mailů JEDNOMU člověku  ✘
-- Série smí mít až 200 termínů.
--
-- MUTAČNÍ ZKOUŠKA (všechny ověřeny, každá tenhle soubor zčervená):
--   * `COALESCE(event_id, series_id, id)` zpět (pořadí)  → scénář 1
--   * typ se nepřepne na `reservation_series_cancelled`  → scénář 2
--   * z klíče značky zmizí `created_by`                  → scénář 8
--   * strop odstraněn z `email_outbox_prevzit`           → scénář 4
--   * strop čte natvrdo místo `settings`                 → scénář 5
--   * ze stropu vypadne vazba na `user_id`               → scénář 4b
--   * ze stropu vypadne okno jedné hodiny                → scénář 4c
--   * přes strop se řádek zahodí místo odložení          → scénář 4d
--   * vrácená mez na stáří řádku (ničí poštu při výpadku)  → scénář 4e
--   * strop přes `CROSS JOIN` (prázdná `settings` zastaví vše) → scénář 4f
--   * výběr zpět na prosté FIFO (zahlcená oběť nedostane nic) → scénář 4g
--   * řádky bez `user_id` obcházejí strop                    → scénář 4h
--   * `count(*)` místo `count(DISTINCT event_id)`        → scénář 7
--
-- ⚠️ CO TU DŘÍV STÁLO A BYLA TO NEPRAVDA: seznam sliboval, že zčervená i mutace
-- „`_pocet` se počítá až ZA značkou". Brána code review ji 12. 9. 2026 provedla
-- a celý soubor prošel. Na pořadí opravdu nezáleží (proč, viz migrace
-- 20260912160000, oddíl u značky) — řádek byl planý slib, ne měření.
--
-- POZOR NA PAST: dedup je transakčně lokální a tenhle soubor je JEDNA
-- transakce. Každý scénář proto potřebuje VLASTNÍ sérii, jinak ho umlčí
-- značka z předchozího scénáře a test bude falešně zelený.
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

-- Založí sérii tréninků od daného dne a vrátí series_id.
CREATE OR REPLACE FUNCTION pg_temp.serie(_od date, _do date, _drah int DEFAULT 1) RETURNS uuid
 LANGUAGE plpgsql AS $$
DECLARE _r jsonb;
BEGIN
  _r := public.create_booking_series(
    (SELECT array_agg(id) FROM (SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT _drah) q),
    'training', 'TEST serie ' || _od,
    (_od + time '17:00') AT TIME ZONE 'Europe/Prague',
    (_od + time '19:00') AT TIME ZONE 'Europe/Prague',
    ARRAY[extract(isodow FROM _od)::int], _do,
    (SELECT id FROM public.subjects WHERE name = 'CK Ostravské kameny'));
  RETURN (_r->>'series_id')::uuid;
END $$;

UPDATE public.settings SET email_notifications_enabled = true;
CREATE TEMP TABLE _s (klic text PRIMARY KEY, sid uuid);

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: zrušení série = JEDNA zpráva, ne jedna na termín
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$ BEGIN INSERT INTO _s VALUES ('zrus', pg_temp.serie(DATE '2029-09-03', DATE '2029-10-22')); END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _terminu int;
        _mailu   int;
BEGIN
  SELECT count(*) INTO _terminu FROM public.reservations r
    JOIN _s s ON r.series_id = s.sid AND s.klic = 'zrus' WHERE r.status = 'confirmed';
  PERFORM pg_temp.tvrd(_terminu >= 5,
    'příprava: série má aspoň 5 termínů (jinak by test neměl co měřit), má ' || _terminu);

  DELETE FROM public.email_outbox;
  PERFORM public.cancel_booking(
    (SELECT r.id FROM public.reservations r JOIN _s s ON r.series_id = s.sid AND s.klic='zrus'
      WHERE r.status='confirmed' ORDER BY r.start_at LIMIT 1),
    'series', 'Porucha chlazení');

  SELECT count(*) INTO _mailu FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_mailu = 1,
    'JÁDRO: zrušení série ' || _terminu || ' termínů poslalo 1 e-mail, ne ' || _mailu);
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: ta zpráva mluví o SÉRII, ne o jednom termínu
-- -----------------------------------------------------------------------------
DO $$
DECLARE _predmet text; _telo text; _typ text;
BEGIN
  SELECT o.subject, o.body, n.type INTO _predmet, _telo, _typ
    FROM public.email_outbox o JOIN public.notifications n ON n.id = o.notification_id;

  PERFORM pg_temp.tvrd(_typ = 'reservation_series_cancelled',
    'zrušená série má vlastní typ upozornění');
  -- Bez vlastního typu měl e-mail v těle sérii, ale v předmětu jednu rezervaci.
  PERFORM pg_temp.tvrd(_predmet = 'Série rezervací byla zrušena',
    'JÁDRO: PŘEDMĚT e-mailu mluví o sérii');
  PERFORM pg_temp.tvrd(_telo LIKE '%Zrušeno termínů: %',
    'JÁDRO: tělo uvádí POČET zrušených termínů');
  PERFORM pg_temp.tvrd(_telo LIKE '%od 03.09.2029 do %',
    'tělo uvádí rozsah série');
  PERFORM pg_temp.tvrd(_telo LIKE '%Porucha chlazení%',
    'tělo nese důvod zrušení');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: zrušení JEDNOHO termínu série se NEUMLČÍ a mluví o termínu
-- -----------------------------------------------------------------------------
-- Opačná chyba než ta opravovaná: kdyby se dedupovalo přes sérii natvrdo,
-- zmizely by i zprávy o jednotlivých termínech.
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$ BEGIN INSERT INTO _s VALUES ('jeden', pg_temp.serie(DATE '2029-11-05', DATE '2029-12-10')); END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _mailu int; _predmet text;
BEGIN
  DELETE FROM public.email_outbox;
  PERFORM public.cancel_booking(
    (SELECT r.id FROM public.reservations r JOIN _s s ON r.series_id = s.sid AND s.klic='jeden'
      WHERE r.status='confirmed' ORDER BY r.start_at LIMIT 1),
    'single', 'Jen tenhle termín');

  SELECT count(*) INTO _mailu FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_mailu = 1,
    'JÁDRO: zrušení jednoho termínu série pořád upozorní (1 e-mail), poslalo ' || _mailu);

  SELECT subject INTO _predmet FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_predmet = 'Rezervace byla zrušena',
    'JÁDRO: u jednoho termínu zůstává zpráva o REZERVACI, ne o sérii');
END $$;

-- -----------------------------------------------------------------------------
-- Pomůcka: kolik řádků si dávka vezme (a rovnou je označí `sending`)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.davka(_limit int DEFAULT 50) RETURNS int
 LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.email_outbox_prevzit(_limit);
$$;

-- Založí _kolik zpráv do fronty danému uživateli.
CREATE OR REPLACE FUNCTION pg_temp.nasyp(_kdo uuid, _kolik int) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  FOR i IN 1.._kolik LOOP
    PERFORM public.notify_user(_kdo, 'reservation_cancelled',
      'Rezervace byla zrušena', 'Zpráva ' || i, '/calendar');
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 4) JÁDRO: strop brzdí ODESÍLÁNÍ, na uživatele a klouzavou hodinu
-- -----------------------------------------------------------------------------
-- ⚠️ STROP SE STĚHOVAL. První verze ho počítala v `notify_user` a řádek přes
-- strop zakládala jako `skipped`, což je TERMINÁLNÍ stav — bezpečnostní brána
-- 12. 9. 2026 změřila, že se tím trvale ztrácely e-maily o zrušených
-- rezervacích. Teď strop rozhoduje jen o tom, KDY se odešle; nic se nezahazuje.
DO $$
DECLARE _kdo uuid := '22222222-2222-2222-2222-222222222222';
        _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 3;

  PERFORM pg_temp.nasyp(_kdo, 5);
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.email_outbox WHERE status='pending') = 5,
    'příprava: ve frontě čeká 5 zpráv jednomu člověku');

  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 3,
    'JÁDRO: dávka si vzala jen 3 (strop), ne ' || _vzato);

  -- Tohle je ta vlastnost, kvůli které strop opustil `notify_user`.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.email_outbox WHERE status='pending') = 2,
    'JÁDRO: zbytek zůstal `pending` (nic se nezahodilo)');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.email_outbox WHERE status IN ('skipped','failed')) = 0,
    'JÁDRO: přes strop nevznikl ŽÁDNÝ terminální řádek');
END $$;

-- -----------------------------------------------------------------------------
-- 4d) JÁDRO: odložená pošta se OPRAVDU odešle, až se okno posune
-- -----------------------------------------------------------------------------
-- Bez tohohle by „odložíme" byl jen hezčí název pro „zahodíme".
DO $$
DECLARE _vzato int;
BEGIN
  -- Nic nového nepřibylo a strop je pořád vyčerpaný → dávka nesmí vzít nic.
  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 0,
    'dokud je okno plné, dávka nebere nic (vzala ' || _vzato || ')');

  -- Posuneme okno: co odešlo, odešlo před víc než hodinou. Řádky se přitom
  -- musí dostat do `sent`, jak je po odeslání označí edge funkce — kdyby
  -- zůstaly v `sending` s razítkem 90 minut zpátky, byly by to UVÍZNUTÉ
  -- řádky k opakování a dávka by si vzala i je (změřeno: vzala 3 místo 2).
  UPDATE public.email_outbox
     SET status = 'sent', sent_at = now() - interval '90 minutes',
         claimed_at = now() - interval '90 minutes'
   WHERE status = 'sending';

  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 2,
    'JÁDRO: po posunu okna se odložené 2 zprávy odeslaly (vzato ' || _vzato || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 4e) JÁDRO: VÝPADEK CRONU NESMÍ POŠTU ZNIČIT
-- -----------------------------------------------------------------------------
-- Tohle je regresní test na vlastní chybu. Chvíli tu byla „druhá mez":
-- `pending` starší než 24 hodin se uzavíralo jako `failed`, aby fronta
-- nemohla růst donekonečna. Brána code review 12. 9. 2026 změřila, co to
-- doopravdy dělá: třicetihodinový VÝPADEK CRONU, dvanáct zpráv, strop 100/h
-- — tedy nikde nic nepřeteklo — a pět zpráv skončilo trvale `failed`
-- s `attempts = 0`. Nikdy se je nikdo nepokusil odeslat.
--
-- Stáří řádku totiž neříká „tenhle přetekl strop", ale „tenhle tu leží",
-- a při zastaveném cronu tu leží všechno.
DO $$
DECLARE _kdo uuid := '44444444-4444-4444-4444-444444444444';
        _stare uuid; _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 100;

  -- Cron stál 30 hodin, fronta se mezitím plnila.
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, created_at)
  SELECT _kdo, 'vypadek@test.local', 'Z výpadku', 'Z výpadku', 'pending',
         now() - interval '30 hours' + (i || ' minutes')::interval
    FROM generate_series(1, 12) i;

  SELECT id INTO _stare FROM public.email_outbox ORDER BY created_at LIMIT 1;

  _vzato := pg_temp.davka(50);

  PERFORM pg_temp.tvrd(_vzato = 12,
    'JÁDRO: po výpadku se pošta odešle celá, ne zčásti (vzato ' || _vzato || ')');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.email_outbox WHERE status = 'failed') = 0,
    'JÁDRO: stáří řádku samo o sobě NIC neuzavře jako `failed`');
  PERFORM pg_temp.tvrd(
    (SELECT attempts FROM public.email_outbox WHERE id = _stare) = 1,
    'JÁDRO: i nejstarší zpráva dostala svůj pokus');
END $$;

-- -----------------------------------------------------------------------------
-- 4f) JÁDRO: bez řádku v `settings` se strop nezblázní
-- -----------------------------------------------------------------------------
-- Komentář u stropu dřív tvrdil, že dvojitý COALESCE ošetří i chybějící řádek
-- v `settings`. Nebyla to pravda: `CROSS JOIN` s prázdnou stranou nevrátí NULL,
-- ale NIC, takže by se nevzalo vůbec nic — ani pošta bez `user_id`, o které
-- týž komentář tvrdil, že strop neřeší. Oba COALESCE byly mrtvý kód.
-- Našla to brána code review 12. 9. 2026 měřením („vzato 0").
DO $$
DECLARE _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  PERFORM pg_temp.nasyp('33333333-3333-3333-3333-333333333333', 3);

  -- Řádek bez `user_id`: strop nemá komu ho účtovat a nesmí kvůli tomu uvíznout.
  INSERT INTO public.email_outbox (email, subject, body, status)
  VALUES ('bez-uzivatele@test.local', 'Servisní', 'Servisní', 'pending');

  -- `settings` se musí vrátit, jinak by o ně přišly další scénáře.
  CREATE TEMP TABLE _settings_zaloha ON COMMIT DROP AS SELECT * FROM public.settings;
  DELETE FROM public.settings;

  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 4,
    'JÁDRO: bez řádku v `settings` se použije výchozí strop a pošta jde ven (vzato ' || _vzato || ')');

  INSERT INTO public.settings SELECT * FROM _settings_zaloha;
  DROP TABLE _settings_zaloha;
END $$;

-- -----------------------------------------------------------------------------
-- 4b) JÁDRO: strop platí NA UŽIVATELE, ne na celou halu
-- -----------------------------------------------------------------------------
-- Kdyby ze stropu vypadla vazba na `user_id`, počítal by se provoz všech
-- dohromady: tři lidi si nechají poslat po jedné zprávě a čtvrtý člověk v hale
-- svou nedostane, ani kdyby to byla jeho první za den.
DO $$
DECLARE _cizi   uuid := '44444444-4444-4444-4444-444444444444';
        _mereny uuid := '55555555-5555-5555-5555-555555555555';
        _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 3;

  -- Cizí člověk má strop vyčerpaný: pět zpráv, které už šly ven.
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, claimed_at)
  SELECT _cizi, 'cizi@test.local', 'Cizí', 'Cizí', 'sent', now() - interval '5 minutes'
    FROM generate_series(1, 5);

  PERFORM pg_temp.nasyp(_mereny, 2);
  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 2,
    'JÁDRO: cizí provoz nespotřebuje strop měřeného uživatele (vzato ' || _vzato || ')');
END $$;

-- -----------------------------------------------------------------------------
-- 4c) JÁDRO: strop je klouzavá HODINA, ne „navždy"
-- -----------------------------------------------------------------------------
-- Kdyby z dotazu vypadlo okno, byl by to doživotní limit: po stu zprávách za
-- celou sezónu by uživatel přestal dostávat poštu natrvalo a nikdo by nevěděl
-- proč. `now()` je čas ZAČÁTKU transakce, takže „před 90 minutami" je tu
-- spolehlivě mimo okno i uprostřed dlouhého testu.
DO $$
DECLARE _kdo uuid := '22222222-2222-2222-2222-222222222222';
        _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 3;

  INSERT INTO public.email_outbox (user_id, email, subject, body, status, claimed_at)
  SELECT _kdo, 'stara@test.local', 'Stará', 'Stará', 'sent', now() - interval '90 minutes'
    FROM generate_series(1, 5);

  PERFORM pg_temp.nasyp(_kdo, 2);
  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 2,
    'JÁDRO: pošta starší než hodina se do stropu nepočítá (vzato ' || _vzato || ')');

  -- ROZLIŠUJÍCÍ PROTIPŘÍKLAD: táž pošta uvnitř okna strop vyčerpat MUSÍ,
  -- jinak by testu vyhověla i funkce, která strop nepočítá vůbec.
  DELETE FROM public.email_outbox;
  INSERT INTO public.email_outbox (user_id, email, subject, body, status, claimed_at)
  SELECT _kdo, 'nova@test.local', 'Nová', 'Nová', 'sent', now() - interval '5 minutes'
    FROM generate_series(1, 5);

  PERFORM pg_temp.nasyp(_kdo, 2);
  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 0,
    'JÁDRO: táž pošta uvnitř okna strop vyčerpá (test rozlišuje), vzato ' || _vzato);
END $$;

-- -----------------------------------------------------------------------------
-- 4g) JÁDRO: zahlcená oběť dostane to podstatné, ne až po hromadě spamu
-- -----------------------------------------------------------------------------
-- Strop se počítá na PŘÍJEMCE, takže cizí člověk umí vyrobit provoz na adresu
-- oběti. Bezpečnostní brána 12. 9. 2026 změřila, že obyčejný člen klubu
-- opakovaným zakládáním a rušením rezervace pošle zástupci deset e-mailů
-- a může v tom pokračovat. Při striktním FIFO by se obětina SKUTEČNÁ zpráva
-- („vaši rezervaci zrušili") zařadila až za tu hromadu a při vyčerpaném
-- stropu by se k ní nikdy nedostalo.
DO $$
DECLARE _kdo uuid := '44444444-4444-4444-4444-444444444444';
        _dulezita uuid;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 2;

  -- Útočník nasype rutinní poštu. Je STARŠÍ, takže při FIFO by šla první.
  FOR i IN 1..20 LOOP
    PERFORM public.notify_user(_kdo, 'reservation_needs_approval',
      'Máte rezervaci k potvrzení', 'Spam ' || i, '/calendar');
  END LOOP;
  UPDATE public.email_outbox SET created_at = now() - interval '30 minutes';

  -- A teprve POTOM přijde to, na čem oběti opravdu záleží.
  _dulezita := public.notify_user(_kdo, 'reservation_cancelled',
    'Rezervace byla zrušena', 'Přišli jste o led', '/calendar');

  PERFORM pg_temp.davka(50);

  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.email_outbox WHERE notification_id = _dulezita) = 'sending',
    'JÁDRO: zpráva o zrušení se odešle i přes 20 starších rutinních zpráv');
END $$;

-- -----------------------------------------------------------------------------
-- 4h) JÁDRO: řádky bez `user_id` strop neobcházejí
-- -----------------------------------------------------------------------------
-- Bezpečnostní brána změřila obejití: při stropu 1 si dávka vzala 200 řádků
-- bez `user_id`. Prázdné `user_id` přitom nevzniká jen ručním vložením —
-- doplní ho i `ON DELETE SET NULL`, když zanikne profil.
DO $$
DECLARE _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 3;

  INSERT INTO public.email_outbox (email, subject, body, status)
  SELECT 'bez-uzivatele@test.local', 'Servisní', 'Servisní', 'pending'
    FROM generate_series(1, 50);

  _vzato := pg_temp.davka(200);
  PERFORM pg_temp.tvrd(_vzato = 3,
    'JÁDRO: i pošta bez `user_id` podléhá stropu (vzato ' || _vzato || ', čekáno 3)');
END $$;

-- -----------------------------------------------------------------------------
-- 5) JÁDRO: strop se řídí NASTAVENÍM, není zadrátovaný
-- -----------------------------------------------------------------------------
DO $$
DECLARE _kdo uuid := '33333333-3333-3333-3333-333333333333';
        _vzato int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 1;

  PERFORM pg_temp.nasyp(_kdo, 4);
  _vzato := pg_temp.davka(50);
  PERFORM pg_temp.tvrd(_vzato = 1,
    'JÁDRO: při stropu 1 vezme dávka jednu zprávu (strop se čte z nastavení), vzala ' || _vzato);
END $$;

-- -----------------------------------------------------------------------------
-- 6) Založení série pořád posílá dvě zprávy (autor + správce), ne víc
-- -----------------------------------------------------------------------------
-- Regresní pojistka: dedup u ZALOŽENÍ fungoval už dřív a nesmí se rozbít.
DO $$
DECLARE _mailu int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 100;
  PERFORM set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555"}', true);
  PERFORM pg_temp.serie(DATE '2030-02-04', DATE '2030-03-25');

  SELECT count(*) INTO _mailu FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_mailu = 2,
    'založení série = 2 e-maily (autor + správce), ne ' || _mailu);
END $$;

-- -----------------------------------------------------------------------------
-- 7) JÁDRO: dvoudráhová série hlásí TERMÍNY, ne řádky
-- -----------------------------------------------------------------------------
-- Rezervace přes obě dráhy jsou DVA řádky na jeden termín. `count(*)` by tedy
-- u šestitýdenní dvoudráhové série hlásil „Zrušeno termínů: 12“. Změřeno
-- 12. 9. 2026, než se z toho stal `count(DISTINCT COALESCE(event_id, id))`.
DO $$
DECLARE _sid uuid; _radku int; _terminu int; _telo text; _mailu int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 100;
  PERFORM set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555"}', true);
  _sid := pg_temp.serie(DATE '2030-05-06', DATE '2030-06-10', 2);

  SELECT count(*), count(DISTINCT COALESCE(r.event_id, r.id)) INTO _radku, _terminu
    FROM public.reservations r WHERE r.series_id = _sid AND r.status = 'confirmed';
  PERFORM pg_temp.tvrd(_radku = _terminu * 2,
    'příprava: série drží obě dráhy (' || _radku || ' řádků na ' || _terminu || ' termínů)');

  DELETE FROM public.email_outbox;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  PERFORM public.cancel_booking(
    (SELECT r.id FROM public.reservations r WHERE r.series_id = _sid AND r.status='confirmed'
      ORDER BY r.start_at LIMIT 1),
    'series', 'Dvě dráhy');

  SELECT count(*) INTO _mailu FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_mailu = 1,
    'JÁDRO: dvoudráhová série = 1 e-mail, ne ' || _mailu);

  SELECT body INTO _telo FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_telo LIKE '%Zrušeno termínů: ' || _terminu || '%',
    'JÁDRO: hlásí ' || _terminu || ' termínů, ne ' || _radku || ' řádků');
END $$;

-- -----------------------------------------------------------------------------
-- 8) JÁDRO: série se dvěma autory = KAŽDÝ autor právě jedna zpráva
-- -----------------------------------------------------------------------------
-- Značka dedupu je klíčovaná SÉRIÍ, ale adresát se bere PO ŘÁDKU
-- (`NEW.created_by`). Bez příjemce v klíči umlčí první autor všechny ostatní.
-- Že to není teorie: `create_booking` hlídá u série jen shodu SUBJEKTU, ne
-- autora, a klub smí mít víc zástupců — v seedu jsou 44444444 i 55555555 oba
-- zástupci „CK Ostravské kameny". Našla to brána code review 12. 9. 2026;
-- byla to regrese proti stavu PŘED touhle migrací.
DO $$
DECLARE _sid uuid; _rez uuid; _autoru int;
BEGIN
  DELETE FROM public.email_outbox;
  UPDATE public.settings SET email_max_za_hodinu = 100;

  -- Sérii založí 55555555…
  PERFORM set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555"}', true);
  _sid := pg_temp.serie(DATE '2031-01-06', DATE '2031-02-10');

  -- …a jeden termín v ní přepíšeme na druhého autora 44444444.
  -- `created_by` hlídá guard „smí měnit jen správce", takže pod adminem.
  -- Trigger upozornění to nespustí: visí na sheet_id/start_at/end_at/status.
  SELECT r.id INTO _rez FROM public.reservations r
   WHERE r.series_id = _sid AND r.status = 'confirmed' ORDER BY r.start_at DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  UPDATE public.reservations SET created_by = '44444444-4444-4444-4444-444444444444'
   WHERE id = _rez;

  DELETE FROM public.email_outbox;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  PERFORM public.cancel_booking(
    (SELECT r.id FROM public.reservations r WHERE r.series_id = _sid AND r.status='confirmed'
      ORDER BY r.start_at LIMIT 1),
    'series', 'Dva autoři');

  SELECT count(DISTINCT user_id) INTO _autoru FROM public.email_outbox;
  PERFORM pg_temp.tvrd(_autoru = 2,
    'JÁDRO: zprávu dostali OBA autoři série, ne jen první (dostalo ji ' || _autoru || ')');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.email_outbox) = 2,
    'JÁDRO: a každý právě jednu, ne jednu na termín');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
