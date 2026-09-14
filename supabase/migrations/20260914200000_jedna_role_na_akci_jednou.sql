-- =============================================================================
-- JEDNA ROLE NA AKCI JENOM JEDNOU — a nedá se to obejít schvalovací frontou
-- =============================================================================
--
-- CO SE MĚNÍ: nic na pravidle, všechno na jeho vymahatelnosti.
--
-- Pravidlo platí od 1. 9. 2026 a zůstává beze změny:
--   * TÁŽ role na téže akci dvakrát  → zakázáno (tatáž práce, dvakrát placená)
--   * RŮZNÉ role na téže akci        → povoleno (bar + instruktor je běžný
--     provoz a platí se za obojí — potvrzeno klientem)
--
-- NÁLEZ (14. 9. 2026): kontrola seděla uvnitř větve `open -> pending`, tedy
-- jen na samoobslužné cestě. Schvalování přihlášky jde jinudy —
-- `useShiftApplications.approveApplication` píše rovnou `open -> claimed` —
-- takže se kontrola PŘESKOČILA CELÁ. Změřeno na replice produkce reálným
-- tokenem (`SET LOCAL ROLE authenticated` + JWT admina), dva příkazy za sebou,
-- žádný souběh:
--
--   UPDATE shifts SET status='claimed', claimed_by='<X>' WHERE id='<A>';  → UPDATE 1
--   UPDATE shifts SET status='claimed', claimed_by='<X>' WHERE id='<B>';  → UPDATE 1
--   → týž člověk, TÁŽ role `instructor`, táž akce, obě směny `claimed`
--
-- Táž věta přes samoobsluhu přitom padala na „Na této akci už tuhle roli máte."
-- Nešlo tedy o chybějící pravidlo, ale o pravidlo hlídané na jedné ze dvou cest.
--
-- STAV PRODUKCE PŘED MIGRACÍ (ověřeno dotazem 14. 9. 2026):
--   * porušení pravidla „táž role dvakrát"            → 0 případů
--   * lidí s víc rolemi na jedné akci                 → 1 (instructor + bar_staff,
--     obě `completed`, tedy odpracované a proplacené) — tenhle případ je
--     LEGITIMNÍ a migrace se ho nesmí dotknout. Proto je v klíči i `required_role`.
--
-- POZOR, TENHLE INDEX UŽ JEDNOU ZAMÍTNUTÝ BYL — A SPRÁVNĚ.
-- Migrace 20260901160000 (nález 10) k tomu píše doslova:
--
--   „Původní návrh sem chtěl unikátní index na (event_id, claimed_by), tedy
--   »jeden člověk, jedna směna na akci«. JE TO FALEŠNÝ POPLACH a index by
--   blokoval legitimní provoz: podle Jakuba (potvrzeno 1. 9. 2026) může jeden
--   člověk na jedné akci dělat DVĚ RŮZNÉ ROLE a dostat za obě zaplaceno."
--
-- To pořád platí a tahle migrace to NERUŠÍ. Rozdíl je jediný, ale podstatný:
-- v klíči je navíc `required_role`. Tím index přestává být tím falešným
-- poplachem — nezakazuje druhou ROLI, zakazuje druhou TÉŽE role. Kdyby
-- z klíče `required_role` kdykoli vypadlo, je to zpátky ta zamítnutá varianta;
-- scénář 3 v `supabase/tests/jedna_role_na_akci_test.sql` na to spadne.
--
-- ROZSAH (odsouhlaseno 14. 9. 2026): hlídá se táž role, na živých i dokončených
-- směnách (`pending`/`claimed`/`completed`); `cancelled` a `open` se nepočítají,
-- takže zrušená ani uvolněná směna nikomu neblokuje novou. Historie se nepřepisuje.
--
-- DVĚ VRSTVY SCHVÁLNĚ:
--   1) unikátní index = tvrdá záruka. Drží i na INSERT a na cestách, které
--      `BEFORE UPDATE` trigger vůbec neuvidí. Tohle je ta „zábrana na DB úrovni".
--   2) trigger        = srozumitelná hláška česky, aby uživatel nečetl
--      „duplicate key value violates unique constraint".
-- Kdyby zůstal jen trigger, opakuje se přesně ta dnešní chyba: hlídaná cesta
-- a vedle ní nehlídaná.
--
-- IDEMPOTENTNÍ: `IF NOT EXISTS` + `CREATE OR REPLACE`. Viz CLAUDE.md, pravidlo 6 —
-- dávka migrací není atomická, takže opakovaný push musí projít.
--
-- VRATNOST:
--   DROP INDEX IF EXISTS public.shifts_jedna_role_na_akci;
--   `validate_shift_claim` zpět z migrace
--   `20260903180000_zavrena_smena_je_zavrena.sql` (řádky 79–473) — ověřeno
--   14. 9. 2026 jako kódově shodné s produkcí PŘED touhle migrací.
--   ⚠️ POZOR: PO PUSHI UŽ STARÉ TĚLO Z `pg_get_functiondef` NEDOSTANEŠ —
--   vrátí se ti to nové. Jediný zdroj pro rollback je ta migrace nebo dump.
--   `DROP INDEX` je bezztrátový (index nenese data) a vrácení funkce je čisté
--   `CREATE OR REPLACE`: OID zůstává, trigger `validate_shift_before_update`
--   se nerozváže.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Kontrola dat PŘED indexem
-- ---------------------------------------------------------------------------
-- `CREATE UNIQUE INDEX` by na porušených datech spadl taky, ale hláškou, ze
-- které není poznat KDO a NA KTERÉ AKCI. Tohle to vypíše.
DO $$
DECLARE _kolik int;
BEGIN
  SELECT count(*) INTO _kolik FROM (
    SELECT 1 FROM public.shifts
     WHERE claimed_by IS NOT NULL
       AND status IN ('pending', 'claimed', 'completed')
     GROUP BY event_id, claimed_by, required_role
    HAVING count(*) > 1
  ) x;
  IF _kolik > 0 THEN
    RAISE EXCEPTION 'Nelze zavést unikátnost: % dvojic porušuje „jedna role na akci jednou". Nejdřív je vyřeš, pak migruj.', _kolik
      USING HINT = 'SELECT event_id, claimed_by, required_role, count(*) FROM shifts WHERE claimed_by IS NOT NULL AND status IN (''pending'',''claimed'',''completed'') GROUP BY 1,2,3 HAVING count(*) > 1;';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2) Tvrdá záruka: unikátní index
