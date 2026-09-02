-- =============================================================================
-- Sazbu a odpracované hodiny na směně mění jen správce haly (nález F1)
-- =============================================================================
-- KROK 0 — CO PLATÍ DNES (změřeno reálným tokenem na produkci 2. 9. 2026):
--
-- Politika `Staff update own shifts, admins anything` má ve `WITH CHECK` jen
-- podmínku na `status` a `claimed_by`. `validate_shift_claim()` kontroluje
-- u sazby a hodin POUZE ROZSAH (1–10 000 Kč, 0,1–24 h) — nikdy ne, jestli je
-- vůbec někdo směl změnit. Sloupce jsou přitom v tabulkovém UPDATE grantu pro
-- `authenticated`, takže je brigádník zapíše přímo.
--
-- Naměřeno jedním příkazem při zabrání volné směny vypsané na 200 Kč/h:
--
--   update shifts set status='pending', claimed_by=<já>,
--                     hours_worked=24, hourly_rate=10000 where id=…;
--   → pending, 24 h × 10 000 Kč
--
-- Admin pak jen překlopí `pending → claimed → completed`. Hodiny zadávat
-- nemusí, už tam jsou (kontrola „Musíte zadat odpracované hodiny" vidí
-- vyplněnou hodnotu), takže o ničem neví. `Payouts.tsx:654` počítá
-- `hours_worked × hourly_rate` = **240 000 Kč** místo ~400 Kč.
--
-- Týká se všech čtyř štábních rolí, které politika jmenuje: `part_time_staff`,
-- `instructor`, `bar_staff`, `manager`.
--
-- DRUHÁ CESTA K TÝMŽ PENĚZŮM (našla brána RLS, potvrzeno měřením 2. 9. 2026).
-- Zavřít jen přímý zápis nestačí: přechod `completed → open` nehlídala žádná
-- větev, takže brigádník znovu otevřel KOLEGOVI DOKONČENOU směnu, vzal si ji
-- a hodiny se sazbou ZDĚDIL — guard výš se nespustí, protože se ta čísla
-- nemění. Dvěma obyčejnými UPDATE, bez adminské role, i napříč rolemi:
-- `part_time_staff` za 150 Kč/h si takhle vzal trenérskou směnu za 600 Kč/h.
-- Původnímu držiteli tím z dokončené směny zmizel podklad k výplatě.
--
-- Do téže úvahy patří `payout_id` a `notes`: obojí je pro štáb v tabulkovém
-- UPDATE grantu a `WITH CHECK` je nejmenuje. Ověřeno, že je zapisuje jedině
-- admin — `notes` přes `completeShift`/`completeShiftsIndividually`,
-- `payout_id` přes `usePayouts.ts:52` při zakládání výplaty — takže se
-- zamčením nezavírá žádná legitimní cesta.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ
-- -----------------------------------------------------------------------------
-- Do `validate_shift_claim()` přibývá ÚPLNĚ NAHOŘE brána: kdo není admin,
-- nesmí `hourly_rate` ani `hours_worked` změnit. Ani u volné směny — sazbu
-- u `open` směny by jinak šlo nadhodnotit dopředu a teprve pak si ji vzít.
--
-- Brána je schválně PŘED kontrolou rozsahu: sazba 9 999 Kč je „v rozsahu",
-- a přesto ji brigádník nastavit nesmí. Rozsah je pojistka proti překlepu
-- admina, ne oprávnění.
--
-- VÝJIMKA JEN PRO DATABÁZOVOU ROLI — a má doložený důvod, není „pro jistotu".
--
-- Aplikační cesty ji nepotřebují: ověřeno na živém schématu, že jediné funkce,
-- které `shifts` updatují (`cancel_open_shifts_on_reservation_cancel`,
-- `dorovnej_stab`, `odeber_trenera`), sahají výhradně na `status`,
-- `cancelled_at` a `cancelled_by`. Guard je tedy nepotkává.
--
-- Potřebují ji ale MIGRACE. První verze téhle migrace výjimku neměla a sada
-- testů to chytila: `20260827090000_sazby_roli.sql:444` dělá backfill
-- `UPDATE public.shifts SET hourly_rate = 150 WHERE hourly_rate IS NULL`
-- jako `postgres`. Bez výjimky by taková údržba spadla na guardu, který na ni
-- nemíří.
--
-- Podmínka schválně NESTOJÍ jen na „auth.uid() IS NULL" — to by z tokenu
-- bez `sub` udělalo klíč k sazbám. Druhá půlka je `session_user`, tedy totéž
-- kritérium, jaké používá `billing_reconcile`. Přes PostgREST je `session_user`
-- vždycky `authenticator`, nikdy `postgres`, takže tudy se z webu neproleze.
--
-- LEGITIMNÍ CESTY, KTERÉ MUSÍ DÁL FUNGOVAT (ověřeno v `src/hooks/useShifts.ts`):
--   requestShift  (štáb, open→pending)  … status, claimed_by, claimed_at
--   cancelRequest / cancelShift (štáb)  … status, claimed_by, claimed_at
--   approveShift / rejectShift (admin)  … status, claimed_by, claimed_at
--   assignShift (admin)                 … status, claimed_by, claimed_at
--   completeShift / completeShiftsIndividually (admin) … hours_worked + hourly_rate
-- Z nich jen ta poslední na hlídané sloupce sahá — a je adminská.
--
-- VRATNOST: funkce zpátky bez bloku „SAZBU A HODINY MĚNÍ JEN SPRÁVCE HALY".
-- =============================================================================

