-- =============================================================================
-- Na zrušené akci nežije žádná směna — INVARIANT, ne jednorázový úklid
-- Jakubův nález (3. 9. 2026)
-- =============================================================================
-- CO BYLO ŠPATNĚ
--
-- Zrušená akce dál nabízela směnu a šlo se na ni přihlásit („Mám zájem"
-- prošlo na „Čeká na schválení"). Měřeno na produkci, akce „Teambuilding
-- Hybridní vzdělávání, s.r.o.":
--
--     1. 9. 15:52  rezervace confirmed, 2 instruktorské směny `open`
--     1. 9. 15:54  jednu si někdo vzal        open    -> claimed
--     1. 9. 15:56  rezervace ZRUŠENA          → úklid uklidil jen tu neobsazenou
--     2. 9. 15:16  držitel směnu pustil       claimed -> open   ← nabídka zpátky
--
-- Úklid `cancel_open_shifts_on_reservation_cancel` funguje, ale je
-- JEDNORÁZOVÝ — sáhne na směny v okamžiku zrušení rezervace a víc se neozve.
-- Život směny přitom pokračuje: uvolnění, přihláška, schválení, dorovnání
-- štábu. Každá z těch cest umí na zrušené akci vyrobit živou nabídku znovu.
-- Migrace 20260902120000 rozšířila úklid o `claimed` a bug se přesto vrátil,
-- protože se opravoval OKAMŽIK, ne PRAVIDLO.
--
-- CO SE MĚNÍ: pravidlo „na zrušené akci nežije žádná směna" se hlídá při
-- KAŽDÉM zápisu, ne jednou:
--
--   1. `akce_je_zrusena()` — jedna definice zrušené akce pro všechna místa
--   2. `validate_shift_claim()` — zabrání/schválení odmítne, uvolnění zavře
--   3. BEFORE INSERT na `shifts` — nová směna na zrušené akci se nezaloží
--   4. politiky `shifts` a `shift_applications` — totéž na úrovni RLS
--   5. datová náprava toho, co už viselo
--
-- ODPRACOVANÉ SMĚNY (`completed`) SE NEDOTÝKÁ NIC. Jsou podklad pro výplaty —
-- táž hranice, jakou drží `odeber_trenera` i stávající úklid.
--
-- VRATNOST: `validate_shift_claim` je převzatá ze ŽIVÉHO schématu
-- (`pg_get_functiondef`) a ověřená diffem — 0 odebraných řádků, 42 přidaných.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Jedna definice „zrušené akce"
-- ---------------------------------------------------------------------------
-- Shodná se stávajícím triggerem: akce MÁ rezervace a ŽÁDNÁ není živá.
-- Akce s nula rezervacemi zrušená NENÍ — jinak by brány smetly i akce
-- založené mimo rezervační cestu.
--
-- `SECURITY DEFINER` NENÍ ozdoba: `reservations_select` pouští neadminovi jen
-- rezervace jeho vlastního subjektu. Měřeno — brigádník vidí 11 rezervací z 62
-- a u zrušeného Teambuildingu NULA.
--
-- Bez definera se to nerozbije nahlas, ale TIŠE A NAOPAK: první podmínka
-- („existuje rezervace") vyjde brigádníkovi false, takže mu zrušená akce vyjde
-- jako ŽIVÁ a brána na něj vůbec nesáhne — přesně na toho, koho má zastavit.
-- Změřeno mutací (helperu se sebral definer): `akce_je_zrusena` na zrušeném
-- Teambuildingu vrátila neadminovi `false`, adminovi `true`.
--
-- Druhý dopad je opačný a hlučný: `cancelled` větev politiky `shifts` níž se
-- opírá o tutéž funkci, takže by držiteli přestalo jít směnu vůbec uvolnit.
CREATE OR REPLACE FUNCTION public.akce_je_zrusena(p_event_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
           SELECT 1 FROM public.reservations r WHERE r.event_id = p_event_id
         )
     AND NOT EXISTS (
           SELECT 1 FROM public.reservations r
            WHERE r.event_id = p_event_id
              AND r.status <> 'cancelled'
              AND r.deleted_at IS NULL
         );
$function$;

CREATE OR REPLACE FUNCTION public.smena_je_na_zrusene_akci(p_shift_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.shifts s
     WHERE s.id = p_shift_id AND public.akce_je_zrusena(s.event_id)
  );
$function$;

-- Přijímá směna přihlášky? Musí být `open` A akce musí žít.
-- Podmínka `status = 'open'` zavírá druhou díru nalezenou při téhle opravě:
-- přihláška na už ZRUŠENOU směnu prošla i na živé akci (ověřeno reálným
-- tokenem neadmina). Přihlásit se jde na nabídku, ne na zavřenou směnu.
CREATE OR REPLACE FUNCTION public.smena_prijima_prihlasky(p_shift_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.shifts s
     WHERE s.id = p_shift_id
       AND s.status = 'open'
       AND NOT public.akce_je_zrusena(s.event_id)
  );
$function$;

-- Pro UI: která akce je zrušená. Brigádník na `reservations` nevidí, takže si
-- to frontend nemůže spočítat sám — musí se zeptat téhle funkce.
CREATE OR REPLACE FUNCTION public.zrusene_akce_se_smenami()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT DISTINCT s.event_id
    FROM public.shifts s
   WHERE s.event_id IS NOT NULL
     AND public.akce_je_zrusena(s.event_id);
$function$;

REVOKE ALL ON FUNCTION public.akce_je_zrusena(uuid)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.smena_je_na_zrusene_akci(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.smena_prijima_prihlasky(uuid)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.zrusene_akce_se_smenami()      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.akce_je_zrusena(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.smena_je_na_zrusene_akci(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.smena_prijima_prihlasky(uuid)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.zrusene_akce_se_smenami()      TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Brána na směně (tělo ze živého schématu, vložen jen blok nahoře)
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
  IF OLD.status <> 'completed' AND public.akce_je_zrusena(NEW.event_id) THEN
    IF NEW.status IN ('pending', 'claimed') AND OLD.status IS DISTINCT FROM NEW.status THEN
      RAISE EXCEPTION 'Akce je zrušená, směnu na ní vzít nelze.'
        USING HINT = 'Nabídka na zrušené akci se zavírá, ne obsazuje.';
    END IF;
    IF NEW.status = 'open' AND OLD.status IS DISTINCT FROM 'open' THEN
      NEW.status       := 'cancelled';
      NEW.cancelled_at := now();
      NEW.cancelled_by := auth.uid();
    END IF;
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

  RETURN NEW;
END;
$function$

;

-- ---------------------------------------------------------------------------
-- 3) Nová směna na zrušené akci nevznikne
-- ---------------------------------------------------------------------------
-- `dorovnej_stab()` doplňuje štáb při každé úpravě `role_reqs`,
-- `required_staff` nebo `event_type` a na zrušení se neptá. Po datové nápravě
-- níž mu počet živých směn klesne na nulu, takže PRVNÍ úprava zrušené akce by
-- bug rovnou vrátila — proto tahle brána patří sem, ne do dalšího ticketu.
--
-- TIŠE PŘESKOČIT, NE VYHODIT CHYBU. `dorovnej_stab` běží z triggeru nad
-- `events`; výjimka by shodila celý UPDATE akce, takže by adminovi přestalo
-- jít upravit zrušenou akci. Přeskočení dá přesně to, co chceme: akce se
-- upraví, nabídka nevznikne.
CREATE OR REPLACE FUNCTION public.preskoc_smenu_na_zrusene_akci()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF public.akce_je_zrusena(NEW.event_id) THEN
    RETURN NULL;  -- BEFORE INSERT + NULL = řádek se nevloží, chyba se nevyhodí
  END IF;
  RETURN NEW;
END;
$function$;

-- Jméno schválně na `_a_`: BEFORE triggery se spouštějí abecedně a tenhle musí
-- běžet PŘED `trg_shifts_sazba`. Jakmile vrátí NULL, další už se nespustí.
DROP TRIGGER IF EXISTS trg_shifts_a_zrusena_akce ON public.shifts;
CREATE TRIGGER trg_shifts_a_zrusena_akce
  BEFORE INSERT ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.preskoc_smenu_na_zrusene_akci();

-- ---------------------------------------------------------------------------
-- 4) Totéž na úrovni RLS
-- ---------------------------------------------------------------------------
-- `ALTER POLICY`, ne DROP+CREATE: nevzniká okamžik, kdy tabulka stojí bez
-- politiky, a `USING` zůstává nedotčené.

-- shifts: výsledný řádek smí být nově i `cancelled`, ale JEN na zrušené akci.
-- Bez tohohle by přepis `open -> cancelled` z bodu 2 spadl na RLS — ověřeno
-- reálným tokenem: neadmin držitel dostal
-- „new row violates row-level security policy for table shifts".
ALTER POLICY "Staff update own shifts, admins anything" ON public.shifts
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
        OR ((status = 'cancelled'::public.shift_status) AND public.akce_je_zrusena(event_id))
      )
    )
  );

