-- =============================================================================
-- Deaktivovaný účet nesmí mít práva — 17 politik obcházelo has_role()
-- Audit 1. 9. 2026, měřeno na lokální DB na HEADu reálným tokenem přes PostgREST
-- =============================================================================
-- NÁLEZ 1 (KRITICKÝ): DEAKTIVOVANÝ ADMIN SI VRÁTIL ADMINA.
--
-- `public.has_role()` schválně přidává `AND public.ucet_aktivni()` — role sama
-- nestačí, účet musí být otevřený (R6). Jenže 17 politik `has_role()` vůbec
-- nevolá; mají v sobě vepsané
--     EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
-- což čte roli přímo a na `profiles.stav` se nepodívá. Účet, kterému správce
-- haly vypnul `stav`, tedy tyhle politiky pořád projde.
--
-- Změřeno na účtu se `stav = 'deaktivovan'` a ponechanou rolí `admin`
-- (has_role = false, ucet_aktivni = false), jeho vlastním platným JWT:
--
--     POST /rest/v1/user_roles          Prefer: return=minimal
--     {"user_id":"<běžný AKTIVNÍ člen>","role":"admin"}      → HTTP 201
--     SELECT has_role('<ten člen>','admin');                 → true
--
-- Z běžného člena je rázem plnohodnotný správce: billing_settings 1 řádek,
-- audit_log 102 řádků, reservations_billing 35 řádků (peníze všech klubů).
-- Vyhozený správce si takhle přes nastrčený účet otevře systém zpátky.
--
-- ⚠️ PROČ TO NEBYLO VIDĚT DŘÍV: přes PostgREST to projde jen INSERTEM.
--   • `Prefer: return=representation` přidá RETURNING, tím se do hry dostane
--     SELECT politika a přijde 403. `return=minimal` RETURNING nemá a projde.
--   • Filtrovaný PATCH/DELETE spadne taky na SELECT politiku (WHERE čte
--     sloupce), nefiltrovaný PostgREST sám odmítne („UPDATE requires a WHERE
--     clause"). Proto u `events`/`user_roles`/`shifts` tekl jen INSERT.
--   • U `chat_groups` teče i FILTROVANÝ UPDATE, protože jeho SELECT politika
--     (NÁLEZ 2) řádek zavřenému účtu ukáže. Změřeno:
--     PATCH /rest/v1/chat_groups?id=eq.<id> {"whatsapp_url":"https://evil…"}
--       → HTTP 204, řádek přepsán.
--
-- NÁLEZ 2: `chat_groups` vidí i NESCHVÁLENÝ účet. Obě SELECT politiky mají
-- větev `authorized_roles = '{}'`, která je pravdivá pro KOHOKOLI, a nikde
-- v nich není `ucet_aktivni()`. Čerstvě registrovaný (nikdy neschválený),
-- zamítnutý i deaktivovaný účet si tak přes REST vytáhne skupinu i s
-- `whatsapp_url` — tedy pozvánku do klubového chatu.
--
-- NÁLEZ 3: `sheets_select` byl `USING (true)` — poslední `USING (true)`
-- ve schématu `public`. Neschválený účet tím dostal seznam drah i s jejich
-- UUID, což jsou přesně ty argumenty, které berou rezervační RPC.
--
-- NÁLEZ 4: `get_user_role()` je SECURITY DEFINER s EXECUTE pro `authenticated`
-- a BEZ jakékoli kontroly volajícího — z libovolného UUID udělá roli. Čekající
-- účet si tím vyjede, kdo je admin. `user_roles` se přitom neschváleným účtům
-- zavřel 1. 9. (20260901090000) právě proto, aby UUID adminů neunikala.
--
-- -----------------------------------------------------------------------------
-- CO SE VĚDOMĚ NEMĚNÍ
-- -----------------------------------------------------------------------------
-- 1) AKTIVNÍMU uživateli se nemění vůbec nic. Tahle migrace jen dolepuje
--    `ucet_aktivni()` tam, kde chyběl; množiny rolí, větve ani `WITH CHECK`
--    zůstávají znak po znaku stejné. Je to bezpečnostní záplata, ne úklid.
--
-- 2) `shifts` má DVĚ překrývající se UPDATE politiky — „Staff and admins can
--    update shifts" (volný WITH CHECK) a „Staff can update shifts" (přísný,
--    hlídá `claimed_by`). Permisivní politiky se OR-ují, takže ta volná tu
--    přísnou dnes stejně přebíjí. NECHÁVÁM TO BÝT: zrušení té volné by
--    brigádníkovi zúžilo práva na samotné přebírání směn, což je změna
--    chování pro aktivní uživatele a patří do vlastního ticketu, ne do
--    bezpečnostní opravy nasazované v den předání.
--
-- 3) Stejnou úvahou tu NENÍ plošný `REVOKE` zbylých `anon` grantů z dob
--    Lovable (`events`, `sheets`, `shifts`, `shift_applications`, `payouts`,
--    `profiles`, `user_roles`). Dnes jsou neúčinné (pro `anon` neplatí žádná
--    politika) a je to samostatný hygienický ticket. Výjimka je `chat_groups`
--    níž — ten s NÁLEZEM 2 souvisí přímo.
--
-- -----------------------------------------------------------------------------
-- VRATNOST: politiky zpátky ve znění z 20260715000000_baseline_production.sql
--   (řádky 471-478 user_roles, 483-492 events, 497-507 payouts,
--    512-536 shifts, 555-580 chat_groups), sheets z 20260716140000:61,
--   a  GRANT EXECUTE ON FUNCTION public.get_user_role(uuid) TO authenticated;
--   Pozor: tím se všechny čtyři nálezy vrátí.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) NÁLEZ 1 — role se všude ptá přes has_role(), tedy i na stav účtu
--
-- Všude níž platí totéž: `EXISTS (… user_roles …)` → `has_role(…)`. Množina
-- rolí i struktura výrazu se zachovává; přibývá jen kontrola stavu účtu,
-- kterou `has_role()` nese v sobě.
-- -----------------------------------------------------------------------------

