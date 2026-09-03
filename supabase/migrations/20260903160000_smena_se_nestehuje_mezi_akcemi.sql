-- =============================================================================
-- Záplata na díru otevřenou migrací 20260903120000
-- =============================================================================
-- CO SE STALO
--
-- Migrace 20260903120000 přidala do politiky `Staff update own shifts, admins
-- anything` větev, která pouští výsledný řádek se `status = 'cancelled'`,
-- pokud `akce_je_zrusena(event_id)`. Potřebná byla kvůli tomu, aby si držitel
-- mohl směnu na zrušené akci uvolnit (přepis `open -> cancelled` v triggeru by
-- jinak spadl na RLS).
--
-- Přehlédnuté: `event_id` v té podmínce je z VÝSLEDNÉHO řádku, tedy hodnota,
-- kterou si do UPDATE dosadí sám volající — a `event_id` na `shifts` nehlídalo
-- nic. Změřeno na replice produkce, útočník s rolí `instructor`, bez adminské
-- role, bez souběhu, dva obyčejné UPDATE:
--
--   UPDATE shifts SET status='cancelled', event_id='<zrušená akce>'
--    WHERE id='<cizí claimed směna kolegy na ŽIVÉ akci>';        → PROŠLO
--   UPDATE shifts SET status='open', claimed_by=NULL, event_id='<zrušená akce>'
--    WHERE id='<cizí směna>';                                    → PROŠLO
--
-- Druhá varianta navíc obešla hlášku „Nemůžete zrušit cizí směnu": přepis
-- `NEW.status` na `cancelled` proběhl DŘÍV než větve, které se ptají na
-- `NEW.status = 'open'`, takže se ty kontroly vůbec nespustily.
--
-- Dopad: kterýkoli člen štábu mohl mazat kolegům potvrzené i čekající směny
-- a stěhovat je na cizí akce. Na peníze to necestovalo — `completed` chrání
-- starší brána. Před 20260903120000 obojí padalo na RLS, je to tedy regrese
-- zavlečená tou migrací, ne starý stav.
--
-- CO SE MĚNÍ
--   1. `event_id` na směně je neměnné (žádná cesta v aplikaci ho nemění)
--   2. přepis `open -> cancelled` se přesouvá až ZA kontroly vlastnictví
--   3. `prirad_trenera` na zrušené akci končí hláškou, ne tichým „hotovo"
--   4. datová náprava dorovná i přihlášky visící na už zrušených směnách
--
-- VRATNOST
--   Obě funkce jsou převzaté ze ŽIVÉHO schématu (`pg_get_functiondef`)
--   a ověřené diffem: 0 odebraných řádků.
--   Návrat: `validate_shift_claim` a `prirad_trenera` znovu z 20260903120000
--   resp. 20260831233000. Pořadí při případném rušení helperů: nejdřív
--   `ALTER POLICY` zpět (20260902240000, 20260902262000), teprve pak DROP
--   funkcí — dokud na ně politiky ukazují, dropnout nejdou.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) + 2) Brána na směně
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
-- 3) Trenér na zrušené akci
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prirad_trenera(_event_id uuid, _user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _ev        public.events%ROWTYPE;
  _subject   uuid;
  _subjektu  int;
  _stary     uuid;
  _novy      uuid;
BEGIN
  SELECT * INTO _ev FROM public.events WHERE id = _event_id;
  IF _ev.id IS NULL THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  -- TRENÉR PATŘÍ K TRÉNINKU. U komerční akce se štáb řeší přes `role_reqs`
  -- a dorovnání; míchat obě cesty by znamenalo dvě pravdy o jedné směně.
  IF _ev.event_type <> 'training' THEN
    RAISE EXCEPTION 'Trenéra lze přiřadit jen k tréninku (tahle akce je %).', _ev.event_type;
  END IF;

  -- NA ZRUŠENOU AKCI SE TRENÉR NEPŘIŘAZUJE.
  --
  -- Bez téhle věty funkce na zrušené akci LŽE. Od migrace 20260903120000 tam
  -- `INSERT` do `shifts` tiše přeskočí brána `trg_shifts_a_zrusena_akce`,
  -- jenže `RETURNING id INTO _novy` bez `STRICT` chybu nevyhodí — funkce
  -- doběhne a vrátí `{"zmena": true, "shift_id": null}`. Změřeno:
  -- UI ohlásí „trenér přiřazen" a nevzniklo nic.
  --
  -- Horší varianta téhož: kdyby na zrušené akci ještě visela nezrušená
  -- trenérská směna, funkce ji o pár řádků níž nejdřív zruší a teprve pak
  -- neúspěšně zakládá novou — původní trenér by o směnu přišel a náhradník
  -- by žádnou nedostal. Proto se zastavuje TADY, před tím vším.
  IF public.akce_je_zrusena(_event_id) THEN
    RAISE EXCEPTION 'Akce je zrušená, trenéra k ní přiřadit nelze.'
      USING HINT = 'Obnov rezervaci, nebo založ akci novou.';
  END IF;

  -- Klub, kterému trénink patří — kvůli právům zástupce.
  --
  -- `LIMIT 1` bez `ORDER BY` tu dřív znamenalo, že o tom, ČÍ zástupce smí
  -- k akci pověsit placenou směnu, rozhodoval plánovač: u akce s drahami dvou
  -- klubů vracel jednou jeden subjekt, jindy druhý. `approve_reservation` se
  -- proti témuž brání výslovně („kdyby někdo ručně pověsil na akci rezervaci
  -- jiného klubu, nesmí ji zástupce potvrdit jedním kliknutím s tou svou").
  --
  -- Tady se to řeší přísněji: buď má akce JEDEN klub, nebo ji zástupce neřídí
  -- vůbec a zbývá admin.
  SELECT count(DISTINCT r.subject_id), min(r.subject_id::text)::uuid INTO _subjektu, _subject
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL;

  IF _subjektu > 1 THEN
    _subject := NULL;   -- víc klubů na jedné akci → jen admin
  END IF;

  IF NOT (has_role(auth.uid(), 'admin')
          OR (_subject IS NOT NULL AND public.is_subject_rep(_subject))) THEN
    -- `USING HINT` tu být NEMŮŽE podmíněně: `RAISE ... USING HINT = NULL`
    -- skončí chybou „RAISE statement option cannot be null", takže by se
    -- z běžného odmítnutí stala havárie. Upřesnění jde proto do zprávy.
    RAISE EXCEPTION 'Trenéra přiřazuje správce haly nebo zástupce klubu.%',
      CASE WHEN _subjektu > 1
           THEN ' Tahle akce má navíc dráhy víc klubů, takže ji zástupce neřídí — musí správce haly.'
           ELSE '' END;
  END IF;

  -- P2: roli `trainer` uděluje jen admin. Tady se jen ověří, že ji člověk má —
  -- jinak by zástupce přes přiřazení nepřímo rozdával placené role.
  IF NOT has_role(_user_id, 'trainer') THEN
    RAISE EXCEPTION 'Tenhle člověk není vedený jako trenér. Roli přiděluje správce haly.';
  END IF;

  -- Jeden trenér na trénink. Když už nějaký je, původní směna se ZRUŠÍ SOFT
  -- (zásada 2) a založí se nová — zrušit natvrdo odpracované hodiny nejde.
  SELECT id INTO _stary
    FROM public.shifts
   WHERE event_id = _event_id
     AND required_role = 'trainer'
     AND status <> 'cancelled'
   LIMIT 1;

  IF _stary IS NOT NULL THEN
    -- Už odpracovanou směnu neodebíráme ani při výměně — jsou to peníze.
    IF (SELECT status FROM public.shifts WHERE id = _stary) = 'completed' THEN
      RAISE EXCEPTION 'Trenér už má tuhle směnu uzavřenou, vyměnit ho nejde.'
        USING HINT = 'Uzavřená směna je podklad pro výplatu.';
    END IF;
    IF (SELECT claimed_by FROM public.shifts WHERE id = _stary) = _user_id THEN
      RETURN jsonb_build_object('zmena', false, 'shift_id', _stary, 'trener', _user_id);
    END IF;
    UPDATE public.shifts
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     WHERE id = _stary;
  END IF;

  -- SMĚNA VZNIKÁ ROVNOU OBSAZENÁ — viz hlavička. `hourly_rate` se nevyplňuje,
  -- doplní ho `trg_shifts_sazba` z ceníku rolí.
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_event_id, 'trainer', 'claimed', _user_id, now())
  RETURNING id INTO _novy;

  RETURN jsonb_build_object(
    'zmena', true,
    'shift_id', _novy,
    'trener', _user_id,
    'sazba', (SELECT hourly_rate FROM public.shifts WHERE id = _novy),
    'vymenen_za', _stary
  );

EXCEPTION
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Trenéra se nepodařilo přiřadit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontroluj, jestli je akce trénink a člověk má roli trenéra.';
END;
$function$

;

-- ---------------------------------------------------------------------------
-- 4) Dorovnání přihlášek na už zrušených směnách
-- ---------------------------------------------------------------------------
-- Náprava v 20260903120000 brala jen směny `open/pending/claimed`. Přihláška
-- visící na směně, která už `cancelled` BYLA, tam nespadla — a kontrola
-- invariantu na konci téže migrace ji přitom počítá. Takový řádek jde vyrobit:
-- díru „přihláška na zrušenou směnu projde" zavírá až 20260903120000, takže od
-- 2. 9. mohly vznikat. Na produkci žádný nebyl (migrace prošla), ale na demu
-- nebo při opakovaném běhu by migrace spadla a musela by se dodělávat ručně.
UPDATE public.shift_applications a
   SET status = 'cancelled', updated_at = now()
  FROM public.shifts s
 WHERE s.id = a.shift_id
   AND a.status IN ('pending', 'approved')
   AND (s.status = 'cancelled' OR public.akce_je_zrusena(s.event_id));

