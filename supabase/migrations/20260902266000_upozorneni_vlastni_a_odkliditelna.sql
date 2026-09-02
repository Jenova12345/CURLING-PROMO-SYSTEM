-- =============================================================================
-- Upozornění: zvonek je osobní schránka a jde v něm uklidit (Jakubův nález)
-- =============================================================================
-- KROK 0 — CO PLATÍ DNES (změřeno Jakubovým vlastním tokenem na produkci
-- 2. 9. 2026, `ad69770f-…`):
--
--   vidí v zvonku celkem …… 12
--   z toho cizích ………………………  9
--   odznak (nepřečtené) ……  9
--   po kliknutí na „Označit vše jako přečtené":  UPDATE 3, odznak zůstal 6
--
-- Tím jsou Jakubovy tři symptomy vysvětlené jednou příčinou a jednou navíc:
--
-- 1. „DRŽÍ UPOZORNĚNÍ, KTERÁ NEJSOU MOJE." Politika `notifications_select_own`
--    má větev `OR has_role(auth.uid(), 'admin')`. Zvonek je přitom osobní
--    schránka — žádná obrazovka „všechna upozornění všech" neexistuje, jediný
--    konzument je `NotificationBell.tsx`. Admin tak čte i těla cizích
--    upozornění (jméno klubu, čas rezervace, důvod zrušení).
--
-- 2. „NEJDOU OZNAČIT PŘEČTENÉ." Přímý důsledek bodu 1: SELECT vrátí 12 řádků,
--    ale `notifications_update_own` pouští jen `user_id = auth.uid()`. Klient
--    pošle ID všech nepřečtených, projdou tři vlastní, zbytek RLS zahodí BEZ
--    CHYBY (0 řádků není chyba) — a odznak se zasekne na čísle, které nejde
--    umazat. Proto se to tvářilo jako rozbité tlačítko.
--
-- 3. „NEJDE ODKLIDIT UPOZORNĚNÍ KE ZRUŠENÉ REZERVACI." Tabulka nemá žádnou
--    DELETE politiku (`DELETE` vrátil 0 řádků) ani sloupec, kterým by šlo říct
--    „viděl jsem, zmiz". Přečtení je něco jiného: chci vidět, že mi zrušili
--    trénink, a teprve pak to uklidit.
--
-- (Čtvrtý symptom — panel nejde rolovat — je čistě ve frontendu,
--  `NotificationBell.tsx`, s databází nesouvisí.)
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ
-- -----------------------------------------------------------------------------
--   1. `notifications_select_own` ztrácí adminskou větev. Kdo je adresát, ten
--      to vidí — nikdo jiný. Množina, kterou zvonek NAČTE, se tím srovná
--      s množinou, kterou smí ZAPSAT, a „označit přečtené" začne fungovat samo.
--   2. Přibývá `dismissed_at` — odklizení, ne mazání (zásada „nic nemazat
--      natvrdo"). Upozornění zůstane v tabulce i v auditu, jen zmizí ze zvonku.
--   3. `guard_notification_update()` ho pouští vedle `read_at`. Zbytek sloupců
--      hlídá dál — obsah upozornění si adresát přepsat nesmí.
--
-- ⚠️ DELETE POLITIKA SE NEPŘIDÁVÁ. `email_outbox.notification_id` na tabulku
-- ukazuje a smazané upozornění by z fronty e-mailů udělalo řádek bez původu.
--
-- MUTAČNÍ ZKOUŠKA: vrať do SELECT politiky `OR has_role(…, 'admin')` a pusť
-- `supabase/tests/upozorneni_zvonek_test.sql` — musí zčervenat.
--
-- VRATNOST:
--   ALTER TABLE public.notifications DROP COLUMN dismissed_at;
--   + politika a guard zpátky ve tvaru z 20260812…/20260902220000.
-- =============================================================================

-- Radši spadnout na zámku než čekat za dlouhou transakcí: migrace mění
-- politiky a funkce za provozu a `AccessExclusiveLock` by mezitím blokoval
-- zápisy uživatelů. Tři vteřiny stačí, na klidné databázi se to neprojeví.
--
-- Schválně BEZ `LOCAL`: žádná migrace v tomhle repu si transakci neotvírá
-- sama, takže `SET LOCAL` by mimo transakční blok jen vypsal WARNING
-- a NEPLATIL. Na konci souboru se to vrací `RESET`em.
SET lock_timeout = '3s';

-- 1) Zvonek je osobní schránka.
DROP POLICY IF EXISTS "notifications_select_own" ON public.notifications;
CREATE POLICY "notifications_select_own" ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- 2) Odklizení (soft), ne mazání.
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS dismissed_at timestamptz;

COMMENT ON COLUMN public.notifications.dismissed_at IS
  'Kdy adresát upozornění odklidil ze zvonku. Není to smazání ani přečtení: '
  'zrušený trénink chci nejdřív vidět a teprve pak uklidit.';

-- Zvonek se ptá „moje, neodklizené, od nejnovějšího".
CREATE INDEX IF NOT EXISTS idx_notifications_user_zive
  ON public.notifications (user_id, created_at DESC)
  WHERE dismissed_at IS NULL;

-- 3) Guard pustí i `dismissed_at`. Zbytek sloupců drží dál.
CREATE OR REPLACE FUNCTION public.guard_notification_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.type  IS DISTINCT FROM OLD.type
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.body  IS DISTINCT FROM OLD.body
     OR NEW.link  IS DISTINCT FROM OLD.link
     OR NEW.reservation_id IS DISTINCT FROM OLD.reservation_id
     OR NEW.subject_id     IS DISTINCT FROM OLD.subject_id
     OR NEW.created_at     IS DISTINCT FROM OLD.created_at
     OR NEW.created_by     IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'U notifikace lze měnit jen příznak přečtení a odklizení';
  END IF;
  RETURN NEW;
END;
$function$;

-- =============================================================================
-- SEBEKONTROLA
-- =============================================================================
DO $kontrola$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policy p
     WHERE p.polrelid = 'public.notifications'::regclass
       AND p.polname = 'notifications_select_own'
       AND pg_get_expr(p.polqual, p.polrelid) LIKE '%has_role%'
  ) THEN
    RAISE EXCEPTION 'Zvonek pořád pouští adminskou větev — admin by viděl cizí upozornění.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema='public' AND table_name='notifications' AND column_name='dismissed_at'
  ) THEN
    RAISE EXCEPTION 'Sloupec dismissed_at nevznikl — nešlo by nic odklidit.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid='public.guard_notification_update()'::regprocedure)
     NOT LIKE '%NEW.title IS DISTINCT FROM OLD.title%' THEN
    RAISE EXCEPTION 'Guard přestal hlídat obsah upozornění.';
  END IF;

  RAISE NOTICE 'Zvonek je osobní schránka, dismissed_at je na místě, guard drží.';
END $kontrola$;

RESET lock_timeout;
