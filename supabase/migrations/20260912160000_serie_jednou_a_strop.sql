-- =============================================================================
-- Dvě pojistky PŘED zapnutím e-mailů: série jako jedna zpráva + strop na hodinu
-- =============================================================================
-- Obojí je podmínka pro to, aby se `email_notifications_enabled` dalo vůbec
-- zapnout. Dokud byly e-maily vypnuté, byly to jen řádky navíc ve zvonku.
-- Po zapnutí je z toho odchozí pošta s cenou a s reputací domény.
--
-- KROK 0 (12. 9. 2026, ZMĚŘENO na lokální replice produkčního schématu):
--
--   série 8 tréninků, založení  → 2 e-maily   (autor + správce)   ✔ správně
--   série 8 tréninků, zrušení   → 8 e-mailů   JEDNOMU člověku     ✘ vada
--
-- PROČ: `notify_reservation_changed` dedupuje přes transakční značku klíčovanou
-- `COALESCE(event_id, series_id, id)`. Jenže `create_booking` zakládá KAŽDÉMU
-- termínu série vlastní `event_id`, takže se značka termín od termínu lišila
-- a neumlčela nic. Série smí mít až 200 termínů, tedy 200 e-mailů za jedno
-- kliknutí. Dedup u ZALOŽENÍ série fungoval, protože ten se dívá na sourozence
-- v tabulce (`EXISTS … r.series_id = NEW.series_id`), ne na značku.
--
-- Hromadně mění termíny série jediná funkce, `cancel_booking` se
-- `p_scope = 'series'` (ověřeno dotazem na živé schéma: ostatní funkce, které
-- sahají na `reservations` a znají `series_id`, jsou `create_booking`
-- a `prejmenuj_serii`, a ta mění `events.title`, na což trigger nevisí).
--
-- CO SE TU DĚLÁ:
--   1) Značka preferuje `series_id` → zrušená série je JEDNA zpráva.
--   2) Ta zpráva popisuje SÉRII (počet termínů a rozsah), ne jeden termín.
--      Bez toho by klub dostal „vaše rezervace 8. 1. byla zrušena" a nevěděl,
--      že přišel o všech osm.
--   3) Strop odchozí pošty na uživatele a hodinu, nastavitelný adminem.
--      Brzdí ODESÍLÁNÍ, nezahazuje zprávy (viz oddíl 2, je tam proč).
--
-- PROČ STROP NAVÍC: dedup řeší jednu akci. Neřeší člověka, který si naskriptuje
-- N samostatných rezervací — každá je jiná akce, takže projdou všechny.
-- Vyčerpaná kvóta Resendu a spálená reputace domény znamenají, že přestanou
-- chodit i legitimní notifikace CELÉ hale.
--
-- MUTAČNÍ ZKOUŠKA: viz `supabase/tests/serie_a_strop_test.sql`, hlavička.
--
-- VRATNOST, A ZÁLEŽÍ NA POŘADÍ:
--   1) vrátit předchozí těla `email_outbox_prevzit`, `notify_reservation_changed`
--      A `email_sablona` z historie migrací (na `email_sablona` se snadno
--      zapomene, mění ji oddíl 4 níž),
--   2) TEPRVE POTOM smět sáhnout na sloupec
--      (`ALTER TABLE public.settings DROP COLUMN email_max_za_hodinu;`).
--
--   ⚠️ Opačné pořadí je výpadek. Brána migrací to 12. 9. 2026 pustila naostro:
--   po samotném DROP COLUMN padá `email_outbox_prevzit` na
--   `column "email_max_za_hodinu" does not exist` a fronta se přestane
--   vyprazdňovat. V PRVNÍ verzi téhle migrace byl strop v `notify_user`, kde
--   by týž DROP shodil rovnou ZAKLÁDÁNÍ REZERVACÍ (trigger → create_booking).
--   To je jeden z důvodů, proč strop skončil na straně odesílání.
--   Nejlíp ale na sloupec nesahat vůbec: sám o sobě nepřekáží.
--
-- ⚠️ `email_notifications_enabled` se tímhle NEZAPÍNÁ. Zůstává na adminovi.
-- =============================================================================

SET lock_timeout = '3s';

-- -----------------------------------------------------------------------------
-- 1) Nastavitelný strop (výchozí 20 / uživatel / hodina)
-- -----------------------------------------------------------------------------
-- Sto, ne dvacet. Dvacet jsem odhadl jako „s rezervou nad běžný provoz"
-- s komentářem, že tolik jich zástupce rušného klubu za hodinu nedostane.
-- Brána migrací to 12. 9. 2026 změřila a odhad neplatí: nápor na začátku
-- sezóny (25 samostatných rezervací jednoho člena) zástupci vyrobí 25 zpráv
-- ke schválení a pět by se jich odsunulo o hodinu. Sto pořád spolehlivě
-- zastaví naskriptovaný nápor (ten dělá tisíce), ale do běžné špičky nezasáhne.
--
-- Číslo je vědomě v `settings`, ať ho jde změnit bez migrace — kolik je
-- správně, se pozná až z provozu.
ALTER TABLE public.settings
  ADD COLUMN IF NOT EXISTS email_max_za_hodinu int NOT NULL DEFAULT 100;

