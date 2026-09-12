-- =============================================================================
-- Pravidelné vyprazdňování fronty e-mailů (každých 5 minut)
-- =============================================================================
-- KROK 0 (12. 9. 2026, čteno z živé produkce): `pg_cron` ani `pg_net` nebyly
-- nainstalované a Vault byl prázdný. Edge funkce `send-emails` je nasazená
-- a ověřená, ale nic ji nevolalo, takže fronta by stála.
--
-- ⚠️ Z DATABÁZE SE NEPOSÍLÁ SERVISNÍ KLÍČ. To je hlavní rozhodnutí téhle
-- migrace a stojí za ním měření bezpečnostní brány (12. 9. 2026):
--
--   `CREATE EXTENSION pg_net` spustí supabasí event trigger `issue_pg_net_access`,
--   který udělí `anon` i `authenticated` USAGE na schéma `net` a EXECUTE na
--   `net.http_post`. Tabulky `net.http_request_queue` a `net._http_response`
--   nemají RLS a `PUBLIC` na nich má plná práva. Změřeno pod
--   `SET LOCAL ROLE authenticated`: hlavička `Authorization` je z fronty
--   čitelná. A `postgres` ty granty odebrat NEUMÍ (udělil je `supabase_admin`
--   bez grant option).
--
--   Dnes to zneužít nejde, protože `net` není v exposed schemas PostgRESTu
--   (ověřeno 12. 9. 2026 přes management API: `db_schema = public,graphql_public`).
--   Ale kdyby se to někdy změnilo, znamenal by servisní klíč ve frontě přístup
--   ke VŠEMU: faktury, profily, IBANy brigádníků.
--
--   Proto se posílá VYHRAZENÝ TOKEN, který umí jedinou věc: vyprázdnit frontu
--   e-mailů. Jde rotovat bez dopadu na cokoli jiného a v `net` nemá cenu.
--
-- ⚠️ PROČ SE PŘESTO POSÍLÁ I `Authorization`: platformní brána Supabase stojí
-- PŘED edge funkcí a požadavek bez téhle hlavičky k našemu kódu vůbec nepustí.
-- Změřeno 12. 9. 2026 proti nasazené funkci:
--
--   POST /functions/v1/send-emails  +  jen `x-cron-token`
--   → 401 {"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"Missing authorization header"}
--
-- To je odpověď BRÁNY, ne naší funkce (ta odpovídá česky). Cron by tedy tiše
-- netočil nic. Posílá se proto PUBLISHABLE klíč — ten není tajemství, jede
-- v bundlu každého prohlížeče na produkčním webu, a bráně stačí. O VPUŠTĚNÍ
-- rozhoduje pořád `x-cron-token`; publishable klíč sám o sobě neotevře nic
-- (funkce ho vidí jako roli `anon`).
--
-- TAJEMSTVÍ NEJSOU V TÉHLE MIGRACI (pravidlo 5). Vkládají se mimo repo:
--
--   select vault.create_secret('<nahodny token, aspoň 32 znaků>', 'send_emails_cron_token');
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/send-emails',
--                              'send_emails_url');
--   select vault.create_secret('sb_publishable_…', 'send_emails_anon_key');
--
--   a TÝŽ token musí znát i edge funkce:
--   supabase secrets set EMAIL_CRON_TOKEN='<tentýž token>'
--
-- DŮSLEDEK, KTERÝ JE ZÁMĚR: dokud tajemství neexistují, job se spustí a NIC
-- NEUDĚLÁ. Lokální vývoj a demo tedy nikdy nezavolají produkční funkci, i když
-- tuhle migraci mají taky. Kdyby se URL zadrátovala sem, volal by
-- `supabase db reset` na lokále ostrou produkci.
--
-- PROČ 5 MINUT: notifikace o rezervaci nemusí dorazit do vteřiny a každé
-- tiknutí je jedno HTTP volání i s prázdnou frontou.
--
-- MUTAČNÍ ZKOUŠKA: viz `supabase/tests/cron_fronty_test.sql`, hlavička.
-- VRATNOST: odplánovat VŠECHNY ČTYŘI joby, na tři z nich se snadno zapomene:
--   select cron.unschedule('send-emails-kazdych-5-minut');
--   select cron.unschedule('uklid-odpovedi-pg-net');
--   select cron.unschedule('uklid-historie-cronu');
--   select cron.unschedule('uklid-fronty-emailu');
--   drop function public.posli_frontu_emailu(text, text, text);
--   Rozšíření se nechávají (odinstalace pg_net by shodila i jiné případné
--   uživatele). ⚠️ Pozor: odinstalace `pg_net` granty pro `anon`
--   a `authenticated` na schématu `net` stejně nevrátí zpátky — viz výš.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- `pg_net` je non-relocatable, takže případné `WITH SCHEMA extensions` se
-- tiše ignoruje a objekty stejně skončí ve schématu `net`. Nepíše se tu proto
-- klauzule, která by tvrdila něco jiného, než co se stane — kód níž počítá
-- s `net.http_post` a `net._http_response`.
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Pokus o zúžení práv, která rozdal supabasí event trigger. Na spravované
-- instanci to typicky NEPROJDE (granty udělil `supabase_admin`), proto se
-- výsledek jen VYPÍŠE a migrace kvůli němu nepadá. Je to obrana do hloubky
-- navíc, ne ta, na které stojí bezpečnost — tou je vyhrazený token výš.
-- ⚠️ NEÚSPĚŠNÝ `REVOKE` NEVYHODÍ VÝJIMKU. PostgreSQL vrátí jen
-- `WARNING: no privileges could be revoked` a příkaz USPĚJE. První verze
-- tohohle bloku na tom stála: hlásila do výpisu pushe „odebráno", zatímco
-- `authenticated` měl dál USAGE na `net`, EXECUTE na `net.http_post`
-- i SELECT na `net._http_response`, a větev s pravdivou hláškou se nikdy
-- nespustila. Našla to brána migrací 12. 9. 2026 a je to přesně ten vzor,
-- před kterým varuje CLAUDE.md: hlášení tvrdí zavřené dveře a nikdo se
-- nepodíval na okno vedle. Proto se výsledek PO revoke ZMĚŘÍ.
DO $zuzeni$
DECLARE _ma_dal boolean;
BEGIN
  BEGIN
    EXECUTE 'REVOKE USAGE ON SCHEMA net FROM anon, authenticated';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- na spravované instanci to typicky nejde, viz níž
  END;

  SELECT has_schema_privilege('authenticated', 'net', 'USAGE')
      OR has_schema_privilege('anon', 'net', 'USAGE')
    INTO _ma_dal;

  IF _ma_dal THEN
    RAISE NOTICE 'net: USAGE pro anon/authenticated ODEBRAT NELZE (granty udělil supabase_admin). Ochrana stojí na vyhrazeném tokenu a na tom, že `net` NENÍ v exposed schemas PostgRESTu.';
  ELSE
    RAISE NOTICE 'net: USAGE pro anon/authenticated opravdu odebráno (ověřeno dotazem, ne jen úspěchem příkazu).';
  END IF;
