-- =============================================================================
-- Přímé přidání do klubu uzavírá čekající žádost (Jakubův nález, 4. 9. 2026)
-- =============================================================================
-- CO SE OPRAVUJE
--
-- Členství vzniká DVĚMA cestami, ale frontu žádostí uklízela jen jedna:
--
--   1. `approve_subject_request` — založí členství A žádost uzavře. V pořádku.
--   2. Admin UI „Kluby" (`src/hooks/useSubjectsAdmin.ts`) vkládá do
--      `subject_reps` PŘÍMO (RLS to pouští jen adminovi, viz
--      `subject_reps_insert_admin`). Žádost o tenhle klub zůstane `ceka`
--      NAVŽDY — a žadateli se dál ukazuje „čeká na vyřízení", přestože už
--      členem je.
--
-- Na produkci dnes 0 takových řádků (změřeno), takže se nezavírá požár, ale
-- otevřená cesta. Druhá půlka téhož nálezu byla ve frontendu (karta brala první
-- CIZÍ čekající žádost) a řeší ji `src/lib/vlastniZadosti.ts` — bez migrace.
--
-- PROČ TRIGGER A NE OPRAVA ADMIN UI
--
-- Kdyby se opravila jen obrazovka, platí to do prvního dalšího zapisovatele.
-- Trigger drží pravidlo jako INVARIANT: ať členství založí kdokoli a odkudkoli,
-- odpovídající žádost se tím vyřídí.
--
-- PROČ `SECURITY DEFINER` — A ŽE BEZ NĚJ TO TIŠE NEDĚLÁ NIC
--
-- `subject_requests` má RLS zapnutou a **ani jednu zápisovou politiku**
-- (ověřeno: `pg_policies` má na téhle tabulce jen `subject_requests_select`),
-- a `authenticated` na ni nemá ani tabulkový `UPDATE` grant. Trigger bez
-- `SECURITY DEFINER` běží právy volajícího admina, takže jeho `UPDATE` skončí
-- na `permission denied for table subject_requests` — a s ním spadne i celý
-- `INSERT` do `subject_reps`, tedy přidání člena přes admin UI.
--
-- Změřeno mutací (m2), ne odhadnuto. Dřívější znění tohohle odstavce tvrdilo,
-- že by `UPDATE` „prošel bez chyby a změnil nula řádků" — to NEPLATÍ: grant
-- chybí dřív, než vůbec přijde na řadu RLS. Selhává to tedy nahlas, ne tiše;
-- definer je potřeba stejně, jen z jiného důvodu, než tu stálo.
--
-- Vlastníkem funkce je `postgres` a `relforcerowsecurity` je `false`, takže
-- definer RLS i granty obchází.
--
-- ROZSAH: JEN TÁŽ DVOJICE (uživatel, klub)
--
-- Databáze pouští nejvýš jednu čekající žádost na člověka (unikátní index
-- `idx_subject_requests_jedna_cekajici` na `user_id` WHERE status='ceka').
-- Ta žádost ale může mířit na JINÝ klub, než do kterého ho admin právě přidává
-- — a to je pak žádost, kterou má pořád někdo vyřídit. Proto se zavírá jen
-- shoda `user_id` I `subject_id`.
--
-- PROČ SE NENASTAVUJE `decision_reason`
--
-- Trigger vystřelí i uvnitř `approve_subject_request` (ta do `subject_reps`
-- taky vkládá). Kdyby psal důvod typu „členství přidal správce přímo",
-- zůstala by ta věta u ŘÁDNĚ schválené žádosti — funkce svým pozdějším
-- `UPDATE` důvod nepřepisuje. Bez důvodu je efekt triggeru shodný s tím,
-- co dělá RPC samo, takže se ty dvě cesty nemůžou rozejít. Kdo změnu udělal,
-- je stejně vidět v `decided_by` a v `audit_log`
-- (`trg_subject_requests_audit` na tabulce je).
--
-- VRATNOST
--
-- SCHÉMA — vratné: `DROP TRIGGER trg_subject_reps_zavri_zadost ON
-- public.subject_reps;` a `DROP FUNCTION public.zavri_zadost_pri_primem_clenstvi();`
-- (v tomhle pořadí). Nic staršího se nepřepisuje, takže není co obnovovat.
--
-- DATA — část 2 je NEVRATNÁ: přepisuje `subject_requests.status` na
-- `schvalena` a původní hodnotu si neukládá. Dohledatelná je z `audit_log`
-- (na rozdíl od úklidu přihlášek v 20260903180000 tahle tabulka auditovaná JE).
-- Na produkci je ta množina prázdná, takže dnes není co vracet.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Invariant: členství uzavírá žádost o tentýž klub
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.zavri_zadost_pri_primem_clenstvi()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- `status = 'ceka'` v podmínce je podstatné: bez něj by se přerazítkovala
  -- i dávno vyřízená žádost (nové `decided_at`, nový `decided_by`) pokaždé,
  -- když admin s členstvím jen pohne.
  UPDATE public.subject_requests
     SET status      = 'schvalena',
         decided_at  = now(),
         decided_by  = coalesce(auth.uid(), NEW.created_by)
   WHERE user_id    = NEW.user_id
     AND subject_id = NEW.subject_id
     AND status     = 'ceka';

  RETURN NULL;   -- AFTER trigger, návratová hodnota se zahazuje