ALTER TABLE public.settings DROP CONSTRAINT IF EXISTS settings_email_max_za_hodinu_check;
ALTER TABLE public.settings ADD CONSTRAINT settings_email_max_za_hodinu_check
  CHECK (email_max_za_hodinu BETWEEN 1 AND 1000);

COMMENT ON COLUMN public.settings.email_max_za_hodinu IS
  'Nejvýš tolik e-mailů jednomu uživateli za klouzavou hodinu. Přes strop se odeslání ODLOŽÍ (řádek zůstane `pending`), nic se nezahazuje.';

-- `settings` má SELECT grantovaný PO SLOUPCÍCH (sazby nesmí vidět neadmin),
-- takže nový sloupec by jinak byl zapisovatelný, ale nečitelný: admin by strop
-- nastavil a nepřečetl si ho zpátky. UPDATE je tabulkový, ten nový sloupec
-- pokrývá sám, a zápis stejně hlídá RLS politika `settings_update_admin`.
--
-- Čitelnost pro všechny přihlášené je v pořádku: je to provozní práh, ne cena.
-- Brána `cenik_viditelnost_test.sql` hlídá sazby a tabulkový grant, tohle
-- ani jedno není (ověřeno spuštěním).
GRANT SELECT (email_max_za_hodinu) ON public.settings TO authenticated;

-- Strop se ptá „kolik už tomuhle člověku za poslední hodinu odešlo". Zní to
-- jako index na `(user_id, claimed_at)`, ale to je past: dotaz FILTRUJE podle
-- `claimed_at` a seskupuje až podle `user_id`. S `user_id` vepředu nemá
-- plánovač co použít pro rozsah a stejně sáhne po seqscanu.
--
-- ZMĚŘENO (ne odhadnuto) — 100 000 odeslaných řádků + 2 000 čekajících, každá
-- varianta ve VLASTNÍ transakci, medián z 12 běhů `email_outbox_prevzit(20)`,
-- a celé to dvakrát v opačném pořadí, ať se vyloučí vliv pořadí:
--
--     index                          běh 1      běh 2
--     žádný                          10,97 ms   6,81 ms
--     (user_id, claimed_at DESC)      1,82 ms   6,52 ms   ← kolísá, nespolehlivý
--     (claimed_at)                    1,03 ms   1,08 ms   ← stabilní, zvolený
--
-- ⚠️ TENHLE INDEX BYL PŮVODNĚ `(user_id, claimed_at DESC)` a komentář tu tvrdil
-- „1,3 ms, Index Only Scan". To měření bylo vadné: běželo nad frontou BEZ
-- čekajících řádků, takže se poddotaz stropu vůbec nevyhodnotil a měřilo se
-- prázdno. Jakmile ve frontě něco je, ten index si své místo nezaslouží —
-- v jednom z běhů byl stejně pomalý jako žádný index. Našly brány 13. 9. 2026.
--
-- ⚠️ Druhý index, na výběr kandidátů podle (user_id, created_at), tu chvíli
-- byl a je zase pryč: změřeno 0,68 ms s ním a 0,69 ms bez něj, protože
-- stávající částečný `idx_email_outbox_k_odeslani` tu práci odvede. Index,
-- který si v měření nic nezasloužil, je jen zápisová režie navíc.
CREATE INDEX IF NOT EXISTS idx_email_outbox_claimed
  ON public.email_outbox (claimed_at);