-- ---------------------------------------------------------------------------
-- 5) Kontrola
-- ---------------------------------------------------------------------------
DO $kontrola$
DECLARE _n integer; _src text;
BEGIN
  SELECT prosrc INTO _src FROM pg_proc
   WHERE oid = 'public.validate_shift_claim()'::regprocedure;

  IF _src NOT LIKE '%Směnu nelze přesunout na jinou akci%' THEN
    RAISE EXCEPTION 'Chybí zámek na event_id — směna by se dala přestěhovat na cizí akci.';
  END IF;

  -- Přepis na `cancelled` musí být AŽ ZA kontrolami vlastnictví, jinak je
  -- vyřadí. Měříme pořadím v těle, protože přesně to se posledně rozbilo.
  IF position('Nemůžete zrušit cizí směnu' in _src) > position('NEW.status       := ''cancelled''' in _src) THEN
    RAISE EXCEPTION 'Přepis na cancelled je pořád PŘED kontrolou vlastnictví — vyřazuje ji.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.prirad_trenera(uuid,uuid)'::regprocedure)
     NOT LIKE '%Akce je zrušená, trenéra%' THEN
    RAISE EXCEPTION 'prirad_trenera na zrušené akci pořád mlčky nic neudělá.';
  END IF;

  SELECT count(*) INTO _n
    FROM public.shift_applications a JOIN public.shifts s ON s.id = a.shift_id
   WHERE a.status IN ('pending','approved')
     AND (s.status = 'cancelled' OR public.akce_je_zrusena(s.event_id));
  IF _n > 0 THEN
    RAISE EXCEPTION 'Na zavřených směnách pořád visí % živých přihlášek.', _n;
  END IF;

  RAISE NOTICE 'Směna se nestěhuje, uvolnění nevyřazuje kontroly, trenér na zrušené akci hlásí chybu.';
END $kontrola$;
