-- =============================================================================
-- Placené směny: jeden trenér na trénink, žádné převzetí cizí směny
-- Nálezy 9 a 10 z ultra review (1. 9. 2026)
-- =============================================================================
-- OBOJE JE TÝŽ VZOREC: `SELECT … EXISTS/LIMIT 1` a podle výsledku `INSERT`
-- nebo `UPDATE`, bez zámku a bez constraintu. Pod READ COMMITTED oba souběžné
-- běhy uvidí „nic tam není" a oba zapíšou. A protože jde o SMĚNY, je výsledkem
-- výplata dvakrát.
--
-- NÁLEZ 9 — DVA PLACENÍ TRENÉŘI NA JEDNOM TRÉNINKU.
--   `prirad_trenera` (20260831200000) hledá stávající směnu přes
--   `SELECT id … WHERE event_id = … AND required_role = 'trainer'
--    AND status <> 'cancelled' LIMIT 1` a když nenajde, vloží novou.
--   Dva zástupci (nebo zástupce a admin) kliknou naráz → dvě směny po 600 Kč/h
--   na tomtéž tréninku. Kontrast, který ukazuje, proč to jinde nevadí:
--   `odeber_trenera` a `prirad_trenera` se serializují, protože obě sahají na
--   TÝŽ řádek směny — dvě souběžná PŘIŘAZENÍ ale jen vkládají, takže nemají
--   o co se přetahovat.
--
-- NÁLEZ 10 — JEDEN ČLOVĚK, DVĚ SMĚNY NA TÉŽE AKCI.
--   `validate_shift_claim` (baseline) to hlídá výslovně a má na to i hlášku
--   („Na této akci již máte jinou směnu"), jenže je to `IF EXISTS (…)` uvnitř
--   triggeru — tedy tentýž nezamčený dotaz. Dvě přihlášky na dvě různé směny
--   téže akce odeslané naráz projdou obě.
--
-- -----------------------------------------------------------------------------
-- PROČ INDEX, A NE ZÁMEK
-- -----------------------------------------------------------------------------
-- U přecenění akce (20260901140000) šlo zamknout řádky, o které se obě cesty
-- perou. Tady žádné takové řádky NEJSOU — obě strany jen VKLÁDAJÍ nebo mění
-- různé směny, takže není co zamknout dřív, než to vznikne. Jediné, co
-- souběžné vložení spolehlivě zastaví, je unikátní index: ten kolizi řeší
-- v okamžiku zápisu, ne v okamžiku čtení.
--
-- Trigger ani RPC se proto NEMĚNÍ. Jejich kontroly zůstávají jako první linie
-- (dají uživateli českou hlášku); index je druhá linie pro souběh, kde první
-- z principu nestačí.
--
-- -----------------------------------------------------------------------------
-- PREDIKÁTY ODPOVÍDAJÍ TOMU, CO KONTROLUJE KÓD — ZNAK ZA ZNAK
-- -----------------------------------------------------------------------------
--   trenér:  `status <> 'cancelled'`               … jako `prirad_trenera`
--   (druhý index tu není — viz kapitola 2)
-- Kdyby se predikát a kód rozešly, index by buď blokoval legitimní zápis, nebo
-- by nechal projít to, co kód zakazuje — a jedno i druhé je horší než dnešek.
--
-- -----------------------------------------------------------------------------
-- OVĚŘENO PŘED NASAZENÍM
-- -----------------------------------------------------------------------------
-- Na produkci i lokálně: 0 akcí se dvěma živými trenérskými směnami,
-- 0 dvojic (akce, člověk) se dvěma směnami. Index tedy nemá na čem spadnout.
-- Kontrola níž to ověřuje znovu, aby se migrace nedala pustit na data,
-- která už porušená jsou.
--
-- ⚠️ BEZ `CONCURRENTLY`: to nejde uvnitř transakce a migrace běží
-- v transakci. `shifts` má na produkci 32 řádků, takže krátký zámek při
-- stavbě indexu je neměřitelný. U větší tabulky by to bylo jinak.
--
-- VRATNOST:
--   DROP INDEX IF EXISTS public.shifts_jeden_trener_na_akci;
--   validate_shift_claim zpátky ze ŽIVÉHO schématu (pg_get_functiondef).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) NÁLEZ 9 — jeden trenér na trénink
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS shifts_jeden_trener_na_akci
  ON public.shifts (event_id)
  WHERE required_role = 'trainer' AND status <> 'cancelled';