-- -----------------------------------------------------------------------------
-- 2) Strop odchozí pošty: na STRANĚ ODESÍLÁNÍ, ne při zakládání zprávy
-- -----------------------------------------------------------------------------
-- ⚠️ TOHLE JE DRUHÝ NÁVRH. První verze počítala strop v `notify_user` a řádek
-- přes strop zakládala jako `skipped`. Bezpečnostní brána 12. 9. 2026 změřila,
-- že to dělá TICHOU TRVALOU ZTRÁTU pošty, která má největší cenu:
--
--   admin přebije komerční akcí celý den na obou drahách (30 rezervací)
--   → zástupce klubu: 45 zpráv o jedné akci, z toho 25 `skipped`
--   → dozví se o 20 zrušených termínech z 30 a o zbytku NIKDY
--
-- `skipped` je terminální stav, nic ho nevrací do fronty. Pojistka proti spamu
-- se tak stala výrobcem ztracené pošty — a to je horší než problém, který řeší.
--
-- Druhá věc, kterou první návrh otevřel: strop se počítal na PŘÍJEMCE, takže
-- kvótu oběti vyčerpal cizí člověk. Dvacet rezervací obyčejného člena umlčelo
-- zástupci klubu e-maily na hodinu (změřeno toutéž bránou).
--
-- TEĎ: strop nerozhoduje, jestli zpráva VZNIKNE, ale kdy SE ODEŠLE. Řádek
-- zůstane `pending` a příští běh cronu ho vezme, jakmile se okno posune.
-- Nic se nezahazuje, útok znamená zdržení, ne ztrátu — a `notify_user` se
-- tímhle vůbec nemění, takže výpadek stropu nemůže shodit zakládání rezervací.
--
-- Tělo vygenerované z `pg_get_functiondef` ŽIVÉ produkce (12. 9. 2026);
-- vložený je jen blok stropu ve výběru.
CREATE OR REPLACE FUNCTION public.email_outbox_prevzit(_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, email text, subject text, body text, attempts integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- `RETURNS TABLE` zakládá OUT parametry jménem id/email/subject/body/attempts,
-- takže nekvalifikovaný odkaz na stejnojmenný sloupec by funkci runtime rozbil
-- hláškou o nejednoznačnosti. Tohle říká, že v případě střetu vyhrává SLOUPEC,
-- aby to nedrželo jen na kázni při kvalifikování.
#variable_conflict use_column
DECLARE
  _strop int;
BEGIN
  -- ⚠️ ROZPOČET POKUSŮ JE 5 A ŽIJE NA TŘECH MÍSTECH, která si musí odpovídat:
  -- `attempts >= 5` v úklidu níž, `attempts < 5` ve výběru níž a `MAX_POKUSU`
  -- v `supabase/functions/send-emails/index.ts`. Změna na jednom místě rozhodí
  -- ostatní: TS=3 proti SQL=5 znamená, že se běžná chyba vzdá po třech
  -- pokusech, ale uvíznutý řádek dostane pět.
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    _limit := 50;
  END IF;

  -- Řádek, který zůstal v `sending` po spadlém běhu a vyčerpal pokusy, se
  -- nesmí vracet donekonečna. Deset minut je s přehledem nad délkou dávky.
  --
  -- `COALESCE(claimed_at, created_at)`: řádek se `sending` a PRÁZDNÝM razítkem
  -- by se jinak nevrátil do fronty ani neoznačil `failed` NIKDY, protože
  -- `NULL < cokoli` není pravda. Takový řádek dnes `prevzit` nevyrobí, ale
  -- vyrobí ho jakýkoli ruční zásah, a tiše by z fronty zmizel.
  --
  -- `SKIP LOCKED` i tady: bez něj se můžou dva souběžné běhy, které zaseklé
  -- řádky zamknou v opačném pořadí, zaklesnout.
  WITH k_zavreni AS (
    SELECT o.id
      FROM public.email_outbox o
     WHERE o.status = 'sending'
       AND o.attempts >= 5
       AND COALESCE(o.claimed_at, o.created_at) < now() - interval '10 minutes'
     FOR UPDATE SKIP LOCKED
  )
  UPDATE public.email_outbox o
     SET status = 'failed',
         last_error = COALESCE(o.last_error, 'Odesílání se nedokončilo a vyčerpalo pokusy.')
    FROM k_zavreni z
   WHERE o.id = z.id;

  -- ---- PROČ TU NENÍ ŽÁDNÁ „DRUHÁ MEZ" NA STÁŘÍ ----------------------------
  -- Chvíli tu byla: `pending` starší než 24 hodin se uzavíralo jako `failed`,
  -- aby fronta nemohla růst donekonečna (brána code review správně namítla,
  -- že samotné odkládání nechrání kvótu Resendu — odejde nakonec všechno,
  -- jen pomaleji).
  --
  -- ⚠️ JE TO ZASE PRYČ, PROTOŽE TO NIČILO POŠTU Z ÚPLNĚ JINÉHO DŮVODU.
  -- Změřeno bránou 12. 9. 2026: třicetihodinový VÝPADEK CRONU, dvanáct zpráv,
  -- strop 100/h — tedy nikdo nikde nepřetekl — a přesto pět zpráv skončilo
  -- trvale `failed` s `attempts = 0`. Nikdy se je nikdo nepokusil odeslat.
  -- Stáří řádku totiž neříká „tenhle přetekl strop", ale „tenhle tu leží",
  -- a při zastaveném cronu tu leží všechno. `failed` je přitom terminální
  -- stejně jako `skipped` — a je to TÁŽ vada, kvůli které se zahodil první
  -- návrh stropu. Podruhé už ji sem nepustím.
  --
  -- Co tedy drží frontu na uzdě: (1) série i přebití se slučují do jedné
  -- zprávy (migrace 20260912160000 a 20260912200000), takže špička, kvůli
  -- které mez vznikla, vůbec nenastane; (2) strop brzdí RYCHLOST odesílání,
  -- a právě rychlost je to, co spálí kvótu i reputaci domény.
  --
  -- ⚠️ RETENCE FRONTY NENÍ ŽÁDNÁ, A JE TO VĚDOMÉ. Tenhle komentář chvíli
  -- odkazoval na úklidový job v migraci 20260912180000. Ta migrace byla
  -- zrušena (plánovač šel z databáze ven, `pg_net` se na produkci
  -- neinstaluje), takže odkaz mířil na neexistující soubor a tvrdil úklid,
  -- který nikdo nedělá. Našla to brána code review 13. 9. 2026.
  --
  -- Proč se to nedodělalo jinam: (a) bez `pg_cron` není v databázi co by
  -- úklid spouštělo, (b) tvrdé mazání jde proti zásadě „nic nemazat natvrdo"
  -- z CLAUDE.md a po 90 dnech by nešlo doložit, že e-mail odešel, (c) růst
  -- fronty dnes nic nebolí: změřeno na 100 000 odeslaných + 2 000 čekajících
  -- řádcích, `email_outbox_prevzit(20)` medián 1,03 ms (index
  -- `idx_email_outbox_claimed`; bez něj 10,97 ms — i tak ne katastrofa).
  -- Kdy to řešit a jak (mazat, archivovat, nebo nechat růst) je otázka na PM,
  -- ne věc, kterou má tahle migrace rozhodnout za něj.
  --
  -- Co zbývá jako vědomé riziko: naskriptovaný nápor tisíců samostatných
  -- rezervací frontu nafoukne a ta se bude vyprazdňovat dlouho. Je to ale
  -- VIDĚT ve frontě, dá se to smazat ručně, a žádná zpráva se přitom
  -- neztratí. To je lepší směr selhání než tichá ztráta.

  -- ⚠️ Strop se bere SKALÁRNÍM PODDOTAZEM, ne `CROSS JOIN`. Dřív tu stál
  -- `CROSS JOIN strop` s komentářem, že dvojitý COALESCE ošetří i chybějící
  -- řádek v `settings`. Nebyla to pravda a brána code review to změřila:
  -- prázdná `settings` nedá NULL, nedá NIC — `CROSS JOIN` s prázdnou stranou
  -- vyhodí všechny řádky, takže by se nevzalo vůbec nic, včetně pošty bez
  -- `user_id`, o které týž komentář tvrdil, že strop neřeší. Oba COALESCE
  -- byly mrtvý kód. Skalární poddotaz vrátí při prázdné tabulce NULL
  -- a COALESCE ho převede na výchozích 100.
  _strop := COALESCE((SELECT email_max_za_hodinu FROM public.settings LIMIT 1), 100);

  RETURN QUERY
  WITH uz_slo_ven AS (
    -- Kolik se tomuhle člověku za poslední hodinu UŽ POKUSILO odejít.
    -- `claimed_at` je razítko „sáhli jsme po tom, ať to dopadlo jakkoli",
    -- takže pokrývá `sent`, `sending` i `failed` jedním sloupcem.
    SELECT o.user_id, count(*)::int AS kolik
      FROM public.email_outbox o
     WHERE o.user_id IS NOT NULL
       AND o.claimed_at >= now() - interval '1 hour'
     GROUP BY o.user_id
  ),
  kandidati AS (
    -- ⚠️ NENÍ TO PROSTÉ FIFO, A JE TO ZÁMĚR. Strop se počítá na PŘÍJEMCE,
    -- takže cizí člověk umí vyrobit provoz na adresu oběti: bezpečnostní brána
    -- 12. 9. 2026 změřila, že obyčejný člen klubu opakovaným zakládáním
    -- a rušením rezervace pošle zástupci deset e-mailů a může v tom
    -- pokračovat. Při striktním FIFO by se obětina SKUTEČNÁ zpráva
    -- („vaši rezervaci zrušili") zařadila až za tu hromadu a při stropu
    -- 100/h by se k ní nikdy nedostalo.
    --
    -- Přednost proto mají zprávy o tom, co člověk ZTRATIL. Ty přijdou jednou
    -- za událost a nedají se nasypat: zrušení a přebití zakládá správce haly,
    -- ne ten, kdo se snaží zahltit. Rutinní „máte rezervaci k potvrzení"
    -- čeká za nimi. Uvnitř téže priority pořád platí pořadí příchodu.
    --
    -- Tím se útok mění z „oběť nedostane nic" na „oběť dostane to podstatné
    -- a rutinní pošta se zdrží". Samotné zahlcení tím vyřešené NENÍ, to je
    -- otevřená otázka na PM (viz docs) — tohle jen brání tomu, aby kvůli němu
    -- zmizely zprávy, na kterých záleží.
    SELECT o.id, o.user_id, o.created_at,
           row_number() OVER (
             -- Řádky bez `user_id` tvoří JEDEN společný kbelík, ne neomezenou
             -- cestu okolo stropu. Brána změřila obejití: strop 1 → vzato 200.
             --
             -- ⚠️ Tu díru dělala PODMÍNKA NÍŽ (`k.user_id IS NULL OR …`), která
             -- takové řádky pouštěla všechny; ta je pryč. `COALESCE` tady je
             -- jen srozumitelnost — `PARTITION BY NULL` je svede dohromady
             -- stejně, takže samo o sobě nic neopravuje (ověřeno mutací:
             -- vrácení `PARTITION BY o.user_id` chování nezmění).
             -- `user_id` se přitom vyprázdní i samo, přes `ON DELETE SET NULL`.
             PARTITION BY COALESCE(o.user_id, '00000000-0000-0000-0000-000000000000'::uuid)
             ORDER BY CASE n.type
                        WHEN 'reservation_series_cancelled' THEN 0
                        WHEN 'reservation_cancelled'        THEN 0
                        WHEN 'reservation_overridden'       THEN 0
                        WHEN 'reservation_changed'          THEN 1
                        ELSE 2
                      END,
                      o.created_at) AS poradi
      FROM public.email_outbox o
      LEFT JOIN public.notifications n ON n.id = o.notification_id
     WHERE o.attempts < 5
       AND (o.status = 'pending'
            OR (o.status = 'sending'
                AND COALESCE(o.claimed_at, o.created_at) < now() - interval '10 minutes'))
  ),
  pod_stropem AS (
    -- `poradi` omezuje i to, co se vejde do JEDNÉ dávky. Bez něj by člověk
    -- s nulou odeslaných dostal celou dávku najednou a strop by platil až
    -- od příštího běhu — tedy strop + dávka místo stropu.
    SELECT k.id
      FROM kandidati k
      LEFT JOIN uz_slo_ven u
             ON u.user_id = COALESCE(k.user_id, '00000000-0000-0000-0000-000000000000'::uuid)
     -- Strop platí i na společný kbelík bez `user_id` (viz `kandidati` výš).
     WHERE k.poradi <= greatest(_strop - COALESCE(u.kolik, 0), 0)
  ),
  vybrane AS (
    -- Zámek se bere až tady, nad prostým scanem. `FOR UPDATE` nejde spojit
    -- s okenní funkcí ani agregací v témže dotazu, proto ten mezikrok.
    SELECT o.id
      FROM public.email_outbox o
     WHERE o.id IN (SELECT id FROM pod_stropem)
     ORDER BY o.created_at
     FOR UPDATE SKIP LOCKED
     LIMIT _limit
  )
  UPDATE public.email_outbox o
     SET status     = 'sending',
         claimed_at = now(),
         attempts   = o.attempts + 1
    FROM vybrane v
   WHERE o.id = v.id
  RETURNING o.id, o.email, o.subject, o.body, o.attempts;
END;
$function$;

REVOKE ALL ON FUNCTION public.email_outbox_prevzit(integer) FROM public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3) notify_reservation_changed: série = jedna zpráva, a mluví o sérii
-- -----------------------------------------------------------------------------
-- Tělo vygenerované z `pg_get_functiondef` ŽIVÉ produkce (12. 9. 2026);
-- vložené jsou jen klíč značky a větev pro sérii.
CREATE OR REPLACE FUNCTION public.notify_reservation_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _subject text;
  _sheet   text;
  _kdo     text;
  _kdy     text;
  _kdy_pred text;
  _typ     text;
  _titulek text;
  _text    text;
  _klic    text;
  _pocet   int;
  _od      timestamptz;
  _do      timestamptz;
BEGIN
  -- Bez autora není komu psát.
  IF NEW.created_by IS NULL THEN RETURN NULL; END IF;

  -- Vlastní úprava se neoznamuje.
  IF auth.uid() IS NOT DISTINCT FROM NEW.created_by THEN RETURN NULL; END IF;

  -- Zásah bez přihlášeného člověka = migrace, seed nebo servisní skript.
  -- Ty by jinak při každém hromadném přepočtu vyrobily klubům desítky
  -- upozornění na změnu, kterou nikdo neudělal.
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;

  -- Storno kvůli PŘEBITÍ si zprávu posílá samo, v `create_booking`, a shrnuté
  -- za celou akci. Tenhle trigger o přebití nic neví, takže by ke každému
  -- zrušenému řádku přidal ještě „vaši rezervaci zrušil(a) <admin>" bez
  -- zmínky o komerční akci — změřeno bránou 12. 9. 2026: osm přebitých termínů
  -- = 1 shrnutá zpráva + 8 z triggeru, devět zpráv se dvěma vysvětleními téhož.
  --
  -- Značku zapaluje a zase zhasíná `create_booking` kolem té jediné smyčky,
  -- je transakčně lokální a `app.*` se z API nedá nastavit (CLAUDE.md, pravidlo 8).
  IF current_setting('app.prebiti', true) = 'on' THEN RETURN NULL; END IF;

  -- ---- O co jde: storno, nebo přesun? --------------------------------------
  IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
    _typ := 'reservation_cancelled';
  ELSIF NEW.status <> 'cancelled'
        AND (NEW.sheet_id  IS DISTINCT FROM OLD.sheet_id
          OR NEW.start_at  IS DISTINCT FROM OLD.start_at
          OR NEW.end_at    IS DISTINCT FROM OLD.end_at) THEN
    _typ := 'reservation_changed';
  ELSE
    RETURN NULL;                      -- jiná změna (poznámka, razítka) neupozorňuje
  END IF;

  -- ---- Jedna zpráva na akci, ne na každou dráhu ----------------------------
  -- Akce přes obě dráhy jsou dva řádky a `move_booking` je posouvá SPOLU,
  -- v jedné transakci — trigger tedy proběhne dvakrát a klub by dostal dvě
  -- hlášky o jedné změně.
  --
  -- Značka je transakčně lokální (`set_config(..., true)`), takže platí přesně
  -- pro tenhle jeden zásah a další úprava téže akce (jiná transakce) upozorní
  -- znovu. Dřív tu stálo `created_at >= now()`; vycházelo to jen proto, že
  -- `now()` je čas ZAČÁTKU transakce, a v testu (jedna dlouhá transakce) to
  -- umlčelo i změny, které spolu vůbec nesouvisely. Značka říká totéž nahlas.
  -- Kolik termínů série padlo TÍMŽ zrušením? `cancel_booking` dělá jeden UPDATE,
  -- takže všechny mají shodné `cancelled_at`. AFTER ROW trigger se navíc spouští
  -- až po dokončení CELÉHO příkazu, takže tady už jsou vidět všechny
  -- (ověřeno měřením, ne odhadem).
  --
  -- Počítá se PŘED značkou jen kvůli čitelnosti: typ je pak hotový na jednom
  -- místě a dál se s ním nehýbe.
  --
  -- ⚠️ POZOR, ať to někdo nebrání zbytečně: na pořadí NEZÁLEŽÍ. Dřív tu stálo,
  -- že za značkou by vyšel špatný předmět e-mailu — to byla nepravda. `_typ`
  -- se do `notify_user` (a tím do šablony) předává až na konci, takže by
  -- předmět vyšel stejně; posun by změnil jen sufix klíče značky, který je
  -- v rámci transakce konzistentní tak jako tak. Odhaleno bránou 12. 9. 2026.
  _pocet := 1;
  IF _typ = 'reservation_cancelled' AND NEW.series_id IS NOT NULL AND NEW.cancelled_at IS NOT NULL THEN
    -- ⚠️ `count(DISTINCT event_id)`, NE `count(*)`. `create_booking` bere pole
    -- drah, takže termín na OBOU DRAHÁCH jsou DVA řádky se společným
    -- `event_id`. S `count(*)` by série 6 termínů přes dvě dráhy hlásila
    -- „zrušeno 12 termínů" a jediný termín na dvou drahách by se tvářil jako
    -- celá zrušená série. Změřeno bránou 12. 9. 2026, můj původní test to
    -- nechytil, protože zakládal sérii jen na jedné dráze.
    SELECT count(DISTINCT COALESCE(r.event_id, r.id)), min(r.start_at), max(r.start_at)
      INTO _pocet, _od, _do
      FROM public.reservations r
     WHERE r.series_id = NEW.series_id
       AND r.cancelled_at = NEW.cancelled_at
       AND r.deleted_at IS NULL;

    IF _pocet > 1 THEN
      _typ := 'reservation_series_cancelled';
    END IF;
  END IF;

  -- ⚠️ SÉRIE MÁ PŘEDNOST PŘED AKCÍ. Každý termín série dostane z `create_booking`
  -- VLASTNÍ `event_id`, takže se dřívějším klíčem (event_id první) marker lišil
  -- termín od termínu a zrušení série poslalo jednu zprávu NA KAŽDÝ TERMÍN.
  -- Změřeno 12. 9. 2026: série osmi tréninků = 8 e-mailů jednomu člověku,
  -- a série smí mít až 200 termínů.
  --
  -- Značka je transakčně lokální, takže zrušení JEDNOHO termínu série v jiné
  -- transakci pořád upozorní samostatně. Sloučí se jen to, co se ruší spolu.
  --
  -- ⚠️ V KLÍČI MUSÍ BÝT I PŘÍJEMCE. Značka je klíčovaná sérií, ale adresát se
  -- bere PO ŘÁDKU (`NEW.created_by`). Bez `created_by` v klíči umlčí první
  -- autor všechny ostatní — a série může mít víc autorů, protože
  -- `create_booking` u série hlídá jen shodu SUBJEKTU, ne autora, a klub smí
  -- mít víc zástupců. Změřeno bránou 12. 9. 2026: série se dvěma autory
  -- upozornila jednoho a druhý o zrušení své rezervace nedostal NIC, ani
  -- e-mail, ani zvonek. Byla to regrese proti stavu před touhle migrací.
  _klic := 'app.zmena_' || replace(COALESCE(NEW.series_id, NEW.event_id, NEW.id)::text, '-', '')
           || '_' || replace(NEW.created_by::text, '-', '')
           || '_' || _typ;
  IF current_setting(_klic, true) = 'on' THEN
    RETURN NULL;
  END IF;
  PERFORM set_config(_klic, 'on', true);

  SELECT s.name INTO _subject FROM public.subjects s  WHERE s.id = NEW.subject_id;
  SELECT sh.name INTO _sheet  FROM public.sheets sh   WHERE sh.id = NEW.sheet_id;
  SELECT p.full_name INTO _kdo FROM public.profiles p WHERE p.user_id = auth.uid();

  _kdy := to_char(NEW.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
          || '–' || to_char(NEW.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI');

  -- Zrušená série = JEDNA zpráva, která popisuje sérii. Bez tohohle by jediná
  -- zpráva mluvila o jediném termínu, takže by klub nevěděl, že přišel o všechny.
  IF _typ = 'reservation_series_cancelled' THEN
    _titulek := 'Série rezervací byla zrušena';
    _text := 'Vaši sérii rezervací za ' || COALESCE(_subject, 'klub') || ' zrušil(a) '
             || COALESCE(_kdo, 'správce haly') || '. Zrušeno termínů: ' || _pocet
             || ', od ' || to_char(_od AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY')
             || ' do '  || to_char(_do AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY') || '.'
             || COALESCE(' Důvod: ' || NULLIF(NEW.cancel_reason, '') || '.', '');
  ELSIF _typ = 'reservation_cancelled' THEN
    _titulek := 'Rezervace byla zrušena';
    _text := 'Vaši rezervaci za ' || COALESCE(_subject, 'klub') || ' ('
             || COALESCE(_sheet, 'dráha') || ', ' || _kdy || ') zrušil(a) '
             || COALESCE(_kdo, 'správce haly') || '.'
             -- Důvod storna je pro klub ta nejdůležitější informace; bez něj
             -- vypadá zrušení jako svévole.
             || COALESCE(' Důvod: ' || NULLIF(NEW.cancel_reason, '') || '.', '');
  ELSE
    _kdy_pred := to_char(OLD.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
                 || '–' || to_char(OLD.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI');
    _titulek := 'Rezervace byla upravena';
    _text := COALESCE(_kdo, 'Správce haly') || ' upravil(a) vaši rezervaci za '
             || COALESCE(_subject, 'klub') || '. Původně: ' || _kdy_pred
             || '. Nově: ' || COALESCE(_sheet, 'dráha') || ', ' || _kdy || '.';
  END IF;

  PERFORM public.notify_user(
    NEW.created_by, _typ, _titulek, _text, '/calendar', NEW.id, NEW.subject_id);

  RETURN NULL;
END;
$function$;


-- `lock_timeout` platil kvůli ALTER TABLE výš. Náhrady funkcí (`CREATE OR
-- REPLACE`) berou zámek jen na řádek v `pg_proc`, ale krátký timeout jim
-- neuškodí — proto se pouští až tady, ne uprostřed.
RESET lock_timeout;

-- -----------------------------------------------------------------------------
-- Sebekontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _zdroj text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='settings'
                    AND column_name='email_max_za_hodinu') THEN
    RAISE EXCEPTION 'Sloupec se stropem nevznikl.';
  END IF;

  -- Strop žije v `email_outbox_prevzit`, ne v `notify_user` (proč, viz oddíl 2).
  SELECT prosrc INTO _zdroj FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='email_outbox_prevzit';
  IF _zdroj NOT LIKE '%email_max_za_hodinu%' THEN
    RAISE EXCEPTION 'email_outbox_prevzit se nepřepsal, strop by neplatil.';
  END IF;
  IF _zdroj NOT LIKE '%FOR UPDATE SKIP LOCKED%' THEN
    RAISE EXCEPTION 'Zmizelo zamykání fronty, souběžné běhy pošlou týž e-mail dvakrát.';
  END IF;
  IF _zdroj NOT LIKE '%attempts < 5%' THEN
    RAISE EXCEPTION 'Zmizel rozpočet pokusů, přepsalo se to ze staré verze.';
  END IF;
  IF _zdroj NOT LIKE '%reservation_series_cancelled%' THEN
    RAISE EXCEPTION 'Výběr nedává přednost důležitým typům, zahlcená oběť je nedostane.';
  END IF;
  IF _zdroj NOT LIKE '%00000000-0000-0000-0000-000000000000%' THEN
    RAISE EXCEPTION 'Řádky bez user_id obcházejí strop.';
  END IF;
  IF _zdroj LIKE '%24 hours%' THEN
    RAISE EXCEPTION 'Vrátila se mez na stáří řádku. Ničí poštu při výpadku cronu, viz oddíl 2.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE tablename='email_outbox' AND indexname='idx_email_outbox_claimed') THEN
    RAISE EXCEPTION 'Chybí index pro okno stropu, dotaz by četl celou frontu.';
  END IF;

  -- `notify_user` tahle migrace ZÁMĚRNĚ nemění. Kdyby ho přesto někdo zase
  -- začal přepisovat kvůli stropu, ať je to vidět: strop uvnitř `notify_user`
  -- znamená, že výpadek sloupce shodí zakládání rezervací.
  SELECT prosrc INTO _zdroj FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='notify_user';
  IF _zdroj LIKE '%email_max_za_hodinu%' THEN
    RAISE EXCEPTION 'Strop se vrátil do notify_user. Patří do email_outbox_prevzit.';
  END IF;
  IF _zdroj NOT LIKE '%email_sablona%' THEN
    RAISE EXCEPTION 'notify_user přišel o šablony.';
  END IF;

  SELECT prosrc INTO _zdroj FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='notify_reservation_changed';
  -- Pořadí v COALESCE je celá oprava: series_id MUSÍ být první.
  IF _zdroj NOT LIKE '%COALESCE(NEW.series_id, NEW.event_id, NEW.id)%' THEN
    RAISE EXCEPTION 'Značka dedupu nepreferuje sérii, zrušení série pošle N zpráv.';
  END IF;
  -- Bez příjemce v klíči umlčí první autor série všechny ostatní.
  IF _zdroj NOT LIKE '%replace(NEW.created_by::text%' THEN
    RAISE EXCEPTION 'Značka dedupu nenese příjemce, druhý autor série nedostane nic.';
  END IF;
  IF _zdroj NOT LIKE '%app.prebiti%' THEN
    RAISE EXCEPTION 'Trigger neumí zmlknout u přebití, autor dostane dvě vysvětlení téhož.';
  END IF;
  IF _zdroj NOT LIKE '%Série rezervací byla zrušena%' THEN
    RAISE EXCEPTION 'Chybí zpráva popisující zrušenou sérii.';
  END IF;
  -- Ochrana proti přepsání ze staré verze: tyhle dvě věci tam byly už dřív.
  IF _zdroj NOT LIKE '%auth.uid() IS NULL%' THEN
    RAISE EXCEPTION 'Zmizela ochrana před servisními zápisy, migrace přepsala starou verzi.';
  END IF;
  IF _zdroj NOT LIKE '%cancel_reason%' THEN
    RAISE EXCEPTION 'Zmizel důvod storna ze zprávy.';
  END IF;

  RAISE NOTICE 'Série posílá jednu zprávu každému autorovi a strop brzdí odesílání, nezahazuje.';
END $kontrola$;


-- Trigger funkci volá Postgres sám, EXECUTE pro PUBLIC k ničemu nepotřebuje.
-- Zneužít to dnes nejde (bez `NEW`/`OLD` se z API zavolat nedá), ale výchozí
-- grant pro PUBLIC tu nemá co dělat.
REVOKE ALL ON FUNCTION public.notify_reservation_changed() FROM public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4) Šablona pro zrušenou sérii
-- -----------------------------------------------------------------------------
-- Bez vlastního typu by e-mail o osmi zrušených termínech měl v těle sérii,
-- ale v předmětu „Rezervace byla zrušena". Šablona se vybírá podle typu,
-- takže nový typ musí být i tady — a tím se zároveň dostane do allowlistu.
CREATE OR REPLACE FUNCTION public.email_sablona(
  _type  text,
  _title text,
  _body  text,
  _link  text
) RETURNS TABLE (subject text, body text)
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $sablona$
DECLARE
  _web    constant text := 'https://curling-ostrava-system.netlify.app';
  _odkaz  text;
  _cil    text;
  _uvod   text;
  _zaver  text;
BEGIN
  -- Odkaz musí být cesta na našem webu, ne cokoli. Bez požadavku na úvodní `/`
  -- (a na to, že další znak není další lomítko) by `_link` tvaru
  -- '.zly-web.cz/x' vyrobil „https://…netlify.app.zly-web.cz/x", tedy
  -- podvrženou doménu v e-mailu z NAŠÍ adresy. Dnes všichni volající předávají
  -- literál '/calendar', takže je to obrana do hloubky. NEODSTRAŇOVAT.
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
$sablona$;

REVOKE ALL ON FUNCTION public.email_sablona(text, text, text, text) FROM public, anon, authenticated;

COMMENT ON COLUMN public.notifications.type IS
  'reservation_overridden | reservation_pending | reservation_needs_approval | reservation_approved | reservation_cancelled | reservation_series_cancelled | reservation_changed | subject_request_approved';

DO $k2$
DECLARE _p text;
BEGIN
  SELECT s.subject INTO _p FROM public.email_sablona('reservation_series_cancelled','x','y','/calendar') s;
  IF _p <> 'Série rezervací byla zrušena' THEN
    RAISE EXCEPTION 'Šablona pro zrušenou sérii chybí, e-mail by měl předmět o jedné rezervaci.';
  END IF;
  SELECT s.subject INTO _p FROM public.email_sablona('subject_request_approved','x','y','/') s;
  IF _p IS NOT NULL THEN
    RAISE EXCEPTION 'Allowlist propouští typ mimo matici.';
  END IF;
  RAISE NOTICE 'Šablona zrušené série je na místě.';
END $k2$;
