-- =============================================================================
-- ZÁMEK PŘÍJEMCE NA FAKTUROIDÍM DOKLADU (KROK 2 go-live Fakturoidu)
-- =============================================================================
--
-- ROZHODNUTÍ PM (14. 9. 2026): přehodit rezervaci na jiný klub, když už visí
-- na fakturoidím dokladu, se zakazuje — stejně, jako to dnes zakazuje interní
-- cesta přes `over_neni_vyfakturovano`.
--
-- KROK 0 — CO JE DNES, změřeno na replice reálným tokenem admina, ne odhadem.
-- Obě cesty byly OTEVŘENÉ:
--
--   DÍRA A — přímý UPDATE. `UPDATE reservations SET subject_id = <jiný klub>`
--   nad rezervací, která visí na fakturoidím dokladu, PROŠEL.
--     → „rezervace teď patří Lesy ČR, doklad dál zní na Mladé Kameny"
--   Proč to nic nechytilo: `trg_reservations_jeden_doklad` i zámek fakturace
--   v `guard_reservation_rep_changes` koukají na `reservations.invoice_id` —
--   a fakturoidí cesta tam z rozhodnutí PM nezapisuje. Vazba žije jen
--   v `fakturoid_invoice_reservations`, na kterou se nedíval nikdo.
--
--   DÍRA B — `fakturoid_zkus_zabrat` s hlavičkou na klub B a podkladem klubu A
--   vrátil `true` a doklad vznikl.
--     → „doklad zní na Lesy ČR, ale nese rezervaci klubu Mladé Kameny"
--   Tohle je ta HORŠÍ z dvojice: rozejitý doklad vznikne rovnou a zámek A ho
--   pak ještě zabetonuje.
--
-- CO UŽ ZAVŘENÉ BYLO A NEMĚNÍ SE: legitimní RPC `zmen_firmu_akce` si volá
-- `over_neni_vyfakturovano`, která pokrývá `invoice_id` I fakturoidí vazbu,
-- takže s vyfakturovanou rezervací neprojde už dnes. Zámek A je pro ni
-- druhá pojistka a v běžném běhu na ni nesáhne.
--
-- VZTAH KE KROKU 1: migrace 20260914210000 tuhle divergenci ZVIDITELNILA
-- (sloupec „Rozdíl dokladů"). Tahle jí brání vzniknout. Pořadí je schválně
-- takové — nejdřív to bylo vidět, teprve pak se to zavírá.
--
-- FAIL-CLOSED — kde zámek A stojí a proč:
--   nad `app.trusted_booking` i nad adminskou výjimkou, tedy VÝŠ než zámek
--   fakturace pod ním. Podrobné odůvodnění je u kódu; krátce: admin je právě
--   ta role, která tuhle změnu dělá, a marker vypíná guard na celou transakci.
--   Výjimka pro `postgres`/`supabase_admin` zůstává — bez ní by neprošly
--   migrace a je to jediná servisní cesta, jak opravit divergenci, která by
--   v datech už byla.
--
-- CESTA VEN — A TADY JE OTEVŘENÁ VĚC PRO PM. Změřeno 14. 9. 2026, nikoli
-- odhadnuto; první znění téhle migrace tvrdilo něco jiného a test A5 to shodil:
--   * ZABRANÝ, NEVYSTAVENÝ doklad uvolní `fakturoid_uvolni_zabrani` a vazby
--     přitom smaže → rezervace je zase volná. Tady cesta ven JE.
--   * VYSTAVENÝ doklad (`provider_invoice_id IS NOT NULL`) neuvolní NIC.
--     `fakturoid_uvolni_zabrani` ho odmítá a drží to i CHECK
--     `fakturoid_uvolneni_jen_bez_dokladu`; `storno_invoice` ani
--     `dobropis_invoice` se fakturoidích tabulek netýkají (ověřeno v jejich
--     tělech); vazební tabulka nemá grant pro `authenticated`. Jediná cesta
--     je servisní zásah pod rolí `postgres`.
-- Zámek tedy u vystaveného dokladu ZMRAZÍ `subject_id` natrvalo — což je
-- přesně to, co PM rozhodl (vystavenou fakturu nelze přeadresovat editací
-- naší databáze; patří to k Fakturoidu jako dobropis). Hlášky to od teď říkají
-- narovinu a KAŽDÁ RADÍ TO SVOJE; slibovat „storno nebo dobropis" i tam, kde
-- žádný takový postup není, by admina poslalo do slepé uličky.
-- ➜ K ROZHODNUTÍ PM: jestli má vzniknout aplikační cesta „odpoj vystavený
--   fakturoidí doklad" (dobropis + uvolnění vazby). Není součástí KROKU 2.
--
-- CO SE NEMĚNÍ:
--   * `reservations.invoice_id` ani interní engine.
--   * Návratové typy obou funkcí.
--   * ACL. `CREATE OR REPLACE` je zachovává; blok níž je jen zapisuje černé
--     na bílém. `guard_reservation_rep_changes` má EXECUTE i pro PUBLIC/anon —
--     je to ale triggerová funkce, kterou přímo zavolat stejně nejde
--     („can only be called as trigger"), takže se to tu ZÁMĚRNĚ nemění;
--     odebírat práva mimo zadání by byl zbytečný pohyb u peněz.
--
-- IDEMPOTENTNÍ: obě funkce přes `CREATE OR REPLACE`, žádné DDL nad tabulkami.
-- Viz CLAUDE.md pravidlo 6 — dávka migrací není atomická, opakovaný push musí
-- projít. Do těla se `BEGIN`/`COMMIT` nepíše, obálku dodá CLI.
--
-- VRATNOST:
--   Obě těla zpět z `pg_get_functiondef` VERZE PŘED TOUHLE MIGRACÍ; v repu
--   jsou poslední předchozí verze v migracích, které je naposled měnily.
--   ⚠️ PO PUSHI už stará těla z `pg_get_functiondef` nedostaneš, vrátí se nová.
--   Migrace nic nezapisuje do dat, takže rollback je bezztrátový.
--
-- Těla jsou vygenerovaná z `pg_get_functiondef` ŽIVÉ PRODUKCE (ověřeno, že
-- jsou bajt po bajtu shodná s replikou) a je do nich vložený POUZE ten jeden
-- zásah — CLAUDE.md, pravidlo 7. Ověřeno diffem: 0 odebraných řádků.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PŘED-LET: jsou v datech doklady, které už teď hlavičce neodpovídají?
--
-- Nepadá se na tom schválně. Zámek se týká NOVÝCH změn; řádky, které by už
-- rozejité byly, tahle migrace neopravuje (to je ruční rozhodnutí — uvolnit
-- doklad, nebo opravit rezervaci servisní cestou). Ale musí být VIDĚT, že
-- tam jsou, jinak by se na ně přišlo až tím, že je zámek zabetonoval.
-- -----------------------------------------------------------------------------
DO $predlet$
DECLARE _kolik int; _r record;
BEGIN
  SELECT count(*) INTO _kolik
    FROM public.fakturoid_invoice_reservations fr
    JOIN public.fakturoid_invoices fi ON fi.id = fr.fakturoid_invoice_id
    JOIN public.reservations r        ON r.id  = fr.reservation_id
   WHERE r.subject_id IS DISTINCT FROM fi.subject_id;

  IF _kolik = 0 THEN
    RAISE NOTICE 'PŘED-LET: žádný fakturoidí doklad se s příjemcem svých rezervací nerozchází.';
  ELSE
    RAISE WARNING 'PŘED-LET: % vazeb má jiný subjekt na rezervaci než v hlavičce dokladu. Zámek je od teď zmrazí — opravit je jde uvolněním dokladu (fakturoid_uvolni_zabrani) nebo servisně pod rolí postgres.', _kolik;
    FOR _r IN
      SELECT fi.cislo, fi.idempotency_key, r.id AS rezervace
        FROM public.fakturoid_invoice_reservations fr
        JOIN public.fakturoid_invoices fi ON fi.id = fr.fakturoid_invoice_id
        JOIN public.reservations r        ON r.id  = fr.reservation_id
       WHERE r.subject_id IS DISTINCT FROM fi.subject_id
       ORDER BY fi.cislo LIMIT 20
    LOOP
      RAISE WARNING '  doklad % (%) ← rezervace %', _r.cislo, _r.idempotency_key, _r.rezervace;
    END LOOP;
  END IF;
END
$predlet$;

-- -----------------------------------------------------------------------------
-- ZÁMEK A — přímý UPDATE `reservations.subject_id`
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_reservation_rep_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- Co smí ne-admin přímým zápisem vůbec změnit. Whitelist schválně: při blacklistu
  -- by každý nově přidaný sloupec byl automaticky povolený (a přesně tak se sem
  -- třikrát po sobě vloudilo falšování auditu).
  _allowed CONSTANT text[] := ARRAY[
    'note', 'status',
    'approved_at', 'approved_by',
    'cancelled_at', 'cancelled_by', 'cancel_reason',
    'updated_at', 'updated_by'          -- doplňuje pozdější trigger, klientská hodnota se přepíše
  ];
  _changed text[];
  _forbidden text;
  -- Zámek příjemce (KROK 2). Dva čítače schválně: „kolik dokladů" rozhoduje
  -- O ZÁKAZU, „kolik z nich je vystavených" rozhoduje o TOM, CO PORADIT.
  _dokladu int;
  _vystavenych int;
BEGIN
  -- Migrace, seed a servisní zásahy pod databázovou rolí. `session_user` schválně:
  -- uvnitř SECURITY DEFINER je current_user vždy vlastník funkce, takže by tahle
  -- podmínka nerozlišila vůbec nic. PostgREST se připojuje jako `authenticator`,
  -- takže nepřihlášený klient sem nespadne.
  -- Serverové skripty pod service_role ať používají RPC funkce, ne přímý zápis.
  IF auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- ZÁMEK PŘÍJEMCE: rezervaci na fakturoidím dokladu nejde přehodit jinam.
  -- (KROK 2 go-live Fakturoidu, rozhodnutí PM 14. 9. 2026.)
  --
  -- Interní cesta tohle zakazuje od B1+B2 přes over_neni_vyfakturovano.
  -- Fakturoidí cesta tu zábranu nikdy nedostala, protože do
  -- reservations.invoice_id z rozhodnutí PM nezapisuje — takže ani
  -- trg_reservations_jeden_doklad (kouká jen na invoice_id), ani zámek
  -- fakturace níž (kouká jen na invoice_id/invoiced_at) ji nechytí. Vazba
  -- žije jen ve fakturoid_invoice_reservations, na kterou se nedíval nikdo.
  --
  -- ZMĚŘENO 14. 9. 2026 na replice reálným tokenem admina: přímý
  -- UPDATE reservations SET subject_id = <jiný klub> nad rezervací, která
  -- visí na fakturoidím dokladu, PROŠEL. Doklad pak zní na jeden klub
  -- a rezervace patří druhému — přesně ta tichá chyba, kterou zviditelnila
  -- migrace 20260914210000. Ta ji ukáže; tahle jí brání vzniknout.
  --
  -- STOJÍ SCHVÁLNĚ NAD MARKEREM I NAD ADMINEM, tedy výš než zámek fakturace
  -- pod ním. Fail-closed:
  --   * Admin je ta role, která tuhle změnu dělá — výjimka pro něj by zámek
  --     zrušila celý. Proto nad ním, stejně jako u zámku fakturace.
  --   * Nad markerem proto, že marker vypíná guard na CELOU transakci. Dnes
  --     subject_id na existující rezervaci mění jediné RPC — zmen_firmu_akce —
  --     a to marker ZÁMĚRNĚ nenastavuje (má to u sebe rozepsané) a navíc si
  --     samo volá over_neni_vyfakturovano, takže na doklad narazí dřív a sem
  --     s vyfakturovanou rezervací nedojde. Ověřeno: jiná funkce, která by
  --     reservations.subject_id přepisovala, v public není. Zámek nad markerem
  --     tedy dnes nikomu nepřekáží a zároveň nespadne s prvním RPC, které si
  --     marker příště nastaví.
  --
  -- HLÁŠKA SE LIŠÍ PODLE TOHO, JESTLI JE DOKLAD UŽ VYSTAVENÝ — a je to ta
  -- důležitější půlka téhle změny. Změřeno 14. 9. 2026:
  --   * ZABRANÝ, NEVYSTAVENÝ doklad (provider_invoice_id IS NULL) uvolní
  --     fakturoid_uvolni_zabrani a vazby přitom SMAŽE. Cesta ven existuje.
  --   * VYSTAVENÝ doklad neuvolní NIC. fakturoid_uvolni_zabrani ho odmítá
  --     (má v sobě provider_invoice_id IS NULL a drží to i CHECK
  --     fakturoid_uvolneni_jen_bez_dokladu), storno_invoice ani
  --     dobropis_invoice se fakturoidích tabulek vůbec netýkají (ověřeno:
  --     jejich těla řetězec fakturoid_invoice neobsahují) a vazební tabulka
  --     nemá grant pro authenticated, takže ani přímý DELETE nepřipadá
  --     v úvahu. Zbývá servisní zásah pod rolí postgres, kterou pouští
  --     výjimka o pár řádků výš.
  -- První znění téhle hlášky slibovalo „storno nebo dobropis" v obou
  -- případech. U vystaveného dokladu to byla NEPRAVDA a poslala by admina
  -- do slepé uličky — test A5 na tom spadl.
  --
  -- IS DISTINCT FROM schválně: pokrývá i přehození na NULL (tedy „bez
  -- odběratele"), což je taky rozejití s hlavičkou dokladu.
  -- TG_OP = 'UPDATE' schválně: v BEFORE INSERT je OLD prázdné, takže by
  -- podmínka platila vždycky.
  -- ═══════════════════════════════════════════════════════════════════════
  IF TG_OP = 'UPDATE' AND NEW.subject_id IS DISTINCT FROM OLD.subject_id THEN
    SELECT count(*), count(*) FILTER (WHERE fi.provider_invoice_id IS NOT NULL)
      INTO _dokladu, _vystavenych
      FROM public.fakturoid_invoice_reservations fr
      JOIN public.fakturoid_invoices fi ON fi.id = fr.fakturoid_invoice_id
     WHERE fr.reservation_id = OLD.id;

    IF _dokladu > 0 THEN
      IF _vystavenych > 0 THEN
        RAISE EXCEPTION 'Rezervace je na VYSTAVENÉM dokladu z Fakturoidu, odběratele u ní změnit nejde.'
          USING HINT = 'Vystavený doklad aplikace uvolnit neumí. Nejdřív ho vyřeš u Fakturoidu (dobropis) a vazbu ať odpojí servisní zásah; teprve pak půjde odběratele změnit.';
      ELSE
        RAISE EXCEPTION 'Rezervace je na dokladu z Fakturoidu, odběratele u ní změnit nejde.'
          USING HINT = 'Doklad je zatím jen zabraný, ne vystavený — uvolni ho (fakturoid_uvolni_zabrani) a odběratel půjde změnit.';
      END IF;
    END IF;
  END IF;

  -- Servisní klíč (service_role) se sem dostane bez přihlášeného uživatele přes
  -- PostgREST. Zápis mu nepovolíme — obešel by kontrolu kolizí i schvalování —
  -- ale ať hláška rovnou řekne kudy, jinak to vypadá jako chyba oprávnění uživatele.
  IF auth.uid() IS NULL AND session_user = 'authenticator' THEN
    RAISE EXCEPTION 'Servisní zápis do rezervací jde jen přes RPC (create_booking, move_booking, cancel_booking, …)';
  END IF;

  -- Zápis z důvěryhodných RPC funkcí (public.create_booking a spol.), které samy ověřují
  -- práva, kolize a priority. GUC je transakčně lokální; přes PostgREST ho klient nenastaví
  -- a RPC funkce ho po svých zápisech samy vypínají, aby zvýšené oprávnění neplatilo
  -- pro zbytek transakce.
  IF current_setting('app.trusted_booking', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- ZÁMEK FAKTURACE stojí NAD adminskou výjimkou (doplněno v B1+B2).
  -- Admin má u rezervací jinak volnou ruku a je to správně. Tohle je ale účetní
  -- vazba: odpojit rezervaci od vystavené (a tím neměnné) faktury znamená, že se
  -- naúčtuje podruhé. Uvolnit ji smí jen storno nebo dobropis, tedy RPC — a ty si
  -- nastaví `app.trusted_booking`, takže sem vůbec nedojdou.
  IF TG_OP = 'UPDATE'
     AND (NEW.invoice_id IS DISTINCT FROM OLD.invoice_id
          OR NEW.invoiced_at IS DISTINCT FROM OLD.invoiced_at) THEN
    RAISE EXCEPTION 'Vazbu rezervace na fakturu mění jen fakturační funkce, ne přímý zápis.'
      USING HINT = 'Odpojit rezervaci od vystaveného dokladu lze jen stornem nebo dobropisem.';
  END IF;

  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- OKNO 48 H PŘED AKCÍ — ZALOŽENÍ.
    --
    -- Stojí ZÁMĚRNĚ tady, ne (jen) v `create_booking`. `reservations` má pro
    -- `authenticated` tabulkové INSERT granty a RLS je členovi i zástupci klubu
    -- povoluje, takže rezervace jde založit i úplně mimo RPC — POST /reservations
    -- z prohlížeče. Guard jen v RPC by hlídal jedny ze dvou dveří.
    -- Nad tímhle místem už proběhly výjimky pro `postgres`, `app.trusted_booking`
    -- (tedy naše vlastní RPC) i pro admina, takže sem dojde jen neadminský
    -- přímý zápis.
    IF public.v_okne_48h(NEW.start_at) THEN
      RAISE EXCEPTION '%', public.hlaska_okna_48h('vytvořit')
        USING HINT = 'Vyberte termín aspoň 48 h dopředu, nebo se domluvte se správcem haly.';
    END IF;

    -- Zástupce i člen zakládají jen čistě klubovou rezervaci. Od klienta se přebírá
    -- pouze dráha, subjekt, čas a poznámka — všechno ostatní se tady přepisuje.
    -- (Kdo sem bude přidávat sloupec, musí ho v tomhle výčtu ošetřit; úpravy hlídá
    -- whitelist v UPDATE větvi níž.)
    NEW.created_at        := now();   -- rezervaci nelze zpětně datovat
    NEW.updated_at        := now();
    NEW.created_by        := auth.uid();
    NEW.status            := 'confirmed';
    NEW.deleted_at        := NULL;
    NEW.event_id          := NULL;
    NEW.rate_per_hour     := NULL;   -- sazbu dopočítá pricing z ceníku
    NEW.corrected_hours   := NULL;
    NEW.corrected_amount  := NULL;
    NEW.correction_reason := NULL;
    NEW.cancelled_at      := NULL;
    NEW.cancelled_by      := NULL;
    NEW.cancel_reason     := NULL;
    NEW.series_id         := NULL;   -- sérii zakládá jen create_booking_series (hlídá si subjekt)
    -- ← doplněno v B1+B2. Bez toho si ne-admin nastavil fakturační zámek sám
    --   a jeho rezervace navždy vypadla z fakturačního běhu.
    NEW.invoice_id        := NULL;
    NEW.invoiced_at       := NULL;
    -- Zástupce klubu rezervuje rovnou platně, člen čeká na potvrzení zástupcem.
    IF public.is_subject_rep(NEW.subject_id) THEN
      NEW.approved_at := now();
      NEW.approved_by := auth.uid();
    ELSE
      NEW.approved_at := NULL;
      NEW.approved_by := NULL;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: přístup k řádku hlídá RLS (rep = celý klub, člen = jen created_by = self).
  IF NOT public.is_subject_member(OLD.subject_id) THEN
    RAISE EXCEPTION 'Nemáte právo měnit tuto rezervaci';
  END IF;

  -- Které sloupce se vlastně mění
  SELECT array_agg(n.key) INTO _changed
    FROM jsonb_each(to_jsonb(NEW)) n
    JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
   WHERE n.value IS DISTINCT FROM o.value;
  _changed := COALESCE(_changed, '{}');

  -- Čas a dráha jdou měnit VÝHRADNĚ přes public.move_booking. Přímý zápis by minul
  -- kontrolu kolizí, pravidlo „akce na dvou drahách se posouvá celá" i srovnání času
  -- navázané akce — a směny brigádníků by pak ukazovaly na jiný den.
  IF _changed && ARRAY['sheet_id', 'start_at', 'end_at'] THEN
    RAISE EXCEPTION 'Čas a dráhu měňte přesunem rezervace, ne přímým zápisem';
  END IF;

  -- OKNO 48 H PŘED AKCÍ — STORNO.
  --
  -- `status` a `cancelled_*` JSOU ve whitelistu výš, a to schválně: mimo okno
  -- si klub svoje rezervace ruší sám. V okně ale platí „akce zůstává a naúčtuje
  -- se v plné výši", a `cancel_booking` na to nestačí — rezervace jde stornovat
  -- i přímým zápisem, PATCH /reservations {"status":"cancelled"}, RPC úplně
  -- mimo. Naměřeno bezpečnostní bránou 10. 9. 2026: neadmin takhle sundal
  -- akci za 2 000 Kč z `fakturovatelne_rezervace` na nulu, zatímco `cancel_booking`
  -- mu to na téže rezervaci správně odmítlo.
  --
  -- Rozhoduje PŮVODNÍ začátek (`OLD.start_at`) — čas se stejně o pár řádků výš
  -- měnit nedá, a kdyby se hlídal jen nový, stačilo by ho v témž UPDATE odsunout.
  IF _changed && ARRAY['status', 'cancelled_at', 'cancelled_by', 'cancel_reason']
     AND public.v_okne_48h(OLD.start_at) THEN
    RAISE EXCEPTION '%', public.hlaska_okna_48h('zrušit')
      USING HINT = 'Akce zůstává a naúčtuje se v plné výši.';
  END IF;

  -- Cokoli mimo whitelist (sazba, subjekt, autor, korekce, vazby, soft-delete…)
  SELECT c INTO _forbidden FROM unnest(_changed) c WHERE c <> ALL (_allowed) LIMIT 1;
  IF _forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'Pole „%" smí měnit jen správce', _forbidden;
  END IF;

  -- --- potvrzení rezervace ---------------------------------------------------
  IF (_changed && ARRAY['approved_at', 'approved_by'])
     AND NOT public.is_subject_rep(OLD.subject_id) THEN
    RAISE EXCEPTION 'Rezervaci může potvrdit jen zástupce klubu';
  END IF;
  IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
     AND NEW.approved_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Autora potvrzení nelze podvrhnout';   -- ani jménem někoho jiného
  END IF;
  IF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    IF NEW.approved_at IS NULL THEN
      RAISE EXCEPTION 'Potvrzení může odebrat jen správce';  -- vynulováním by zmizela stopa
    END IF;
    NEW.approved_at := now();                                -- a nelze ho zpětně datovat
  END IF;

  -- --- storno ----------------------------------------------------------------
  IF NEW.cancelled_by IS DISTINCT FROM OLD.cancelled_by
     AND NEW.cancelled_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Autora storna nelze podvrhnout';
  END IF;
  IF NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at THEN
    IF NEW.cancelled_at IS NULL THEN
      RAISE EXCEPTION 'Razítko storna nelze smazat';
    END IF;
    NEW.cancelled_at := now();
  END IF;
  -- Důvod storna patří tomu, kdo rušil — jinak by si klub přepsal „přebito komerční akcí"
  -- na vlastní verzi příběhu.
  IF NEW.cancel_reason IS DISTINCT FROM OLD.cancel_reason
     AND OLD.cancelled_by IS NOT NULL
     AND OLD.cancelled_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Důvod storna smí měnit jen ten, kdo rezervaci zrušil';
  END IF;
  -- Storno je jednosměrné: „od-stornovat" (a nechat u toho staré razítko, kdo rušil)
  -- smí jen správce. Ne-admin ať založí novou rezervaci.
  IF OLD.status = 'cancelled' AND NEW.status = 'confirmed' THEN
    RAISE EXCEPTION 'Stornovanou rezervaci může obnovit jen správce — založte novou.';
  END IF;

  RETURN NEW;
END;
$function$;


-- -----------------------------------------------------------------------------
-- ZÁMEK B — `fakturoid_zkus_zabrat`
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_zkus_zabrat(_klic text, _druh text, _subject uuid, _event uuid, _od date, _do date, _nas_soucet numeric, _radku integer, _rezim text, _rezervace uuid[])
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění zakládat fakturoidí doklady.';
  END IF;

  -- Duplicita v poli by spadla na UNIQUE a vrátila nerozlišitelné `false`,
  -- takže by to vypadalo jako prohraný závod a volající by to zkoušel dokola.
  IF cardinality(_rezervace) <> cardinality(ARRAY(SELECT DISTINCT unnest(_rezervace))) THEN
    RAISE EXCEPTION 'Podklad obsahuje tutéž rezervaci víckrát — doklad by na ni zněl dvojnásobně.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- ZÁMEK PŘÍJEMCE, DRUHÁ CESTA: hlavička dokladu a podklad musí mít TÝŽ
  -- subjekt. (KROK 2 go-live Fakturoidu, rozhodnutí PM 14. 9. 2026.)
  --
  -- Zámek v guard_reservation_rep_changes brání ROZEJITÍ POZDĚJI. Tenhle
  -- brání tomu, aby rozejitý doklad vznikl ROVNOU — a to je ta horší cesta,
  -- protože zámek A pak takový doklad ještě zabetonuje.
  --
  -- ZMĚŘENO 14. 9. 2026 na replice reálným tokenem admina: claim s hlavičkou
  -- na klub B a polem rezervací klubu A vrátil true a doklad vznikl.
  --
  -- TATO KONTROLA DNES EXISTUJE, ALE JEN V TYPESCRIPTU — scripts/fakturoid-akce.ts
  -- i supabase/functions/fakturoid-invoice/index.ts smíšené subjekty samy
  -- odmítají. Obojí je NAD databází, takže to přeskočí kdokoli, kdo si RPC
  -- zavolá přímo — a authenticated na něj EXECUTE má. Sem to patří proto,
  -- že tady se to obejít nedá.
  --
  -- LEGITIMNÍ CESTY TO NEROZBIJE, ověřeno ve zdrojích obou volajících:
  --   * klubový doklad — podklad staví fakturoid_podklady_klub(_subject, …),
  --     tedy filtruje PRÁVĚ tím subjektem, který jde do hlavičky.
  --   * doklad za akci — fakturoid_podklady_akce(_event) filtruje podle akce,
  --     ale oba volající berou hlavičku z první rezervace podkladu a smíšené
  --     subjekty samy odmítají. Hlavička se tedy rovná podkladu i tady; tahle
  --     podmínka to jen přestává brát na dobré slovo.
  --
  -- IS DISTINCT FROM kvůli NULL na obou stranách (rezervace bez odběratele se
  -- na doklad nedostane) a LEFT JOIN kvůli id, které v reservations vůbec
  -- není — to by jinak spadlo až na cizí klíč o dva příkazy dál, s hláškou,
  -- ze které není poznat, co se stalo.
  -- ═══════════════════════════════════════════════════════════════════════
  IF EXISTS (
       SELECT 1
         FROM unnest(_rezervace) AS z(id)
         LEFT JOIN public.reservations r ON r.id = z.id
        WHERE r.id IS NULL
           OR r.subject_id IS DISTINCT FROM _subject
     ) THEN
    RAISE EXCEPTION 'Doklad zní na jiný subjekt, než komu patří % z jeho rezervací — takový doklad vystavit nejde.',
      (SELECT count(*) FROM unnest(_rezervace) AS z(id)
         LEFT JOIN public.reservations r ON r.id = z.id
        WHERE r.id IS NULL OR r.subject_id IS DISTINCT FROM _subject)
      USING HINT = 'Hlavička i podklad musí mít týž subject_id. Zkontroluj, jestli se rezervaci mezitím nezměnil odběratel.';
  END IF;

  BEGIN
    INSERT INTO public.fakturoid_invoices
      (idempotency_key, druh, subject_id, event_id, obdobi_od, obdobi_do,
       nas_soucet, radku, rezervace, rezim, created_by)
    VALUES
      (_klic, _druh, _subject, _event, _od, _do,
       _nas_soucet, _radku, _rezervace, coalesce(_rezim, 'koncept'), auth.uid())
    -- Cíl konfliktu je vyjmenovaný SCHVÁLNĚ. Holé `ON CONFLICT DO NOTHING` chytá
    -- JAKÝKOLI unikátní konflikt, takže by tiše spolklo i chybu, o které nevíme,
    -- a tvářilo se jako „klíč už drží někdo jiný".
    ON CONFLICT (idempotency_key) WHERE uvolneno_at IS NULL AND deleted_at IS NULL
    DO NOTHING
    RETURNING id INTO _id;

    -- Klíč už drží jiný živý claim.
    IF _id IS NULL THEN RETURN false; END IF;

    -- DRUHÁ POLOVINA ZÁMKU (viz `over_neni_vyfakturovano`).
    --
    -- POJISTKA, ne nosný prvek. Serializaci dnes drží už samotný cizí klíč
    -- `reservation_id → reservations(id)`: INSERT přes něj si bere na řádku
    -- rezervace `FOR KEY SHARE`, což koliduje s `FOR UPDATE` v bráně.
    -- Tenhle řádek to říká nahlas, aby záruka nezávisela na constraintu,
    -- který může příští migrace zahodit, aniž by cokoli spadlo.
    --
    -- `ORDER BY id` shodně s druhou stranou, aby nevzniklo uváznutí.
    PERFORM 1
       FROM public.reservations r
      WHERE r.id = ANY (_rezervace)
      ORDER BY r.id
        FOR UPDATE;

    INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
    SELECT _id, r FROM unnest(_rezervace) AS r;

  EXCEPTION WHEN unique_violation THEN
    -- Některá rezervace už visí na jiném fakturoidím dokladu. Subtransakce
    -- se odroluje celá, takže hlavička po sobě nenechá zablokovaný klíč.
    --
    -- `false` tu znamená totéž co výš („nezabrali jsme") a je to správně:
    -- do téhle větve se dá dostat jen ZÁVODEM, protože stav „rezervace už je
    -- na dokladu" odchytí zámek 1 (`fakturoid_je_vyfakturovana`) dřív, než se
    -- k claimu vůbec dojde. Rozlišovat to tady na chybu by z běžného souběhu
    -- udělalo poruchu.
    RETURN false;
  END;

  RETURN true;
END;
$function$;


-- -----------------------------------------------------------------------------
-- PRÁVA. `CREATE OR REPLACE` je zachovává, takže tenhle blok nic nemění — je
-- tu proto, aby stav práv byl v migraci černý na bílém a aby případný budoucí
-- `DROP + CREATE` (který ACL naopak zahodí) nezůstal bez záchytu. Odpovídá
-- doslova tomu, co je 14. 9. 2026 na produkci.
--
-- `fakturoid_zkus_zabrat` je SECURITY DEFINER a zakládá doklady, takže PUBLIC
-- ani `anon` na ni nesmí. `guard_reservation_rep_changes` se ZÁMĚRNĚ neřeší —
-- viz hlavička.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fakturoid_zkus_zabrat(text, text, uuid, uuid, date, date, numeric, integer, text, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fakturoid_zkus_zabrat(text, text, uuid, uuid, date, date, numeric, integer, text, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fakturoid_zkus_zabrat(text, text, uuid, uuid, date, date, numeric, integer, text, uuid[]) TO service_role;

-- -----------------------------------------------------------------------------
-- POST-CHECK. Ověřuje VÝSLEDEK, ne to, že příkaz doběhl. Migrace, která
-- „proběhla" a nic neudělala, je horší než ta, co spadne — 14. 9. 2026 přesně
-- takhle tiše propadl `CREATE INDEX IF NOT EXISTS` při obnově po mutačním
-- testu a nechal za sebou zmutovaný index.
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE
  _guard text;
  _zabrat text;
  _acl text;
BEGIN
  -- KOMENTÁŘE SE ODŘÍZNOU, teprve pak se počítají pozice.
  --
  -- Změřeno při prvním běhu téhle migrace 14. 9. 2026: kontrola pořadí níž
  -- hlásila „zámek stojí až za app.trusted_booking" nad kódem, kde stál
  -- správně — `position()` totiž našla první výskyt toho řetězce v MÉM
  -- VLASTNÍM KOMENTÁŘI u zámku, který ten marker jmenuje. Stráž měřila
  -- prózu, ne kód. Ověřeno, že v žádném z obou těl není `--` uvnitř
  -- řetězcového literálu, takže tohle odříznutí nic jiného neukousne.
  SELECT regexp_replace(pg_get_functiondef(
           to_regprocedure('public.guard_reservation_rep_changes()')), '--[^\n]*', '', 'g') INTO _guard;
  SELECT regexp_replace(pg_get_functiondef(to_regprocedure(
    'public.fakturoid_zkus_zabrat(text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])')),
    '--[^\n]*', '', 'g') INTO _zabrat;

  IF _guard IS NULL OR _zabrat IS NULL THEN
    RAISE EXCEPTION 'Po migraci chybí jedna z funkcí — guard je %, zabrat je %',
      COALESCE('OK', 'NULL'), COALESCE('OK', 'NULL');
  END IF;

  -- 1) Zámek A v guardu OPRAVDU je.
  IF _guard NOT LIKE '%NEW.subject_id IS DISTINCT FROM OLD.subject_id%'
     OR _guard NOT LIKE '%fakturoid_invoice_reservations%' THEN
    RAISE EXCEPTION 'Zámek A (subject_id vs fakturoidí vazba) v guard_reservation_rep_changes chybí.';
  END IF;

  -- 2) A stojí NAD adminskou výjimkou i nad markerem. Kdyby spadl pod ně,
  --    byl by tam, ale nic by nehlídal — přesně ta třída chyby, kvůli které
  --    je tenhle blok o výsledku, a ne o tom, že DDL doběhlo.
  IF position('NEW.subject_id IS DISTINCT FROM OLD.subject_id' in _guard)
     > position('IF current_setting(''app.trusted_booking'', true) = ''on'' THEN' in _guard) THEN
    RAISE EXCEPTION 'Zámek A stojí AŽ ZA výjimkou app.trusted_booking — marker by ho vypnul.';
  END IF;
  IF position('NEW.subject_id IS DISTINCT FROM OLD.subject_id' in _guard)
     > position('IF has_role(auth.uid(), ''admin'') THEN' in _guard) THEN
    RAISE EXCEPTION 'Zámek A stojí AŽ ZA adminskou výjimkou — admin by ho obešel.';
  END IF;

  -- 3) Zámek B v claimu OPRAVDU je — a hlídá se POČET VÝSKYTŮ, ne pouhý výskyt.
  --
  -- `r.subject_id IS DISTINCT FROM _subject` je v těle DVAKRÁT: jednou
  -- v podmínce EXISTS (ta zakazuje) a podruhé v poddotazu, který do hlášky
  -- počítá, kolika rezervací se to týká. Kontrola na pouhý výskyt je proto
  -- k ničemu: mutace, která vyřadí PODMÍNKU, nechá řetězec v hlášce a stráž
  -- projde zeleně. Změřeno 14. 9. 2026 mutací P3 — přesně takhle prošla.
  -- (Táž třída chyby jako u migrace 20260914210000, kde `fi.subject_id`
  -- zůstalo v SELECTu po přehození klíče seskupení.)
  IF (length(_zabrat) - length(replace(_zabrat, 'r.subject_id IS DISTINCT FROM _subject', '')))
     / length('r.subject_id IS DISTINCT FROM _subject') < 2 THEN
    RAISE EXCEPTION 'Zámek B (hlavička vs podklad) ve fakturoid_zkus_zabrat chybí nebo zůstal jen v hlášce.';
  END IF;

  -- 4) A stojí PŘED zápisem hlavičky. Kontrola za INSERTem by nechala doklad
  --    vzniknout a spolehla se na rollback volajícího.
  IF position('r.subject_id IS DISTINCT FROM _subject' in _zabrat)
     > position('INSERT INTO public.fakturoid_invoices' in _zabrat) THEN
    RAISE EXCEPTION 'Zámek B stojí AŽ ZA INSERTem hlavičky.';
  END IF;

  -- 5) Práva na claim: PUBLIC ani anon ne. Pozor na `proacl IS NULL` — to není
  --    „nikdo nemá", ale „platí výchozí stav", a ten u funkcí znamená EXECUTE
  --    pro PUBLIC.
  SELECT COALESCE(p.proacl::text, '(default)') INTO _acl
    FROM pg_proc p
   WHERE p.oid = to_regprocedure(
     'public.fakturoid_zkus_zabrat(text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])');

  IF _acl = '(default)' THEN
    RAISE EXCEPTION 'fakturoid_zkus_zabrat má výchozí ACL, tedy EXECUTE pro PUBLIC. REVOKE výš neproběhl.';
  END IF;
  IF _acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'fakturoid_zkus_zabrat má EXECUTE pro anon: %', _acl;
  END IF;
  -- Grant pro PUBLIC se v ACL píše s PRÁZDNÝM jménem příjemce.
  IF _acl LIKE '{=%' OR _acl LIKE '%,=%' THEN
    RAISE EXCEPTION 'fakturoid_zkus_zabrat má EXECUTE pro PUBLIC: %', _acl;
  END IF;
  IF _acl NOT LIKE '%authenticated=X%' OR _acl NOT LIKE '%service_role=X%' THEN
    RAISE EXCEPTION 'fakturoid_zkus_zabrat ztratila EXECUTE pro authenticated nebo service_role: %', _acl;
  END IF;

  RAISE NOTICE 'Zámek příjemce: A v guardu ✔ (nad markerem i adminem), B v claimu ✔ (před INSERTem), práva ✔ (%)', _acl;
END
$kontrola$;