-- ---- user_roles (bez tohohle si zavřený admin udělí roli zpátky) ----
DROP POLICY IF EXISTS "Only admins can insert roles" ON public.user_roles;
CREATE POLICY "Only admins can insert roles" ON public.user_roles
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can update roles" ON public.user_roles;
CREATE POLICY "Only admins can update roles" ON public.user_roles
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can delete roles" ON public.user_roles;
CREATE POLICY "Only admins can delete roles" ON public.user_roles
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- ---- events ----
DROP POLICY IF EXISTS "Only admins can create events" ON public.events;
CREATE POLICY "Only admins can create events" ON public.events
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can update events" ON public.events;
CREATE POLICY "Only admins can update events" ON public.events
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can delete events" ON public.events;
CREATE POLICY "Only admins can delete events" ON public.events
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- ---- payouts (výplaty brigádníků — peníze) ----
-- Vlastní řádek zůstává čitelný i zavřenému účtu, stejně jako u `profiles`
-- a `user_roles`: ať člověk vidí, co mu hala dluží, i když mu účet uzavřela.
DROP POLICY IF EXISTS "Users can view own payouts and admins all" ON public.payouts;
CREATE POLICY "Users can view own payouts and admins all" ON public.payouts
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can create payouts" ON public.payouts;
CREATE POLICY "Only admins can create payouts" ON public.payouts
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can update payouts" ON public.payouts;
CREATE POLICY "Only admins can update payouts" ON public.payouts
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can delete payouts" ON public.payouts;
CREATE POLICY "Only admins can delete payouts" ON public.payouts
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- ---- shifts ----
DROP POLICY IF EXISTS "Only admins can create shifts" ON public.shifts;
CREATE POLICY "Only admins can create shifts" ON public.shifts
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can delete shifts" ON public.shifts;
CREATE POLICY "Only admins can delete shifts" ON public.shifts
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- Množina rolí (admin + part_time_staff) i volný WITH CHECK zůstávají — viz
-- „CO SE VĚDOMĚ NEMĚNÍ" bod 2. Mění se jen to, že zavřený účet sem nevleze.
DROP POLICY IF EXISTS "Staff and admins can update shifts" ON public.shifts;
CREATE POLICY "Staff and admins can update shifts" ON public.shifts
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin')
      OR public.has_role(auth.uid(), 'part_time_staff'))
  WITH CHECK (public.has_role(auth.uid(), 'admin')
           OR public.has_role(auth.uid(), 'part_time_staff'));