-- Radši spadnout na zámku než čekat za dlouhou transakcí: migrace mění
-- politiky a funkce za provozu a `AccessExclusiveLock` by mezitím blokoval
-- zápisy uživatelů. Tři vteřiny stačí, na klidné databázi se to neprojeví.
--
-- Schválně BEZ `LOCAL`: žádná migrace v tomhle repu si transakci neotvírá
-- sama, takže `SET LOCAL` by mimo transakční blok jen vypsal WARNING
-- a NEPLATIL. Na konci souboru se to vrací `RESET`em.
SET lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.validate_shift_claim()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
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

-- =============================================================================
-- SEBEKONTROLA — síť, kterou sem nainstalovala migrace 20260902090000
-- =============================================================================
-- `CREATE OR REPLACE FUNCTION` vyžaduje CELÉ tělo, takže každý přepis téhle
-- funkce může tiše shodit guard, o kterém autor nevěděl. Přesně to se stalo
-- u commitu 87b1f78 a proto tenhle blok existuje. Tahle migrace funkci
-- přepisuje, takže kontrolu MUSÍ převzít — jinak by ji zahodila a příště by
-- nikoho nechytila.
DO $kontrola$
DECLARE _telo text;
BEGIN
  SELECT prosrc INTO _telo FROM pg_proc
   WHERE oid = 'public.validate_shift_claim()'::regprocedure;

  -- Tři guardy zděděné z 20260902090000:
  IF _telo NOT LIKE '%required_role IS NOT DISTINCT FROM%' THEN
    RAISE EXCEPTION 'Kontrola se pořád neptá na roli — dvě různé role na akci by neprošly.';
  END IF;
  IF _telo NOT LIKE '%už má někdo jiný%' THEN
    RAISE EXCEPTION 'Guard proti převzetí cizí směny zmizel.';
  END IF;
  IF _telo NOT LIKE '%Směna již byla obsazena%' THEN
    RAISE EXCEPTION 'Kontrola „směna už je obsazená" zmizela.';
  END IF;

  -- Guardy, které tam byly a týkají se peněz:
  IF _telo NOT LIKE '%Pouze admin může schválit směnu%'
     OR _telo NOT LIKE '%Pouze admin může dokončit směnu%'
     OR _telo NOT LIKE '%Musíte zadat odpracované hodiny%' THEN
    RAISE EXCEPTION 'Některý z adminských guardů u schválení/dokončení směny zmizel.';
  END IF;

  -- A nový guard z téhle migrace:
  IF _telo NOT LIKE '%Sazbu, hodiny, vazbu na výplatu ani poznámku%' THEN
    RAISE EXCEPTION 'Guard na sazbu, hodiny, payout_id a notes se nezapsal.';
  END IF;
  IF _telo NOT LIKE '%Uzavřenou směnu znovu otevírá jen správce haly%' THEN
    RAISE EXCEPTION 'Guard proti znovuotevření dokončené směny se nezapsal.';
  END IF;

  RAISE NOTICE 'validate_shift_claim(): všechny guardy na místě, sazbu a hodiny mění jen admin.';
END $kontrola$;

RESET lock_timeout;