END $zuzeni$;

-- -----------------------------------------------------------------------------
-- Volání edge funkce
-- -----------------------------------------------------------------------------
-- Jména tajemství jsou PARAMETRY schválně: jinak by se nedala otestovat větev
-- „tajemství chybí" na databázi, kde tajemství jsou. Bez toho by se test na
-- produkci tiše přeskočil a zelená barva by lhala o pokrytí.
CREATE OR REPLACE FUNCTION public.posli_frontu_emailu(
  _jmeno_tokenu text DEFAULT 'send_emails_cron_token',
  _jmeno_url    text DEFAULT 'send_emails_url',
  _jmeno_klice  text DEFAULT 'send_emails_anon_key'
) RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _token text;
  _url   text;
  _pub   text;
  _telo  text;
  _jmeno text;
  _hod   text;
  _i     int;
  _id    bigint;
BEGIN
  SELECT decrypted_secret INTO _token
    FROM vault.decrypted_secrets WHERE name = _jmeno_tokenu;
  SELECT decrypted_secret INTO _url
    FROM vault.decrypted_secrets WHERE name = _jmeno_url;
  SELECT decrypted_secret INTO _pub
    FROM vault.decrypted_secrets WHERE name = _jmeno_klice;

  -- Bez tajemství se mlčí. Tohle je ta pojistka, která drží lokál a demo mimo
  -- produkci — ne komentář, ale chybějící hodnota.
  IF _token IS NULL OR _url IS NULL OR _pub IS NULL THEN
    RAISE NOTICE 'Fronta e-mailů: chybí %, % nebo % ve Vaultu, nevolám nic.',
      _jmeno_tokenu, _jmeno_url, _jmeno_klice;
    RETURN NULL;
  END IF;

  -- ---- Z databáze nesmí odejít nic, co je tajné -----------------------------
  -- Celá tahle migrace stojí na tom, že z databáze neodchází nic, čím by šlo
  -- číst cizí data. Kdyby někdo do Vaultu omylem vložil tajný klíč (publishable
  -- a tajný leží v Dashboardu vedle sebe a OBA se jmenují „default“), tiše by
  -- se to povedlo a servisní pověření by leželo v tabulce bez RLS.
  --
  -- ⚠️ KONTROLUJÍ SE OBĚ HODNOTY, ne jen klíč. První verze hlídala výhradně
  -- `_pub`, a bezpečnostní brána 12. 9. 2026 změřila, že tím zbyla stejně
  -- velká díra vedle: tři tajemství se do Vaultu vkládají jednou dávkou, takže
  -- záměna tokenu a tajného klíče je úplně stejně pravděpodobná jako ta,
  -- proti které kontrola vznikla. Servisní klíč pak odešel jako `x-cron-token`
  -- (změřeno, požadavek se zařadil).
  FOR _i IN 1..2 LOOP
    _jmeno := CASE _i WHEN 1 THEN _jmeno_tokenu ELSE _jmeno_klice END;
    _hod   := CASE _i WHEN 1 THEN _token        ELSE _pub        END;

    IF _hod LIKE 'sb_secret%' OR _hod LIKE 'sbp_%' THEN
      RAISE EXCEPTION 'Ve Vaultu pod % leží TAJNÝ klíč. Ten se z databáze posílat nesmí.', _jmeno;
    END IF;

    IF _hod LIKE 'eyJ%' THEN
      -- Legacy JWT: role je čitelná z prostřední části. Base64url → base64,
      -- doplnit odsazení, rozkódovat. Když se to nepovede, NEPOSÍLÁ SE NIC:
      -- neznámé pověření je horší než neodeslaný cron.
      BEGIN
        _telo := split_part(_hod, '.', 2);
        _telo := translate(_telo, '-_', '+/');
        _telo := _telo || repeat('=', (4 - length(_telo) % 4) % 4);
        _telo := convert_from(decode(_telo, 'base64'), 'utf8');
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Hodnota pod % nejde přečíst, neposílám ji.', _jmeno;
      END;
      IF _telo LIKE '%service_role%' THEN
        RAISE EXCEPTION 'Ve Vaultu pod % leží SERVISNÍ klíč. Sem patří anon/publishable.', _jmeno;
      END IF;
    END IF;
  END LOOP;

  -- ---- Slabý token je totéž co žádný ----------------------------------------
  -- Na tomhle tokenu stojí CELÁ admise mailerů: edge funkce je z internetu
  -- dostupná s veřejným publishable klíčem a nemá rate limit. Komentář výš
  -- říká „náhodný token", ale nic to nevynucovalo — prošel by i čtyřznakový.
  IF length(_token) < 32 THEN
    RAISE EXCEPTION 'Token pod % je kratší než 32 znaků. Na něm stojí celá admise, musí být náhodný a dlouhý.', _jmeno_tokenu;
  END IF;

  -- ---- Kam se to vlastně posílá ---------------------------------------------
  -- Bez tohohle pošle jedna špatně zkopírovaná URL ve Vaultu cron token
  -- v otevřené podobě cizímu hostiteli. Změřeno bránou: `http://neni-https…`
  -- se přijalo a požadavek se zařadil. Tvar je schválně úzký — je to vždycky
  -- edge funkce téhož projektu, nic jiného sem nepatří.
  IF _url !~ '^https://[a-z0-9-]+\.supabase\.co/functions/v1/send-emails$' THEN
    RAISE EXCEPTION 'URL pod % nevypadá jako edge funkce send-emails přes https. Nikam to neposílám.', _jmeno_url;
  END IF;

  BEGIN
    -- pg_net je asynchronní: vrací id požadavku, odpověď přistane
    -- v `net._http_response`. Nečekáme na ni, ať job nedrží spojení.
    --
    -- `Authorization` je tu JEN pro platformní bránu (viz hlavička migrace),
    -- `apikey` posílá totéž, protože brána na obojí u různých generací klíčů
    -- reaguje různě. Admisi rozhoduje `x-cron-token`.
    SELECT net.http_post(
             url     := _url,
             headers := jsonb_build_object(
                          'x-cron-token',   _token,
                          'Authorization',  'Bearer ' || _pub,
                          'apikey',         _pub,
                          'Content-Type',   'application/json'),
             body    := '{}'::jsonb,
             timeout_milliseconds := 60000
           ) INTO _id;
  EXCEPTION WHEN OTHERS THEN
    -- ⚠️ Původní chybu NEPOUŠTĚT ven. Postgres k chybě integrity přilepí
    -- „DETAIL: Failing row contains (…)" a v tom řádku je celá hlavička
    -- včetně tokenu — doletělo by to do `cron.job_run_details.return_message`
    -- i do logu. Týž vzor hlídají `prejmenuj_serii` a `create_booking_series`.
    RAISE EXCEPTION 'Frontu e-mailů se nepodařilo odeslat (SQLSTATE %).', SQLSTATE;
  END;

  RETURN _id;