-- ---- chat_groups ----
DROP POLICY IF EXISTS "Only admins can create chat groups" ON public.chat_groups;
CREATE POLICY "Only admins can create chat groups" ON public.chat_groups
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can update chat groups" ON public.chat_groups;
CREATE POLICY "Only admins can update chat groups" ON public.chat_groups
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Only admins can delete chat groups" ON public.chat_groups;
CREATE POLICY "Only admins can delete chat groups" ON public.chat_groups
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- 2) NÁLEZ 2 — do klubového chatu vidí až vpuštěný účet
--
-- Obě politiky dostávají `ucet_aktivni()` jako PRVNÍ konjunkt, takže větev
-- `authorized_roles = '{}'` (pravdivá pro kohokoli) už sama o sobě nic
-- neotevře. Vnitřek se jinak nemění — aktivní uživatel uvidí přesně to co dřív.
--
-- A obě se zužují `TO authenticated`. „Users can view authorized groups" byla
-- `TO public`, tedy platila i pro `anon`; ten dnes narazí až na chybějící grant
-- na `user_roles` uvnitř poddotazu, což je náhoda, ne brána — anonym dostával
-- „permission denied for table user_roles" místo prázdna. S `TO authenticated`
-- pro něj neplatí žádná politika a dostane čistou prázdnou odpověď.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view authorized groups" ON public.chat_groups;
CREATE POLICY "Users can view authorized groups" ON public.chat_groups
  FOR SELECT TO authenticated
  USING (
    public.ucet_aktivni()
    AND (
      public.has_role(auth.uid(), 'admin')
      OR authorized_roles = '{}'::app_role[]
      OR EXISTS (SELECT 1 FROM public.user_roles ur
                  WHERE ur.user_id = auth.uid()
                    AND ur.role = ANY (chat_groups.authorized_roles))
      OR auth.uid() = ANY (visible_to_user_ids)
    )
  );

DROP POLICY IF EXISTS "Users see groups matching their highest role" ON public.chat_groups;
CREATE POLICY "Users see groups matching their highest role" ON public.chat_groups
  FOR SELECT TO authenticated
  USING (
    public.ucet_aktivni()
    AND (
      public.has_role(auth.uid(), 'admin')
      OR authorized_roles = '{}'::app_role[]
      OR (SELECT ur.role FROM public.user_roles ur
           WHERE ur.user_id = auth.uid()
           ORDER BY CASE ur.role
                      WHEN 'admin'           THEN 1
                      WHEN 'trainer'         THEN 2
                      WHEN 'part_time_staff' THEN 3
                      WHEN 'pro_player'      THEN 4
                      WHEN 'hobby_player'    THEN 5
                      ELSE NULL::integer
                    END
           LIMIT 1) = ANY (authorized_roles)
    )
  );

-- `anon` na chat skupinách nikdy nic pohledávat neměl. Granty z doby Lovable
-- (výchozí práva Supabase na nové tabulky) tam ale pořád visely — a grant,
-- který dnes nic nedělá, je jen čekání na politiku, která ho pustí.
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.chat_groups FROM anon;

-- -----------------------------------------------------------------------------
-- 3) NÁLEZ 3 — dráhy vidí až vpuštěný účet
--
-- Poslední `USING (true)` ve schématu. Aktivní uživatel dráhy vidí dál
-- (kalendář je bez nich k ničemu), neschválený už ne.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "sheets_select" ON public.sheets;
CREATE POLICY "sheets_select" ON public.sheets
  FOR SELECT TO authenticated
  USING (public.ucet_aktivni());

