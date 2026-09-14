-- =============================================================================
-- Adresa portálu v notifikačních e-mailech: z nastavení, ne z kódu
-- =============================================================================
-- CO SE MĚNÍ:
--   1) `settings` dostává sloupec `web_base_url` s novou adresou portálu
--      https://portal.curlingpromoostrava.cz (dosud: netlify.app odkaz)
--   2) `email_sablona()` ho čte místo natvrdo zadané konstanty
-- Žádná tabulka se neruší, žádná data se nemažou.
--
-- PROČ: `email_sablona` měla adresu jako `constant text` přímo v těle. Každá
-- změna domény tak znamenala migraci, která přepisuje CELÉ tělo funkce — a to
-- je v tomhle repu doložená cesta ke ztrátě kusu funkce (pravidlo 7 v CLAUDE.md,
-- commit 87b1f78). Adresa je provozní údaj, ne logika; patří do `settings`
-- vedle otevírací doby.
--
-- KROK 0 (změřeno na produkci 14. 9. 2026):
--   * `email_sablona` je JEDINÉ místo, kde adresa v databázi žije
--   * volá ji JEDINÁ funkce — `notify_user` (SECURITY DEFINER, běží jako
--     `postgres`, takže na `settings` dosáhne i přes RLS)
--   * `email_sablona` NENÍ grantovaná `authenticated` (jen postgres a
--     service_role), takže se čtení `settings` nikomu novému neotevírá.
--     A i kdyby jí někdo EXECUTE přidal, NEUNIKNE tudy nic: funkce je
--     SECURITY INVOKER (`prosecdef = f`, migrace to nemění), takže by běžela
--     pod volajícím a narazila na chybějící sloupcový SELECT. Změřeno:
--     SQLSTATE 42501, hláška `permission denied for table settings` — tedy
--     TABULKOVÁ, ne sloupcová; Postgres to ohlásí o patro výš, než kde je
--     příčina. Selhává tedy ZAVŘENĚ. Kdyby byla DEFINER, bylo by to obráceně —
--     proto se z ní DEFINER dělat nesmí (hlídá tvrzení 6b v testu).
--   * funkce není použitá v žádném indexu ani generovaném sloupci, takže
--     změna IMMUTABLE → STABLE nic nerozbíjí. Ověřeno nad `pg_depend`, ne nad
--     `pg_index` — generovaný sloupec se z `pg_index` zjistit NEDÁ, ten zná jen
--     indexy. (Dřívější znění téhle poznámky citovalo `pg_index`; závěr platil,
--     metoda ne.) Naměřeno 0 závislostí.
--   * `email_sablona` je zároveň jediný objekt ve schématu, kde stará adresa
--     je (prohledány prosrc funkcí, definice pohledů i DEFAULTy)
--
-- CO SE ZPĚTNĚ NEPŘEPISUJE: `email_outbox.body` už odeslaných e-mailů. Je jich
-- na produkci 6 a všechny mají `status='sent'` (ověřeno 14. 9. 2026, ve frontě
-- nečeká nic) — jsou to záznamy o tom, co doopravdy odešlo, ne šablony, takže
-- přepsat by je znamenalo zfalšovat auditní stopu. Kdyby ve frontě něco viselo,
-- musí se to řešit zvlášť: odeslalo by se to se starým odkazem.
--
-- PROČ STABLE A NE IMMUTABLE: funkce nově čte tabulku. IMMUTABLE by byla lež
-- plánovači — směl by si výsledek předpočítat a držet napříč transakcemi,
-- takže by změna adresy nemusela být vidět. STABLE je nejpřísnější správná
-- volba (v rámci jednoho dotazu se nemění).
--
-- PROČ CHECK NA TVAR: tělo skládá odkaz jako `_web || _cil`. Kdyby v adrese
-- byla cesta, koncové lomítko nebo dokonce `http://`, vznikl by rozbitý nebo
-- nešifrovaný odkaz v e-mailu z naší ověřené domény. CHECK proto pouští jen
-- `https://` + hostname, nic za ním. Je to tatáž obrana do hloubky jako
-- kontrola `_link` uvnitř funkce, jen z druhé strany — ta hlídá CESTU, tenhle
-- CHECK hlídá ZÁKLAD. Obě je potřeba, každá zavírá jinou půlku odkazu.
--
-- CO TAHLE MIGRACE NEDĚLÁ: nepřidává políčko do Nastavení v aplikaci. Adresa
-- se dnes mění příkazem
--     UPDATE public.settings SET web_base_url = 'https://…' WHERE singleton;
--
-- Editor v UI je samostatný ticket, a není to lenost — chybí k němu ČTECÍ
-- právo, což je změna přístupů a patří jí vlastní bezpečnostní brána.
--
-- JAK JE `settings` ZAJIŠTĚNÁ (změřeno na produkci 14. 9. 2026, nehádáno):
--   • ZÁPIS  drží tabulkový grant `authenticated=awm` (INSERT, UPDATE, MAINTAIN)
--            a nad ním RLS politika `settings_update_admin`
--            (USING i WITH CHECK `has_role(auth.uid(),'admin')`).
--   • ČTENÍ  tabulkový SELECT grant NENÍ; SELECT je udělený SLOUPCOVĚ, a to jen
--            na sedmi sloupcích (id, singleton, opening_hours, updated_by,
--            updated_at, email_notifications_enabled, email_max_za_hodinu).
--            Zbylých pět sloupců jde zapsat, ale ne přečíst: čtyři cenové
--            (club_default_rate, commercial_default_rate, training_rate,
--            tournament_rate) kvůli A2b, a `ledar_jmeno`, které cena není
--            a s A2b nesouvisí — SELECT grant k němu prostě nikdy nepřibyl.
--
-- Nový `web_base_url` tedy UPDATE dědí z tabulkového grantu (a chrání ho RLS,
-- takže ho stejně změní jen admin — přesně to scénář 5d v testu měří reálným
-- tokenem), ale SELECT nemá VĚDOMĚ ŽÁDNÝ. Formulář v Nastavení by proto
-- adresu nepřečetl, dokud nepřibude `GRANT SELECT (web_base_url) TO authenticated`
-- a dokud se nedoplní do pohledu `settings_public` (frontend čte odtamtud,
-- ne z tabulky). Obojí je samostatná změna přístupů.
--
-- ⚠️ „SELECT nemá VĚDOMĚ ŽÁDNÝ" platí o TABULCE `settings`, ne o hodnotě.
-- `write_audit_log` ukládá `to_jsonb(NEW)`, takže po každém UPDATE je adresa
-- v plném znění v `audit_log`. Díra to není — `audit_log` má sice tabulkový
-- SELECT pro `authenticated`, ale RLS `has_role(…,'admin')`, takže se k němu
-- dostane jen admin (a ten adresu stejně sám mění). Je to naopak jediná stopa,
-- podle které jde změnu adresy dohledat.
--
-- ⚠️ Nesnaž se tohle ověřit introspekcí na lokální replice.
-- `scripts/testovaci-replika.sh` granty `settings` NEPŘENÁŠÍ VĚRNĚ — produkční
-- tabulkový grant rozpustí do per-sloupcových, takže nově přidaný sloupec tam
-- UPDATE nezdědí a `has_column_privilege` ukáže pravý opak produkce.
--
-- VRATNOST:
--   1) `email_sablona` zpět ze ŽIVÉHO schématu přes `pg_get_functiondef`,
--      NE z téhle migrace — ať nezmizí, co do ní vloží migrace mezitím;
--      v původní podobě je IMMUTABLE a má
--          _web constant text := 'https://curling-ostrava-system.netlify.app';
--      Ta adresa je tu vypsaná schválně: migrace maže její JEDINOU kopii
--      v živém schématu, takže jinak by ji revertující člověk musel lovit
--      v gitu. (Nechat v konstantě rovnou NOVOU adresu je ostatně taky
--      v pořádku — revert se dělá kvůli čtení z tabulky, ne kvůli doméně.)
--   2) ALTER TABLE public.settings DROP COLUMN web_base_url;
--      (CHECK `settings_web_base_url_tvar` padá SPOLU se sloupcem, rušit ho
--      zvlášť není potřeba — a po dropu sloupce by to stejně selhalo)
--
-- ⚠️ POŘADÍ SI DATABÁZE NEVYNUTÍ, HLÍDÁ HO JEN TENHLE KOMENTÁŘ. Napoprvé tu
-- stálo, že „dokud funkce sloupec čte, DROP COLUMN selže". Není to pravda,
-- změřeno: těla plpgsql funkcí se v `pg_depend` nesledují, takže
--     ALTER TABLE public.settings DROP COLUMN web_base_url;   → ALTER TABLE (projde)
--     SELECT * FROM email_sablona(…);                         → ERROR: column
--                                                                s.web_base_url
--                                                                does not exist
-- Revert v opačném pořadí tedy projde TIŠE a rozbije se až za běhu. A protože
-- řetěz je `email_sablona` ← `notify_user` ← trigger, nespadne e-mail, ale celé
-- `create_booking` — rezervace by se přestaly dát zakládat. Je to přesně ta
-- havárie, kterou hlídá scénář 3 v `supabase/tests/adresa_portalu_test.sql`.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0) Strop na čekání ve frontě zámků
-- -----------------------------------------------------------------------------
-- Obojí DDL níž bere `AccessExclusiveLock` na `settings`. Samotné držení je
-- zanedbatelné (změřeno: ADD COLUMN 1,6 ms, ADD CONSTRAINT 1,3 ms, žádný přepis
-- tabulky — `relfilenode` se nemění a `atthasmissing = t`), ale ČEKÁNÍ na zámek
-- zanedbatelné být nemusí: kdyby zrovna běžela dlouhá transakce nad `settings`,
-- migrace se zařadí za ni a všechno, co přijde po ní, se zařadí za migraci.
-- `settings` čte kdejaká rezervační cesta, takže by se tím zastavil provoz.
--
-- S timeoutem místo toho migrace rychle SELŽE a pustí se znovu, až bude klid.
--
-- ⚠️ `SET`, NE `SET LOCAL` — A NENÍ TO PŘEHLÉDNUTÍ. Napoprvé tu stálo
-- `SET LOCAL` s komentářem, že `supabase db push` migraci do transakce balí.
-- NEBALÍ. Vyšlo to najevo při ostrém nasazení 14. 9. 2026, kdy push vypsal:
--     WARNING (25P01): SET LOCAL can only be used in transaction blocks
-- `SET LOCAL` tedy neplatil vůbec a timeout nehlídal nic — tiše, protože je to
-- warning, ne chyba. Bez `LOCAL` platí pro zbytek session, což je přesně ta
-- session, která pouští tenhle soubor.
--
-- Plyne z toho ale i něco důležitějšího, co si zaslouží vlastní pozornost:
-- MIGRACE NENÍ ATOMICKÁ. Když selže uprostřed, zůstane půlka aplikovaná
-- a `schema_migrations` o ní neví. Tahle migrace to snese, protože všechny tři
-- kroky jsou idempotentní (`ADD COLUMN IF NOT EXISTS`, `DROP CONSTRAINT
-- IF EXISTS` + `ADD`, `CREATE OR REPLACE FUNCTION`), takže se dá prostě pustit
-- znovu. Kdo sem přidá krok, který idempotentní není, ať si to uvědomí —
-- nebo si soubor obalí vlastním `BEGIN`/`COMMIT`.
SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1) Sloupec s adresou portálu
-- -----------------------------------------------------------------------------
-- DEFAULT je nová ostrá adresa, takže stávající (jediný) řádek `settings` ji
-- dostane rovnou a nic se nemusí doplňovat druhým příkazem.
ALTER TABLE public.settings
  ADD COLUMN IF NOT EXISTS web_base_url text NOT NULL
  DEFAULT 'https://portal.curlingpromoostrava.cz';

