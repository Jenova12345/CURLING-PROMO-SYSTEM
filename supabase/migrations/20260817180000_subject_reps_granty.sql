-- =============================================================================
-- Úklid grantů na `subject_reps` (obrana do hloubky)
-- =============================================================================
-- `subject_reps` je JEDINÉ úložiště klubových oprávnění: kdo je členem klubu a
-- kdo jeho zástupcem. Od migrace „žádosti o klub" na něm stojí celá cesta
-- registrace → schválení → přístup k rezervacím klubu.
--
-- Přitom měl `anon` (tedy KAŽDÝ NEPŘIHLÁŠENÝ) z výchozích grantů Supabase
-- INSERT, UPDATE, DELETE, TRIGGER a REFERENCES. Dnes to zneužít nejde — `anon`
-- nemá na téhle tabulce žádnou politiku, takže ho zastaví RLS (ověřeno: HTTP
-- 401 „new row violates row-level security policy") — jenže mezi nepřihlášeným
-- a tabulkou členství pak stojí JEDNA vrstva. Jediná budoucí politika psaná
-- jako `FOR ALL USING (true)` nebo `TO public` z toho udělá zápis.
--
-- PROČ SE `authenticated` NESAHÁ: adminská správa členů zapisuje do téhle
-- tabulky přímo z klienta (`src/hooks/useSubjectsAdmin.ts`), ne přes RPC.
-- Granty tam tedy musí zůstat a přístup hlídají politiky
-- `subject_reps_insert_admin` / `_update_admin` / `_delete_admin`.
-- Sundat je by znamenalo nejdřív přepsat správu členů na RPC — což je změna,
-- ne úklid, a patří do vlastního zadání.
-- =============================================================================

REVOKE ALL ON public.subject_reps FROM anon;

-- Kontrola na místě: kdyby výchozí granty někdo vrátil (nová tabulka, obnovený
-- projekt), tahle migrace se ozve při dalším spuštění místo aby tiše prošla.
DO $$
DECLARE _zbylo text;
BEGIN
  SELECT string_agg(privilege_type, ', ' ORDER BY privilege_type) INTO _zbylo
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'subject_reps' AND grantee = 'anon';

  IF _zbylo IS NOT NULL THEN
    RAISE EXCEPTION 'Na subject_reps zůstala anonovi práva: %', _zbylo;
  END IF;

  RAISE NOTICE 'subject_reps: anon nemá žádná práva (členství je za dvěma vrstvami, ne jednou).';
END $$;