END;
$function$;

DROP TRIGGER IF EXISTS trg_subject_reps_zavri_zadost ON public.subject_reps;
CREATE TRIGGER trg_subject_reps_zavri_zadost
  AFTER INSERT ON public.subject_reps
  FOR EACH ROW EXECUTE FUNCTION public.zavri_zadost_pri_primem_clenstvi();

-- ---------------------------------------------------------------------------
-- 2) Doběh: žádosti, které takhle uvízly dřív
-- ---------------------------------------------------------------------------
-- Na produkci 0 řádků (změřeno 4. 9. 2026 před nasazením). Na demu a na čisté
-- DB to nula být nemusí, a bez tohohle by tam invariant platil jen pro nová
-- členství, kdežto staré rozpory by zůstaly viset.
--
-- `decided_by` schválně z `subject_reps.created_by`, ne z `auth.uid()`:
-- migraci pouští `postgres` bez přihlášeného uživatele, takže `auth.uid()`
-- je NULL. Kdo členství založil, je zaznamenané u něj.
DO $dobeh$
DECLARE _n integer;
BEGIN
  UPDATE public.subject_requests r
     SET status     = 'schvalena',
         decided_at = now(),
         decided_by = coalesce(sr.created_by, r.decided_by)
    FROM public.subject_reps sr
   WHERE sr.user_id    = r.user_id
     AND sr.subject_id = r.subject_id
     AND r.status      = 'ceka';
  GET DIAGNOSTICS _n = ROW_COUNT;
  RAISE NOTICE 'Uvízlé žádosti uzavřeny: % řádků.', _n;
END $dobeh$;

-- ---------------------------------------------------------------------------
-- 3) Sebekontrola
-- ---------------------------------------------------------------------------
-- CO UMÍ A CO NE: chytí, že se změny z TÉHLE migrace nepropsaly (trigger se
-- nezaložil, tělo se nepropsalo, definer se ztratil). NEHLÍDÁ budoucí regresi —
-- migrace si své DDL o pár řádků výš sama nastaví. Proti regresi je mutační
-- sada v `supabase/tests/prime_clenstvi_zavira_zadost_test.sql`.
DO $kontrola$
DECLARE _src text; _secdef boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid = 'public.subject_reps'::regclass
       AND tgname  = 'trg_subject_reps_zavri_zadost'
       AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Trigger trg_subject_reps_zavri_zadost na subject_reps chybí.';
  END IF;

  SELECT prosrc, prosecdef INTO _src, _secdef
    FROM pg_proc WHERE oid = 'public.zavri_zadost_pri_primem_clenstvi()'::regprocedure;

  -- Bez defineru skončí `UPDATE` na `permission denied for table subject_requests`
  -- (`authenticated` na ni nemá ani tabulkový grant) a shodí s sebou i přidání
  -- člena přes admin UI. Změřeno mutací m2 — dřív tu stálo „tiše neudělá nic",
  -- což NEPLATÍ a odporovalo to hlavičce.
  IF NOT _secdef THEN
    RAISE EXCEPTION 'Funkce není SECURITY DEFINER — UPDATE spadne na permission denied.';
  END IF;

  -- Kotví se na obě půlky podmínky. Kdyby zmizel filtr na `subject_id`,
  -- členství v jednom klubu by zavřelo žádost o úplně jiný.
  --
  -- `position()`, ne `LIKE`: podtržítko je v `LIKE` ŽOLÍK, takže maska
  -- `%subject_id = NEW.subject_id%` by sedla i na `subjectXid = NEWysubject_id`.
  -- Kotva by byla volnější, než vypadá — a kotva, která pustí i přepsaný kód,
  -- nehlídá nic.
  IF position('subject_id = NEW.subject_id' in _src) = 0 THEN
    RAISE EXCEPTION 'Zmizel filtr na subject_id — členství by zavřelo cizí žádost.';
  END IF;
  IF position('status     = ''ceka''' in _src) = 0 THEN
    RAISE EXCEPTION 'Zmizel filtr na ceka — přerazítkovaly by se i vyřízené žádosti.';
  END IF;

  RAISE NOTICE 'Přímé členství uzavírá žádost; trigger i definer sedí.';
END $kontrola$;
