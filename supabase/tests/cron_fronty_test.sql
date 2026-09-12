-- =============================================================================
-- TESTY: cron na vyprazdňování fronty e-mailů
-- Migrace 20260912180000_cron_fronty_emailu.sql
-- =============================================================================
-- Nejcennější tvrzení tu NENÍ „job existuje", ale dvě jiná:
--   * `posli_frontu_emailu()` čte VAULT, takže se k ní z API nesmí dostat
--     nikdo — ani `service_role`. Běží jako `postgres` a sahá na tajemství.
--     (Dřív tu stálo „čte servisní klíč". To byl zbytek po starším návrhu
--     a byl to opak pravdy: celý smysl téhle migrace je, že se servisní klíč
--     z databáze NEPOSÍLÁ. Našla to brána code review 12. 9. 2026.)
--   * Bez tajemství ve Vaultu NESMÍ volat nic. Tohle drží lokál a demo mimo
--     produkci — kdyby se URL zadrátovala do migrace, `supabase db reset`
--     na lokále by zavolal ostrou produkci.
--
-- MUTAČNÍ ZKOUŠKA (ověřeno, každá tenhle soubor zčervená):
--   * `GRANT EXECUTE … TO authenticated`        → scénář 2
--   * vypuštěná kontrola prázdného Vaultu       → scénář 3
--   * job naplánovaný na jiný interval          → scénář 1
--   * vypuštěná kontrola tvaru klíče            → scénář 5
--   * kontrola tvaru běží jen nad klíčem, ne nad tokenem → scénář 5d
--   * vypuštěná kontrola délky tokenu           → scénář 5d
--   * vypuštěná kontrola cílové URL             → scénář 5d
--
-- ⚠️ SCÉNÁŘ 3 SE DŘÍV SÁM PŘESKAKOVAL. Ptal se, jestli databáze tajemství má,
-- a když ano, tiše se vynechal — takže přesně na produkci, kde na tom záleží,
-- neměřil nic a zeleně o tom mlčel. Teď se volá s VYMYŠLENÝMI jmény tajemství,
-- takže větev „chybí" jde změřit i tam, kde ta pravá tajemství jsou.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_p boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_p, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Job je naplánovaný, aktivní a volá tu správnou věc
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record;
BEGIN
  SELECT schedule, active, command INTO _r
    FROM cron.job WHERE jobname = 'send-emails-kazdych-5-minut';

  PERFORM pg_temp.tvrd(_r IS NOT NULL, 'job na frontu e-mailů existuje');
  PERFORM pg_temp.tvrd(_r.schedule = '*/5 * * * *', 'job běží po 5 minutách');
  PERFORM pg_temp.tvrd(_r.active, 'job je aktivní');
  PERFORM pg_temp.tvrd(_r.command LIKE '%posli_frontu_emailu%', 'job volá posli_frontu_emailu()');

  -- Duplicitní job by frontu volal dvakrát; zamykání by to uneslo, ale
  -- je to zbytečná zátěž a známka toho, že migrace neběžela idempotentně.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM cron.job WHERE command LIKE '%posli_frontu_emailu%') = 1,
    'JÁDRO: job je právě jeden (migrace nezduplikovala plán)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: z API se na funkci nedosáhne
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('authenticated', 'public.posli_frontu_emailu(text, text, text)', 'EXECUTE'),
    'JÁDRO: `authenticated` na posli_frontu_emailu() nedosáhne');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.posli_frontu_emailu(text, text, text)', 'EXECUTE'),
    '`anon` na posli_frontu_emailu() nedosáhne');
  -- PostgREST se na servisní klíč přepne do role `service_role`, takže bez
  -- tohohle by funkci šlo spustit přes API kdekoli, kde ten klíč je.
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('service_role', 'public.posli_frontu_emailu(text, text, text)', 'EXECUTE'),
    'JÁDRO: ani `service_role` na ni z API nedosáhne');

  -- Staré signatury musí být pryč, jinak by na nich zůstal výchozí grant
  -- pro PUBLIC a REVOKE na nové signatuře by nechránil nic.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'posli_frontu_emailu') = 1,
    'JÁDRO: existuje jediná signatura (staré přetížení nezůstalo grantované)');
END $$;