-- CHECK hlídá TVAR I IDENTITU. Tvar: jen `https://` + hostname, žádná cesta,
-- žádné koncové lomítko, žádný port, žádné `http://`. Identita: hostname musí
-- KONČIT na `curlingpromoostrava.cz` (samotná doména nebo libovolná subdoména).
--
-- PROČ ALLOWLIST A NE JEN TVAR (nález bezpečnostní brány, rozhodnutí Tomáše
-- 14. 9. 2026): `authenticated` dědí na `web_base_url` tabulkové UPDATE
-- a politika `settings_update_admin` ho pouští adminovi. Admin — nebo kdokoli
-- s ukradenou admin session — tedy adresu změnit může. Kdyby CHECK hlídal jen
-- tvar, prošlo by `https://curling-phishing.example.com` i
-- `https://portal.curlingpromoostrava.cz.zly.cz` a odkazy ve VŠECH notifikačních
-- e-mailech by vedly na phishing — z naší ověřené domény, se správným SPF/DKIM.
-- Přitěžuje, že admin sloupec přepsat může, ale PŘEČÍST ne (nemá sloupcový
-- SELECT), takže by tu změnu v aplikaci neviděl nikdo; jediná stopa je
-- `audit_log` přes `trg_settings_audit`.
--
-- ⚠️ CO ALLOWLIST NEDOKÁŽE, ať se mu nevěří víc, než umí. Brání phishingu
-- MIMO naši doménu. NA naší doméně ne — a není to teorie, je to změřeno
-- (bezpečnostní brána, 14. 9. 2026):
--     dig +short '*.curlingpromoostrava.cz' A          → 37.9.175.213
--     nahodny-nesmysl-9z8q.curlingpromoostrava.cz      → 37.9.175.213
--     curl https://nahodny-nesmysl-9z8q.…/             → 404, certifikát PLATNÝ
-- V zóně je tedy WILDCARD A záznam a wildcard TLS. Každá subdoména se otevře
-- se zeleným zámkem a bez varování; dnes na ní je 404 na hostingu klienta,
-- takže by to byl rozbitý odkaz, ne phishing.
--
-- Reálným kanálem se to stane, až se nějaká subdoména DELEGUJE TŘETÍ STRANĚ
-- (`blog.`, `status.`, `shop.` → SaaS) nebo vznikne visící CNAME — klasický
-- subdomain takeover, jen zesílený o to, že se přes něj dají přesměrovat odkazy
-- ve VŠECH e-mailech systému. DELEGACE SUBDOMÉNY `curlingpromoostrava.cz` JE
-- PROTO ZÁSAH DO TÉHLE POJISTKY, ne jen DNS operace — kdo ji udělá, ať zúží
-- allowlist na konkrétní hosty:
--     web_base_url IN ('https://curlingpromoostrava.cz',
--                      'https://portal.curlingpromoostrava.cz')
-- Za cenu toho, že nová subdoména pak potřebuje migraci.
--
-- CO TO STOJÍ: změna domény teď potřebuje migraci, kdežto změna subdomény ne.
-- Je to vědomý ústupek ze zadání „adresa ať žije v nastavení": v nastavení dál
-- žije, jen se nesmí utrhnout z naší domény. Hodnota se mění jedním UPDATEm,
-- allowlist se mění jednou za život firmy.
--
-- Změřeno (scénář 4 v testu, protipóly 4l–4n): PROJDE holá
-- `curlingpromoostrava.cz`, `novy-portal.curlingpromoostrava.cz`
-- a víceúrovňová `a.b.curlingpromoostrava.cz`. NEPROJDE
-- `portal.curlingpromoostrava.cz.zly.cz`, `zlycurlingpromoostrava.cz`,
-- `portal-curlingpromoostrava.cz`, `curling-phishing.example.com`, punycode
-- homograf, port, cesta, koncové lomítko, mezera, http:// a délka přes 200.
--
-- A silněji než seznamem případů — bezpečnostní brána regex prohnala BRUTE
-- FORCEM přes všech 65 535 codepointů (mimo surrogáty) a naměřila:
--   * povolených znaků je právě 38, všechny ASCII z `[-.0-9a-z]`
--   * nad U+007F NEPROJDE ANI JEDEN, navzdory kolaci `en_US.UTF-8`
--     (takže ani IDN, homografy, ani velká písmena)
--   * ZA doménou neprojde žádný znak — ani LF, CR, TAB, VT, FF. V Postgres ARE
--     je `$` striktní konec ŘETĚZCE, ne jako v PCRE „i před koncovým \n".
--   * `%00` do textového sloupce v UTF8 vůbec nejde vložit
--   * ReDoS není: čtyři patologické vstupy 80–100 kB celkem za 2 ms
--
-- STROP DÉLKY 200 ZNAKŮ je z téhož nálezu. Samotný regex délku nehlídá, takže
-- `'https://' || repeat('a-',50000) || 'a.curlingpromoostrava.cz'` (100 032
-- znaků) jím projde. Odkaz to nepřesměruje a zapsat to smí jen admin, ale
-- nafouklo by to tělo každého e-mailu. DNS stejně dovolí 253 znaků na host,
-- takže 200 je pohodlně nad čímkoli reálným a pod čímkoli absurdním.
-- Obchvat mimo regex taky ne: na `settings` nejsou žádná RULES, žádná z 19
-- funkcí zmiňujících `settings` do `web_base_url` nezapisuje, a tabulkový
-- grant sice nese `a` (INSERT), ale INSERT politika neexistuje, takže ho RLS
-- zavře.
-- DROP + ADD, NE `IF NOT EXISTS`. Guard na JMÉNO constraintu je past: kdyby
-- na dané databázi už `settings_web_base_url_tvar` existoval ve starší, slabší
-- podobě (a to se stane všude, kde běžel dřívější draft téhle migrace — demo,
-- kdejaká replika), migrace by „proběhla úspěšně" a nechala tam tu starou
-- definici. Bez hlášky, bez chyby. Změřeno: po ručním vrácení constraintu do
-- podoby bez `length(...) <= 200` migrace doběhla a strop se NEDOPLNIL.
-- (Nález brány pro migrace.)
--
-- Drop a znovuvytvoření je tu bezpečné: na CHECK constraintu nic nezávisí
-- a `settings` má jediný řádek, takže revalidace je okamžitá. Výsledkem je
-- idempotence, která konverguje ke SPRÁVNÉ definici, ne jen k existenci jména.
ALTER TABLE public.settings DROP CONSTRAINT IF EXISTS settings_web_base_url_tvar;
ALTER TABLE public.settings
  ADD CONSTRAINT settings_web_base_url_tvar
  CHECK (web_base_url ~ '^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*curlingpromoostrava\.cz$'
         AND length(web_base_url) <= 200);

