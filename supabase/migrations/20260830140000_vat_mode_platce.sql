-- =============================================================================
-- `billing_settings.vat_mode` → 'platce'
-- Blok B — hala je od přechodu plátce DPH
-- =============================================================================
-- ⚠️ TAHLE MIGRACE MĚNÍ DATA, NE SCHÉMA. Přečti si to celé, než ji pustíš.
--
-- PROČ VŮBEC: `IS_VAT_PAYER` (prostředí) řídí fakturoidí cestu, `vat_mode`
-- (databáze) interní engine. Jsou to DVA NEZÁVISLÉ PŘEPÍNAČE TÉŽE VĚCI a po
-- zapnutí prvního bez druhého by šlo ze dvou obrazovek vystavit doklad
-- s DPH i doklad bez ní — každý v jiné číselné řadě.
--
-- Ověřeno spuštěním `issue_invoice` pod rolí `authenticated` jako admin
-- (zásada 8 z CLAUDE.md — jako `postgres` by prošlo obojí):
--
--     vat_mode = 'neplatce'  →  issue_invoice PROŠLO   (vystaví doklad bez DPH)
--     vat_mode = 'platce'    →  ODMÍTNUTO: „Doklad umí zatím jen režim
--                               neplátce DPH (nastaveno: platce)."
--
-- CO SE TÍM TEDY DĚLÁ: interní engine se ZAVŘE. Není to vedlejší škoda, je to
-- ZÁMĚR. Pod S2 vystavuje ostré doklady Fakturoid a interní engine je na
-- vyřazení (samostatný ticket) — do té doby je „hlasitě nedostupný" přesně to,
-- co chceme.
--
-- ⚠️ SAMA O SOBĚ TO NESTIHNE CELÉ. `issue_invoice` guard má, ale tlačítko
-- „Vygenerovat fakturu" v „Kdo dluží" volá `create_invoice_draft_*`, a ty ho
-- neměly — koncept tedy vznikl, zamkl rezervace a vystavit se pak nedal.
-- Dotahuje to navazující migrace `20260830160000_dph_guard_koncept.sql`;
-- bez ní je tahle sama past, ne zábrana.
--
-- -----------------------------------------------------------------------------
-- NEŽ TO PUSTÍŠ NA DEMO NEBO PRODUKCI
-- -----------------------------------------------------------------------------
-- 1. ČERSTVÁ ZÁLOHA DATABÁZE. Pravidlo repa a tady dvojnásob: mění se peněžní
--    nastavení a zpátky se to sice vrátí jedním UPDATE (viz VRATNOST), ale
--    doklady vystavené mezitím ne.
-- 2. `IS_VAT_PAYER=true` v Supabase secrets TÉHOŽ projektu. Obojí patří
--    k jednomu okamžiku — k datu účinnosti registrace k DPH.
-- 3. ÚČET VE FAKTUROIDU musí být taky vedený jako plátce. Tři místa, jeden
--    okamžik; kterékoli z nich pozadu znamená doklad v jiném režimu, než v jakém
--    ho hala vystavit chtěla. Opravuje se to dobropisem, ne přepnutím zpátky.
-- 4. AUTOMATIKU NEZAPÍNAT, dokud interní engine nevypadne.
--    `billing_automation_tick` volá `issue_invoice` uvnitř `EXCEPTION WHEN
--    OTHERS`, takže po tomhle přepnutí nespadne — jen bude tiše počítat `chyb`.
--    Dnes je `automation_enabled = false` i `auto_issue = false`; ať to tak
--    zůstane. Ověř: SELECT automation_enabled, auto_issue FROM billing_settings;
--
-- -----------------------------------------------------------------------------
-- ZÁLOHA HODNOTY: migrace si původní režim schová do `audit_log`
--
-- `billing_settings` má auditní trigger od Etapy 2, takže se `old_data`
-- s celým řádkem zapíše samo. Tady se navíc PŘED změnou vypíše, co tam bylo —
-- aby to bylo v logu nasazení, ne jen v tabulce, do které se musí umět někdo
-- podívat. Dohledat se to dá takhle:
--
--   SELECT changed_at, changed_by,
--          old_data ->> 'vat_mode' AS puvodni,
--          new_data ->> 'vat_mode' AS nove
--     FROM public.audit_log
--    WHERE table_name = 'billing_settings'
--      AND action = 'update'                    -- bez tohohle se přimíchá i INSERT
--      AND old_data ->> 'vat_mode' IS DISTINCT FROM new_data ->> 'vat_mode'
--    ORDER BY changed_at DESC;
--
-- ⚠️ `changed_by` BUDE NULL. Migrace běží bez JWT, takže `auth.uid()` nic
-- nevrací — z auditu se dozvíš KDY, ne KDO. Prázdné `changed_by` u téhle
-- tabulky tedy znamená „systémová změna z migrace"; autora hledej v logu
-- nasazení, ne tady. Ruční přepnutí adminem přes aplikaci `changed_by` má.
--
-- VRATNOST:
--   UPDATE public.billing_settings SET vat_mode = 'neplatce' WHERE singleton;
--
-- ⚠️ REVERT MUSÍ JÍT RUKU V RUCE s `IS_VAT_PAYER=false` v secrets, jinak
-- vznikne přesně ta dvouspínačová nekonzistence, jen obráceně: Fakturoid by
-- dál dostával plátcovské doklady, kdežto interní engine by se otevřel pro
-- neplátcovské. Dopředný směr to říká v bodech 1–4 výš; platí to i zpátky.
--
-- Data se neztrácejí. Ale POZOR: doklady vystavené mezitím fakturoidí cestou
-- už DPH nesou a revertem nezmizí — vrací se nastavení, ne historie.
-- =============================================================================