END;
$$;

COMMENT ON FUNCTION public.posli_frontu_emailu(text, text, text) IS
  'Zavolá edge funkci send-emails vyhrazeným tokenem z Vaultu (NE servisním klíčem). Volá ji jen cron; bez tajemství ve Vaultu nedělá nic.';

-- Čte tajemství, takže se k ní z API nesmí dát dosáhnout vůbec.
-- ⚠️ REVOKE musí mířit na NOVOU signaturu (tři parametry), jinak by na starých
-- zůstal výchozí grant pro PUBLIC.
DROP FUNCTION IF EXISTS public.posli_frontu_emailu();
DROP FUNCTION IF EXISTS public.posli_frontu_emailu(text, text);
-- `service_role` schválně TAKY: PostgREST se na servisní klíč přepne do téhle
-- role, takže bez tohohle by funkci šlo spustit přes API kdekoli, kde ten klíč
-- je. Cron ji volá jako `postgres` (SECURITY DEFINER, job vlastní postgres),
-- takže mu to nevadí.
REVOKE ALL ON FUNCTION public.posli_frontu_emailu(text, text, text) FROM public, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Naplánování
-- -----------------------------------------------------------------------------
-- `cron.schedule` je podle jména upsert (ověřeno: dvě volání = jeden jobid),
-- takže opakované spuštění migrace job nezduplikuje.
SELECT cron.schedule(
  'send-emails-kazdych-5-minut',
  '*/5 * * * *',
  $job$SELECT public.posli_frontu_emailu()$job$
);