-- ---------------------------------------------------------------------------
-- `NULLS NOT DISTINCT` (PG 15+, produkce běží 17.6) schválně: směny bez role
-- (starší cesta přes `events.required_staff`) mají `required_role` NULL a bez
-- tohohle by se dvě takové na jedné akci NEsrazily — v indexu jsou NULL hodnoty
-- normálně různé. Odpovídá to `IS NOT DISTINCT FROM` v triggeru.
--
-- `cancelled` v predikátu chybí ZÁMĚRNĚ: zrušená směna nesmí nikomu blokovat
-- novou na téže akci. `open` se nefiltruje zvlášť — tam je `claimed_by` NULL.
--
-- Bez CONCURRENTLY: uvnitř migrace neprojde (SQLSTATE 25001, viz CLAUDE.md).
-- `shifts` má 57 řádků, zámek je okamžik.
--
-- Vzor převzat z `shifts_jeden_trener_na_akci`, který tu stejnou práci dělá
-- pro trenéry od 12. 9. 2026.
CREATE UNIQUE INDEX IF NOT EXISTS shifts_jedna_role_na_akci
    ON public.shifts (event_id, claimed_by, required_role) NULLS NOT DISTINCT
 WHERE claimed_by IS NOT NULL
   AND status IN ('pending', 'claimed', 'completed');

COMMENT ON INDEX public.shifts_jedna_role_na_akci IS
  'Jeden člověk nesmí mít na jedné akci dvakrát tutéž roli (různé role povolené jsou). Tvrdá záruka pod triggerem validate_shift_claim — drží i na INSERT.';

-- POSTKONTROLA: `IF NOT EXISTS` POROVNÁVÁ JEN JMÉNO, NE DEFINICI.
--
-- Kdyby na databázi existoval index téhož jména s jiným klíčem, `CREATE INDEX
-- IF NOT EXISTS` ho TIŠE PŘESKOČÍ a migrace skončí zeleně nad indexem, který
-- hlídá něco jiného. Dvě konkrétní podoby té chyby, obě popsané výš:
--   * bez `required_role` v klíči → je to zpátky varianta zamítnutá 1. 9. 2026,
--     která blokuje legitimní „bar + instruktor"
--   * bez `NULLS NOT DISTINCT`   → dvě směny bez role se přestanou srážet
-- Proto se výsledek kontroluje, ne předpokládá. Sesterská migrace
-- 20260901160000 má postkontrolu ze stejného důvodu.
DO $$
DECLARE _def text;
BEGIN
  SELECT indexdef INTO _def FROM pg_indexes
   WHERE schemaname = 'public' AND indexname = 'shifts_jedna_role_na_akci';
  IF _def IS NULL THEN
    RAISE EXCEPTION 'Index shifts_jedna_role_na_akci po migraci neexistuje.';
  END IF;
  IF _def NOT LIKE '%required_role%' THEN
    RAISE EXCEPTION 'Index shifts_jedna_role_na_akci nemá v klíči required_role — to je varianta zamítnutá 1. 9. 2026, blokovala by bar + instruktora. Definice: %', _def;
  END IF;
  IF _def NOT LIKE '%NULLS NOT DISTINCT%' THEN
    RAISE EXCEPTION 'Index shifts_jedna_role_na_akci nemá NULLS NOT DISTINCT — dvě směny bez role by se nesrazily. Definice: %', _def;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Srozumitelná hláška: kontrola se stěhuje ven z větve `open -> pending`
