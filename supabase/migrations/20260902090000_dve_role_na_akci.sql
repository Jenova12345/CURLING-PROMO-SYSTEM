-- =============================================================================
-- Dvě různé role na jedné akci si brigádník vezme sám
-- Upřesnění provozu (Jakub, 1. 9. 2026)
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- `validate_shift_claim` odmítala druhou směnu na téže akci hláškou „Na této
-- akci již máte jinou směnu" — BEZ OHLEDU NA ROLI. Kdo na jedné akci dělá bar
-- a zároveň instruktora, si tu druhou přes samoobsluhu vzít nemohl; musel ho
-- tam přiřadit admin přímým zápisem, kde se trigger nespustí.
--
-- Provoz to přitom dělá běžně a platí se za obojí. Kontrola tedy zakazovala
-- něco legitimního a zároveň se dala obejít cestou, která ji míjí — nejhorší
-- kombinace, jakou pravidlo může mít.
--
-- CO SE MĚNÍ: kontrola se zužuje na TOTOŽNOU ROLI. Táž role na téže akci
-- dvakrát zůstává zakázaná — to není druhá práce, to je jedna práce vykázaná
-- (a zaplacená) dvakrát.
--
-- CO SE NEMĚNÍ: ochrana proti dvojímu zabrání TÉŽE směny. Drží ji dvě jiné
-- větve téhož triggeru — `OLD.claimed_by IS NOT NULL` při `open -> pending`
-- a guard proti převzetí cizí směny z 20260901160000. Obojí zůstává znak za
-- znakem a testuje se dál.
--
-- VRATNOST: funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef).
-- =============================================================================

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

DO $kontrola$
BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.validate_shift_claim()'::regprocedure)
     NOT LIKE '%required_role IS NOT DISTINCT FROM%' THEN
    RAISE EXCEPTION 'Kontrola se pořád neptá na roli — dvě různé role na akci by neprošly.';
  END IF;
  -- Ochrana téže směny se tímhle nesmí ztratit.
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.validate_shift_claim()'::regprocedure)
     NOT LIKE '%už má někdo jiný%' THEN
    RAISE EXCEPTION 'Guard proti převzetí cizí směny zmizel.';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.validate_shift_claim()'::regprocedure)
     NOT LIKE '%Směna již byla obsazena%' THEN
    RAISE EXCEPTION 'Kontrola „směna už je obsazená" zmizela.';
  END IF;
  RAISE NOTICE 'Dvě různé role na akci projdou; táž role dvakrát ne.';
END $kontrola$;