-- Odpovědi pg_netu obsahují těla našich odpovědí a drží se ~6 h v tabulce
-- bez RLS. Nic z nich nečteme, tak ať tam neleží déle, než je nutné.
--
-- ⚠️ ÚSPĚCH SE MAŽE HNED, CHYBA ZŮSTÁVÁ, DOKUD JI NESMAŽE SÁM pg_net.
-- Brána code review 12. 9. 2026 upozornila, že selhání cronu je jinak ÚPLNĚ
-- TICHÉ: když se `EMAIL_CRON_TOKEN` rozejde s Vaultem, vrací funkce 401
-- každých 5 minut donekonečna, `posli_frontu_emailu` odpověď nečte,
-- `cron.job_run_details` vidí úspěch (požadavek se přece zařadil) — a jediná
-- stopa se mazala dřív, než se na ni kdokoli podíval.
--
-- ⚠️ DRUHÁ OPRAVA: chvíli tu vedle stál ještě job, který měl chyby držet DEN.
-- Bezpečnostní brána změřila, že neměl co dělat: `pg_net.ttl = 6 hours`,
-- takže si pg_net svoje odpovědi maže sám a déle je nikdo neudrží. Job tedy
-- nic nedržel a jen dodával falešnou jistotu. Reálné okno na chybu je 6 hodin
-- (proti 15 minutám předtím) a je to vidět z hodnoty `pg_net.ttl`, ne z názvu
-- jobu, který by sliboval víc.
--
-- Kde se na to podívat:
--   select created, status_code, content from net._http_response
--    where status_code is distinct from 200 order by created desc limit 20;
SELECT cron.schedule(
  'uklid-odpovedi-pg-net',
  '*/15 * * * *',
  $job$DELETE FROM net._http_response
        WHERE created < now() - interval '15 minutes'
          AND status_code BETWEEN 200 AND 299$job$
);

-- Historie běhů cronu: pg_cron ji nemaže sám a při čtyřech jobech naroste
-- řádově o statisíce řádků ročně. Držíme měsíc, což pokryje i zpětné pátrání.
SELECT cron.schedule(
  'uklid-historie-cronu',
  '52 3 * * *',
  $job$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '30 days'$job$
);

