-- =============================================================================
-- Účet se nesmí schválit sám — tři nálezy z hloubkového auditu rolí
-- Audit 31. 8. 2026, měřeno na ostré produkci reálným tokenem
-- =============================================================================
-- NÁLEZ 1 (KRITICKÝ): ÚČET SI SÁM NASTAVIL `stav = 'aktivni'`.
--
-- `profiles` má TABULKOVÝ `GRANT UPDATE` pro `authenticated` a politiku
-- `USING (auth.uid() = user_id)`, takže uživatel legitimně upravuje svůj
-- profil — jenže `stav` je jeho sloupec jako každý jiný. Změřeno na produkci
-- na čerstvě registrovaném, nikdy neschváleném účtu:
--
--     stav PŘED:  ceka
--     PATCH /rest/v1/profiles?user_id=eq.<sám sebe>  {"stav":"aktivni"} → 204
--     stav PO:    aktivni
--
-- A tím se otevřelo všechno, co drží `ucet_aktivni()`: kalendář 0 → 81 řádků
-- (jména klubů i firem, názvy akcí, časy), akce 0 → 43, jména lidí 1 → 4.
-- Totéž fungovalo na účet, který admin DEAKTIVOVAL — sám se pustil zpátky.
--
-- Schválení adminem tedy bylo doporučení, ne podmínka.
--
-- ⚠️ SLOUPCOVÝ `REVOKE UPDATE (stav)` NIC NEŘEŠÍ. Tabulkový grant pokrývá
-- všechny sloupce a odebrat z něj jeden nejde — `information_schema` pak jen
-- ukáže tentýž tabulkový grant rozepsaný po sloupcích. (Táž past jako
-- u `reservations.preferovany_trener`, viz 20260831233000.) Jediná cesta je
-- tabulkový grant ZRUŠIT a nahradit ho výčtem sloupců, které formulář profilu
-- opravdu zapisuje: `full_name`, `phone`, `bank_account` (`useProfile.ts`).
--
-- NÁLEZ 2: `user_roles` měl SELECT `USING (true)`, takže neschválený účet
-- vyjel seznam rolí všech lidí — tedy i UUID adminů.
--
-- NÁLEZ 3: pohled `settings_public` dostal bránu 31. 8., ale TABULKA `settings`
-- pod ním zůstala na `USING (true)`; peníze v ní chrání až sloupcové granty.
-- Neschválený účet měl `select=*` → 403, ale `select=opening_hours` → 200.
--
-- -----------------------------------------------------------------------------
-- CO SE NEMĚNÍ
-- -----------------------------------------------------------------------------
-- Schvalování žádostí. `approve_subject_request` i `reject_subject_request`
-- jsou SECURITY DEFINER, běží pod vlastníkem tabulky a žádný grant pro
-- `authenticated` nepotřebují — `stav` tedy dál mění, jen už to nedokáže sám
-- vlastník účtu. Ověřeno testem, ne úvahou.
--
-- Formulář profilu (jméno, telefon, číslo účtu) funguje beze změny.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   GRANT UPDATE ON public.profiles TO authenticated;   -- pozor, tím se díra vrátí
--   DROP POLICY IF EXISTS user_roles_select ON public.user_roles;
--   CREATE POLICY "Anyone authenticated can read all roles" ON public.user_roles
--     FOR SELECT TO authenticated USING (true);
--   DROP POLICY IF EXISTS settings_select ON public.settings;
--   CREATE POLICY settings_select ON public.settings FOR SELECT TO authenticated USING (true);
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) NÁLEZ 1 — vlastní profil ano, vlastní stav ne
-- -----------------------------------------------------------------------------
REVOKE UPDATE ON public.profiles FROM authenticated;
-- `anon` měl na profilech UPDATE taky. RLS ho nepustí (politika porovnává
-- `auth.uid()`, které je u anonyma NULL), takže to nikdy nebyla díra — ale
-- grant, který nemá co dělat nic, je jen čekání na politiku, která ho pustí.
REVOKE UPDATE ON public.profiles FROM anon;

