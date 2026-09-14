-- =============================================================================
-- DAŇOVÝ REŽIM NEPLÁTCE — testy k migraci 20260915090000
-- =============================================================================
--
-- Hlídá čtyři věci, a ta poslední je tu schválně jako VAROVÁNÍ, ne jako
-- pochvala: přepnutí režimu odemyká interní fakturační engine. Je to vedlejší
-- efekt, o který nikdo nežádal, a test ho drží viditelný — kdyby ho někdo
-- později zamkl jinak, spadne to tady a bude jasné proč.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF current_database() <> 'curling_test' THEN
    RAISE EXCEPTION 'ODMÍTNUTO: test ZAPISUJE, patří jen do repliky curling_test, běží nad "%".',
      current_database();
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE '  OK  %', _popis;
END $$;

-- ===========================================================================
-- 1) REŽIM JE NEPLÁTCE
-- ===========================================================================
DO $$
DECLARE _r text;
BEGIN
  SELECT vat_mode INTO _r FROM public.billing_settings WHERE singleton;
  PERFORM pg_temp.tvrd(_r = 'neplatce',
    '1a) billing_settings.vat_mode je „neplatce" (je „' || COALESCE(_r,'NULL') || '")');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.billing_settings WHERE singleton) = 1,
    '1b) a je právě jeden singleton řádek');
END $$;

-- ===========================================================================
-- 2) ČÁSTKY SE REŽIMEM NEHÝBOU
--
--    Tohle je to hlavní tvrzení celé změny: „Kdo kolik dluží" nezávisí na
--    daňovém režimu. Neověřuje se čtením funkce, ale POROVNÁNÍM VÝSLEDKŮ
--    v obou režimech nad týmiž daty.
-- ===========================================================================
SAVEPOINT s2;
DO $$
DECLARE _neplatce text; _platce text; _radku int;
BEGIN
  SELECT string_agg(subject_id::text || ':' || dluzi::text || ':' || k_fakturaci::text, '|' ORDER BY subject_id::text),
         count(*)
    INTO _neplatce, _radku
    FROM public.billing_reconcile('2026-01-01','2026-12-31');

  PERFORM pg_temp.tvrd(_radku > 0, '2a) sestava vůbec něco vrací (jinak 2b neměří nic)');

  UPDATE public.billing_settings SET vat_mode = 'platce' WHERE singleton;
  SELECT string_agg(subject_id::text || ':' || dluzi::text || ':' || k_fakturaci::text, '|' ORDER BY subject_id::text)
    INTO _platce
    FROM public.billing_reconcile('2026-01-01','2026-12-31');

  PERFORM pg_temp.tvrd(_neplatce IS NOT DISTINCT FROM _platce,
    '2b) „Kdo kolik dluží" je v obou režimech IDENTICKÉ — částky na DPH nezávisí');
END $$;
ROLLBACK TO s2;

-- ===========================================================================
-- 3) BRÁNA NA MÍCHÁNÍ CEN JE POD NEPLÁTCEM NEÚČINNÁ
--
--    `cena_bez_dph` pod neplátcem nic neznamená, takže brána, která podle něj
--    odmítá podklady, by kontrolovala prázdno. Testuje se VOLÁNÍM — zajímá
--    nás chování, ne znění zdrojáku.
-- ===========================================================================
SAVEPOINT s3;
DO $$
DECLARE _rez uuid[]; _opak boolean; _spadlo boolean;
BEGIN
  SELECT array_agg(r.id ORDER BY r.id), NOT bool_or(r.cena_bez_dph)
    INTO _rez, _opak
    FROM (SELECT id, cena_bez_dph FROM public.reservations
           WHERE deleted_at IS NULL AND subject_id IS NOT NULL ORDER BY id LIMIT 5) r;

  -- pod NEPLÁTCEM: nesmí spadnout, i když se ptáme na opak toho, co v datech je
  BEGIN
    PERFORM public.over_danovy_rezim_podkladu(_rez, _opak, 'TEST');
    _spadlo := false;
  EXCEPTION WHEN OTHERS THEN _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(NOT _spadlo,
    '3a) pod neplátcem brána podklad NEodmítá (cena_bez_dph tu nic neznamená)');

  -- kontrolní vzorek: pod PLÁTCEM tatáž otázka spadnout MUSÍ, jinak 3a
  -- neměří režim, ale jen to, že brána nefunguje nikdy
  UPDATE public.billing_settings SET vat_mode = 'platce' WHERE singleton;
  BEGIN
    PERFORM public.over_danovy_rezim_podkladu(_rez, _opak, 'TEST');
    _spadlo := false;
  EXCEPTION WHEN OTHERS THEN _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo,
    '3b) …zatímco pod plátcem tentýž dotaz spadne — 3a tedy měří REŽIM, ne mrtvou bránu');
