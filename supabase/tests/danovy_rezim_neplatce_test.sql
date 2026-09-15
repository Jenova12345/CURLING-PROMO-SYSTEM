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
-- 4) INTERNÍ ENGINE ZŮSTÁVÁ ZAVŘENÝ — UŽ NE NÁHODOU, ALE VLASTNÍM ZÁMKEM
--
--    Dřívější znění tohohle scénáře varovalo, že přepnutí na neplátce interní
--    engine MIMODĚK ODEMKNE: `create_invoice_draft_*` a `issue_invoice` totiž
--    odmítaly cokoli vystavit jen proto, že `vat_mode = 'platce'`. Nastavení
--    `platce` neslo dvě věci najednou — daňový režim a zámek enginu —, takže
--    návrat do daňově správné polohy by pustil živá tlačítka „Vygenerovat
--    fakturu" (Dues.tsx) a „Vystavit fakturu" (Invoices.tsx), přestože ostré
--    doklady má z rozhodnutí PM vystavovat Fakturoid.
--
--    TO UŽ NEPLATÍ. Migrace `20260915100000_zamek_interniho_enginu.sql` dala
--    enginu vlastní zámek, nezávislý na daňovém režimu a fail-closed. Tenhle
--    scénář proto nově tvrdí opak: i pod neplátcem je engine ZAVŘENÝ.
--
--    Podrobné pokrytí toho zámku (všech pět vstupních bodů, fail-closed,
--    nepřepnutelnost z aplikace) je v `zamek_interniho_enginu_test.sql`.
--    Tady jde jen o jedno: že přepnutí daňového režimu engine neodemklo.
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
  PERFORM pg_temp.tvrd(_odmitl,
    '4a) pod plátcem interní engine odmítá vystavit');
  PERFORM pg_temp.tvrd(_hlaska LIKE '%vyřazený%' OR _hlaska LIKE '%neplátce DPH%',
    '4a2) a je to jeden z těch dvou zámků, ne náhodný pád (' || left(_hlaska, 50) || ')');
END $$;
ROLLBACK TO s4;

SAVEPOINT s4b;
DO $$
DECLARE _hlaska text; _odmitl boolean;
BEGIN
  -- Režim je tu neplátce (stav po migraci). Starý zámek na `vat_mode` tedy mlčí —
  -- a právě proto se tady měří, jestli drží ten NOVÝ.
  BEGIN
    PERFORM public.create_invoice_draft_commercial(
      (SELECT event_id FROM public.reservations
        WHERE event_id IS NOT NULL AND deleted_at IS NULL ORDER BY id LIMIT 1));
    _odmitl := false; _hlaska := '(prošlo)';
  EXCEPTION WHEN OTHERS THEN _odmitl := true; _hlaska := SQLERRM;
  END;
  PERFORM pg_temp.tvrd(_odmitl,
    '4b) pod neplátcem je interní engine POŘÁD zavřený (dřív se tu odemykal)');
  PERFORM pg_temp.tvrd(_hlaska LIKE '%Interní fakturační engine je vyřazený%',
    '4c) a drží ho VLASTNÍ zámek, ne daňový režim (' || left(_hlaska, 50) || ')');
  PERFORM pg_temp.tvrd(_hlaska NOT LIKE '%neplátce DPH%',
    '4d) starý zámek na vat_mode už tu opravdu nedrží — proto ten nový musel vzniknout');
END $$;
ROLLBACK TO s4b;

ROLLBACK;
