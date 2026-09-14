-- =============================================================================
-- DAŇOVÝ REŽIM: billing_settings.vat_mode → 'neplatce'
-- =============================================================================
--
-- PROČ. Curling promo Ostrava s.r.o., IČO 29796717, JE NEPLÁTCE DPH. Ověřeno
-- 14. 9. 2026 ve čtyřech nezávislých registrech (ARES základní záznam
-- `"dic": null`; ARES `seznamRegistraci` → `"stavZdrojeDph": "NEEXISTUJICI"`;
-- ARES endpoint DPH → 404; registr plátců DPH MFČR → `statusCode="0"`,
-- `typSubjektu="NENALEZEN"`; VIES → `"isValid": false`). `typSubjektu` je
-- právě to pole, které by odlišilo identifikovanou osobu — není ani ta.
-- Plné znění odpovědí je v CLAUDE.md, kapitola „Daňový režim haly".
--
-- Účet ve Fakturoidu je nastavený správně (`vat_mode: non_vat_payer`).
-- Špatně jsou obě NAŠE místa, a protože se shodují spolu, brána
-- `overDanovyRezim` je propustila — porovnává dva zdroje, které jsou oba
-- vedle. Tahle migrace srovnává jedno z nich; druhé (`IS_VAT_PAYER=false`
-- v Supabase secrets) přepíná Tomáš ručně při nasazení.
--
-- POŘADÍ PŘI NASAZENÍ NA TOM NEZÁLEŽÍ a je to schválně:
--   * `IS_VAT_PAYER=true` + `vat_mode='neplatce'` → `overDanovyRezim` VYHODÍ
--     výjimku a fakturoidí cesta se zastaví. Hlasitě, ne tiše.
--   * `IS_VAT_PAYER=false` + `vat_mode='platce'` → totéž z druhé strany.
-- Mezistav tedy nic nevystaví; jen dočasně nejde fakturovat. To je správně —
-- opak (tiše projít v jednom z režimů) by byl ten drahý stav.
--
-- CO SE NEMĚNÍ A PROČ:
--   * `vat_rate_ice` (12,00) zůstává. Pod neplátcem ho NEČTE ani jedna
--     databázová funkce (ověřeno dotazem nad `pg_get_functiondef` všech funkcí
--     v `public`) a mapovací vrstva si sazbu drží vlastní konstantou
--     `SAZBA_DPH_LED`. Mazat nastavení, které se nepoužívá, by jen zahodilo
--     údaj pro případ, že se hala k DPH někdy registruje.
--   * Částky rezervací. `amount` je hodiny × sazba, na `vat_mode` nezávisí.
--   * KONTROLNÍ SOUČET `billing_reconcile` („Přehled fakturací"). Změřeno
--     14. 9. 2026 na produkci v transakci s ROLLBACKem: všech 18 řádků je
--     před i po IDENTICKÝCH. Ta funkce o DPH neví vůbec.
--   * `cena_bez_dph` na rezervacích. Hodnoty zůstávají; pod neplátcem se na ně
--     nikdo neptá (viz `over_danovy_rezim_podkladu` níž).
--
-- ⚠️ CO SE ZMĚNÍ — ČTI, NEŽ TO NASADÍŠ:
--   0. OBRAZOVKA „KDO DLUŽÍ" UKÁŽE NIŽŠÍ ČÍSLA. Čte pohled
--      `reservations_billing`, a ten má sloupec `dluh`, který u rezervací
--      s `cena_bez_dph` NAVYŠUJE o `vat_rate_ice`, dokud je `vat_mode`
--      cokoli jiného než `neplatce`. Změřeno 15. 9. 2026 na produkci
--      reálným tokenem admina v transakci s ROLLBACKem:
--        dluh jako plátce   1 912 832,00 Kč
--        dluh jako neplátce 1 838 300,00 Kč
--        rozdíl              −74 532,00 Kč u 15 komerčních subjektů
--      (největší: Správa železnic −14 100, Český svaz curlingu −12 360,
--      pak 4× −6 000 a MODRÝ PAVILON −4 800.)
--      NENÍ TO ZTRÁTA. Je to částka, kterou neplátce účtovat nesmí —
--      dosud se zobrazovala jako pohledávka neprávem. Základ (`dluh_zaklad`)
--      se nemění ani o korunu.
--      ⚠️ Nepleť si to s `billing_reconcile` výš: ten se opravdu nehne.
--      Jsou to DVA různé pohledy na totéž a jen jeden z nich o DPH ví.
--   1. `over_danovy_rezim_podkladu` se pod `'neplatce'` vrací PRVNÍM
--      příkazem, takže brána „doklad by míchal ceny s DPH a bez DPH"
--      přestane být činná. Dnes nic neblokuje (rozejitých rezervací je 0,
--      přeměřeno 14. 9. 2026), takže se tím nic neodemyká.
--   2. INTERNÍ FAKTURAČNÍ ENGINE SE ODEMKNE — A TEN ZÁMEK BYL ZÁMĚRNÝ.
--      `create_invoice_draft_club`, `create_invoice_draft_commercial`
--      i `issue_invoice` dnes odmítají cokoli vystavit hláškou „Doklad umí
--      zatím jen režim neplátce DPH (nastaveno: platce)".
--      NENÍ TO NÁHODA. Migrace `20260830140000_vat_mode_platce.sql` to píše
--      doslova: „interní engine se ZAVŘE pro nové doklady. Není to vedlejší
--      škoda, je to ZÁMĚR." Nastavení `platce` se tedy používalo ZÁROVEŇ jako
--      daňový režim A jako zámek enginu — dvě věci na jednom přepínači.
--      Tahle migrace ten přepínač vrací do daňově správné polohy, čímž
--      zámek MIMODĚK POUŠTÍ. Po nasazení začnou fungovat, a jsou navěšené na
--      živá tlačítka v aplikaci (`src/pages/Dues.tsx:258` „Vystavit fakturu",
--      `src/pages/Invoices.tsx` vystavení a storno). Z rozhodnutí PM přitom
--      ostré doklady vystavuje Fakturoid, ne tenhle engine — interní by
--      založil doklad ve VLASTNÍ číselné řadě vedle fakturoidí.
--      Tahle migrace to ZÁMĚRNĚ neřeší: vyřazení interního enginu je
--      samostatný ticket (viz CLAUDE.md, Etapa 3) a udělat z něj vedlejší
--      efekt daňové opravy by bylo horší než to pojmenovat.
--      ➜ ROZHODNUTÍ PM, A TOHLE JE TA DŮLEŽITÁ OTÁZKA CELÉHO KROKU 4:
--        buď se engine zamkne vlastní zábranou (nezávislou na daňovém
--        režimu) dřív nebo současně s touhle migrací, nebo se vědomě
--        přijme, že tlačítka ožijí. Nechat to náhodě není třetí možnost —
--        interní doklad by vznikl ve VLASTNÍ číselné řadě vedle fakturoidí.
--
--      Poznámka k původnímu záměru: migrace z 30. 8. 2026 se jmenuje „hala
--      je od přechodu plátce DPH" a předpokládala registraci k DPH. Registry
--      ověřené 14. 9. 2026 žádnou registraci neznají (ARES `dic: null`,
--      MFČR `typSubjektu="NENALEZEN"`, VIES `isValid: false`) a firma vznikla
--      teprve 16. 7. 2026. Ten předpoklad se tedy nenaplnil — ale byl to
--      předpoklad, ne překlep, a patří to vědět.
--
-- IDEMPOTENTNÍ: `UPDATE` na konkrétní hodnotu. Druhý běh nic nezmění
-- a post-check dopadne stejně. Viz CLAUDE.md pravidlo 6.
--
-- VRATNOST: `UPDATE public.billing_settings SET vat_mode = 'platce'
-- WHERE singleton;` Bezztrátové — mění se jedna hodnota jednoho řádku
-- a žádná data se nepřepočítávají.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PŘED-LET. Tahle migrace se NESMÍ pustit nad databází, kde už někdo vystavil
-- doklad v režimu plátce. Přepnout režim pod hotovým daňovým dokladem není
-- oprava nastavení, ale rozpor v účetnictví — a opravuje se dobropisem,
-- ne migrací. K 14. 9. 2026 je na produkci 0 dokladů, takže projde.
-- -----------------------------------------------------------------------------
DO $predlet$
DECLARE _doklady int; _fakturoid int; _rezim text;
BEGIN
  SELECT vat_mode INTO _rezim FROM public.billing_settings WHERE singleton;
  RAISE NOTICE 'PŘED-LET: vat_mode je teď „%".', COALESCE(_rezim, '(nenastaveno)');

  SELECT count(*) INTO _doklady
    FROM public.invoices WHERE vat_mode IS DISTINCT FROM 'neplatce';
  IF _doklady > 0 THEN
    RAISE EXCEPTION
      'ODMÍTNUTO: v invoices je % dokladů vystavených v jiném režimu než neplátce. '
      'Přepnutí režimu pod hotovým daňovým dokladem je účetní rozpor, ne oprava nastavení.',
      _doklady
      USING HINT = 'Doklady nejdřív vyřeš dobropisem a teprve pak měň režim.';
  END IF;

  SELECT count(*) INTO _fakturoid
    FROM public.fakturoid_invoices WHERE provider_invoice_id IS NOT NULL;
  IF _fakturoid > 0 THEN
    RAISE EXCEPTION
      'ODMÍTNUTO: u Fakturoidu je % vystavených dokladů. Ty vznikly v režimu, '
      'který se tímhle mění — viz hláška výš.', _fakturoid
      USING HINT = 'Řeš to u Fakturoidu dobropisem, ne přepnutím nastavení.';
  END IF;

  RAISE NOTICE 'PŘED-LET: 0 vystavených dokladů (interních i fakturoidích) — přepnutí je bezpečné.';
END
$predlet$;

-- -----------------------------------------------------------------------------
-- VLASTNÍ ZMĚNA
-- -----------------------------------------------------------------------------
UPDATE public.billing_settings
   SET vat_mode   = 'neplatce',
       updated_at = now()
 WHERE singleton
   AND vat_mode IS DISTINCT FROM 'neplatce';   -- druhý běh už nic nepřepisuje

-- -----------------------------------------------------------------------------
-- POST-CHECK. Ověřuje VÝSLEDEK, ne to, že příkaz doběhl.
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _rezim text; _radku int; _brana_cinna boolean;
BEGIN
  SELECT count(*) INTO _radku FROM public.billing_settings WHERE singleton;
  IF _radku <> 1 THEN
    RAISE EXCEPTION 'billing_settings nemá právě jeden singleton řádek (je jich %).', _radku;
  END IF;

  SELECT vat_mode INTO _rezim FROM public.billing_settings WHERE singleton;
  IF _rezim IS DISTINCT FROM 'neplatce' THEN
    RAISE EXCEPTION 'vat_mode je po migraci „%", měl být „neplatce".', COALESCE(_rezim,'(NULL)');
  END IF;

  -- Brána na míchání cen se pod neplátcem NESMÍ chovat jako činná. Není to
  -- kosmetika: kdyby se `over_danovy_rezim_podkladu` chovala dál jako pod
  -- plátcem, odmítala by podklady podle `cena_bez_dph`, které pod neplátcem
  -- nic neznamená — a fakturace by stála na kontrole bez obsahu.
  -- Testuje se VOLÁNÍM, ne čtením zdrojáku: zajímá nás chování.
  BEGIN
    PERFORM public.over_danovy_rezim_podkladu(
      ARRAY(SELECT r.id FROM public.reservations r
             WHERE r.deleted_at IS NULL AND r.subject_id IS NOT NULL
             ORDER BY r.id LIMIT 5),
      -- Schválně se ptáme na OPAK toho, co v datech je, ať by brána pod
      -- plátcem musela vyhodit výjimku.
      NOT COALESCE((SELECT r.cena_bez_dph FROM public.reservations r
                     WHERE r.deleted_at IS NULL AND r.subject_id IS NOT NULL
                     ORDER BY r.id LIMIT 1), false),
      'POST-CHECK');
    _brana_cinna := false;
  EXCEPTION WHEN OTHERS THEN
    _brana_cinna := true;
  END;
  IF _brana_cinna THEN
    RAISE EXCEPTION
      'over_danovy_rezim_podkladu pod neplátcem pořád odmítá podklad — režim se neprojevil.';
  END IF;

  RAISE NOTICE 'Daňový režim: vat_mode = neplatce ✔, brána na míchání cen neúčinná ✔ (pod neplátcem správně)';
  RAISE NOTICE 'ZBÝVÁ RUČNĚ: přepnout IS_VAT_PAYER na false v Supabase secrets. Do té doby fakturoidí cesta hlásí rozpor režimů — a je to tak správně.';
END
$kontrola$;