DO $$
DECLARE
  _puvodni public.vat_mode;
  _automatika boolean;
  _auto_issue boolean;
BEGIN
  SELECT vat_mode, automation_enabled, auto_issue
    INTO _puvodni, _automatika, _auto_issue
    FROM public.billing_settings WHERE singleton;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'billing_settings nemá řádek — přepínat režim DPH není na čem.';
  END IF;

  RAISE NOTICE 'Původní režim DPH: %  (uloží se do audit_log jako old_data)', _puvodni;

  IF _puvodni = 'platce' THEN
    RAISE NOTICE 'Už je nastavený plátce — migrace nic nemění.';
    RETURN;
  END IF;

  -- IDENTIFIKOVANÁ OSOBA JE JINÝ REŽIM, NE MEZIKROK. Přepsat ji naslepo na
  -- plátce by změnilo daňový režim haly na základě migrace, která o tom
  -- rozhodnutí nic neví. Takový stav vzniknout neměl, ale kdyby vznikl,
  -- patří na stůl člověku.
  IF _puvodni = 'identifikovana_osoba' THEN
    RAISE EXCEPTION 'Hala je vedená jako identifikovaná osoba, ne neplátce. Přepnutí na plátce je v tom případě rozhodnutí účetní, ne migrace — zastavuji.';
  END IF;

  UPDATE public.billing_settings
     SET vat_mode = 'platce'
   WHERE singleton;

  RAISE NOTICE 'Režim DPH přepnut na plátce. Interní engine (issue_invoice) je tím ZAVŘENÝ — je to záměr, viz hlavička migrace.';

  IF _automatika OR _auto_issue THEN
    RAISE WARNING 'POZOR: automatika je zapnutá (automation_enabled=%, auto_issue=%). Po tomhle přepnutí bude billing_automation_tick tiše počítat chyby, protože issue_invoice odmítá. Vypni ji, dokud interní engine nevypadne.',
      _automatika, _auto_issue;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rezim public.vat_mode; _zaznamu int;
BEGIN
  SELECT vat_mode INTO _rezim FROM public.billing_settings WHERE singleton;
  IF _rezim <> 'platce' THEN
    RAISE EXCEPTION 'Režim DPH se nepřepnul (je %).', _rezim;
  END IF;

  -- Auditní stopa je to jediné, co po změně peněžního nastavení zbude.
  -- Kdyby chyběla, přišlo by se na to až ve chvíli, kdy se někdo ptá „kdo to
  -- přepnul a kdy" — tedy pozdě.
  --
  -- ⚠️ PODMÍNKA MUSÍ BÝT ÚZKÁ, jinak nemůže selhat. Dřívější znění se ptalo jen
  -- na `old_data->>'vat_mode' IS DISTINCT FROM new_data->>'vat_mode'` — jenže
  -- `write_audit_log` zapisuje u INSERTu `old_data = NULL`, takže záznam
  -- o ZALOŽENÍ singletonu (`NULL IS DISTINCT FROM 'neplatce'`) tu podmínku
  -- splňoval taky. Kontrola tedy byla splněná od chvíle, kdy tabulka vznikla,
  -- a prošla by, i kdyby se tenhle UPDATE nezapsal vůbec. Kontrola, která
  -- nemůže selhat, je v tomhle repu známá kategorie (CLAUDE.md, bod 8).
  SELECT count(*) INTO _zaznamu FROM public.audit_log
   WHERE table_name = 'billing_settings'
     AND action = 'update'
     AND old_data ->> 'vat_mode' = 'neplatce'
     AND new_data ->> 'vat_mode' = 'platce';
  IF _zaznamu = 0 THEN
    RAISE EXCEPTION 'Změna režimu DPH se nezapsala do audit_log — bez stopy se to měnit nemá.';
  END IF;

  RAISE NOTICE 'Hala je vedená jako plátce DPH. Fakturuje se přes Fakturoid; interní engine je zavřený.';
END $$;