-- Grant je jen papír, měříme pod rolí (CLAUDE.md pravidlo 9).
DO $$
DECLARE _pusteno boolean := false;
BEGIN
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.posli_frontu_emailu();
    _pusteno := true;
  EXCEPTION WHEN insufficient_privilege OR sqlstate '42501' THEN
    _pusteno := false;
  END;
  RESET ROLE;
  PERFORM pg_temp.tvrd(NOT _pusteno,
    'JÁDRO: pod rolí `authenticated` funkci spustit NELZE');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: bez tajemství ve Vaultu se nevolá nic
-- -----------------------------------------------------------------------------
-- Tohle je pojistka, která drží lokál a demo mimo produkci: kdyby se URL
-- zadrátovala do migrace, `supabase db reset` na lokále by zavolal ostrou
-- produkci.
--
-- Měří se přes VYMYŠLENÁ jména tajemství, ne přes prázdný Vault. Jména jsou
-- proto parametry funkce — jinak by tenhle scénář šel změřit jen tam, kde
-- tajemství chybí, tedy všude kromě produkce.
DO $$
DECLARE _vysledek bigint;
BEGIN
  _vysledek := public.posli_frontu_emailu(
                 'tenhle_token_neexistuje_xyz',
                 'tahle_url_neexistuje_xyz',
                 'tenhle_klic_neexistuje_xyz');
  PERFORM pg_temp.tvrd(_vysledek IS NULL,
    'JÁDRO: bez tajemství ve Vaultu funkce nevolá nic (vrací NULL)');
END $$;

-- A chybět smí KTERÉKOLI z těch tří, ne jen všechna najednou. Tři tajemství
-- znamenají tři způsoby, jak to nastavit napůl.
DO $$
DECLARE _jmena text[] := ARRAY['send_emails_cron_token','send_emails_url','send_emails_anon_key'];
        _i int;
        _a text[];
BEGIN
  FOR _i IN 1..3 LOOP
    _a := _jmena;
    _a[_i] := 'chybi_schvalne_xyz';
    PERFORM pg_temp.tvrd(
      public.posli_frontu_emailu(_a[1], _a[2], _a[3]) IS NULL,
      'chybí-li jen ' || _jmena[_i] || ', neodesílá se nic');
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 4) Klíč není nikde v otevřené podobě
-- -----------------------------------------------------------------------------
DO $$
DECLARE _zdroj text; _prikaz text;
BEGIN
  SELECT prosrc INTO _zdroj FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'posli_frontu_emailu';
  SELECT command INTO _prikaz FROM cron.job WHERE jobname = 'send-emails-kazdych-5-minut';

  PERFORM pg_temp.tvrd(_zdroj LIKE '%vault.decrypted_secrets%',
    'funkce bere klíč z Vaultu');
  -- Servisní klíč Supabase je JWT (eyJ…) nebo sb_secret_…; ani jedno tu nesmí být.
  -- Hledá se KLÍČ, ne ten prefix: funkce sama ty prefixy zmiňuje, protože
  -- kontroluje, že jí z Vaultu nepřišel tajný klíč. Rozhoduje délka.
  PERFORM pg_temp.tvrd(_zdroj !~ 'eyJ[A-Za-z0-9_-]{10,}' AND _zdroj !~ 'sb_secret_[A-Za-z0-9]{5,}',
    'JÁDRO: v definici funkce není zadrátovaný klíč');
  PERFORM pg_temp.tvrd(_prikaz !~ 'eyJ[A-Za-z0-9_-]{10,}' AND _prikaz !~ 'sb_secret_[A-Za-z0-9]{5,}',
    'JÁDRO: v příkazu jobu není zadrátovaný klíč');
  PERFORM pg_temp.tvrd(_zdroj NOT LIKE '%supabase.co%',
    'JÁDRO: v definici funkce není zadrátovaná URL produkce');
END $$;

