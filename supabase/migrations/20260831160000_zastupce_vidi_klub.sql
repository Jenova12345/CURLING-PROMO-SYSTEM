-- =============================================================================
-- Zástupce klubu vidí členy svého klubu
-- Blok A z docs/ETAPA3-ROLE-DALSI.md · navazuje na blok C (R5)
-- =============================================================================
-- CO JE ŠPATNĚ DNES:
--
-- Politika `subject_reps_select` je z Etapy 1 (`20260716140000_etapa1_rls.sql:49`)
-- a od té doby se nezměnila:
--
--   USING (has_role(auth.uid(), 'admin') OR user_id = auth.uid())
--
-- Zástupce klubu si tedy přečte JEN SVŮJ VLASTNÍ ŘÁDEK. Změřeno na seedu:
-- `clen@test.local` je zástupcem CK Ostravské kameny a v `subject_reps` vidí
-- 1 řádek — sebe.
--
-- Blok C mu přitom dal právo schvalovat žádosti do svého klubu a udělovat
-- „právo navíc" (`nastav_pravo_navic`). Obojí jsou SECURITY DEFINER funkce,
-- takže fungují — ale UI, které by mu ukázalo, KOMU to uděluje, nemá z čeho
-- postavit seznam. Bez téhle migrace je blok B (UI práva navíc) neproveditelný.
--
-- -----------------------------------------------------------------------------
-- ROZŠIŘUJE SE JEN ČTENÍ, ZÁPIS ZŮSTÁVÁ ADMINOVI
-- -----------------------------------------------------------------------------
-- `subject_reps_insert_admin` / `_update_admin` / `_delete_admin` se NEMĚNÍ.
-- Rozhodnutí PM (P3, 31. 8. 2026): odebírání členů zůstává adminovi, dokud se
-- nedořeší politika odchodu z klubu (co s rolí, s historií směn a s výplatami).
-- Bod A je proto READ-ONLY.
--
-- Cokoli, co má zástupce smět měnit, jde přes SECURITY DEFINER RPC s vlastní
-- kontrolou — tak to dělá `nastav_pravo_navic` z bloku C. Tabulka zůstává
-- zavřená a výjimky jsou vyjmenované a auditovatelné.
--
-- -----------------------------------------------------------------------------
-- PROČ TO NENÍ NEKONEČNÁ REKURZE
-- -----------------------------------------------------------------------------
-- Politika NA `subject_reps` volá `is_subject_rep()`, která ze `subject_reps`
-- ČTE. To by rekurze být mohla — není, protože `is_subject_rep` je SECURITY
-- DEFINER a běží pod vlastníkem, pro kterého se politiky neuplatňují.
-- Ověřeno testem, ne úvahou: `zastupce_klub_test.sql` dělá pod rolí
-- `authenticated` přesně ten dotaz, který by rekurzi spustil.
--
-- -----------------------------------------------------------------------------
-- CO ZÁSTUPCE UVIDÍ NAVÍC
-- -----------------------------------------------------------------------------
-- Řádky `subject_reps` svého klubu, tedy: kdo je člen, kdo zástupce a kdo má
-- „právo navíc". Jména k tomu dodá `profiles_public`, kam `authenticated`
-- SELECT má už dnes (telefon a číslo účtu z něj vidí jen vlastník a admin —
-- to se nemění).
--
-- Je to v souladu s rozhodnutím klienta z 31. 7.: zástupce rezervuje za celý
-- klub a potvrzuje rezervace jeho členů, takže vědět, kdo do klubu patří, je
-- přesně jeho role.
--
-- `is_subject_rep` má od bloku C v sobě bránu `ucet_aktivni()`, takže
-- deaktivovaný zástupce touhle cestou neprojde. To je zadarmo.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   DROP POLICY IF EXISTS subject_reps_select ON public.subject_reps;
--   CREATE POLICY subject_reps_select ON public.subject_reps
--     FOR SELECT TO authenticated
--     USING (has_role(auth.uid(), 'admin') OR user_id = auth.uid());
-- Nic se nemaže, žádná data se nemění — jen se zužuje viditelnost zpátky.
-- =============================================================================

DROP POLICY IF EXISTS subject_reps_select ON public.subject_reps;
CREATE POLICY subject_reps_select ON public.subject_reps
  FOR SELECT TO authenticated
  USING (
    has_role(auth.uid(), 'admin')
    OR user_id = auth.uid()
    -- Zástupce vidí celý svůj klub (R5). Zápis tím nezískává — na to jsou
    -- samostatné politiky, které zůstávají admin-only.
    OR public.is_subject_rep(subject_id)
  );

COMMENT ON POLICY subject_reps_select ON public.subject_reps IS
  'Členství vidí: admin všechno, každý svůj vlastní řádek, a zástupce celý svůj klub (blok A). Zápis zůstává adminovi — zástupce mění jen `muze_potvrzovat`, a to přes nastav_pravo_navic().';

-- -----------------------------------------------------------------------------
-- Kontrola
-- -----------------------------------------------------------------------------
DO $$
DECLARE _qual text;
BEGIN
  SELECT pg_get_expr(polqual, polrelid) INTO _qual
    FROM pg_policy
   WHERE polrelid = 'public.subject_reps'::regclass AND polname = 'subject_reps_select';

  IF _qual IS NULL THEN
    RAISE EXCEPTION 'Politika subject_reps_select zmizela.';
  END IF;
  IF _qual NOT LIKE '%is_subject_rep%' THEN
    RAISE EXCEPTION 'Politika neobsahuje větev pro zástupce — blok B by neměl co zobrazit.';
  END IF;

  -- Zápisové politiky se nesměly hnout.
  IF (SELECT count(*) FROM pg_policy
       WHERE polrelid = 'public.subject_reps'::regclass
         AND polname IN ('subject_reps_insert_admin','subject_reps_update_admin','subject_reps_delete_admin')) <> 3 THEN
    RAISE EXCEPTION 'Některá zápisová politika na subject_reps chybí — zápis musí zůstat adminovi.';
  END IF;

  RAISE NOTICE 'Zástupce vidí členy svého klubu; zápis zůstal adminovi.';
END $$;
