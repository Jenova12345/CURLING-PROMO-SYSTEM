-- =============================================================================
-- TESTY STORNA VYSTAVENÉHO DOKLADU (opravný doklad)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/storno_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ PŘEDEVŠÍM:
-- že po stornu SEDÍ KONTROLNÍ SOUČET. Storno rovnici rozbíjí samo od sebe —
-- uvolněná rezervace se počítá jednou jako `ve_stornu` a podruhé jako
-- `k_fakturaci`. Před opravou vycházelo `rozdil = -22 600`. Všechno ostatní
-- (čísla, immutabilita, práva) je obrana kolem téhle jedné věty.
--
-- PRAVIDLO 8: tvrzení o právech běží pod SKUTEČNOU rolí `authenticated`.
-- Jako `postgres` projde všechno, takže by test tvrdil zavřeno o dveřích,
-- vedle kterých je otevřené okno.
--
-- Celý soubor běží v transakci a končí ROLLBACKem: vystavené faktury by jinak
-- zůstaly v seedu a další běh by dostal jiná čísla v řadě.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale prošla', _popis;
END $$;

CREATE TEMP TABLE _stav (klic text primary key, hodnota text);
-- Přenáší hodnoty mezi bloky, které běží pod rolí `authenticated` — bez grantu
-- na ni role nedosáhne a test spadne na vlastní pomůcce, ne na tvrzení.
GRANT SELECT, INSERT ON _stav TO authenticated;

