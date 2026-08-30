-- =============================================================================
-- TESTY ČÁSTEČNÉHO DOBROPISU
-- =============================================================================
-- Hlídá se především kontrolní součet. Dobropis je přesně ten druh změny, po
-- které rovnice tiše přestane platit: doklad zůstane vystavený v plné výši,
-- ale klub tolik nedluží.
--
-- Rozhodnutí, které se tu tvrdí (R1): částečný dobropis rezervace NEUVOLŇUJE.
-- Kdyby je uvolnil, dostaly by se mezi „k fakturaci" a automatika by naúčtovala
-- znovu něco, co je částečně dobropisované.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- -----------------------------------------------------------------------------
-- PŘEDPOKLAD: NEPLÁTCOVSKÝ REŽIM
--
-- Tenhle soubor testuje INTERNÍ fakturační engine (`issue_invoice` a spol.),
-- a ten umí jen režim neplátce — `20260813140000_faktury_rpc.sql` to tvrdě
-- hlídá. Od migrace `20260830140000_vat_mode_platce.sql` je hala vedená jako
-- PLÁTCE, takže engine odmítá vystavit cokoli. Je to záměr: ostré doklady pod
-- S2 vystavuje Fakturoid a interní engine je na vyřazení.
--
-- Testy proto svůj předpoklad říkají NAHLAS, místo aby spoléhaly na výchozí
-- hodnotu, která se právě změnila. Celý soubor končí ROLLBACKem, takže se
-- nastavení nikam nepropíše.
--
-- ⚠️ AŽ INTERNÍ ENGINE VYPADNE, tenhle soubor jde smazat celý — ne opravit.
-- Netestuje totiž nic, co by pak ještě existovalo.
-- -----------------------------------------------------------------------------
UPDATE public.billing_settings SET vat_mode = 'neplatce' WHERE singleton;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis; RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): mělo to skončit chybou, ale prošlo', _popis;
END $$;

UPDATE public.billing_settings SET
  supplier_name = 'Curling Promo Ostrava z.s.', supplier_address = 'Ledová 1, Ostrava',
  supplier_ico = '12345678', bank_account = '19-2000145399/0800',
  bank_iban = 'CZ6508000000192000145399';

CREATE TEMP TABLE _s (klic text primary key, hodnota text);
GRANT SELECT, INSERT ON _s TO authenticated;

-- Subjekt se vybírá TADY, ještě pod databázovou rolí: `authenticated` nemá na
-- `reservations` tabulkový grant a čte je jen přes pohledy a RPC.
INSERT INTO _s (klic, hodnota)
SELECT 'subjekt', r.subject_id::text
  FROM public.reservations r
 WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
   AND r.invoice_id IS NULL AND COALESCE(r.corrected_amount, r.amount) > 0
 GROUP BY r.subject_id ORDER BY count(*) DESC LIMIT 1;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: po dobropisu sedí kontrolní součet a je vidět, kolik se vrátilo
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _od date := '2026-07-01'; _do date := '2026-08-31';
        _fid uuid; _ids uuid[]; _v jsonb; _r record; _pred numeric;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic = 'subjekt';

  _fid := public.create_invoice_draft_club(_sub, _od, _do);
  PERFORM public.issue_invoice(_fid);
  SELECT rozdil INTO _pred FROM public.billing_reconcile(_od, _do) WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_pred = 0, 'před dobropisem kontrolní součet sedí');

  SELECT array_agg(id) INTO _ids FROM (
    SELECT id FROM public.invoice_items WHERE invoice_id = _fid ORDER BY poradi LIMIT 2) x;
  _v := public.dobropis_invoice(_fid, _ids, 'Dráha 2 se nakonec nepoužila.');

  INSERT INTO _s VALUES ('faktura', _fid::text), ('opravny', _v->>'opravny_id'),
                        ('castka', _v->>'dobropisovano');

  SELECT fakturovano, dobropisovano, rozdil INTO _r
    FROM public.billing_reconcile(_od, _do) WHERE subject_id = _sub;

  PERFORM pg_temp.tvrd(_r.rozdil = 0,
    format('PO DOBROPISU kontrolní součet sedí (rozdil=%s)', _r.rozdil));
  PERFORM pg_temp.tvrd(_r.dobropisovano = (_v->>'dobropisovano')::numeric,
    'a je vidět, kolik se dobropisem vrátilo');
  PERFORM pg_temp.tvrd(_r.dobropisovano > 0 AND _r.dobropisovano < _r.fakturovano,
    'dobropis je ČÁSTÍ vyfakturovaného, ne celkem');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Co dobropis (ne)udělá s dokladem a rezervacemi
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _opr uuid; _p record; _o record;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _s WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _opr FROM _s WHERE klic = 'opravny';
  SELECT * INTO _p FROM public.invoices WHERE id = _fid;
  SELECT * INTO _o FROM public.invoices WHERE id = _opr;

  PERFORM pg_temp.tvrd(_p.status = 'vystaveno',
    'původní faktura po dobropisu DÁL PLATÍ (na rozdíl od storna)');
  PERFORM pg_temp.tvrd(_o.opravuje_id = _fid AND _o.status = 'vystaveno',
    'opravný doklad je vystavený a ukazuje na původní');
  PERFORM pg_temp.tvrd(_o.je_plne_storno = false,
    'a je označený jako ČÁSTEČNÝ — plné storno smí být jen jedno');
  PERFORM pg_temp.tvrd(_o.total < _p.total, 'zní na menší částku než originál');
  PERFORM pg_temp.tvrd(_o.pdf_status IS NOT NULL, 'a jde do fronty na PDF jako každý doklad');