END $$;
ROLLBACK TO s3;

-- ===========================================================================
-- 4) ⚠ VEDLEJŠÍ EFEKT: INTERNÍ ENGINE SE ODEMYKÁ
--
--    Dnes `create_invoice_draft_*` a `issue_invoice` odmítají cokoli vystavit,
--    protože `vat_mode = 'platce'`. Ten zámek je ZÁMĚRNÝ — migrace
--    `20260830140000_vat_mode_platce.sql` ho tak zavedla doslova („interní
--    engine se ZAVŘE pro nové doklady … je to ZÁMĚR"). Nastavení `platce`
--    tedy neslo dvě věci najednou: daňový režim a zámek enginu. Návrat do
--    daňově správné polohy ten zámek mimoděk pouští a živá tlačítka v aplikaci
--    (Dues.tsx „Vystavit fakturu", Invoices.tsx vystavení/storno) ožijí,
--    přestože ostré doklady má z rozhodnutí PM vystavovat Fakturoid.
--
--    Test to NEOPRAVUJE — jen to drží pojmenované a měřitelné. Až se engine
--    vyřadí (samostatný ticket), tenhle scénář zčervená a bude hned vidět,
--    že se tak stalo, a ne že se něco rozbilo.
-- ===========================================================================
SAVEPOINT s4;
-- Savepointy se ZÁMĚRNĚ řídí zvenčí, ne z DO bloku: `ROLLBACK TO` uvnitř
-- plpgsql není dovolené (transakční řízení do funkce nepatří) a první verze
-- tohohle scénáře na tom spadla se `syntax error at or near "TO"`.
DO $$
DECLARE _hlaska text; _odmitl boolean;
BEGIN
  UPDATE public.billing_settings SET vat_mode = 'platce' WHERE singleton;
  BEGIN
    PERFORM public.create_invoice_draft_commercial(
      (SELECT event_id FROM public.reservations
        WHERE event_id IS NOT NULL AND deleted_at IS NULL ORDER BY id LIMIT 1));
    _odmitl := false;
  EXCEPTION WHEN OTHERS THEN
    _odmitl := true; _hlaska := SQLERRM;
  END;
  PERFORM pg_temp.tvrd(_odmitl AND _hlaska LIKE '%neplátce DPH%',
    '4a) pod plátcem interní engine odmítá vystavit (to je ten náhodný zámek)');
END $$;
ROLLBACK TO s4;

SAVEPOINT s4b;
DO $$
DECLARE _hlaska text;
BEGIN
  -- Režim je tu neplátce (stav po migraci). Engine už nesmí odmítat NA REŽIM;
  -- spadnout může na něčem jiném (práva, prázdná akce), proto se hlídá jen to,
  -- že to NENÍ hláška o daňovém režimu.
  BEGIN
    PERFORM public.create_invoice_draft_commercial(
      (SELECT event_id FROM public.reservations
        WHERE event_id IS NOT NULL AND deleted_at IS NULL ORDER BY id LIMIT 1));
    _hlaska := '(prošlo)';
  EXCEPTION WHEN OTHERS THEN _hlaska := SQLERRM;
  END;
  PERFORM pg_temp.tvrd(_hlaska NOT LIKE '%neplátce DPH%',
    '4b) ⚠ pod neplátcem už engine na režim NEodmítá — zámek je pryč. Hláška: ' || _hlaska);
END $$;
ROLLBACK TO s4b;

ROLLBACK;