-- Retence fronty e-mailů. `email_outbox` je provozní fronta, ne obchodní
-- záznam — co se stalo, zůstává v `notifications`, kterých se tohle netýká.
-- Bez úklidu rostla donekonečna a strop by pak řadil desetitisíce dávno
-- odeslaných řádků (změřeno bránou migrací: řazení na disk).
-- Devadesát dní je s rezervou nad jakoukoli reklamaci „mně nic nepřišlo".
SELECT cron.schedule(
  'uklid-fronty-emailu',
  '41 3 * * *',
  $job$DELETE FROM public.email_outbox
        WHERE status IN ('sent', 'failed', 'skipped')
          AND COALESCE(sent_at, claimed_at, created_at) < now() - interval '90 days'$job$
);

-- -----------------------------------------------------------------------------
-- Sebekontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _r record; _src text;
BEGIN
  SELECT schedule, active, command INTO _r FROM cron.job WHERE jobname = 'send-emails-kazdych-5-minut';
  IF _r IS NULL THEN RAISE EXCEPTION 'Job na vyprazdňování fronty nevznikl.'; END IF;
  IF _r.schedule <> '*/5 * * * *' THEN RAISE EXCEPTION 'Job má jiný interval: %', _r.schedule; END IF;
  IF NOT _r.active THEN RAISE EXCEPTION 'Job je naplánovaný, ale neaktivní.'; END IF;
  IF _r.command NOT LIKE '%posli_frontu_emailu%' THEN RAISE EXCEPTION 'Job volá něco jiného: %', _r.command; END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'uklid-odpovedi-pg-net') THEN
    RAISE EXCEPTION 'Úklid odpovědí pg_net nevznikl.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'uklid-historie-cronu') THEN
    RAISE EXCEPTION 'Úklid historie cronu nevznikl, cron.job_run_details poroste donekonečna.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'uklid-fronty-emailu') THEN
    RAISE EXCEPTION 'Retence fronty e-mailů nevznikla.';
  END IF;
  -- Úspěch se maže po 15 minutách, chyba se musí držet dýl.
  IF (SELECT command FROM cron.job WHERE jobname = 'uklid-odpovedi-pg-net')
     NOT LIKE '%status_code BETWEEN 200 AND 299%' THEN
    RAISE EXCEPTION 'Úklid maže i chybové odpovědi, selhání cronu by nebylo vidět.';
  END IF;

  IF has_function_privilege('authenticated', 'public.posli_frontu_emailu(text, text, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.posli_frontu_emailu(text, text, text)', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.posli_frontu_emailu(text, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'posli_frontu_emailu je dosažitelné z API.';
  END IF;

  -- Servisní klíč se z databáze posílat NESMÍ. Dřív to hlídal zákaz hlavičky
  -- `Authorization` — ta ale musí odcházet kvůli platformní bráně, takže tvar
  -- hlavičky už nic neříká. Hlídá se to, o co doopravdy jde: odchozí pověření
  -- se bere z Vaultu, ne z literálu v kódu, a před odesláním se kontroluje.
  SELECT prosrc INTO _src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'posli_frontu_emailu';
  -- ⚠️ `LIKE '%sb_secret_%'` tu NEFUNGUJE: v LIKE je `_` zástupný znak pro
  -- libovolný znak, takže vzor sedne i na `sb_secret%` v kontrole výš a migrace
  -- si sama vytkne pověření, které nikde není. Regulární výraz bere `_` doslova.
  IF _src ~ 'sb_secret_[A-Za-z0-9]{5,}' OR _src ~ 'eyJ[A-Za-z0-9_-]{10,}' THEN
    RAISE EXCEPTION 'V těle funkce je zadrátované pověření. Tajemství patří do Vaultu.';
  END IF;
  IF _src NOT LIKE '%x-cron-token%' THEN
    RAISE EXCEPTION 'Funkce neposílá x-cron-token — pak by o vpuštění rozhodoval publishable klíč.';
  END IF;
  IF _src NOT LIKE '%service_role%' THEN
    RAISE EXCEPTION 'Zmizela kontrola, že se do fronty pg_net nedostane servisní klíč.';
  END IF;
  IF _src NOT LIKE '%FOR _i IN 1..2%' THEN
    RAISE EXCEPTION 'Kontrola tajnosti neběží nad OBĚMA hodnotami (token i klíč).';
  END IF;
  IF _src NOT LIKE '%length(_token) < 32%' THEN
    RAISE EXCEPTION 'Nevynucuje se délka cron tokenu.';
  END IF;
  IF _src NOT LIKE '%functions/v1/send-emails$%' THEN
    RAISE EXCEPTION 'Nekontroluje se cílová URL, token může odejít cizímu hostiteli.';
  END IF;

  RAISE NOTICE 'Cron na frontu e-mailů je naplánovaný (5 min) a posílá vyhrazený token, ne servisní klíč.';
END $kontrola$;