-- ---------------------------------------------------------------------------
-- Tělo funkce je vygenerované z `pg_get_functiondef` živého schématu a je do něj
-- vložen POUZE tenhle zásah (CLAUDE.md, pravidlo 7 — přepis z paměti už jednou
-- utnul půlku bezpečnostního guardu). Ověřeno diffem proti originálu.
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- =========================================================================
  -- NA ZRUŠENÉ AKCI SMĚNA NEŽIJE (Jakubův nález, 3. 9. 2026)
  -- =========================================================================
  -- Úklid při zrušení rezervace (`cancel_open_shifts_on_reservation_cancel`)
  -- je JEDNORÁZOVÝ: sáhne na směny v okamžiku zrušení a víc se neozve. Jenže
  -- život směny pokračuje i potom. Změřeno na produkci, akce „Teambuilding
  -- Hybridní vzdělávání, s.r.o.":
  --
  --     15:52  rezervace confirmed, 2 instruktorské směny open
  --     15:54  jednu si někdo vzal            open    -> claimed
  --     15:56  rezervace ZRUŠENA              (úklid uklidil jen tu druhou)
  --   +1 den   držitel směnu pustil           claimed -> open   ← nabídka je zpátky
  --
  -- Ten poslední krok by se stal i s opraveným úklidem — uvolnění přijde AŽ PO
  -- zrušení a nikdo se v tu chvíli neptá, jestli akce ještě je. Proto tahle
  -- brána není další úklid, ale INVARIANT: platí při každém UPDATE, ne jednou.
  --
  -- Dvě různé odpovědi schválně:
  --   * do `pending`/`claimed` (zabrání, schválení) → TVRDĚ ODMÍTNOUT
  --   * do `open` (uvolnění, zamítnutí, revokeApproval) → PŘEPSAT na `cancelled`
  -- Uvolnit se člověk musí umět vždycky; jen ta směna nesmí skončit jako živá
  -- nabídka. Chybou by se držitel zasekl na akci, která se nekoná.
  --
  -- Hlídají se JEN SKUTEČNÉ PŘECHODY (`OLD.status IS DISTINCT FROM ...`).
  -- Kdyby brána reagovala na každý UPDATE, adminovi by úprava sazby na takové
  -- směně tiše přepsala stav — to je přesně ten druh překvapení, co se pak
  -- hledá půl dne.
  --
  -- `completed` se NEDOTÝKÁ: odpracovaná směna je podklad pro výplatu (táž
  -- hranice jako v `odeber_trenera` i v úklidu při zrušení).
  -- =========================================================================
  -- ZAVŘENÁ SMĚNA JE ZAVŘENÁ (nálezy N1 a N2, 3. 9. 2026)
  -- =========================================================================
  -- `cancelled` nebyl koncový stav, jen další stav na cestě. Dvě měřené díry:
  --
  -- N2 (regrese z 20260903120000, moje): větev politiky pro `status='cancelled'`
  -- nemá kontrolu vlastnictví, takže kterýkoli člen štábu přepsal cizí ZAVŘENOU
  -- směnu na zrušené akci. Změřeno na replice, útočník `instructor` bez admina:
  --
  --   UPDATE shifts SET claimed_by='<já>', cancelled_by='<kolega>',
  --          cancelled_at='2020-01-01' WHERE id='<cizí zrušená směna>';  → PROŠLO
  --
  -- Na peníze to necestuje (`completed` chrání brána níž), ale je to přepsání
  -- auditní stopy — přímo proti požadavku klienta „musí být vidět, kdo co
  -- zadával". S předmigrační politikou totéž padalo na RLS.
  --
  -- N1 (starší, od 20260902240000): zrušenou směnu na ŽIVÉ akci šlo jedním
  -- UPDATE oživit. Změřeno: zrušená trenérská směna za 600 Kč/h, útočník není
  -- trenér ani admin →  status=pending, drží ji on, sazba 600 zděděná.
  -- Prochází mezi guardy: `akce_je_zrusena` je false (akce žije), takže brána
  -- ze zrušených akcí mlčí; „tuhle směnu už má někdo jiný" vyžaduje
  -- `OLD.status IN ('pending','claimed','completed')` a `cancelled` tam není;
  -- větev `open -> pending` se nespustí, takže se přeskočí i „na této akci už
  -- tuhle roli máte". Sazba se DĚDÍ, nemění, takže brána na sazbu nesáhne.
  --
  -- Řešení je pro obojí jedno: pro neadmina je zavřený řádek zmrazený —
  -- nezmění se ani stav, ani kdo ho držel, ani kdo a kdy ho zavřel.
  --
  -- Admin výjimku má (přeobsazení a opravy jsou legitimní provozní úkon)
  -- a `postgres` taky, kvůli datovým nápravám v migracích.
  --
  -- Legitimní cesty tím nepadnou: ověřeno, že `dorovnej_stab`, `prirad_trenera`,
  -- `odeber_trenera`, `zmen_typ_akce` ani `cancel_open_shifts_on_reservation_cancel`
  -- zrušenou směnu NIKDY neoživují — všechny jen zavírají.
  --
  -- CO TO ZAVAZUJE DO BUDOUCNA: jakýkoli hromadný UPDATE směn přes `event_id`
  -- musí od teď vyloučit `cancelled`, jinak neadminovi spadne na téhle bráně.
  -- Změřeno: úklid směn neadminem na akci, kde už jedna `cancelled` směna leží,
  -- projde jen s tím filtrem; bez něj skončí na „Do zrušené směny už zapisovat
  -- nelze." Všechny dnešní cesty ten filtr mají.
  IF OLD.status = 'cancelled'
     AND NOT has_role(auth.uid(), 'admin')
     AND NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin')) THEN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Zrušenou směnu znovu otevírá jen správce haly.'
        USING HINT = 'Když se akce koná, ať ti ji správce otevře nebo založí novou.';
    END IF;
    IF NEW.claimed_by    IS DISTINCT FROM OLD.claimed_by
       OR NEW.cancelled_by  IS DISTINCT FROM OLD.cancelled_by
       OR NEW.cancelled_at  IS DISTINCT FROM OLD.cancelled_at
       OR NEW.claimed_at    IS DISTINCT FROM OLD.claimed_at
       OR NEW.completed_at  IS DISTINCT FROM OLD.completed_at
       OR NEW.required_role IS DISTINCT FROM OLD.required_role THEN
      RAISE EXCEPTION 'Do zrušené směny už zapisovat nelze.'
        USING HINT = 'Kdo ji držel, kdy a kdo ji zavřel, je auditní stopa.';
    END IF;
  END IF;

  -- ZAVÍRÁNÍ SE PODEPISUJE TOMU, KDO ZAVÍRÁ — A CIZÍ OBSAZENOU NE (nález N3).
  --
  -- Zmrazení výš platí až OD chvíle, kdy je řádek `cancelled`. PŘECHOD DO
  -- `cancelled` nehlídalo nic: kontrola „Nemůžete zrušit cizí směnu" se ptá jen
  -- na `NEW.status = 'open'`, a guard „už ji má někdo jiný" vyžaduje
  -- `NEW.claimed_by IS NOT NULL`. Stačilo tedy psát `cancelled` přímo a
  -- `claimed_by` nastavit na NULL. Změřeno, `instructor` bez admina, jeden
  -- příkaz na KOLEGOVĚ `claimed` směně:
  --
  --   UPDATE shifts SET status='cancelled', claimed_by=NULL,
  --          cancelled_by='<kolega>', cancelled_at='2020-01-01' WHERE id='<cizí>';
  --   → prošlo: kolegovi zmizela směna I ZÁZNAM, že ji držel, a zavření je
  --     podepsané někým třetím a antedatované do roku 2020
  --
  -- Je to zrcadlo nálezu z 20260903160000: tam se obcházelo přes `open`,
  -- tady přes `cancelled`. Dosažitelnost dnes nulová (na produkci není živá
  -- směna na zrušené akci), ale jakmile jedna vznikne, slib té migrace
  -- „kdo ji držel, kdy a kdo ji zavřel, je auditní stopa" přestane platit.
  --
  -- DVĚ VÝJIMKY, protože jedna nestačí:
  --
  -- `pg_trigger_depth() <= 1` odlišuje PŘÍMÝ zápis od systémového úklidu.
  -- Změřeno: přímý UPDATE na `shifts` = 1, kaskáda z
  -- `cancel_open_shifts_on_reservation_cancel` (AFTER UPDATE na `reservations`)
  -- = 2. Bez toho by rušení rezervace zástupcem klubu spadlo — ten úklid ruší
  -- cizí obsazené směny a `auth.uid()` je v něm pořád volající, ne `postgres`.
  --
  -- `app.uklid_trenera` pokrývá to, co hloubka NEODLIŠÍ: `prirad_trenera`
  -- a `odeber_trenera` jsou RPC, ne triggery, takže hloubka je 1 stejně jako
  -- u přímého zápisu z API — a obě zavírají směnu, kterou drží TRENÉR, tedy
  -- někdo jiný než volající zástupce klubu. Změřeno: s první podobou téhle
  -- brány zástupce klubu trenéra vůbec neodebral. Marker si obě funkce nastaví
  -- samy, až ZA svými kontrolami práv (jinak by to byl obchvat, ne marker) —
  -- táž konstrukce, jakou už používá `zmen_typ_akce` s `app.preceneni`.
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled'
     AND NOT has_role(auth.uid(), 'admin')
     AND NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND pg_trigger_depth() <= 1
     AND coalesce(current_setting('app.uklid_trenera', true), 'off') <> 'on' THEN
    IF OLD.claimed_by IS NOT NULL AND OLD.claimed_by <> auth.uid() THEN
      RAISE EXCEPTION 'Nemůžete zrušit cizí směnu.'
        USING HINT = 'Zavřít cizí obsazenou směnu může jen správce haly.';
    END IF;
    -- Držitel se NEMAŽE (je to auditní stopa) a podpis nese ten, kdo zavírá.
    -- Pozn.: cesta „uvolnění" (`open` -> přepis na konci funkce) `claimed_by`
    -- naopak nechává na NULL — tam se ho držitel vzdal sám, což je jiná věta
    -- než „někdo zavřel směnu, kterou držel kolega".
    NEW.claimed_by   := OLD.claimed_by;
    NEW.cancelled_by := auth.uid();
    NEW.cancelled_at := now();
  END IF;

  -- IDENTITA A DATUM ZALOŽENÍ SE NEPŘEPISUJÍ (nález N4).
  --
  -- `id` ani `created_at` nehlídal nikdo. Přepis `id` odpojí řádek od jeho
  -- historie v `audit_log` (ta se váže přes `record_id`), přepis `created_at`
  -- navíc mění pořadí, podle kterého `dorovnej_stab` ruší přebytek
  -- (`ORDER BY created_at DESC, id DESC`). Obojí změřeno jako průchozí na volné
  -- směně, bez vypínání čehokoli. Není to regrese těchhle migrací, ale je to
  -- táž věta „musí být vidět, kdo co zadával" a jsou to dva řádky.
  IF (NEW.id IS DISTINCT FROM OLD.id OR NEW.created_at IS DISTINCT FROM OLD.created_at)
     AND NOT has_role(auth.uid(), 'admin')
     AND NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin')) THEN
    RAISE EXCEPTION 'Identitu ani datum založení směny přepsat nelze.'
      USING HINT = 'Váže se na ně auditní historie.';
  END IF;

  -- ROLI NA SMĚNĚ MĚNÍ JEN SPRÁVCE HALY.
  --
  -- `required_role` nehlídalo při UPDATE nic — ani politika, ani trigger —
  -- a `trg_shifts_sazba` je BEFORE INSERT ONLY, takže se sazba při změně role
  -- NEPŘEPOČÍTÁ a brána na peníze si ničeho nevšimne. Změřeno, řadový
  -- brigádník, jeden příkaz na volné směně `bar_staff` za 150 Kč/h:
  --
  --   UPDATE shifts SET status='pending', claimed_by=auth.uid(),
  --          required_role='trainer' WHERE id='<volná směna>';
  --   → role=trainer, drží ji člověk bez role trenéra, sazba zůstala 150
  --
  -- Dvě škody: v rozpisu i v auditu visí trenérská směna na někom, kdo tu roli
  -- nemá (totéž pravidlo hlídá `prirad_trenera` výslovně), a hlavně se tím
  -- obchází „jednu roli jednou": kontrola porovnává `required_role`, takže
  -- druhou směnu na téže akci si člověk vezme prostě tak, že jí přepíše roli.
  -- To je „tatáž práce vykázaná dvakrát", kvůli které ta kontrola vznikla.
  --
  -- Není to regrese z těchhle migrací — je to starší mezera, kterou našla
  -- bezpečnostní brána u téhle změny. Zavírá se tady, protože je to tatáž
  -- funkce a jeden řádek.
  --
  -- Legitimní cesty to nerozbije: `prirad_trenera`, `odeber_trenera`
  -- ani `zmen_typ_akce` roli nikdy nenastavují, jen na ni filtrují (ověřeno).
  IF NEW.required_role IS DISTINCT FROM OLD.required_role
     AND NOT has_role(auth.uid(), 'admin')
     AND NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin')) THEN
    RAISE EXCEPTION 'Roli na směně mění jen správce haly.'
      USING HINT = 'Když je rozpis špatně, ať ho opraví správce.';
  END IF;

  -- SMĚNA SE MEZI AKCEMI NESTĚHUJE.
  --
  -- Tohle je záplata na díru, kterou otevřela migrace 20260903120000 (a která
  -- na produkci žila asi hodinu). Nová větev politiky `shifts` pouští výsledný
  -- řádek se `status='cancelled'`, když `akce_je_zrusena(event_id)` — jenže
  -- `event_id` si do toho UPDATE dosadí sám volající a nikdo ho nehlídal.
  -- Změřeno na replice, útočník `instructor` bez adminské role, bez souběhu:
  --
  --   UPDATE shifts SET status='cancelled', event_id='<zrušená akce>'
  --    WHERE id='<cizí claimed směna kolegy na ŽIVÉ akci>';   → prošlo
  --
  -- Kolegovi tím zmizela potvrzená směna a ještě se přestěhovala na cizí akci.
  -- Táž věta přes `status='open'` obešla i hlášku „Nemůžete zrušit cizí směnu".
  -- Před migrací 20260903120000 obojí spolehlivě padalo na RLS.
  --
  -- `event_id` nemá důvod se měnit NIKDY: směna patří k akci, pro kterou
  -- vznikla. Žádná cesta v aplikaci ho nepřepisuje (ověřeno) a žádná z funkcí
  -- `dorovnej_stab`, `prirad_trenera`, `odeber_trenera`, `zmen_typ_akce` ani
  -- `cancel_open_shifts_on_reservation_cancel` ho v UPDATE nenastavuje.
  IF NEW.event_id IS DISTINCT FROM OLD.event_id THEN
    RAISE EXCEPTION 'Směnu nelze přesunout na jinou akci.'
      USING HINT = 'Zruš ji a založ novou u té správné akce.';
  END IF;

  -- NA ZRUŠENÉ AKCI SE SMĚNA NEOBSAZUJE.
  --
  -- Druhá polovina pravidla (uvolnění → `cancelled`) je schválně až na konci
  -- funkce, za kontrolami vlastnictví. Když se `NEW.status` přepsal tady
  -- nahoře, větve níž, které se ptají na `NEW.status = 'open'`, se přestaly
  -- spouštět — a s nimi i „Nemůžete zrušit cizí směnu" a „cizí přihlášku".
  -- Autorizační kontrola vyřazená pořadím je pořád vyřazená kontrola.
  IF OLD.status <> 'completed' AND public.akce_je_zrusena(NEW.event_id)
     AND NEW.status IN ('pending', 'claimed')
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    RAISE EXCEPTION 'Akce je zrušená, směnu na ní vzít nelze.'
      USING HINT = 'Nabídka na zrušené akci se zavírá, ne obsazuje.';
  END IF;

  -- SAZBU A HODINY MĚNÍ JEN SPRÁVCE HALY.
  --
  -- Tohle je jediné místo, kde se dá poznat, ŽE se ta čísla mění: politika vidí
  -- jen výslednou podobu řádku, ne rozdíl proti původní. Proto brána sedí tady
  -- a ne ve `WITH CHECK`.
  --
  -- Nesmí to být „jen při zabírání". Kdyby se hlídal jen přechod
  -- `open -> pending`, stačí sazbu nadhodnotit jedním příkazem předem
  -- a druhým si směnu vzít — změřeno, obojí prošlo.
  IF (NEW.hourly_rate  IS DISTINCT FROM OLD.hourly_rate
      OR NEW.hours_worked IS DISTINCT FROM OLD.hours_worked
      OR NEW.payout_id    IS DISTINCT FROM OLD.payout_id
      OR NEW.notes        IS DISTINCT FROM OLD.notes)
     AND NOT has_role(auth.uid(), 'admin')
     AND NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin')) THEN
    RAISE EXCEPTION 'Sazbu, hodiny, vazbu na výplatu ani poznámku si na směně nastavit nemůžete.'
      USING HINT = 'Vyplňuje je správce haly, když směnu dokončuje a proplácí.';
  END IF;

  -- UZAVŘENOU SMĚNU ZNOVU OTEVÍRÁ JEN SPRÁVCE HALY.
  --
  -- Bez tohohle je guard nad ním k ničemu — útočník ta čísla NEPOTŘEBUJE MĚNIT,
  -- on je ZDĚDÍ. `validate_shift_claim()` měla větve pro open→pending,
  -- pending→claimed, pending→open, claimed→open a claimed→completed, ale
  -- `completed → open` nehlídalo nic a politika ten tvar řádku pouští.
  --
  -- Změřeno na cizí DOKONČENÉ trenérské směně (8 h × 600 Kč), dva obyčejné
  -- UPDATE, žádný souběh, žádná adminská role, útočník `part_time_staff`
  -- se sazbou 150 Kč/h:
  --     UPDATE shifts SET status='open', claimed_by=NULL, completed_at=NULL …
  --     UPDATE shifts SET status='pending', claimed_by=<já> …
  --   → drží ji útočník, pořád 8 h × 600 Kč = 4 800 Kč
  --
  -- Dvojí škoda: kolegovi zmizí z dokončené směny podklad k výplatě
  -- a přebírá se i NAPŘÍČ ROLEMI (nic neváže `required_role` na role žadatele).
  IF OLD.status = 'completed' AND NEW.status IS DISTINCT FROM 'completed'
     AND NOT has_role(auth.uid(), 'admin')
     AND NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin')) THEN
    RAISE EXCEPTION 'Uzavřenou směnu znovu otevírá jen správce haly.'
      USING HINT = 'Je to podklad pro výplatu.';
  END IF;
  -- Validace hours_worked
  IF NEW.hours_worked IS NOT NULL THEN
    IF NEW.hours_worked < 0.1 OR NEW.hours_worked > 24 THEN
      RAISE EXCEPTION 'Hodiny musí být mezi 0.1 a 24';
    END IF;
  END IF;

  -- Validace hourly_rate
  IF NEW.hourly_rate IS NOT NULL THEN
    IF NEW.hourly_rate < 1 OR NEW.hourly_rate > 10000 THEN
      RAISE EXCEPTION 'Hodinová sazba musí být mezi 1 a 10000 Kč';
    END IF;
  END IF;

  -- CIZÍ ZABRANOU SMĚNU NIKDO NEPŘEVEZME.
  --
  -- Kontrola níž hlídá jen přechod `open -> pending`. Jakmile je řádek
  -- `pending`, ta větev se nespustí vůbec — a `UPDATE shifts SET claimed_by =
  -- <já>` pak projde komukoli ze štábu, protože politika `Staff can update
  -- shifts` zápis pouští. Ověřeno na živém schématu, a NEPOTŘEBUJE TO ANI
  -- SOUBĚH: dvě po sobě jdoucí transakce stačí, druhá tiše přepsala první
  -- a původnímu zájemci se nic nezobrazilo. Výplata pak jde tomu druhému.
  --
  -- Souběžné zabrání téhož řádku zavírá tatáž podmínka: oba `UPDATE` se
  -- serializují na zámku řádku, takže ten druhý uvidí `OLD.status = 'pending'`
  -- a narazí tady.
  --
  -- Admin výjimku má — přeobsadit směnu za někoho jiného je legitimní provozní
  -- úkon (nemoc, výměna). Odhlásit se sám smí i držitel: tam se `claimed_by`
  -- vrací na NULL, ne na cizí osobu.
  IF OLD.claimed_by IS NOT NULL
     AND NEW.claimed_by IS NOT NULL
     AND NEW.claimed_by IS DISTINCT FROM OLD.claimed_by
     AND OLD.status IN ('pending', 'claimed', 'completed')
     AND NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Tuhle směnu už má někdo jiný.'
      USING HINT = 'Přeobsadit ji může jen správce haly.';
  END IF;

  -- Staff žádá o směnu (open -> pending)
  IF OLD.status = 'open' AND NEW.status = 'pending' THEN
    IF OLD.claimed_by IS NOT NULL THEN
      RAISE EXCEPTION 'Směna již byla obsazena';
    END IF;
  END IF;

  -- JEDNU ROLI JEDNOU, RŮZNÉ ROLE KLIDNĚ OBĚ.
  --
  -- Co zůstává zakázané: TÁŽ ROLE na téže akci dvakrát. To není druhá práce,
  -- to je tatáž práce vykázaná dvakrát — a rovnou dvakrát placená.
  -- Různé role naopak povolené JSOU: brigádník, který na jedné akci dělá bar
  -- a zároveň instruktora, je běžný provoz a platí se za obojí (potvrzeno
  -- klientem 1. 9. 2026). Tohle pravidlo se nemění, jen se přestává dát obejít.
  --
  -- `IS NOT DISTINCT FROM` schválně: směny bez role (starší cesta přes
  -- `events.required_staff`) mají `required_role` NULL a dvě takové na jedné
  -- akci jsou taky jen jedna práce dvakrát.
  --
  -- PROČ SE TENHLE BLOK STĚHOVAL VEN Z `open -> pending` (nález 14. 9. 2026):
  -- seděl uvnitř větve, která se spustí JEN při samoobslužném zabrání směny.
  -- Schvalování přihlášky ale jde jinudy — `useShiftApplications.approveApplication`
  -- píše rovnou `open -> claimed` —, takže se kontrola PŘESKOČILA CELÁ.
  -- Změřeno na replice reálným tokenem (`SET LOCAL ROLE authenticated`,
  -- JWT admina), dva příkazy, žádný souběh:
  --
  --   UPDATE shifts SET status='claimed', claimed_by='<X>' WHERE id='<směna A>';
  --   UPDATE shifts SET status='claimed', claimed_by='<X>' WHERE id='<směna B>';
  --   → obě `claimed`, týž člověk, TÁŽ role `instructor`, táž akce → prošlo
  --
  -- Táž věta přes samoobsluhu (`open -> pending`) přitom spolehlivě padala.
  -- Proto se teď hlídá KAŽDÝ přechod do obsazeného stavu, ne jedna jeho cesta.
  --
  -- Podmínka na změnu schválně: bez ní by kontrola běžela i při úpravě hodin
  -- nebo sazby na dokončené směně, kde se obsazení vůbec nemění.
  --
  -- Tvrdou zárukou je unikátní index `shifts_jedna_role_na_akci` — ten drží
  -- i na INSERT a i na cestách, které trigger neuvidí. Tenhle blok je tu kvůli
  -- srozumitelné hlášce, ne místo něj.
  IF NEW.claimed_by IS NOT NULL
     AND NEW.status IN ('pending', 'claimed', 'completed')
     AND (NEW.claimed_by    IS DISTINCT FROM OLD.claimed_by
          OR NEW.status        IS DISTINCT FROM OLD.status
          OR NEW.required_role IS DISTINCT FROM OLD.required_role) THEN
    IF EXISTS (
      SELECT 1 FROM public.shifts
      WHERE event_id = NEW.event_id
        AND claimed_by = NEW.claimed_by
        AND id != NEW.id
        AND required_role IS NOT DISTINCT FROM NEW.required_role
        AND status IN ('pending', 'claimed', 'completed')
    ) THEN
      -- Dvě znění: kdo si směnu bere sám, čte „máte"; admin, který přiřazuje
      -- někoho jiného, by na „máte" jen koukal, koho že se to týká.
      IF NEW.claimed_by = auth.uid() THEN
        RAISE EXCEPTION 'Na této akci už tuhle roli máte.'
          USING HINT = 'Jinou roli na téže akci si vzít můžete.';
      ELSE
        RAISE EXCEPTION 'Tenhle člověk už na této akci tuhle roli má.'
          USING HINT = 'Jinou roli na téže akci mu přiřadit můžete.';
      END IF;
    END IF;
  END IF;

  -- Admin schvaluje směnu (pending -> claimed)
  IF OLD.status = 'pending' AND NEW.status = 'claimed' THEN
    IF NOT has_role(auth.uid(), 'admin') THEN
      RAISE EXCEPTION 'Pouze admin může schválit směnu';
    END IF;
  END IF;

  -- Zamítnutí směny (pending -> open)
  IF OLD.status = 'pending' AND NEW.status = 'open' THEN
    IF NOT has_role(auth.uid(), 'admin') THEN
      IF OLD.claimed_by != auth.uid() THEN
        RAISE EXCEPTION 'Nemůžete zrušit cizí přihlášku';
      END IF;
    END IF;
  END IF;

  -- Zrušení schválené směny
  IF OLD.status = 'claimed' AND NEW.status = 'open' THEN
    IF OLD.claimed_by != auth.uid() AND NOT has_role(auth.uid(), 'admin') THEN
      RAISE EXCEPTION 'Nemůžete zrušit cizí směnu';
    END IF;
  END IF;

  -- Dokončení směny (claimed -> completed) - pouze admin
  IF OLD.status = 'claimed' AND NEW.status = 'completed' THEN
    IF NOT has_role(auth.uid(), 'admin') THEN
      RAISE EXCEPTION 'Pouze admin může dokončit směnu';
    END IF;

    IF NEW.hours_worked IS NULL OR NEW.hours_worked <= 0 THEN
      RAISE EXCEPTION 'Musíte zadat odpracované hodiny';
    END IF;
  END IF;

  -- UVOLNĚNÍ NA ZRUŠENÉ AKCI ZAVÍRÁ, NEOTVÍRÁ.
  --
  -- Až tady, za kontrolami vlastnictví výš: kdo nesmí sáhnout na cizí směnu,
  -- narazil už na ně. Kdo uvolňuje svoji (nebo je to admin), tomu se výsledek
  -- překlopí z `open` na `cancelled` — odhlásit se musí jít vždycky, jen z toho
  -- nesmí zůstat živá nabídka na akci, která se nekoná.
  IF OLD.status <> 'completed' AND NEW.status = 'open'
     AND OLD.status IS DISTINCT FROM 'open'
     AND public.akce_je_zrusena(NEW.event_id) THEN
    NEW.status       := 'cancelled';
    NEW.cancelled_at := now();
    NEW.cancelled_by := auth.uid();
  END IF;

  RETURN NEW;
END;
$function$

;