-- -----------------------------------------------------------------------------
-- 5) JÁDRO: do fronty pg_netu se nedostane tajný klíč
-- -----------------------------------------------------------------------------
-- Publishable a tajný klíč leží v Dashboardu vedle sebe a OBA se jmenují
-- „default“. Záměna je tedy realistický překlep, ne teoretická možnost —
-- a skončila by tím, že servisní pověření leží v `net.http_request_queue`,
-- což je tabulka bez RLS. Proto se tvar klíče kontroluje před odesláním.
DO $$
DECLARE _url_id uuid; _tok_id uuid; _klic_id uuid; _odmitnuto boolean;
BEGIN
  _tok_id  := vault.create_secret('token-na-test-dost-dlouhy-aby-prosel-0123456789', 'test_cron_token_' || gen_random_uuid());
  _url_id  := vault.create_secret('https://priklad.supabase.co/functions/v1/send-emails', 'test_cron_url_' || gen_random_uuid());

  -- (a) nová generace: sb_secret_…
  _klic_id := vault.create_secret('sb_secret_3_TOHLE_JE_TAJNY', 'test_cron_klic_' || gen_random_uuid());
  _odmitnuto := false;
  BEGIN
    PERFORM public.posli_frontu_emailu(
      (SELECT name FROM vault.secrets WHERE id = _tok_id),
      (SELECT name FROM vault.secrets WHERE id = _url_id),
      (SELECT name FROM vault.secrets WHERE id = _klic_id));
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true;
  END;
  PERFORM pg_temp.tvrd(_odmitnuto, 'JÁDRO: klíč `sb_secret_…` funkce odmítne odeslat');

  -- (b) legacy JWT s rolí service_role. Payload je base64url {"role":"service_role"}.
  PERFORM vault.update_secret(_klic_id,
    'eyJhbGciOiJIUzI1NiJ9.' ||
    translate(encode(convert_to('{"role":"service_role","iss":"supabase"}','utf8'),'base64'), '+/=', '-_') ||
    '.podpisnenidulezity');
  _odmitnuto := false;
  BEGIN
    PERFORM public.posli_frontu_emailu(
      (SELECT name FROM vault.secrets WHERE id = _tok_id),
      (SELECT name FROM vault.secrets WHERE id = _url_id),
      (SELECT name FROM vault.secrets WHERE id = _klic_id));
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true;
  END;
  PERFORM pg_temp.tvrd(_odmitnuto, 'JÁDRO: legacy JWT s rolí service_role funkce odmítne odeslat');

  -- (c) ROZLIŠUJÍCÍ PROTIPŘÍKLAD: legacy JWT s rolí anon projít MUSÍ.
  -- Bez něj by testu vyhověla i funkce, která odmítá všechno.
  PERFORM vault.update_secret(_klic_id,
    'eyJhbGciOiJIUzI1NiJ9.' ||
    translate(encode(convert_to('{"role":"anon","iss":"supabase"}','utf8'),'base64'), '+/=', '-_') ||
    '.podpisnenidulezity');
  _odmitnuto := false;
  BEGIN
    PERFORM public.posli_frontu_emailu(
      (SELECT name FROM vault.secrets WHERE id = _tok_id),
      (SELECT name FROM vault.secrets WHERE id = _url_id),
      (SELECT name FROM vault.secrets WHERE id = _klic_id));
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true;
  END;
  PERFORM pg_temp.tvrd(NOT _odmitnuto, 'JÁDRO: legacy JWT s rolí anon projde (test rozlišuje)');
END $$;

-- -----------------------------------------------------------------------------
-- 5c) JÁDRO: úklidové joby existují a selhání cronu NEZAMETAJÍ
-- -----------------------------------------------------------------------------
-- Brána migrací 12. 9. 2026 tenhle soubor přistihla, že úklidové joby nehlídá
-- vůbec (mutace je odstranila a test zůstal zelený). A brána code review
-- ukázala proč na tom záleží: když se `EMAIL_CRON_TOKEN` rozejde s Vaultem,
-- vrací funkce 401 každých 5 minut donekonečna, `posli_frontu_emailu`
-- odpověď nečte, `cron.job_run_details` vidí úspěch (požadavek se přece
-- zařadil) — a jediná stopa se mazala dřív, než se na ni kdokoli podíval.
DO $$
DECLARE _uspech text; _chyby text; _fronta text;
BEGIN
  SELECT command INTO _uspech FROM cron.job WHERE jobname = 'uklid-odpovedi-pg-net';
  SELECT command INTO _chyby  FROM cron.job WHERE jobname = 'uklid-chybnych-odpovedi-pg-net';
  SELECT command INTO _fronta FROM cron.job WHERE jobname = 'uklid-fronty-emailu';

  PERFORM pg_temp.tvrd(_uspech IS NOT NULL, 'úklid odpovědí pg_net je naplánovaný');
  PERFORM pg_temp.tvrd(_chyby  IS NOT NULL, 'úklid CHYBNÝCH odpovědí je naplánovaný');
  PERFORM pg_temp.tvrd(_fronta IS NOT NULL, 'retence fronty e-mailů je naplánovaná');

  -- Tohle je to jádro: rychlý úklid se smí dotknout JEN úspěšných odpovědí.
  PERFORM pg_temp.tvrd(_uspech LIKE '%status_code BETWEEN 200 AND 299%',
    'JÁDRO: rychlý úklid maže jen úspěšné odpovědi, chyby nechává');

  -- Retence nesmí sáhnout na to, co ještě čeká nebo se odesílá.
  PERFORM pg_temp.tvrd(_fronta LIKE '%status IN (''sent'', ''failed'', ''skipped'')%',
    'JÁDRO: retence maže jen dokončené řádky, ne čekající poštu');
