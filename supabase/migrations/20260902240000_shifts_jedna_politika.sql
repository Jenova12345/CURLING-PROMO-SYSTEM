-- =============================================================================
-- Hygiena z review: dvě překrývající se UPDATE politiky na `shifts`
--                   + doplnění chybějících rolí do řazení `chat_groups`
-- =============================================================================
-- KROK 0 (2. 9. 2026) — co na produkci opravdu bylo:
--
--   A) „Staff and admins can update shifts"  (TO authenticated)
--        USING: admin OR part_time_staff
--        CHECK: admin OR part_time_staff        ← ŽÁDNÉ omezení, CO se smí zapsat
--
--   B) „Staff can update shifts"              (TO public)
--        USING: admin OR part_time_staff OR instructor OR bar_staff OR manager
--        CHECK: admin OR (štáb AND (vlastní pending | vlastní completed | volná))
--
-- Permisivní politiky se OR-ují, takže **A úplně rušila pečlivý CHECK z B** —
-- ale jen pro `part_time_staff`. Instruktor, barman a manažer omezení byli,
-- brigádník ne. Vzniklo to tak, že B přibylo později vedle A, místo aby ji
-- nahradilo.
--
-- ZMĚŘENO REÁLNÝM TOKENEM (SET LOCAL ROLE authenticated, brigádník), NE ODHADEM.
-- Před touhle migrací part_time_staff SMĚL:
--   b) přiřadit se rovnou na `claimed` a obejít schválení adminem,
--   c) vlastní směnu si proplatit — `completed`, 24 h × 10 000 Kč,
--   d) přepsat hodinovou sazbu na CIZÍ směně.
--
-- c) není teoretické: `status='completed'` s `payout_id IS NULL` je přímo řádek
-- „k výplatě" v adminově přehledu (`useShifts.ts`, `unpaidTotal`). Trigger
-- `validate_shift_claim` hlídá přechody `pending→claimed` a `claimed→completed`
-- (oba jen admin), ale `pending→completed` nemá větev — a tudy to prošlo.
--
-- CO TAHLE MIGRACE DĚLÁ: skládá obě politiky do JEDNÉ a bere to přísnější
-- z obou. Žádné právo nepřibývá.
--
-- Oproti B navíc mizí větev `completed AND claimed_by = já`. Není to rozšíření
-- zadání do peněz jen tak: právě ta větev drží díru c) otevřenou a k ničemu
-- jinému neslouží — dokončení směny je podle triggeru i podle UI výhradně
-- adminská věc (`completeShift` je v `useShifts.ts` označené „Admin completes
-- shift" a samo sazbu při dokončení přepisuje). Štábu tedy nic legitimního
-- neubírá.
--
-- Co štábu ZŮSTÁVÁ: přihlásit se na volnou směnu (`open → pending`, na sebe),
-- odhlásit se a vrátit ji (`→ open`, `claimed_by = NULL`). To jsou obě cesty,
-- které samoobsluha v UI používá.
-- =============================================================================

DROP POLICY IF EXISTS "Staff and admins can update shifts" ON public.shifts;
DROP POLICY IF EXISTS "Staff can update shifts"            ON public.shifts;

DROP POLICY IF EXISTS "Staff update own shifts, admins anything" ON public.shifts;
CREATE POLICY "Staff update own shifts, admins anything" ON public.shifts
  FOR UPDATE TO authenticated
  -- USING (které řádky vůbec smím vzít do ruky) zůstává jako v B: štáb musí
  -- vidět i VOLNÉ směny, jinak by se na ně nemohl přihlásit. Co z toho vzejde,
  -- hlídá WITH CHECK níž.
  USING (
    public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'part_time_staff')
    OR public.has_role(auth.uid(), 'instructor')
    OR public.has_role(auth.uid(), 'bar_staff')
    OR public.has_role(auth.uid(), 'manager')
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'admin')
    OR (
      (   public.has_role(auth.uid(), 'part_time_staff')
       OR public.has_role(auth.uid(), 'instructor')
       OR public.has_role(auth.uid(), 'bar_staff')
       OR public.has_role(auth.uid(), 'manager'))
      AND (
        -- přihlásit se na směnu: výsledkem je MOJE čekající přihláška
        (status = 'pending' AND claimed_by = auth.uid())
        -- odhlásit se / vrátit směnu: výsledkem je zase volná směna
        OR (status = 'open' AND claimed_by IS NULL)
      )
    )
  );