END $$;
RESET ROLE;

-- R1: zámek se NEUVOLŇUJE. Čte se mimo roli `authenticated` — ta na
-- `reservations` tabulkový grant nemá.
DO $$
DECLARE _fid uuid; _zamcenych int;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _s WHERE klic = 'faktura';
  SELECT count(*) INTO _zamcenych FROM public.reservations WHERE invoice_id = _fid;
  PERFORM pg_temp.tvrd(_zamcenych > 0,
    'rezervace zůstávají zamčené na faktuře — dobropis je neuvolňuje (R1)');
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 3) Co dobropisovat NELZE
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _opr uuid; _vsechny uuid[]; _cizi uuid[]; _sub uuid;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _s WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _opr FROM _s WHERE klic = 'opravny';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.dobropis_invoice(%L, ARRAY[]::uuid[])', _fid),
    'aspoň jednu položku', 'dobropis bez vybraných položek se odmítne');

  SELECT array_agg(id) INTO _vsechny FROM public.invoice_items WHERE invoice_id = _fid;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.dobropis_invoice(%L, %L::uuid[])', _fid, _vsechny),
    'použij storno', 'dobropis na VŠECHNY položky se odmítne — na to je storno');

  -- Cizí řádek: bez téhle kontroly by šlo dobropisovat z jiné faktury.
  SELECT array_agg(id) INTO _cizi FROM public.invoice_items WHERE invoice_id = _opr;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.dobropis_invoice(%L, %L::uuid[])', _fid, _cizi),
    'nejsou', 'položky z cizího dokladu se odmítnou');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.dobropis_invoice(%L, %L::uuid[])', _opr, _cizi),
    'sám nedobropisuje', 'opravný doklad se sám nedobropisuje');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 4) Plné storno PO dobropisu: rovnice musí sednout i tak
--
-- Tady se dřív rozbíjela: dobropis se odečítal i po tom, co originál skončil
-- ve stornu, a `fakturovano` spadlo do mínusu.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _fid uuid; _sub uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _s WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic = 'subjekt';

  PERFORM public.storno_invoice(_fid, 'Zbytek taky ruším.');

  SELECT fakturovano, dobropisovano, ve_stornu, k_fakturaci, rozdil INTO _r
    FROM public.billing_reconcile('2026-07-01', '2026-08-31') WHERE subject_id = _sub;

  PERFORM pg_temp.tvrd(_r.rozdil = 0,
    format('kontrolní součet sedí i po stornu dobropisované faktury (rozdil=%s)', _r.rozdil));
  PERFORM pg_temp.tvrd(_r.fakturovano >= 0,
    'a `fakturovano` nespadne do mínusu (dobropis se po stornu už nepočítá)');
  PERFORM pg_temp.tvrd(_r.dobropisovano = 0,
    'dobropis ke stornovanému dokladu se přestane vykazovat');
  PERFORM pg_temp.tvrd(_r.k_fakturaci > 0,
    'a rezervace se vrátily k fakturaci');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 5) Práva
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _opr uuid;
BEGIN
  SELECT hodnota::uuid INTO _opr FROM _s WHERE klic = 'opravny';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.dobropis_invoice(%L, ARRAY[%L]::uuid[])', _opr, _opr),
    'jen správce', 'člen dobropis nevystaví');
END $$;
RESET ROLE;

DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.dobropis_invoice(uuid, uuid[], text)', 'EXECUTE'),
    'nepřihlášený už vůbec ne');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_invoices_jedno_plne_storno') = 1,
    'plné storno smí být na doklad jen jedno (index drží)');
END $$;

ROLLBACK;