-- Přesně to, co zapisuje formulář profilu (`useProfile.ts`). `stav` tu
-- SCHVÁLNĚ NENÍ a nesmí přibýt — o vpuštění do systému rozhoduje schvalovací
-- fronta, ne vlastník účtu.
GRANT UPDATE (full_name, phone, bank_account) ON public.profiles TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) NÁLEZ 2 — role vidí až vpuštěný účet
--
-- Vlastní řádek zůstává čitelný vždy: `AuthContext` si po přihlášení tahá
-- role přihlášeného a čekající účet žádné nemá, takže mu to vrátí prázdno —
-- ale ať to vrátí prázdno kvůli tomu, že žádné nemá, ne kvůli tomu, že mu
-- politika sebrala i pohled na sebe.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anyone authenticated can read all roles" ON public.user_roles;
CREATE POLICY "Anyone authenticated can read all roles" ON public.user_roles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.ucet_aktivni());

-- `anon` neměl na `user_roles` co pohledávat ani dřív (žádná politika pro něj
-- neplatí), ale grant tam visel.
REVOKE SELECT, UPDATE ON public.user_roles FROM anon;

-- -----------------------------------------------------------------------------
-- 3) NÁLEZ 3 — tabulka nastavení se zavírá stejně jako pohled nad ní
--
-- Čtení pro aplikaci jde přes `settings_public`, který maskuje sazby a od
-- 20260831234000 má vlastní bránu. Tabulku samotnou nečte v `src/` nikdo —
-- `useSettings` do ní jen ZAPISUJE (admin), a UPDATE politika zůstává.
--
-- SECURITY DEFINER funkce (`set_reservation_pricing`, `validate_reservation_slot`)
-- běží pod vlastníkem tabulky, na kterého se RLS neuplatňuje, takže se jich
-- tahle brána netýká.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS settings_select ON public.settings;
CREATE POLICY settings_select ON public.settings
  FOR SELECT TO authenticated
  USING (public.ucet_aktivni());

-- -----------------------------------------------------------------------------
-- 4) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _n int;
BEGIN
  -- Tabulkový UPDATE na profiles nesmí existovat pro nikoho z klientských rolí.
  SELECT count(*) INTO _n FROM (
    SELECT (aclexplode(c.relacl)).grantee::regrole::text AS g,
           (aclexplode(c.relacl)).privilege_type AS p
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'profiles') x
   WHERE g IN ('authenticated','anon') AND p = 'UPDATE';
  IF _n > 0 THEN
    RAISE EXCEPTION 'profiles má pořád TABULKOVÝ UPDATE grant — sloupcový výčet je tím k ničemu a stav jde přepsat.';
  END IF;

  -- A `stav` nesmí být mezi sloupci, které smí klient zapsat.
  IF EXISTS (SELECT 1 FROM information_schema.column_privileges
              WHERE table_schema='public' AND table_name='profiles'
                AND column_name='stav' AND privilege_type='UPDATE'
                AND grantee IN ('authenticated','anon')) THEN
    RAISE EXCEPTION 'profiles.stav je pro klienta zapisovatelný — účet se schválí sám.';
  END IF;

  -- Formulář profilu musí dál fungovat.
  FOREACH _n IN ARRAY ARRAY[1] LOOP NULL; END LOOP;
  IF (SELECT count(*) FROM information_schema.column_privileges
       WHERE table_schema='public' AND table_name='profiles' AND grantee='authenticated'
         AND privilege_type='UPDATE' AND column_name IN ('full_name','phone','bank_account')) <> 3 THEN
    RAISE EXCEPTION 'Formulář profilu přišel o zápis — jméno, telefon a účet musí jít uložit.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname='public' AND tablename IN ('user_roles','settings')
                AND cmd='SELECT' AND qual = 'true') THEN
    RAISE EXCEPTION 'user_roles nebo settings má pořád SELECT USING (true).';
  END IF;

  RAISE NOTICE 'Účet se sám neschválí; role i nastavení vidí až vpuštěný účet.';
END $kontrola$;