-- Subjekt s nejvíc nevyfakturovanými rezervacemi + období, do kterého padnou.
DO $$
DECLARE _sub uuid;
BEGIN
  SELECT r.subject_id INTO _sub FROM public.reservations r
   WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
     AND r.invoice_id IS NULL AND COALESCE(r.corrected_amount, r.amount) > 0
   GROUP BY r.subject_id ORDER BY count(*) DESC LIMIT 1;
  IF _sub IS NULL THEN
    RAISE EXCEPTION 'ODMÍTNUTO: v seedu není subjekt s nevyfakturovanými rezervacemi.';
  END IF;
  INSERT INTO _stav VALUES ('subjekt', _sub::text), ('od', '2026-07-01'), ('do', '2026-08-31');
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: po stornu sedí kontrolní součet
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _sub uuid; _od date; _do date; _fid uuid; _res jsonb; _r record; _cislo text;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subjekt';
  SELECT hodnota::date INTO _od  FROM _stav WHERE klic = 'od';
  SELECT hodnota::date INTO _do  FROM _stav WHERE klic = 'do';

  _fid := public.create_invoice_draft_club(_sub, _od, _do);
  PERFORM public.issue_invoice(_fid);
  SELECT cislo INTO _cislo FROM public.invoices WHERE id = _fid;

  SELECT rozdil INTO _r FROM public.billing_reconcile(_od, _do) WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.rozdil = 0, 'před stornem kontrolní součet sedí');

  _res := public.storno_invoice(_fid, 'Klub akci odvolal.');
  INSERT INTO _stav VALUES ('faktura', _fid::text), ('opravny', _res->>'opravny_id');

  -- TOHLE JE TA VĚTA, KVŮLI KTERÉ SOUBOR EXISTUJE.
  SELECT fakturovano, ve_stornu, k_fakturaci, rozdil INTO _r
    FROM public.billing_reconcile(_od, _do) WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.rozdil = 0,
    format('PO STORNU kontrolní součet sedí (rozdil=%s, fakturovano=%s, ve_stornu=%s, k_fakturaci=%s)',
           _r.rozdil, _r.fakturovano, _r.ve_stornu, _r.k_fakturaci));
  PERFORM pg_temp.tvrd(_r.fakturovano = 0,
    'stornovaný doklad se přestal počítat jako vyfakturovaný');
  PERFORM pg_temp.tvrd(_r.ve_stornu = 0,
    'a jeho řádky nezůstaly viset ve `ve_stornu` (rezervace se uvolnily)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Co po stornu zůstalo v datech
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _opr uuid; _p record; _o record; _polozek int; _radku int;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _stav WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _opr FROM _stav WHERE klic = 'opravny';

  SELECT * INTO _p FROM public.invoices WHERE id = _fid;
  SELECT * INTO _o FROM public.invoices WHERE id = _opr;

  PERFORM pg_temp.tvrd(_p.status = 'stornovano', 'původní doklad je ve stavu stornovano');
  PERFORM pg_temp.tvrd(_p.cislo IS NOT NULL, 'a číslo si ponechal (v řadě nevzniká díra)');
  PERFORM pg_temp.tvrd(_o.opravuje_id = _fid, 'opravný doklad ukazuje na původní');
  PERFORM pg_temp.tvrd(_o.status = 'vystaveno', 'a je vystavený');
  PERFORM pg_temp.tvrd(_o.cislo IS NOT NULL AND _o.cislo <> _p.cislo,
    'má vlastní číslo z téže řady');
  PERFORM pg_temp.tvrd(_o.storno_duvod = 'Klub akci odvolal.',
    'nese důvod storna, ať se dá dohledat proč');
  PERFORM pg_temp.tvrd(_o.total = _p.total,
    'a zní na tutéž částku jako originál');

  -- Položky originálu zůstávají — vystavený doklad je historie, nemaže se.
  SELECT count(*) INTO _polozek FROM public.invoice_items WHERE invoice_id = _fid;
  SELECT count(*) INTO _radku   FROM public.invoice_items WHERE invoice_id = _opr;
  PERFORM pg_temp.tvrd(_polozek > 0, 'položky původního dokladu se nesmazaly');
  PERFORM pg_temp.tvrd(_radku = _polozek, 'opravný doklad je zrcadlí jedna ku jedné');
END $$;
RESET ROLE;

-- Uvolnění rezervací se kontroluje mimo roli `authenticated` — ta na
-- `reservations` nemá tabulkový grant a čte je jen přes pohledy a RPC.
DO $$
DECLARE _fid uuid; _opr uuid;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _stav WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _opr FROM _stav WHERE klic = 'opravny';

  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.reservations WHERE invoice_id = _fid),
    'žádná rezervace už na stornovaném dokladu nevisí');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.reservations r
                 JOIN public.invoice_items it ON it.reservation_id = r.id
                WHERE it.invoice_id = _opr AND r.invoiced_at IS NOT NULL),
    'a nezůstalo jim ani razítko `invoiced_at`');
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 3) Zdravotní počítadlo vidí do místa, kam rovnice nevidí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _h record;
BEGIN
  SELECT * INTO _h FROM public.billing_health();
  PERFORM pg_temp.tvrd(_h.opravne_nesedi = 0, 'opravný doklad sedí s originálem');
  -- Storno je NÁPRAVA vyfakturované zrušené rezervace, ne její další výskyt.
  -- Kdyby se opravné doklady z tohohle počítadla nevyloučily, hlásilo by po
  -- stornu pořád totéž a admin by opravoval už opravené.
  PERFORM pg_temp.tvrd(_h.vyfakturovane_zrusene = 0,
    'a nehlásí se jako „vyfakturovaná zrušená rezervace"');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Co se stornovat NESMÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _opr uuid; _sub uuid; _od date; _do date; _koncept uuid;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _stav WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _opr FROM _stav WHERE klic = 'opravny';
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subjekt';
  SELECT hodnota::date INTO _od  FROM _stav WHERE klic = 'od';
  SELECT hodnota::date INTO _do  FROM _stav WHERE klic = 'do';

  PERFORM pg_temp.ocekavej_chybu(format('SELECT public.storno_invoice(%L)', _fid),
    'už stornovaný', 'dvakrát stornovat nejde (jinak by se vrátilo dvakrát)');

  PERFORM pg_temp.ocekavej_chybu(format('SELECT public.storno_invoice(%L)', _opr),
    'sám nestornuje', 'opravný doklad se sám nestornuje');

  PERFORM pg_temp.ocekavej_chybu(format('SELECT public.storno_invoice(%L)', gen_random_uuid()),
    'neexistuje', 'neexistující doklad se odmítne');

  -- Koncept ještě dokladem není — zahazuje se, nestornuje.
  _koncept := public.create_invoice_draft_club(_sub, _od, _do);
  IF _koncept IS NOT NULL THEN
    PERFORM pg_temp.ocekavej_chybu(format('SELECT public.storno_invoice(%L)', _koncept),
      'Koncept se nestornuje', 'koncept se nestornuje, zahazuje se');
    PERFORM public.delete_invoice_draft(_koncept);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 5) Storno ZAPLACENÉ faktury (rozhodnutí PM: pouštět)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _od date; _do date; _fid uuid; _res jsonb; _r record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subjekt';
  SELECT hodnota::date INTO _od  FROM _stav WHERE klic = 'od';
  SELECT hodnota::date INTO _do  FROM _stav WHERE klic = 'do';

  _fid := public.create_invoice_draft_club(_sub, _od, _do);
  IF _fid IS NULL THEN RETURN; END IF;   -- už není co fakturovat
  PERFORM public.issue_invoice(_fid);
  PERFORM public.mark_invoice_paid(_fid, (now() AT TIME ZONE 'Europe/Prague')::date);

  _res := public.storno_invoice(_fid, 'Zaplaceno omylem dvakrát.');
  PERFORM pg_temp.tvrd(_res->>'opravny_cislo' IS NOT NULL,
    'zaplacenou fakturu jde stornovat (rozhodnutí PM)');

  PERFORM pg_temp.tvrd(
    (SELECT datum_uhrady FROM public.invoices WHERE id = _fid) IS NOT NULL,
    'a datum úhrady na ní zůstalo (peníze opravdu přišly)');

  SELECT rozdil INTO _r FROM public.billing_reconcile(_od, _do) WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.rozdil = 0, 'kontrolní součet sedí i po stornu zaplacené faktury');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 6) Práva — pod SKUTEČNOU rolí, jinak test nehlídá nic (pravidlo 8)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _fid uuid;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _stav WHERE klic = 'faktura';

  PERFORM pg_temp.ocekavej_chybu(format('SELECT public.storno_invoice(%L)', _fid),
    'jen správce', 'člen doklad nestornuje');

  -- Přímé cesty kolem RPC. RLS u UPDATE NEHÁZÍ CHYBU, jen odfiltruje řádky,
  -- takže se tvrdí i to, že se nic nezměnilo — „nespadlo to" tady nic neznamená.
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.invoices SET status = ''stornovano'' WHERE id = %L', _fid),
    'permission denied', 'ani si stav dokladu nepřepíše přímo');
