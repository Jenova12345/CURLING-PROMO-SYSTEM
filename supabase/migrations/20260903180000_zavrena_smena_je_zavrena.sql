-- =============================================================================
-- Zavřená směna je zavřená (nálezy N1 a N2 z bezpečnostní brány, 3. 9. 2026)
-- =============================================================================
-- OPRAVA TVRZENÍ Z PŘEDCHOZÍ MIGRACE
--
-- Hlavička `20260903160000` říká: „Obě funkce jsou převzaté ze ŽIVÉHO schématu
-- (`pg_get_functiondef`) a ověřené diffem: 0 odebraných řádků."
-- **Pro `validate_shift_claim` to NEPLATÍ.** Deset řádků kódu z horního bloku
-- zmizelo a objevilo se dole ve dvou kusech — což byl smysl té změny (přesun
-- za kontroly vlastnictví), takže je to sémanticky v pořádku, ale ta věta lže.
-- Vzniklo to tím, že jsem diff filtroval přes `grep -v` na komentáře a přečetl
-- z něj nulu. Soubor `20260903160000` se needituje (je nasazený, migrace jsou
-- dopředné) — proto ta oprava stojí tady.
--
-- V TÉHLE migraci je `validate_shift_claim` opravdu čistý přírůstek:
-- 0 odebraných řádků, 49 přidaných, ověřeno syrovým diffem bez filtrování.
--
-- =============================================================================
-- CO SE OPRAVUJE
--
-- N2 (regrese z 20260903120000): větev politiky pro `status='cancelled'` neměla
--    kontrolu vlastnictví → neadmin přepsal cizí zavřenou směnu včetně toho,
--    kdo ji držel a kdo a kdy ji zrušil. Auditní stopa, ne peníze.
--
-- N1 (starší, od 20260902240000): zrušenou směnu na ŽIVÉ akci šlo jedním
--    UPDATE oživit na `pending` s cizí rolí a zděděnou sazbou. Na produkci
--    dnes nebylo čím spustit (0 zrušených směn na živých akcích), ale první
--    `odeber_trenera` nebo přebytek v `dorovnej_stab` takový řádek vyrobí.
--
-- Obojí zavírá jedno pravidlo: pro neadmina je zavřený řádek zmrazený.
--
-- F3 (starší mezera, našla ji brána u téhle změny): `required_role` nehlídalo
--    při UPDATE nic, takže si ho brigádník přepsal při zabírání směny —
--    obcházelo to „jednu roli jednou" i vazbu role na člověka.
--
-- Obojí u zavřených směn zavírá jedno pravidlo: pro neadmina je zavřený řádek
-- zmrazený. Roli hlídá samostatná brána.
--
-- Dál se opravuje sebekontrola z `20260903160000` (měřila komentář místo kódu)
-- a přesah datové části na `completed`.
--
-- =============================================================================
-- VRATNOST
--
-- SCHÉMA — vratné, v tomhle pořadí:
--   1. `ALTER POLICY "Staff update own shifts, admins anything" ON public.shifts`
--      zpět na znění z `20260903120000` (USING i WITH CHECK; pozor, USING je
--      od téhle migrace užší — vrací se na „jen kontrola rolí").
--   2. `validate_shift_claim()` znovu z `20260903160000` (celé tělo, ne ručně).
--   Helpery (`akce_je_zrusena` a spol.) se rušit nesmějí dřív než politika —
--   dokud na ně `WITH CHECK` ukazuje, `DROP FUNCTION` neprojde.
--
-- DATA — NEVRATNÉ. Úklid v části 3 přepisuje `shift_applications.status` na
--   `cancelled` a nikde si neukládá, jaká byla předchozí hodnota; temp tabulka
--   `_uklid_prihlasek` žije jen po dobu migrace. Zpětně to jde dohledat jen
--   z `audit_log` (trigger `trg_updated_at_apps` na tabulce je, ale audit píše
--   `write_audit_log` u `shifts`, ne u přihlášek — takže reálně z ničeho).
--   Na produkci je ta množina prázdná (`20260903160000` už doběhla), takže
--   dnes není co vracet; na čisté DB nebo na demu ale ano.
--
-- ROLLBACK CELÉ MIGRACE ZNOVU OTEVÍRÁ N1, N2 i F3 — vracet ji má smysl jen
-- když ji nahradí něco lepšího, ne „aby se to odblokovalo".
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Zavřená směna je pro neadmina zmrazená
-- ---------------------------------------------------------------------------
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

    -- JEDNU ROLI JEDNOU, RŮZNÉ ROLE KLIDNĚ OBĚ.
    --
    -- Dřív tu stálo „na této akci už máte JINOU směnu" bez ohledu na roli,
    -- takže brigádník, který na jedné akci dělá bar a zároveň instruktora,
    -- si tu druhou přes samoobsluhu vzít nemohl — musel ho tam přiřadit admin.
    -- Provoz to přitom dělá běžně a platí se za obojí (potvrzeno 1. 9. 2026).
    --
    -- Co zůstává zakázané: TÁŽ ROLE na téže akci dvakrát. To není druhá práce,
    -- to je tatáž práce vykázaná dvakrát — a rovnou dvakrát placená.
    -- `IS NOT DISTINCT FROM` schválně: směny bez role (starší cesta přes
    -- `events.required_staff`) mají `required_role` NULL a dvě takové na jedné
    -- akci jsou taky jen jedna práce dvakrát.
    --
    -- Ochrana proti dvojímu zabrání TÉŽE směny je jinde a nemění se: nahoře
    -- `OLD.claimed_by IS NOT NULL` a guard proti převzetí cizí směny.
    IF EXISTS (
      SELECT 1 FROM public.shifts
      WHERE event_id = NEW.event_id
        AND claimed_by = NEW.claimed_by
        AND id != NEW.id
        AND required_role IS NOT DISTINCT FROM NEW.required_role
        AND status IN ('pending', 'claimed', 'completed')
    ) THEN
      RAISE EXCEPTION 'Na této akci už tuhle roli máte.'
        USING HINT = 'Jinou roli na téže akci si vzít můžete.';
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

-- ---------------------------------------------------------------------------
-- 2) Druhá vrstva patří do USING, ne do WITH CHECK
-- ---------------------------------------------------------------------------
-- První pokus dal podmínku vlastnictví do `WITH CHECK`. To NENÍ druhá vrstva:
-- `WITH CHECK` vidí jen VÝSLEDNÝ řádek, který si celý skládá volající, takže
-- podmínku `claimed_by IS NULL OR claimed_by = auth.uid()` splní tím, že si
-- `claimed_by` v témže příkazu přepíše na sebe. Změřeno s vypnutým triggerem,
-- útočník `instructor` bez admina:
--
--   UPDATE shifts SET claimed_by = auth.uid(),        -- ← tenhle sloupec navíc
--          cancelled_by = auth.uid(), cancelled_at='2020-01-01'
--    WHERE id='<cizí zrušená směna>';                 → PROŠLO
--
-- Původní test to nechytil, protože `claimed_by` nenastavoval — tedy přesně
-- ten vzorec „kontrola, která projde i bez ochrany", na který se tenhle repo
-- už několikrát napálil.
--
-- Rozhoduje `USING`: jediné místo, které vidí PŮVODNÍ řádek. Pro štáb se proto
-- zavřená směna stává nedotknutelnou — nejen „nepřepsatelnou do jiného tvaru".
-- Zůstává to konzistentní s triggerem: `cancelled` je pro neadmina koncový stav.
--
-- Legitimní provoz to nezavře: uvolnění směny má `OLD.status` `claimed`/`open`,
-- ne `cancelled`; úklidy běží jako `postgres` nebo přes SECURITY DEFINER, kde
-- RLS neplatí.
--
-- `WITH CHECK` zůstává i s podmínkou vlastnictví, ale ať je to řečeno naplno:
-- BRÁNA TO NENÍ a nikdo se na ni nemá spoléhat. Změřeno mutací — když se
-- podmínka vlastnictví z `WITH CHECK` odebere, celá testovací sada zůstane
-- ZELENÁ, protože `USING` zablokuje dřív. Je to jen zúžení tvaru řádku, který
-- smí vzniknout; nic to nestojí a v den, kdy někdo `USING` rozvolní, to sníží
-- škodu. Chránit se tím ale nedá a v tomhle repu už se na „ochranu", kterou
-- nejde zčervenat, doplatilo víckrát.
ALTER POLICY "Staff update own shifts, admins anything" ON public.shifts
  USING (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    OR (
      (public.has_role(auth.uid(), 'part_time_staff'::public.app_role)
       OR public.has_role(auth.uid(), 'instructor'::public.app_role)
       OR public.has_role(auth.uid(), 'bar_staff'::public.app_role)
       OR public.has_role(auth.uid(), 'manager'::public.app_role))
      AND status <> 'cancelled'::public.shift_status
    )
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    OR (
      (public.has_role(auth.uid(), 'part_time_staff'::public.app_role)
       OR public.has_role(auth.uid(), 'instructor'::public.app_role)
       OR public.has_role(auth.uid(), 'bar_staff'::public.app_role)
       OR public.has_role(auth.uid(), 'manager'::public.app_role))
      AND (
        ((status = 'pending'::public.shift_status) AND (claimed_by = auth.uid()))
        OR ((status = 'open'::public.shift_status) AND (claimed_by IS NULL))
        OR ((status = 'cancelled'::public.shift_status)
            AND public.akce_je_zrusena(event_id)
            AND (claimed_by IS NULL OR claimed_by = auth.uid()))
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 3) Datová část: odpracované směny se nedotýká ani úklid přihlášek
-- ---------------------------------------------------------------------------
-- `20260903160000` tuhle podmínku neměla, takže `approved` přihláška
-- u ODPRACOVANÉ směny na zrušené akci by se přepsala na `cancelled` — v rozporu
-- s tím, co ta migrace o sobě tvrdí. Na produkci byla množina prázdná (jinak by
-- spadla už kontrola v 20260903120000), takže se nic nestalo; na čisté DB nebo
-- na demu se to stát může, proto je správné znění tady.
-- Zasažené řádky se schválně SBÍRAJÍ, ne dohledávají zpětně podle času.
-- První verze kontroly níž se ptala na `updated_at >= now() - interval '1 minute'`,
-- což je dotaz na hodiny, ne na vlastní práci: stačí, aby v databázi ležela
-- nesouvisející `cancelled` přihláška u odpracované směny s čerstvým razítkem,
-- a migrace spadne hláškou, že sáhla na podklad pro výplaty — přestože nesáhla
-- na nic. Reprodukováno na replice. Selhává sice bezpečným směrem, ale obviňuje
-- se z něčeho, co neudělala, a to se pak hledá půl dne.
DO $naprava$
DECLARE _n integer; _spatne integer;
BEGIN
  CREATE TEMP TABLE _uklid_prihlasek (id uuid, shift_id uuid);

  WITH zmeny AS (
    UPDATE public.shift_applications a
       SET status = 'cancelled', updated_at = now()
      FROM public.shifts s
     WHERE s.id = a.shift_id
       AND a.status IN ('pending', 'approved')
       AND s.status <> 'completed'
       AND (s.status = 'cancelled' OR public.akce_je_zrusena(s.event_id))
    RETURNING a.id, a.shift_id
  )
  INSERT INTO _uklid_prihlasek SELECT id, shift_id FROM zmeny;
  GET DIAGNOSTICS _n = ROW_COUNT;

  SELECT count(*) INTO _spatne
    FROM _uklid_prihlasek u JOIN public.shifts s ON s.id = u.shift_id
   WHERE s.status = 'completed';
  IF _spatne > 0 THEN
    RAISE EXCEPTION 'Úklid přihlášek sáhl na % odpracovaných směn.', _spatne;
  END IF;

  RAISE NOTICE 'Úklid přihlášek: % řádků, z toho 0 u odpracovaných směn.', _n;
  DROP TABLE _uklid_prihlasek;
END $naprava$;

-- ---------------------------------------------------------------------------
-- 4) Sebekontrola
-- ---------------------------------------------------------------------------
-- CO TENHLE BLOK UMÍ A CO NE — ať se na něj nespoléhá víc, než unese:
--
-- UMÍ zachytit, že se změny z TÉHLE migrace nepropsaly (překlep v kotvě,
-- neproběhlý `ALTER POLICY`, přepsané tělo funkce jinou migrací mezitím).
--
-- NEUMÍ hlídat budoucí regresi. Migrace si své DDL o pár řádků výš sama
-- nastaví, takže než se ke kontrole dojde, je stav vždycky správný — ověřeno
-- pokusem: s vrácenou politikou (mutace m10) blok stejně prošel.
--
-- Proti regresi je mutační sada v `supabase/tests/zrusena_akce_nenabizi_test.sql`,
-- kde m9 (brány pryč) i m10 (politika bez vlastnictví) opravdu červenají.
-- Předchozí migrace `20260903160000` tuhle hranici popletla a spoléhala se na
-- kontrolu, která navíc měřila komentář místo kódu.
DO $kontrola$
DECLARE
  _src   text;
  _p_chk integer;   -- pozice skutečné kontroly vlastnictví
  _p_set integer;   -- pozice přepisu na `cancelled`
BEGIN
  SELECT prosrc INTO _src FROM pg_proc
   WHERE oid = 'public.validate_shift_claim()'::regprocedure;

  -- PROČ NE `position('Nemůžete zrušit cizí směnu' in _src)`:
  -- `prosrc` nese i komentáře a ta fráze je v těle třikrát. `position()` vrací
  -- PRVNÍ výskyt, tedy komentář — v 20260903160000 to bylo 2487, kdežto
  -- skutečný RAISE je na 9864. Kontrola tak měřila polohu komentáře o kontrole,
  -- ne kontrolu samotnou: kdyby někdo celý RAISE smazal a komentáře nechal,
  -- prošla by zeleně. Proto se hledá celý příkaz včetně `RAISE EXCEPTION`
  -- a nulová pozice je chyba, ne „v pořádku".
  _p_chk := position('RAISE EXCEPTION ''Nemůžete zrušit cizí směnu''' in _src);
  -- Kotví se na PŘIŘAZENÍ STAVU, ne na razítko vedle něj: kdyby se přesunul
  -- jen ten jeden řádek, kotva na `cancelled_by` by to neodhalila.
  _p_set := position('NEW.status       := ''cancelled''' in _src);

  IF _p_chk = 0 THEN
    RAISE EXCEPTION 'Zmizela kontrola „Nemůžete zrušit cizí směnu".';
  END IF;
  IF _p_set = 0 THEN
    RAISE EXCEPTION 'Zmizel přepis uvolněné směny na cancelled.';
  END IF;
  IF _p_chk > _p_set THEN
    RAISE EXCEPTION 'Přepis na cancelled je PŘED kontrolou vlastnictví (%>%) — vyřazuje ji.',
      _p_chk, _p_set;
  END IF;

  IF _src NOT LIKE '%RAISE EXCEPTION ''Zrušenou směnu znovu otevírá jen správce haly.''%' THEN
    RAISE EXCEPTION 'Chybí brána N1 — zrušená směna jde znovu oživit.';
  END IF;
  IF _src NOT LIKE '%RAISE EXCEPTION ''Do zrušené směny už zapisovat nelze.''%' THEN
    RAISE EXCEPTION 'Chybí brána N2 — do cizí zrušené směny jde zapsat.';
  END IF;
  IF _src NOT LIKE '%RAISE EXCEPTION ''Směnu nelze přesunout na jinou akci.''%' THEN
    RAISE EXCEPTION 'Zmizel zámek na event_id.';
  END IF;

  -- Hledá se text SPECIFICKÝ PRO CANCELLED VĚTEV, ne jen `claimed_by = auth.uid()`.
  -- Ten řetězec je totiž i ve větvi `pending` a byl tam odjakživa, takže by
  -- kontrola prošla i s odebraným vlastnictvím u `cancelled` — táž chyba, jakou
  -- tahle migrace opravuje o pár řádků výš. Odhaleno vlastním stavovým markerem
  -- v mutačním běhu, ne úvahou.
  IF (SELECT with_check FROM pg_policies
       WHERE tablename = 'shifts' AND cmd = 'UPDATE')
     NOT LIKE '%akce_je_zrusena(event_id) AND ((claimed_by IS NULL)%' THEN
    RAISE EXCEPTION 'Politika nemá u cancelled větve kontrolu vlastnictví.';
  END IF;
  -- USING je ta vrstva, která opravdu drží (vidí původní řádek).
  IF (SELECT qual FROM pg_policies
       WHERE tablename = 'shifts' AND cmd = 'UPDATE')
     NOT LIKE '%status <> ''cancelled''%' THEN
    RAISE EXCEPTION 'USING politiky nechrání zavřené směny — druhá vrstva chybí.';
  END IF;

  RAISE NOTICE 'Zavřená směna je zavřená; sebekontrola měří kód, ne komentář.';
END $kontrola$;