-- shift_applications, INSERT: přihláška jen na směnu, která je opravdu nabídkou.
ALTER POLICY "user insert own" ON public.shift_applications
  WITH CHECK (
    (user_id = auth.uid())
    AND public.ucet_aktivni()
    AND public.smena_prijima_prihlasky(shift_id)
  );

-- shift_applications, UPDATE: „Mám zájem" je UPSERT (`onConflict shift_id,user_id`),
-- takže OPAKOVANÁ přihláška teče TOUHLE větví, ne INSERTem. Bez podmínky na
-- `pending` by se dírou dalo projít podruhé.
--
-- Dvě různé podmínky schválně:
--   * na `pending` se vyžaduje živá nabídka (`smena_prijima_prihlasky`)
--   * na `approved` jen to, že akce žije
-- Schvalování totiž nejdřív překlopí směnu `open -> claimed` a AŽ POTOM
-- označí přihlášku jako `approved` — v tu chvíli už nabídka není `open`.
-- Kdyby se i tady žádalo `smena_prijima_prihlasky`, zablokovalo by to
-- schvalování na živých akcích, tedy úplně běžný provoz.
--
-- Rušení a zamítání (`cancelled`, `rejected`) zůstává průchodné — jinak by si
-- nikdo neuklidil ani vlastní přihlášku.
ALTER POLICY "user cancel own / admin update" ON public.shift_applications
  WITH CHECK (
    (
      ((user_id = auth.uid()) AND public.ucet_aktivni() AND (status <> 'approved'::text))
      OR public.has_role(auth.uid(), 'admin'::public.app_role)
    )
    AND (status <> 'pending'::text  OR public.smena_prijima_prihlasky(shift_id))
    AND (status <> 'approved'::text OR NOT public.smena_je_na_zrusene_akci(shift_id))
  );

