-- =============================================================================
-- Čekající účet nesmí vidět nic — brána `ucet_aktivni()` i nad pohledy
-- Nález z KROKU 0 (31. 8. 2026), MĚŘENO NA OSTRÝCH DATECH
-- =============================================================================
-- CO SE ZJISTILO:
--
-- Blok C zavřel čekajícímu účtu `has_role`, `is_subject_member` a
-- `is_subject_rep`, takže mu RLS nepustí rezervace, subjekty, ceník, směny ani
-- peníze. NEZAVŘEL ale tři místa, která se RLS neptají:
--
--   • `events` a `profiles` mají SELECT politiku `USING (true)`,
--   • `reservations_calendar`, `profiles_public`, `profiles_self`
--     a `settings_public` jsou pohledy se `security_invoker = off`,
--     tedy běží pod vlastníkem a RLS podkladových tabulek je míjí.
--
-- Změřeno dotazem pod `SET LOCAL ROLE authenticated` s tokenem účtu, který
-- v databázi ani nemá profil (transakce se vrátila zpět):
--
--     reservations_calendar   80 řádků   ← jména klubů i firem, názvy akcí, časy
--     events                  42 řádků
--     profiles / _public / _self  3 řádky ← jména všech lidí v systému
--     settings_public          1 řádek
--     reservations, subjects, cenik_pasma, shifts, reservations_billing … 0
--
-- Peníze tedy neunikaly (částky jsou maskované, ceník i „Kdo dluží" vracely
-- nulu řádků), ale ROZVRH HALY VČETNĚ JMEN ZÁKAZNÍKŮ ano.
--
-- -----------------------------------------------------------------------------
-- PROČ TEĎ, A NE „AŽ BUDE ČAS"
-- -----------------------------------------------------------------------------
-- Dokud Auth vyžaduje potvrzení e-mailu, musí útočník aspoň ovládat schránku.
-- Jakmile se potvrzování vypne (a to se chystá, protože projekt nemá SMTP),
-- znamená „kdokoli přihlášený" doslova KDOKOLI: vyplní registrační formulář
-- s vymyšleným e-mailem a v ten okamžik čte celý rozvrh haly i jména členů.
--
-- Tahle migrace proto musí být na produkci DŘÍV, než se potvrzování vypne.
--
-- -----------------------------------------------------------------------------
-- CO SE NEMĚNÍ
-- -----------------------------------------------------------------------------
-- `clubs_public` zůstává čitelný i nepřihlášeným — bez něj by si člověk
-- v registraci nevybral klub. Vydává jen id a název, nic víc.
--
-- Rozhodnutí klienta z 31. 7. („obsazenost a název klubu vidí všichni
-- přihlášení") zůstává v platnosti pro všechny SCHVÁLENÉ účty. Mění se jen
-- výklad slova „přihlášený": vpuštěný dovnitř, ne kdokoli po registraci.
--
-- ⚠️ VLASTNÍ PROFIL VIDÍ I ČEKAJÍCÍ ÚČET. Bez toho by `AuthContext` nezjistil
-- `stav` a čekající člověk by místo věty „Čeká se na potvrzení" dostal
-- „Profil se nepodařilo načíst" (fail-closed větev z 20260831233000). Proto
-- `user_id = auth.uid() OR ucet_aktivni()`, ne holá brána.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- politiky zpátky na USING (true):
--   --   events   → "Anyone authenticated can read events"
--   --   profiles → "Anyone authenticated can read profiles"
--   -- pohledy zpátky ze ŽIVÉHO schématu (pg_get_viewdef) bez koncové brány.
--   -- Data se nemění, migrace sahá jen na viditelnost.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Tabulkové politiky
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anyone authenticated can read events" ON public.events;
CREATE POLICY "Anyone authenticated can read events" ON public.events
  FOR SELECT TO authenticated
  USING (public.ucet_aktivni());

DROP POLICY IF EXISTS "Anyone authenticated can read profiles" ON public.profiles;
CREATE POLICY "Anyone authenticated can read profiles" ON public.profiles
  FOR SELECT TO authenticated
  -- Vlastní řádek vždycky (kvůli čekací obrazovce), cizí až po schválení.
  USING (user_id = auth.uid() OR public.ucet_aktivni());

-- -----------------------------------------------------------------------------
-- 2) Pohledy, které běží pod vlastníkem
--
-- Znění z `pg_get_viewdef` živého schématu (pravidlo 7); zásah je v každém
-- jediná přidaná koncová podmínka. `CREATE OR REPLACE VIEW` nepustí jiné
-- pořadí ani typy sloupců, takže sloupce zůstávají do písmene stejné.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.profiles_self AS
 SELECT id,
    user_id,
    full_name,
        CASE
            WHEN user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN phone
            ELSE NULL::text
        END AS phone,
        CASE
            WHEN user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN bank_account
            ELSE NULL::text
        END AS bank_account,
    created_at,
    updated_at,
    COALESCE(user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role), false) AS smim_videt_udaje,
    stav
   FROM profiles p
  -- BRÁNA ČEKAJÍCÍHO ÚČTU: vlastní řádek vidí každý (bez něj by přihlášení
  -- nepoznalo, že se čeká na schválení, a místo věty „Čeká se na potvrzení"
  -- by naskočilo „Profil se nepodařilo načíst"). Cizí profily až po schválení.
  WHERE p.user_id = auth.uid() OR public.ucet_aktivni();

CREATE OR REPLACE VIEW public.profiles_public AS
 SELECT id,
    user_id,
    full_name,
        CASE
            WHEN user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN phone
            ELSE NULL::text
        END AS phone,
        CASE
            WHEN user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN bank_account
            ELSE NULL::text
        END AS bank_account,
    created_at,
    updated_at
   FROM profiles p
  -- BRÁNA ČEKAJÍCÍHO ÚČTU: vlastní řádek vidí každý (bez něj by přihlášení
  -- nepoznalo, že se čeká na schválení, a místo věty „Čeká se na potvrzení"
  -- by naskočilo „Profil se nepodařilo načíst"). Cizí profily až po schválení.
  WHERE p.user_id = auth.uid() OR public.ucet_aktivni();

CREATE OR REPLACE VIEW public.settings_public AS
 SELECT id,
    singleton,
    opening_hours,
    email_notifications_enabled,
    updated_at,
    updated_by,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN club_default_rate
            ELSE NULL::numeric
        END AS club_default_rate,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN commercial_default_rate
            ELSE NULL::numeric
        END AS commercial_default_rate,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN training_rate
            ELSE NULL::numeric
        END AS training_rate,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN tournament_rate
            ELSE NULL::numeric
        END AS tournament_rate,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role), false) AS can_see_rates
   FROM settings s
  -- Otevírací dobu potřebuje kalendář, a ten čekající účet nevidí.
  --
  -- VÝJIMKA PRO BĚH POD DATABÁZOVOU ROLÍ (pg_cron, Edge funkce sahající na
  -- pohled): tam žádný `auth.uid()` není a bez téhle větve by pohled vracel
  -- NULA ŘÁDKŮ místo řádku s maskovanými sazbami. Ověřeno: bez ní padá
  -- `cenik_viditelnost_test.sql` na tvrzení „bez přihlášení: sazby nejsou vidět".
  --
  -- Podmínka schválně NESTOJÍ jen na `auth.uid() IS NULL` — to by z chybějícího
  -- `sub` v tokenu udělalo klíč k otevírací době. Je to týž vzorec, jaký má
  -- `billing_reconcile` a guard v `booking_core`.
  WHERE public.ucet_aktivni()
     OR (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'));

CREATE OR REPLACE VIEW public.reservations_calendar AS
 SELECT r.id,
    r.sheet_id,
    r.subject_id,
    r.event_id,
    r.series_id,
    r.start_at,
    r.end_at,
    r.status,
    s.name AS subject_name,
    s.type AS subject_type,
    e.title AS event_title,
    COALESCE(e.event_type,
        CASE
            WHEN s.type = 'commercial'::subject_type THEN 'commercial'::event_type
            ELSE 'training'::event_type
        END) AS event_type,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND s2.deleted_at IS NULL)) THEN r.note
            ELSE NULL::text
        END AS note,
    r.approved_at,
    r.created_by,
    cp.full_name AS created_by_name,
    r.created_at,
    r.cancelled_at,
    r.cancelled_by,
    xp.full_name AS cancelled_by_name,
    r.cancel_reason,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.hours
            ELSE NULL::numeric
        END AS hours,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.rate_per_hour
            ELSE NULL::numeric
        END AS rate_per_hour,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.amount
            ELSE NULL::numeric
        END AS amount,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.corrected_hours
            ELSE NULL::numeric
        END AS corrected_hours,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.corrected_amount
            ELSE NULL::numeric
        END AS corrected_amount,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid(), false) AS can_see_amount,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() AND (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND s2.deleted_at IS NULL)), false) AS can_manage,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)), false) AS can_approve,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() THEN r.preferovany_trener
            ELSE NULL::uuid
        END AS preferovany_trener,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() THEN tp.full_name
            ELSE NULL::text
        END AS preferovany_trener_jmeno
   FROM reservations r
     LEFT JOIN subjects s ON s.id = r.subject_id
     LEFT JOIN events e ON e.id = r.event_id
     LEFT JOIN profiles cp ON cp.user_id = r.created_by
     LEFT JOIN profiles xp ON xp.user_id = r.cancelled_by
     LEFT JOIN profiles tp ON tp.user_id = r.preferovany_trener
  WHERE r.deleted_at IS NULL
    -- BRÁNA ČEKAJÍCÍHO ÚČTU. Pohled běží pod vlastníkem (`security_invoker = off`)
    -- a má GRANT pro `authenticated`, takže RLS na `reservations` se ho netýká —
    -- do dneška si tedy KAŽDÝ přihlášený účet vyjel celý rozvrh haly i se jmény
    -- klubů a firem, včetně účtu, který teprve čeká na schválení.
    --
    -- Rozhodnutí klienta z 31. 7. („obsazenost a název klubu vidí všichni
    -- přihlášení") tím není dotčené: „přihlášený" znamená vpuštěný dovnitř,
    -- ne kdokoli, kdo prošel registračním formulářem.
    AND public.ucet_aktivni();

-- -----------------------------------------------------------------------------
-- 3) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _v text; _chybi text[] := '{}';
BEGIN
  FOREACH _v IN ARRAY ARRAY['profiles_self','profiles_public','settings_public','reservations_calendar'] LOOP
    IF pg_get_viewdef(('public.'||_v)::regclass) NOT LIKE '%ucet_aktivni%' THEN
      _chybi := _chybi || _v;
    END IF;
  END LOOP;
  IF cardinality(_chybi) > 0 THEN
    RAISE EXCEPTION 'Brána čekajícího účtu chybí v pohledech: %', array_to_string(_chybi, ', ');
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname='public' AND tablename IN ('events','profiles')
                AND cmd='SELECT' AND qual = 'true') THEN
    RAISE EXCEPTION 'Některá SELECT politika na events/profiles je pořád USING (true).';
  END IF;

  -- `clubs_public` musí zůstat otevřený i anonymům, jinak si nikdo nevybere
  -- klub v registraci — a registrace je jediná cesta dovnitř.
  IF NOT has_table_privilege('anon', 'public.clubs_public', 'SELECT') THEN
    RAISE EXCEPTION 'clubs_public přestal být čitelný pro anon — registrace by nešla dokončit.';
  END IF;

  RAISE NOTICE 'Čekající účet vidí jen svůj profil a seznam klubů.';
END $kontrola$;
