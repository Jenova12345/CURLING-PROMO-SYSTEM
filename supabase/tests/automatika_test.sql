-- =============================================================================
-- TESTY AUTOMATIKY FAKTURACE (fáze D)
-- =============================================================================
-- Nejdůležitější tvrzení: automatika NESMÍ vyfakturovat totéž dvakrát, a to ani
-- když ji někdo spustí dvakrát za sebou. Držení se opírá o dvě nezávislé věci
-- (zámek `invoice_id` a evidence `billing_runs`), takže se testují obě.
--
-- Druhé v pořadí: vypínače. `automation_enabled = false` znamená „tikej, ale
-- nesahej na nic" a `auto_issue = false` znamená „koncepty, nic nevystavuj".
-- Kdyby některý netěsnil, začaly by v ostrém provozu samy vznikat doklady.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

-- Fakturační údaje (migrace je nechávají prázdné) + komerční akce v minulosti.
UPDATE public.billing_settings SET
  supplier_name = 'Curling Promo Ostrava z.s.', supplier_address = 'Ledová 1, Ostrava',
  supplier_ico = '12345678', bank_account = '19-2000145399/0800',
  bank_iban = 'CZ6508000000192000145399';
UPDATE public.events SET end_time = now() - interval '3 days' WHERE event_type = 'commercial';

-- -----------------------------------------------------------------------------
-- 1) Vypnutá automatika NESMÍ udělat nic — ale musí být vidět, že běží
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _pred int; _po int;
BEGIN
  UPDATE public.billing_settings SET automation_enabled = false;
  SELECT count(*) INTO _pred FROM public.invoices;
  _v := public.billing_automation_tick();
  SELECT count(*) INTO _po FROM public.invoices;

  PERFORM pg_temp.tvrd(_v->>'stav' = 'vypnuto', 'vypnutá automatika to o sobě řekne');
  PERFORM pg_temp.tvrd(_v->>'tik' IS NOT NULL, 'a přesto ohlásí tik (mrtvý muž — je vidět, že plánovač žije)');
  PERFORM pg_temp.tvrd(_po = _pred, 'vypnutá automatika nezaloží ani jeden doklad');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Zapnutá automatika: koncepty ano, vystavení ne
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _po int; _vyst int; _komercni jsonb;
BEGIN
  UPDATE public.billing_settings SET automation_enabled = true, auto_issue = false;
  _v := public.billing_automation_tick();

  SELECT count(*), count(*) FILTER (WHERE status <> 'koncept') INTO _po, _vyst FROM public.invoices;
  SELECT b INTO _komercni FROM jsonb_array_elements(_v->'behy') b WHERE b->>'druh' = 'komercni_denni';

  PERFORM pg_temp.tvrd((_komercni->>'vytvoreno')::int > 0, 'automatika slízla proběhlé komerční akce');
  PERFORM pg_temp.tvrd(_po > 0, 'a doklady opravdu vznikly');
  PERFORM pg_temp.tvrd(_vyst = 0,
    'ale NIC nevystavila — auto_issue = false znamená jen koncepty (vystavení je nevratné)');
  PERFORM pg_temp.tvrd((_v->>'auto_issue')::boolean = false, 'souhrn říká, v jakém režimu běžela');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: druhý běh nesmí vyfakturovat totéž znovu
-- -----------------------------------------------------------------------------
DO $$
DECLARE _pred int; _po int; _v jsonb; _komercni jsonb;
BEGIN
  SELECT count(*) INTO _pred FROM public.invoices;
  _v := public.billing_automation_tick();
  SELECT count(*) INTO _po FROM public.invoices;
  SELECT b INTO _komercni FROM jsonb_array_elements(_v->'behy') b WHERE b->>'druh' = 'komercni_denni';

  PERFORM pg_temp.tvrd(_po = _pred, 'druhý běh nevytvoří ANI JEDEN doklad navíc');
  PERFORM pg_temp.tvrd((_komercni->>'vytvoreno')::int = 0, 'a hlásí, že nic nevytvořil');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Zahozený koncept: automatika ho sama NEOBNOVÍ, ale řekne to