-- -----------------------------------------------------------------------------
-- 4) NÁLEZ 4 — get_user_role() přestává být veřejná
--
-- Funkci NERUŠÍM, jen jí beru EXECUTE klientským rolím: v `src/` ji nevolá
-- nikdo (je jen ve vygenerovaných `types.ts`), nevolá ji žádná jiná funkce
-- ani politika — ověřeno dotazem nad `pg_proc` a `pg_policies`. Odebrání
-- práva je proto bez dopadu na aplikaci a vratnější než měnit její chování.
--
-- ⚠️ `FROM PUBLIC` TU MUSÍ BÝT. Funkce v Postgresu mají EXECUTE pro PUBLIC
-- ve výchozím stavu, takže `get_user_role` má v ACL i `=X/postgres`:
--     {=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,…}
-- Samotné `REVOKE … FROM anon, authenticated` proto NEUDĚLÁ NIC — přes PUBLIC
-- se k funkci dostane pořád každý. (Odhalila to až kontrola dole; první znění
-- téhle migrace revoke bez PUBLIC mělo a tvářilo se, že je hotovo.)
-- Táž past jako u tabulkových vs. sloupcových grantů v 20260901090000.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_user_role(uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5) Kontrola — ať se to nedá tiše vrátit
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _n int; _t text;
BEGIN
  -- Žádná politika v `public` už nesmí číst `user_roles` napřímo bez
  -- `has_role()` / `ucet_aktivni()`. Tohle je jádro NÁLEZU 1.
  SELECT count(*), coalesce(string_agg(tablename||'.'||policyname, ', '), '')
    INTO _n, _t
    FROM pg_policies
   WHERE schemaname = 'public'
     AND (coalesce(qual,'')||' '||coalesce(with_check,'')) LIKE '%FROM user_roles%'
     AND (coalesce(qual,'')||' '||coalesce(with_check,'')) NOT LIKE '%has_role%'
     AND (coalesce(qual,'')||' '||coalesce(with_check,'')) NOT LIKE '%ucet_aktivni%';
  IF _n > 0 THEN
    RAISE EXCEPTION 'Politiky pořád čtou user_roles mimo has_role(): %', _t;
  END IF;

  -- `has_role()` musí dál nést kontrolu stavu účtu — na tom celá oprava stojí.
  IF pg_get_functiondef('public.has_role(uuid, app_role)'::regprocedure)
       NOT LIKE '%ucet_aktivni%' THEN
    RAISE EXCEPTION 'has_role() přestala kontrolovat ucet_aktivni() — oprava je tím k ničemu.';
  END IF;

  -- Ve schématu nesmí zůstat SELECT USING (true).
  SELECT count(*), coalesce(string_agg(tablename||'.'||policyname, ', '), '')
    INTO _n, _t
    FROM pg_policies
   WHERE schemaname = 'public' AND cmd = 'SELECT' AND qual = 'true';
  IF _n > 0 THEN
    RAISE EXCEPTION 'Zůstalo SELECT USING (true): %', _t;
  END IF;

  -- Obě SELECT politiky chatu musí mít bránu na stav účtu.
  SELECT count(*) INTO _n
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'chat_groups' AND cmd = 'SELECT'
     AND coalesce(qual,'') LIKE '%ucet_aktivni%';
  IF _n <> 2 THEN
    RAISE EXCEPTION 'chat_groups: očekávám 2 SELECT politiky s ucet_aktivni(), mám %.', _n;
  END IF;

  -- get_user_role už nesmí být volatelná klientem.
  IF has_function_privilege('authenticated', 'public.get_user_role(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.get_user_role(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'get_user_role() je pořád volatelná klientem — role adminů jdou vyjet.';
  END IF;

  -- A admin musí dál fungovat: politiky pro klíčové tabulky nesmí zmizet.
  SELECT count(*) INTO _n
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('user_roles','events','payouts','shifts','chat_groups');
  -- 22 je NAMĚŘENÁ hodnota (produkce i lokál, 1. 9. 2026), ne odhad. Původní
  -- práh 17 byl volný o pět politik — mohlo jich tolik zmizet a kontrola by
  -- to odkývala. Přibude-li politika záměrně, číslo se tu zvedne vědomě.
  IF _n <> 22 THEN
    RAISE EXCEPTION 'Na klíčových tabulkách je % politik místo 22 — něco se ztratilo nebo přibylo.', _n;
  END IF;

  RAISE NOTICE 'Deaktivovaný účet nemá práva; chat i dráhy vidí až vpuštěný účet.';
END $kontrola$;