-- `anon` na směnách nikdy nic pohledávat neměl; RLS ho sice nikam nepustí
-- (bez `auth.uid()` je každé `has_role` false), ale grant, který dnes nic
-- nedělá, je jen čekání na politiku, která ho pustí. Stejný úklid, jaký
-- dostaly `chat_groups` v 20260901120000.
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.shifts FROM anon;

-- -----------------------------------------------------------------------------
-- chat_groups: doplnit chybějící role do řazení „nejvyšší role"
-- -----------------------------------------------------------------------------
-- `ORDER BY CASE` znal jen admin/trainer/part_time_staff/pro_player/hobby_player
-- a zbytek posílal na `ELSE NULL`. V `ORDER BY ... ASC` jdou NULLy NAKONEC,
-- takže komu patřila i jedna z „známých" rolí, tomu instruktorství, barmanství
-- ani vedení směny nikdy nevyhrálo — třeba instruktor + hobby_player se počítal
-- jako hobby hráč.
--
-- POZNÁMKA K DOPADU, ať se to nepřečte jako víc, než to je: vedle téhle
-- politiky stojí širší „Users can view authorized groups" (stačí JAKÁKOLI moje
-- role) a permisivní politiky se OR-ují — takže dnes tahle chyba nikomu nic
-- neubírá. Je to mina do doby, kdy někdo tu širší politiku odstraní.
-- Práva se tu proto NEMĚNÍ, jen řazení.
--
-- Pořadí: pět původních rolí si drží svoje vzájemné pořadí (admin < trainer <
-- part_time_staff < pro_player < hobby_player), tři nové se řadí podle míry
-- zodpovědnosti — manažer vede směnu, instruktor vede led, barman je štáb
-- vedle brigádníka. `ELSE 999` místo NULL, ať je i neznámá budoucí role
-- seřazená určitě, ne „někde".
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
                      WHEN 'admin'           THEN 10
                      WHEN 'trainer'         THEN 20
                      WHEN 'manager'         THEN 30
                      WHEN 'instructor'      THEN 40
                      WHEN 'part_time_staff' THEN 50
                      WHEN 'bar_staff'       THEN 60
                      WHEN 'pro_player'      THEN 70
                      WHEN 'hobby_player'    THEN 80
                      ELSE 999
                    END
           LIMIT 1) = ANY (authorized_roles)
    )
  );

-- ---- Sebekontrola ----------------------------------------------------------
DO $$
DECLARE _n int; _def text;
BEGIN
  SELECT count(*) INTO _n FROM pg_policies
   WHERE tablename = 'shifts' AND cmd = 'UPDATE';
  IF _n <> 1 THEN
    RAISE EXCEPTION 'Na shifts má zůstat právě JEDNA UPDATE politika, je jich %.', _n;
  END IF;

  -- Kdyby se sem někdy vrátila větev „completed", díra c) je zpátky.
  SELECT with_check INTO _def FROM pg_policies
   WHERE tablename = 'shifts' AND cmd = 'UPDATE';
  IF _def LIKE '%completed%' THEN
    RAISE EXCEPTION 'WITH CHECK pouští zápis do stavu completed — sebeproplacení je zpátky.';
  END IF;

  SELECT qual INTO _def FROM pg_policies
   WHERE tablename = 'chat_groups' AND policyname = 'Users see groups matching their highest role';
  IF _def NOT LIKE '%instructor%' OR _def NOT LIKE '%bar_staff%' OR _def NOT LIKE '%manager%' THEN
    RAISE EXCEPTION 'Řazení chat_groups pořád nezná všechny role.';
  END IF;

  RAISE NOTICE 'shifts: jedna UPDATE politika, ta přísnější. chat_groups: řazení zná všech 8 rolí.';
END $$;
