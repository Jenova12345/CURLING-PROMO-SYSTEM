-- =============================================================================
-- Správce klubu: úprava vlastní rezervace ho neposílá stát frontu
-- Požadavek Jakuba (2. 9. 2026)
-- =============================================================================
-- KROK 0 — CO UŽ EXISTUJE (a co se proto NESTAVÍ znovu):
--
-- Role „správce klubu" je v databázi od Etapy 3 jako `subject_reps.level = 'rep'`
-- (rozhodnutí R2: je to VZTAH KE KLUBU, ne globální role — člověk může být
-- správcem jednoho klubu a řadovým hráčem jiného). Obě schopnosti, které
-- Jakub požaduje, už fungují — ověřeno reálným tokenem, ne čtením kódu:
--
--   • potvrzuje rezervace svého klubu … `approve_reservation` má větev
--     `is_subject_rep(_res.subject_id)`; zástupce potvrdil rezervaci člena
--     svého klubu (`approved: 1`)
--   • vlastní rezervace rovnou schválená … `create_booking` má
--     `IF _is_admin OR p_subject_id IS NULL OR is_subject_rep(p_subject_id)
--      THEN _approved := now()`. Změřeno vedle sebe:
--         zástupce  → rovnou schválená: true
--         profi hráč → rovnou schválená: false
--
-- A zákazy platí taky: peníze 0/0/0/0 (ceník, „Kdo dluží", sazby, faktury),
-- cizí klub 0 řádků, `INSERT` do `user_roles` i `subject_reps` končí na RLS
-- a úroveň `rep` smí udělit jen admin (`approve_subject_request`).
--
-- -----------------------------------------------------------------------------
-- CO TEDY ZBÝVÁ: SOUHRA S TRIGGEREM #5
-- -----------------------------------------------------------------------------
-- Od 20260902110000 shodí každá změna ceny razítko schválení. Na správce klubu
-- to dopadá nesmyslně: jeho rezervace vzniká rovnou schválená, ale jakmile ji
-- přesune, spadne mu do fronty — a on si ji tam vzápětí odklepne sám, protože
-- schvalovat smí. Jedno kliknutí navíc, které nikoho nic nedozví.
--
-- ŘEŠENÍ: kdo smí schvalovat, ten právě schválil. Když úpravu dělá admin nebo
-- zástupce toho klubu, razítko se PŘERAZÍ NA NĚJ místo shození. Kontrola se
-- tím neztrácí — smysl #5 je, aby se na novou cenu podíval někdo oprávněný,
-- a ten se podíval: zadal ji. Auditní stopa je dokonce lepší, `approved_by`
-- ukazuje toho, kdo tu cenu opravdu odsouhlasil.
--
-- Pro člena (i profi hráče) se NEMĚNÍ NIC: jeho úprava razítko shodí a čeká
-- na správce klubu, přesně jako dosud.
--
-- ⚠️ Členovi s „právem navíc" (R11) se to schválně nerozšiřuje — viz komentář
-- v těle funkce.
--
-- -----------------------------------------------------------------------------
-- CO SE NESTAVÍ A PROČ
-- -----------------------------------------------------------------------------
-- Žádná nová hodnota v `app_role`. Rozhodnutí R1/R2 z návrhu rolí: enum se
-- nemění a „správce klubu" zůstává vztahem ke klubu. Nová globální role by
-- navíc neuměla to hlavní — být správcem JEN JEDNOHO klubu.
--
-- Pojmenování v UI („zástupce klubu" vs. „správce klubu") je otázka popisku,
-- ne databáze, a patří do vlastního ticketu k UI.
--
-- VRATNOST: funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.zrus_schvaleni_pri_uprave()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Nebylo co shodit.
  IF OLD.approved_at IS NULL THEN
    RETURN NEW;
  END IF;

  -- Ve stejném příkazu se hýbe schválením — to je `approve_reservation`
  -- (nebo admin, který razítko odebírá ručně), ne úprava rezervace.
  IF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    RETURN NEW;
  END IF;

  IF (NEW.start_at, NEW.end_at, NEW.sheet_id, NEW.subject_id,
      NEW.rate_per_hour, NEW.amount, NEW.cenove_pasma)
     IS DISTINCT FROM
     (OLD.start_at, OLD.end_at, OLD.sheet_id, OLD.subject_id,
      OLD.rate_per_hour, OLD.amount, OLD.cenove_pasma) THEN
    -- KDO SMÍ SCHVALOVAT, TEN PRÁVĚ SCHVÁLIL.
    --
    -- Smysl shození razítka (#5) je, aby s novou cenou souhlasil KLUB. Když
    -- úpravu dělá správce toho klubu, tak souhlasil: zadal ji sám. Nutit ho
    -- o vteřinu později kliknout „potvrdit" na vlastní úpravu je obřad,
    -- ne kontrola.
    --
    -- ⚠️ SPRÁVCE HALY (admin) SEM SCHVÁLNĚ NEPATŘÍ, i když schvalovat smí.
    -- Když cenu změní hala — přecení akci, přehodí typ — klub o tom neví
    -- a razítko mu podepsat nemůže nikdo jiný než on sám. Právě tohle byl
    -- bug #5: „kdo podepsal 2 400, má pod sebou 1 600". Admin proto razítko
    -- dál shazuje a rezervace se vrací klubu k potvrzení.
    --
    -- Razítko se proto přerazí na NĚJ. Auditní stopa tím nic neztrácí, právě
    -- naopak: `approved_by` ukazuje toho, kdo tu cenu doopravdy odsouhlasil.
    --
    -- ⚠️ ČLENA S „PRÁVEM NAVÍC" (R11) se to schválně NETÝKÁ. To právo je úzké
    -- a týká se jen potvrzení VLASTNÍ rezervace před akcí; rozšířit ho tady
    -- potichu na „a taky si smíš sám odklepnout přecenění" by z výjimky
    -- udělalo něco jiného, než co PM schválil.
    IF NEW.subject_id IS NOT NULL AND public.is_subject_rep(NEW.subject_id) THEN
      NEW.approved_at := now();
      NEW.approved_by := auth.uid();
    ELSE
      NEW.approved_at := NULL;
      NEW.approved_by := NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$

;

DO $kontrola$
BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.zrus_schvaleni_pri_uprave()'::regprocedure)
     NOT LIKE '%is_subject_rep%' THEN
    RAISE EXCEPTION 'Přerazítkování pro správce klubu chybí.';
  END IF;
  -- Shození pro ostatní musí zůstat — jinak by #5 přestal platit úplně.
  IF (SELECT prosrc FROM pg_proc WHERE oid='public.zrus_schvaleni_pri_uprave()'::regprocedure)
     NOT LIKE '%NEW.approved_at := NULL%' THEN
    RAISE EXCEPTION 'Větev, která razítko shazuje, zmizela — #5 by přestal platit.';
  END IF;
  RAISE NOTICE 'Správce klubu si úpravu odsouhlasí sám; členovi razítko dál padá.';
END $kontrola$;