-- ---------------------------------------------------------------------------
-- 5) Datová náprava
-- ---------------------------------------------------------------------------
-- Množinově podle téže definice, ne přes napevno vypsaná id — ať to platí
-- i pro řádky, které mezitím přibudou.
DO $naprava$
DECLARE
  _completed_pred integer;
  _completed_po   integer;
  _smen           integer;
BEGIN
  SELECT count(*) INTO _completed_pred FROM public.shifts WHERE status = 'completed';

  UPDATE public.shifts
     SET status       = 'cancelled',
         cancelled_at = now(),
         cancelled_by = NULL   -- uklidila migrace; podepsat to uživatelem by v auditu lhalo
   WHERE status IN ('open', 'pending', 'claimed')
     AND public.akce_je_zrusena(event_id);
  GET DIAGNOSTICS _smen = ROW_COUNT;

  SELECT count(*) INTO _completed_po FROM public.shifts WHERE status = 'completed';
  IF _completed_pred <> _completed_po THEN
    RAISE EXCEPTION 'Náprava sáhla na odpracované směny (% -> %). To je podklad pro výplaty.',
      _completed_pred, _completed_po;
  END IF;

  RAISE NOTICE 'Náprava: zavřeno % směn na zrušených akcích, completed beze změny (%).',
    _smen, _completed_po;
END $naprava$;

-- Živé přihlášky na těch směnách uklidí `trg_shifts_zrus_prihlasky`
-- (ruší `pending` i `approved`) — tím padne i ta `approved` přihláška
-- na akci „DIvize". Kontrola, že se to opravdu stalo, je níž.

-- ---------------------------------------------------------------------------
-- 6) Kontrola, že invariant po migraci opravdu platí
-- ---------------------------------------------------------------------------
DO $kontrola$
DECLARE _n integer;
BEGIN
  SELECT count(*) INTO _n FROM public.shifts s
   WHERE s.status IN ('open', 'pending', 'claimed') AND public.akce_je_zrusena(s.event_id);
  IF _n > 0 THEN
    RAISE EXCEPTION 'Na zrušených akcích pořád visí % živých směn.', _n;
  END IF;

  SELECT count(*) INTO _n
    FROM public.shift_applications a JOIN public.shifts s ON s.id = a.shift_id
   WHERE a.status IN ('pending', 'approved') AND public.akce_je_zrusena(s.event_id);
  IF _n > 0 THEN
    RAISE EXCEPTION 'Na zrušených akcích pořád visí % živých přihlášek.', _n;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_shifts_a_zrusena_akce' AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Chybí BEFORE INSERT brána — dorovnání štábu by bug vrátilo.';
  END IF;

  IF (SELECT prosrc FROM pg_proc
       WHERE oid = 'public.validate_shift_claim()'::regprocedure) NOT LIKE '%akce_je_zrusena%' THEN
    RAISE EXCEPTION 'Brána na směně neobsahuje kontrolu zrušené akce.';
  END IF;

  RAISE NOTICE 'Invariant platí: na zrušené akci nežije žádná směna ani přihláška.';
END $kontrola$;