END $$;
RESET ROLE;

DO $$
DECLARE _fid uuid; _n int;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _stav WHERE klic = 'faktura';
  -- Guard na rezervacích: uvolnit zámek smí jen fakturační RPC, ani admin ne.
  SELECT count(*) INTO _n FROM public.invoices WHERE id = _fid AND status = 'stornovano';
  PERFORM pg_temp.tvrd(_n = 1, 'a doklad zůstal v tom stavu, do kterého ho dalo storno');

  PERFORM pg_temp.tvrd(
    has_function_privilege('authenticated', 'public.storno_invoice(uuid, text)', 'EXECUTE'),
    'RPC je spustitelné pro přihlášené (uvnitř si ověří admina)');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.storno_invoice(uuid, text)', 'EXECUTE'),
    'a nepřihlášený ho nespustí vůbec');
END $$;

-- -----------------------------------------------------------------------------
-- 7) Auditní stopa — „musí být vidět, kdo co zadával"
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _opr uuid; _n int;
BEGIN
  SELECT hodnota::uuid INTO _fid FROM _stav WHERE klic = 'faktura';
  SELECT hodnota::uuid INTO _opr FROM _stav WHERE klic = 'opravny';

  SELECT count(*) INTO _n FROM public.audit_log
   WHERE table_name = 'invoices' AND record_id = _fid AND action = 'update'
     AND changed_by = '11111111-1111-1111-1111-111111111111';
  PERFORM pg_temp.tvrd(_n > 0, 'storno je v auditu i s tím, kdo ho udělal');

  SELECT count(*) INTO _n FROM public.audit_log
   WHERE table_name = 'invoices' AND record_id = _opr AND action = 'insert';
  PERFORM pg_temp.tvrd(_n > 0, 'vznik opravného dokladu taky');
END $$;

ROLLBACK;
