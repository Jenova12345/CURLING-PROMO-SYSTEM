-- =============================================================================
-- Přihlásit se na směnu smí jen aktivní účet (nález F2)
-- =============================================================================
-- KROK 0 — CO PLATÍ DNES (změřeno reálným tokenem na produkci 2. 9. 2026):
--
-- Všechny čtyři politiky na `shift_applications` jsou `TO PUBLIC` a stojí
-- výhradně na `user_id = auth.uid()`. Brána účtu `ucet_aktivni()` tam NENÍ —
-- je to jediné místo v celém schématu, kde chybí. Naměřeno:
--
--   profil stav='ceka'        → INSERT do shift_applications PROŠEL
--   profil stav='deaktivovan' → INSERT do shift_applications PROŠEL
--
-- Deaktivovaný účet přitom jinde nevidí a nesmí nic — `has_role()` má
-- `ucet_aktivni()` v sobě, takže ho zavírá i tam, kde mu role zůstala. Tady se
-- role neptáme vůbec, tak se to minulo.
--
-- Vyžaduje to znát UUID směny, protože číst `shift_applications` ani `shifts`
-- takový účet nemůže. To ale není překážka pro toho, o koho jde nejvíc:
-- brigádník, kterého hala právě deaktivovala, ta UUID zná z doby, kdy aktivní
-- byl. Přihlášky pak visí ve frontě a admin je vyřizuje, aniž by z nich poznal,
-- že je poslal zrušený účet.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ
-- -----------------------------------------------------------------------------
--   1. `ucet_aktivni()` do všech vlastnických větví (SELECT, INSERT, UPDATE).
--   2. `TO PUBLIC` → `TO authenticated`. `anon` má na téhle tabulce tabulkové
--      granty (SELECT/INSERT/UPDATE/DELETE) a `TO PUBLIC` znamenalo, že se
--      politiky vztahovaly i na něj. Zavřený byl jen shodou okolností — přes
--      `auth.uid() IS NULL` mu vycházelo `user_id = NULL` na false. Spoléhat
--      u zápisu na NULL-logiku je zbytečně tenké; ať tam ta role je napsaná.
--   3b. Ne-admin si nesmí vlastní přihlášku přepnout na `approved` (nález
--      brány RLS). Schvaluje výhradně správce haly.
--   3. UPDATE dostává výslovný `WITH CHECK`. Klient se přihlašuje přes
--      `upsert(onConflict: 'shift_id,user_id')` (`useShiftApplications.ts:66`),
--      tedy `INSERT … ON CONFLICT DO UPDATE` — a ten se ptá i UPDATE politiky.
--      Bez `WITH CHECK` by se použilo `USING`, což by sice vyšlo stejně, ale
--      opakované přihlášení po zamítnutí je běžná cesta a nemá viset na
--      implicitním pravidle.
--
-- ADMINSKÁ VĚTEV SE NEMĚNÍ: `has_role()` bránu účtu obsahuje.
--
-- VRATNOST: politiky zpátky ve tvaru bez `ucet_aktivni()` a s `TO PUBLIC`
--   (viz baseline / 20260812…_shift_applications).
-- =============================================================================

-- Radši spadnout na zámku než čekat za dlouhou transakcí: migrace mění
-- politiky a funkce za provozu a `AccessExclusiveLock` by mezitím blokoval
-- zápisy uživatelů. Tři vteřiny stačí, na klidné databázi se to neprojeví.
--
-- Schválně BEZ `LOCAL`: žádná migrace v tomhle repu si transakci neotvírá
-- sama, takže `SET LOCAL` by mimo transakční blok jen vypsal WARNING
-- a NEPLATIL. Na konci souboru se to vrací `RESET`em.
SET lock_timeout = '3s';

-- SELECT — svoje, a jen dokud je účet otevřený; admin všechno.
DROP POLICY IF EXISTS "view own or admin" ON public.shift_applications;
CREATE POLICY "view own or admin" ON public.shift_applications
  FOR SELECT TO authenticated
  USING (
    (user_id = auth.uid() AND public.ucet_aktivni())
    OR public.has_role(auth.uid(), 'admin')
  );

-- INSERT — přihlásit se smí jen aktivní účet, a jen sám za sebe.
DROP POLICY IF EXISTS "user insert own" ON public.shift_applications;
CREATE POLICY "user insert own" ON public.shift_applications
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND public.ucet_aktivni());

-- UPDATE — zrušit/obnovit vlastní přihlášku (i cestou upsertu), admin cokoli.
DROP POLICY IF EXISTS "user cancel own / admin update" ON public.shift_applications;
CREATE POLICY "user cancel own / admin update" ON public.shift_applications
  FOR UPDATE TO authenticated
  USING (
    (user_id = auth.uid() AND public.ucet_aktivni())
    OR public.has_role(auth.uid(), 'admin')
  )
  WITH CHECK (
    -- SCHVALUJE JEN ADMIN. Politika pouštěla vlastní řádek bez ohledu na
    -- `status`, takže si člověk mohl vlastní přihlášku přepnout na `approved`
    -- (ověřeno). Směnu tím nezíská — `shifts` je hlídané jinde — ale
    -- `Shifts.tsx:202` a `IceCalendar.tsx:1112` podle toho kreslí „schváleno"
    -- a z adminské fronty `pending` přihláška zmizí. Je to zmatení provozu.
    --
    -- Ne-admin dnes legitimně nastavuje jen `pending` (opakované přihlášení
    -- přes upsert) a `cancelled` (zrušení vlastní přihlášky) —
    -- `useShiftApplications.ts`. `approved` i `rejected` jsou adminské cesty;
    -- zavírá se schválně JEN `approved`, protože to je ta integritní díra.
    (user_id = auth.uid() AND public.ucet_aktivni() AND status <> 'approved')
    OR public.has_role(auth.uid(), 'admin')
  );

-- DELETE — beze změny obsahu, jen se dopisuje role. `has_role()` bránu má.
DROP POLICY IF EXISTS "admin delete" ON public.shift_applications;
CREATE POLICY "admin delete" ON public.shift_applications
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- =============================================================================
-- SEBEKONTROLA — brána účtu musí být ve VŠECH třech vlastnických větvích
-- =============================================================================
DO $kontrola$
DECLARE _chybi text;
BEGIN
  SELECT string_agg(p.polname, ', ') INTO _chybi
    FROM pg_policy p
   WHERE p.polrelid = 'public.shift_applications'::regclass
     AND p.polcmd IN ('r','a','w')          -- SELECT / INSERT / UPDATE
     AND coalesce(pg_get_expr(p.polqual, p.polrelid), '')
       || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') NOT LIKE '%ucet_aktivni%';
  IF _chybi IS NOT NULL THEN
    RAISE EXCEPTION 'Brána účtu chybí v politikách: %', _chybi;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policy p
     WHERE p.polrelid = 'public.shift_applications'::regclass
       AND 0 = ANY(p.polroles)              -- 0 = PUBLIC
  ) THEN
    RAISE EXCEPTION 'Některá politika je pořád TO PUBLIC — vztahovala by se i na anon.';
  END IF;

  RAISE NOTICE 'shift_applications: brána účtu ve všech větvích, žádná politika TO PUBLIC.';
END $kontrola$;

RESET lock_timeout;