COMMENT ON INDEX public.shifts_jeden_trener_na_akci IS
  'Jedna živá trenérská směna na akci. prirad_trenera() to kontroluje dotazem, jenže dvě souběžná přiřazení oba dotazy projdou a hala pak platí dva trenéry — kontrolu proto zálohuje tenhle index.';

-- -----------------------------------------------------------------------------
-- 2) NÁLEZ 10 — jen to, co je doopravdy špatně: PŘEVZETÍ CIZÍ SMĚNY
--
-- Původní návrh sem chtěl unikátní index na (event_id, claimed_by), tedy
-- „jeden člověk, jedna směna na akci". JE TO FALEŠNÝ POPLACH a index by
-- blokoval legitimní provoz: podle Jakuba (potvrzeno 1. 9. 2026) může jeden
-- člověk na jedné akci dělat DVĚ RŮZNÉ ROLE a dostat za obě zaplaceno.
--
-- Skutečné riziko je užší a nepotřebuje ani souběh: `validate_shift_claim`
-- hlídá jen přechod `open -> pending`, takže jakmile je směna zabraná,
-- `UPDATE shifts SET claimed_by = <já>` projde komukoli ze štábu a původní
-- držitel o ni tiše přijde. Změřeno dvěma po sobě jdoucími transakcemi:
-- výsledek `pending / 55555555`, původní zájemce 33333333 bez jediné hlášky.
--
-- Zavírá se to v triggeru, ne indexem — index by musel být nad dvojicí
-- (řádek, osoba), což nedává smysl; tady jde o PŘECHOD, ne o duplicitu.
-- Souběžné zabrání téhož řádku tím padá taky: oba `UPDATE` se serializují
-- na zámku řádku a ten druhý pak narazí na tutéž podmínku.
--
-- Tělo z `pg_get_functiondef` živého schématu (pravidlo 7); zásah je jediný
-- vložený blok.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
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

    IF EXISTS (
      SELECT 1 FROM public.shifts
      WHERE event_id = NEW.event_id
        AND claimed_by = NEW.claimed_by
        AND id != NEW.id
        AND status IN ('pending', 'claimed', 'completed')
    ) THEN
      RAISE EXCEPTION 'Na této akci již máte jinou směnu';
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
$function$;

-- -----------------------------------------------------------------------------
-- 3) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _n int;
BEGIN
  FOR _n IN SELECT 1 LOOP END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE schemaname='public' AND indexname='shifts_jeden_trener_na_akci') THEN
    RAISE EXCEPTION 'Index na jednoho trenéra chybí.';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.validate_shift_claim()'::regprocedure)
     NOT LIKE '%už má někdo jiný%' THEN
    RAISE EXCEPTION 'Guard proti převzetí cizí směny chybí.';
  END IF;

  -- Data musí pravidlům odpovídat i po vytvoření indexů (kdyby někdo index
  -- postavil s jiným predikátem, tohle to chytí).
  SELECT count(*) INTO _n FROM (
    SELECT event_id FROM public.shifts
     WHERE required_role='trainer' AND status <> 'cancelled'
     GROUP BY event_id HAVING count(*) > 1) x;
  IF _n > 0 THEN RAISE EXCEPTION 'Pořád je % akcí se dvěma živými trenéry.', _n; END IF;

  -- Index na (akce, člověk) tu SCHVÁLNĚ NENÍ — dvě různé role na jedné akci
  -- jsou legitimní (potvrzeno provozem 1. 9. 2026).
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='shifts_jedna_smena_na_cloveka_a_akci') THEN
    RAISE EXCEPTION 'Index na (akce, člověk) je zpátky — blokuje dvě role jednoho člověka na akci.';
  END IF;

  RAISE NOTICE 'Placené směny nejdou zdvojit ani v souběhu.';
END $kontrola$;