END $$;

-- Tvrzení o chování, ne o textu příkazu: co rychlý úklid opravdu smaže.
DO $$
DECLARE _zbylo_ok int; _zbylo_chyb int;
BEGIN
  INSERT INTO net._http_response (id, status_code, content, created)
  VALUES (900001, 200, 'ok',    now() - interval '30 minutes'),
         (900002, 401, 'chyba', now() - interval '30 minutes');

  EXECUTE (SELECT command FROM cron.job WHERE jobname = 'uklid-odpovedi-pg-net');

  SELECT count(*) INTO _zbylo_ok   FROM net._http_response WHERE id = 900001;
  SELECT count(*) INTO _zbylo_chyb FROM net._http_response WHERE id = 900002;

  PERFORM pg_temp.tvrd(_zbylo_ok = 0,   'stará ÚSPĚŠNÁ odpověď se uklidila');
  PERFORM pg_temp.tvrd(_zbylo_chyb = 1,
    'JÁDRO: stará CHYBOVÁ odpověď ZŮSTALA (jinak je selhání cronu neviditelné)');
END $$;

-- -----------------------------------------------------------------------------
-- 5d) JÁDRO: hlídá se i TOKEN, jeho délka a cílová URL
-- -----------------------------------------------------------------------------
-- Původní verze kontrolovala výhradně publishable klíč. Bezpečnostní brána
-- 12. 9. 2026 změřila, že vedle toho zbyly tři stejně velké díry:
--   * tři tajemství se do Vaultu vkládají jednou dávkou, takže záměna TOKENU
--     a tajného klíče je stejně pravděpodobná jako ta, proti které guard vznikl
--     (změřeno: servisní klíč odešel jako `x-cron-token`),
--   * prošel by i čtyřznakový token, ačkoli na něm stojí celá admise,
--   * prošla by `http://cizi-host/…`, tedy token v otevřené podobě cizímu
--     hostiteli.
DO $$
DECLARE _tok uuid; _url uuid; _klic uuid; _odmitnuto boolean;
        _jt text; _ju text; _jk text;
BEGIN
  _tok  := vault.create_secret('token-na-test-dost-dlouhy-aby-prosel-0123456789', 'test5d_token_' || gen_random_uuid());
  _url  := vault.create_secret('https://priklad.supabase.co/functions/v1/send-emails', 'test5d_url_' || gen_random_uuid());
  _klic := vault.create_secret('sb_publishable_VEREJNE', 'test5d_klic_' || gen_random_uuid());
  SELECT name INTO _jt FROM vault.secrets WHERE id = _tok;
  SELECT name INTO _ju FROM vault.secrets WHERE id = _url;
  SELECT name INTO _jk FROM vault.secrets WHERE id = _klic;

  -- (a) tajný klíč vložený omylem jako TOKEN
  PERFORM vault.update_secret(_tok, 'sb_secret_3_TOHLE_JE_SERVISNI_KLIC');
  _odmitnuto := false;
  BEGIN PERFORM public.posli_frontu_emailu(_jt, _ju, _jk);
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true; END;
  PERFORM pg_temp.tvrd(_odmitnuto, 'JÁDRO: tajný klíč vložený jako TOKEN se neodešle');

  -- (b) krátký token
  PERFORM vault.update_secret(_tok, 'kratky');
  _odmitnuto := false;
  BEGIN PERFORM public.posli_frontu_emailu(_jt, _ju, _jk);
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true; END;
  PERFORM pg_temp.tvrd(_odmitnuto, 'JÁDRO: krátký token se odmítne');

  -- (c) cizí / nešifrovaná URL
  PERFORM vault.update_secret(_tok, 'token-na-test-dost-dlouhy-aby-prosel-0123456789');
  PERFORM vault.update_secret(_url, 'http://neni-https.example/f');
  _odmitnuto := false;
  BEGIN PERFORM public.posli_frontu_emailu(_jt, _ju, _jk);
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true; END;
  PERFORM pg_temp.tvrd(_odmitnuto, 'JÁDRO: cizí nešifrovaná URL se odmítne');

  -- (d) ROZLIŠUJÍCÍ PROTIPŘÍKLAD: všechno v pořádku PROJÍT MUSÍ.
  -- Bez něj by testu vyhověla i funkce, která odmítá všechno.
  PERFORM vault.update_secret(_url, 'https://priklad.supabase.co/functions/v1/send-emails');
  _odmitnuto := false;
  BEGIN PERFORM public.posli_frontu_emailu(_jt, _ju, _jk);
  EXCEPTION WHEN OTHERS THEN _odmitnuto := true; END;
  PERFORM pg_temp.tvrd(NOT _odmitnuto, 'JÁDRO: správná trojice projde (test rozlišuje)');