COMMENT ON COLUMN public.settings.web_base_url IS
  'Základní adresa portálu pro odkazy v notifikačních e-mailech (bez koncového '
  'lomítka a bez cesty). Čte ji public.email_sablona().';

-- -----------------------------------------------------------------------------
-- 2) Šablona e-mailu čte adresu z nastavení
-- -----------------------------------------------------------------------------
-- Tělo níž je vygenerované z `pg_get_functiondef` živého schématu a vložen do
-- něj JEN tenhle zásah (pravidlo 7 v CLAUDE.md).
--
-- OVĚŘENO DIFFEM proti produkční definici — čtyři úseky, všechny zamýšlené:
--   1) IMMUTABLE → STABLE
--   2) `_web constant text := '<netlify adresa>'` → `_web text;`
--   3) nový blok, který adresu načte ze `settings` (a fallback)
--   4) přeformulovaný komentář u `_cil` (ilustroval útok na staré adrese)
-- Nic jiného se nemění a nic z těla nezmizelo. Kontrolní postup pro příště:
--     SELECT pg_get_functiondef(p.oid) FROM pg_proc p
--       JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname='public' AND p.proname='email_sablona' AND p.prokind='f';
-- a výstup z produkce porovnat s výstupem po migraci. Pozor: `pg_get_functiondef`
-- si signaturu i dollar tag normalizuje po svém (`$function$`), takže proti
-- TEXTU téhle migrace vyjdou rozdíly i tam, kde se věcně nic nestalo — porovnávej
-- vždycky výstup proti výstupu, ne výstup proti souboru.
CREATE OR REPLACE FUNCTION public.email_sablona(_type text, _title text, _body text, _link text)
 RETURNS TABLE(subject text, body text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  _web    text;
  _odkaz  text;
  _cil    text;
  _uvod   text;
  _zaver  text;
BEGIN
  -- ZÁKLADNÍ ADRESA PORTÁLU SE BERE Z NASTAVENÍ, NE Z KÓDU.
  -- Do 14. 9. 2026 tu byl natvrdo netlify.app odkaz, takže každá změna domény
  -- znamenala migraci, která přepisuje celé tělo funkce.
  --
  -- COALESCE není zbytečný: kdyby řádek `settings` chyběl (prázdná databáze,
  -- rozjetá migrace), `_web` by zůstal NULL a celé tělo e-mailu by vyšlo NULL.
  -- `email_outbox.body` je NOT NULL, takže by výjimka letěla z TRIGGERU — tedy
  -- neshodila by e-mail, ale celé `create_booking`. Táž úvaha jako u `_uvod`.
  SELECT s.web_base_url INTO _web FROM public.settings s WHERE s.singleton LIMIT 1;
  -- Poslední záchrana, když `settings` řádek nemá. Adresa je tu ZÁMĚRNĚ natvrdo
  -- podruhé — MĚNIT JI SPOLU S `DEFAULT` SLOUPCE výš, jinak se po příští změně
  -- domény rozejdou a rozdíl se projeví jen v té jedné divné situaci.
  _web := COALESCE(NULLIF(btrim(COALESCE(_web, '')), ''), 'https://portal.curlingpromoostrava.cz');

  -- Odkaz musí být cesta na našem webu, ne cokoli. Bez požadavku na úvodní `/`
  -- (a na to, že další znak není další lomítko) by `_link` tvaru
  -- '.zly-web.cz/x' vyrobil „https://portal.curlingpromoostrava.cz.zly-web.cz/x",
  -- tedy podvrženou doménu v e-mailu z NAŠÍ adresy. Dnes všichni volající
  -- předávají literál '/calendar', takže je to obrana do hloubky. NEODSTRAŇOVAT.
  _cil := COALESCE(NULLIF(btrim(COALESCE(_link, '')), ''), '/calendar');
  IF _cil !~ '^/[^/]' THEN
    _cil := '/calendar';
  END IF;
  _odkaz := _web || _cil;

  subject := CASE _type
    WHEN 'reservation_pending'          THEN 'Rezervace čeká na potvrzení správce klubu'
    WHEN 'reservation_needs_approval'   THEN 'Máte rezervaci k potvrzení'
    WHEN 'reservation_approved'         THEN 'Rezervace je potvrzena'
    WHEN 'reservation_cancelled'        THEN 'Rezervace byla zrušena'
    WHEN 'reservation_series_cancelled' THEN 'Série rezervací byla zrušena'
    WHEN 'reservation_changed'          THEN 'Rezervace byla upravena'
    WHEN 'reservation_overridden'       THEN 'Rezervace byla zrušena kvůli jiné akci'
    ELSE NULL
  END;

  IF subject IS NULL THEN
    RETURN;
  END IF;

  _zaver := CASE _type
    WHEN 'reservation_pending'          THEN 'Rezervace zatím neplatí. Platit začne, jakmile ji správce klubu potvrdí.'
    WHEN 'reservation_needs_approval'   THEN 'Potvrdit nebo zrušit ji můžete v kalendáři.'
    WHEN 'reservation_approved'         THEN 'Termín je tím závazně obsazený.'
    WHEN 'reservation_cancelled'        THEN 'Termín je znovu volný. Náhradní si můžete vybrat v kalendáři.'
    WHEN 'reservation_series_cancelled' THEN 'Termíny jsou znovu volné. Náhradní si můžete vybrat v kalendáři.'
    WHEN 'reservation_changed'          THEN 'Nový termín si prosím zkontrolujte v kalendáři.'
    WHEN 'reservation_overridden'       THEN 'Omlouváme se. Náhradní termín si můžete vybrat v kalendáři.'
  END;

  -- ⚠️ Do `_body` vstupuje `profiles.full_name` autora a název klubu, tedy
  -- text, který si KAŽDÝ PŘIHLÁŠENÝ nastavuje sám a bez omezení. Beze změny
  -- by si člen klubu mohl do jména dát prázdný řádek a vlastní odstavec, a ten
  -- by zástupcům klubu dorazil z ověřené domény haly, se správným SPF/DKIM
  -- a pod naším podpisem. Proto jednořádkový text s pevným stropem.
  -- `_title` na konci COALESCE je proto, aby tělo nikdy nevyšlo NULL:
  -- `email_outbox.body` je NOT NULL a výjimka by letěla z TRIGGERU, takže by
  -- neshodila e-mail, ale celé `create_booking`. NEODSTRAŇOVAT.
  _uvod := left(
    regexp_replace(
      COALESCE(NULLIF(btrim(COALESCE(_body, '')), ''), _title, ''),
      '[[:cntrl:]]+', ' ', 'g'),
    500);

  body :=
    'Dobrý den,' || E'\n\n' ||
    _uvod || E'\n\n' ||
    _zaver || E'\n\n' ||
    'Kalendář haly: ' || _odkaz || E'\n\n' ||
    'Curling Promo Ostrava' || E'\n' ||
    'Tato zpráva je automatická, neodpovídejte na ni.';

  RETURN NEXT;
END;
$function$

;