--
-- Je to vědomé: u peněz je „radši nic než dvakrát" správná strana. Zároveň je
-- to past, kterou musí být vidět — proto se tvrdí i to, že se skok objeví
-- v souhrnu jako `preskoceno`, ne že tiše zmizí.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _v jsonb; _komercni jsonb; _po int;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  FOR _fid IN SELECT id FROM public.invoices WHERE status = 'koncept' LOOP
    PERFORM public.delete_invoice_draft(_fid);
  END LOOP;
  RESET ROLE;

  _v := public.billing_automation_tick();
  SELECT b INTO _komercni FROM jsonb_array_elements(_v->'behy') b WHERE b->>'druh' = 'komercni_denni';
  SELECT count(*) INTO _po FROM public.invoices WHERE status = 'koncept';

  PERFORM pg_temp.tvrd((_komercni->>'vytvoreno')::int = 0,
    'po zahození konceptu automatika doklad sama neobnoví');
  PERFORM pg_temp.tvrd((_komercni->>'preskoceno')::int > 0,
    'ale ohlásí to jako přeskočené — není to tiché selhání');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Cesta zpět: `forget_billing_run` a jeho pojistka
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klic text; _v jsonb; _komercni jsonb;
BEGIN
  SELECT klic INTO _klic FROM public.billing_runs WHERE druh = 'komercni_denni' LIMIT 1;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555"}', true);
  BEGIN
    PERFORM public.forget_billing_run('komercni_denni', _klic);
    PERFORM pg_temp.tvrd(false, 'člen NEMĚL smět zapomenout běh');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.tvrd(SQLERRM LIKE '%jen správce%', 'běhy automatiky člen nespravuje');
  END;

  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  PERFORM public.forget_billing_run('komercni_denni', _klic);
  RESET ROLE;

  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.billing_runs WHERE druh = 'komercni_denni' AND klic = _klic),
    'admin běh zapomene');

  _v := public.billing_automation_tick();
  SELECT b INTO _komercni FROM jsonb_array_elements(_v->'behy') b WHERE b->>'druh' = 'komercni_denni';
  PERFORM pg_temp.tvrd((_komercni->>'vytvoreno')::int > 0,
    'a automatika tu akci zpracuje znovu');
END $$;

-- Pojistka: dokud doklad z běhu existuje, zapomenout ho nejde.
DO $$
DECLARE _klic text;
BEGIN
  SELECT klic INTO _klic FROM public.billing_runs
   WHERE druh = 'komercni_denni' AND invoice_id IS NOT NULL LIMIT 1;
  IF _klic IS NULL THEN
    RAISE NOTICE 'OK  (přeskočeno: žádný běh s existujícím dokladem)';
    RETURN;
  END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  BEGIN
    PERFORM public.forget_billing_run('komercni_denni', _klic);
    PERFORM pg_temp.tvrd(false, 'zapomenutí běhu s ŽIVÝM dokladem mělo být odmítnuto');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.tvrd(SQLERRM LIKE '%pořád existuje%',
      'běh se živým dokladem zapomenout nejde (jinak by vznikl druhý doklad na tutéž akci)');
  END;
  RESET ROLE;
END $$;

-- -----------------------------------------------------------------------------
-- 6) Práva — kdo smí tik spustit
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.billing_automation_tick();
    PERFORM pg_temp.tvrd(false, 'člen NEMĚL spustit automatiku');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.tvrd(SQLERRM LIKE '%plánovač nebo správce%', 'člen automatiku nespustí');
  END;
END $$;
RESET ROLE;

DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.billing_automation_tick()', 'EXECUTE'),
    'nepřihlášený se k automatice nedostane vůbec');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.forget_billing_run(text, text)', 'EXECUTE'),
    'ani ke správě běhů');
END $$;

-- -----------------------------------------------------------------------------
-- 7) Evidence běhů je čitelná jen adminovi (jsou v ní názvy akcí a chyby)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _n int;
BEGIN
  SELECT count(*) INTO _n FROM public.billing_runs;
  PERFORM pg_temp.tvrd(_n = 0, 'člen do evidence běhů nevidí');
END $$;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _n int;
BEGIN
  SELECT count(*) INTO _n FROM public.billing_runs;
  PERFORM pg_temp.tvrd(_n > 0, 'admin ano');
END $$;
RESET ROLE;

ROLLBACK;