END $$;

-- -----------------------------------------------------------------------------
-- 6) JÁDRO: co doopravdy odchází ve frontě pg_netu
-- -----------------------------------------------------------------------------
-- Brána Supabase požadavek bez `Authorization` k funkci vůbec nepustí
-- (změřeno 12. 9. 2026: 401 UNAUTHORIZED_NO_AUTH_HEADER), takže bez té hlavičky
-- by cron tiše netočil nic. Zároveň nesmí zmizet `x-cron-token` — jinak by
-- o vpuštění rozhodoval klíč, který má v prohlížeči každý.
--
-- ⚠️ Dřív se to tvrdilo čtením `prosrc`. To NEMĚŘÍ NIC: když se jméno hlavičky
-- v kódu přepíše, zůstane slovo v okolním komentáři a test je dál zelený
-- (ověřeno mutací). Čte se proto `net.http_request_queue` — skutečný
-- odchozí požadavek. Transakce se rollbackuje, takže nikam neodejde.
DO $$
DECLARE _tok_id uuid; _url_id uuid; _klic_id uuid;
        _id bigint; _h jsonb;
BEGIN
  _tok_id  := vault.create_secret('TAJNY-CRON-TOKEN-XYZ-0123456789-dost-dlouhy', 'test_hlavicky_token_' || gen_random_uuid());
  _url_id  := vault.create_secret('https://priklad.supabase.co/functions/v1/send-emails', 'test_hlavicky_url_' || gen_random_uuid());
  _klic_id := vault.create_secret('sb_publishable_TOHLE_JE_VEREJNE', 'test_hlavicky_klic_' || gen_random_uuid());

  _id := public.posli_frontu_emailu(
           (SELECT name FROM vault.secrets WHERE id = _tok_id),
           (SELECT name FROM vault.secrets WHERE id = _url_id),
           (SELECT name FROM vault.secrets WHERE id = _klic_id));
  PERFORM pg_temp.tvrd(_id IS NOT NULL, 'příprava: s tajemstvími se požadavek opravdu zařadí');

  SELECT headers INTO _h FROM net.http_request_queue WHERE id = _id;
  PERFORM pg_temp.tvrd(_h IS NOT NULL, 'příprava: požadavek je ve frontě pg_netu a jde přečíst');

  PERFORM pg_temp.tvrd(_h ? 'Authorization',
    'odchází Authorization (bez ní požadavek k funkci nedojde)');
  PERFORM pg_temp.tvrd(_h ->> 'Authorization' = 'Bearer sb_publishable_TOHLE_JE_VEREJNE',
    'v Authorization je PUBLISHABLE klíč z Vaultu');
  PERFORM pg_temp.tvrd(_h ->> 'x-cron-token' = 'TAJNY-CRON-TOKEN-XYZ-0123456789-dost-dlouhy',
    'JÁDRO: odchází x-cron-token z Vaultu (ten o vpuštění rozhoduje)');

  -- A tohle je ta vlastnost, kvůli které se vůbec posílá vyhrazený token:
  -- v `net.http_request_queue` (tabulka bez RLS) nesmí ležet nic, čím by šlo
  -- číst faktury, profily nebo IBANy brigádníků.
  PERFORM pg_temp.tvrd(
    NOT (_h::text ~ 'sb_secret_[A-Za-z0-9]{5,}') AND NOT (_h::text ~ 'eyJ[A-Za-z0-9_-]{10,}'),
    'JÁDRO: ve frontě pg_netu neleží servisní klíč');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
