-- =============================================================================
-- Guard upozornění na whitelist: ne-admin smí měnit jen read_at a dismissed_at
-- =============================================================================
-- KROK 0 — CO PLATÍ DNES (změřeno reálným tokenem na produkci 2. 9. 2026):
--
-- `guard_notification_update()` je psaný jako BLACKLIST — vyjmenovává, co se
-- měnit nesmí (`user_id, type, title, body, link, reservation_id, subject_id,
-- created_at, created_by`). Sloupec `id` v seznamu chybí, takže si adresát
-- přepíše identifikátor vlastního upozornění. Ověřeno: `UPDATE notifications
-- SET id = '…'` prošlo (1 řádek).
--
-- Dopad toho konkrétního případu je nulový: na cizí `id` nepustí PK a jakmile
-- na upozornění ukazuje `email_outbox.notification_id`, zápis spadne na FK
-- (`20260731110000_booking_core.sql:492`, `ON DELETE SET NULL`, tedy
-- `ON UPDATE NO ACTION`).
--
-- ⚠️ ALE PŘÍČINA NENÍ „ZAPOMNĚLI JSME `id`". Příčina je tvar guardu: u
-- blacklistu je každý NOVĚ PŘIDANÝ sloupec automaticky povolený. `id` tam
-- nechybí omylem — vypadlo přesně tímhle mechanismem, stejně jako
-- `dismissed_at` v migraci 20260902266000 muselo být do seznamu dopsáno
-- ručně, aby šlo měnit. Táž past kousla `guard_reservation_rep_changes()`
-- třikrát po sobě (falšování auditu), načež se přepsal na whitelist
-- (`20260813090000_faktury_zaklad.sql:355`). Tady se dělá totéž.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ
-- -----------------------------------------------------------------------------
-- Místo výčtu zakázaných sloupců výčet POVOLENÝCH: `read_at`, `dismissed_at`.
-- Cokoli jiného — včetně `id` a včetně sloupců, které teprve přibudou — je
-- zakázané, dokud ho tam někdo vědomě nedopíše. Hláška navíc jmenuje sloupec,
-- na kterém to stálo, ať se to nehádá.
--
-- ⚠️ ADMINSKÁ VÝJIMKA SE SCHVÁLNĚ NEPŘIDÁVÁ, i když zadání mluví o ne-adminovi.
-- `notifications_update_own` pouští jen `user_id = auth.uid()`, takže se sem
-- admin dostane výhradně u SVÉHO upozornění — tedy jako adresát, ne jako
-- správce. Přidat mu bypass by znamenalo, že si smí přepsat text upozornění,
-- které dostal; nikomu to k ničemu není a auditní stopě to škodí. Guard proto
-- platí na všechny stejně, což je PŘÍSNĚJŠÍ než zadání, ne volnější.
--
-- Výjimka pro databázovou roli tu je, stejně jako u vzoru: migrace a seed
-- musí projít. `session_user` schválně — uvnitř SECURITY DEFINER je
-- `current_user` vždy vlastník funkce, takže by nerozlišil nic; PostgREST se
-- připojuje jako `authenticator`, takže tudy klient nespadne.
--
-- MUTAČNÍ ZKOUŠKA: vrať `_allowed` na `ARRAY['read_at','dismissed_at','id']`
-- (nebo guard celý na blacklist) a pusť `supabase/tests/upozorneni_zvonek_test.sql`
-- — musí zčervenat na scénáři „přepsání id".
--
-- VRATNOST: funkce zpátky z 20260902266000_upozorneni_vlastni_a_odkliditelna.sql.
-- =============================================================================

SET lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.guard_notification_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  -- WHITELIST, ne blacklist. Kdo přidá sloupec, který má jít adresátovi měnit,
  -- musí ho sem dopsat — a tím se nad tím zamyslí. To je celý smysl.
  _allowed CONSTANT text[] := ARRAY['read_at', 'dismissed_at'];
  _changed text[];
  _forbidden text;
BEGIN
  -- Migrace, seed a servisní zásahy pod databázovou rolí.
  IF auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  SELECT array_agg(n.key) INTO _changed
    FROM jsonb_each(to_jsonb(NEW)) n
    JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
   WHERE n.value IS DISTINCT FROM o.value;
  _changed := COALESCE(_changed, '{}');

  SELECT c INTO _forbidden FROM unnest(_changed) c WHERE c <> ALL (_allowed) LIMIT 1;
  IF _forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'U upozornění lze měnit jen přečtení a odklizení, ne „%".', _forbidden
      USING HINT = 'Text upozornění zakládá server a je součástí auditní stopy.';
  END IF;

  RETURN NEW;
END;
$function$;

-- =============================================================================
-- SEBEKONTROLA
-- =============================================================================
DO $kontrola$
DECLARE _telo text;
BEGIN
  SELECT prosrc INTO _telo FROM pg_proc
   WHERE oid = 'public.guard_notification_update()'::regprocedure;

  IF _telo NOT LIKE '%_allowed CONSTANT text[]%' THEN
    RAISE EXCEPTION 'Guard upozornění není na whitelistu — default-allow se vrátil.';
  END IF;
  IF _telo LIKE '%NEW.title IS DISTINCT FROM OLD.title%' THEN
    RAISE EXCEPTION 'V guardu zůstal starý blacklist; whitelist se nezapsal.';
  END IF;

  RAISE NOTICE 'guard_notification_update(): whitelist (read_at, dismissed_at), nic jiného.';
END $kontrola$;

RESET lock_timeout;
