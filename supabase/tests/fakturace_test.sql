-- =============================================================================
-- TESTY FAKTURACE — B5 (RPC) + B6 (kontrolní součet)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/fakturace_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ PŘEDEVŠÍM:
-- akceptační kritérium Etapy 2 — „suma vystavených faktur za období == Kdo kolik
-- dluží za totéž období". Všechno ostatní (čísla, immutabilita, práva) je obrana
-- kolem něj.
--
-- POUČENÍ Z A2b: tvrzení o právech se testují pod SKUTEČNOU rolí `authenticated`.
-- Jako `postgres` projde všechno — granty i RLS se na něj nevztahují, takže by
-- test tvrdil zavřeno o dveřích, vedle kterých je otevřené okno.
--
-- Celý soubor běží v transakci a končí ROLLBACKem: vystavené faktury by jinak
-- v seedu zůstaly a další běh by dostal jiná čísla v řadě.
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

-- Přenos hodnot mezi bloky, které běží pod různými rolemi.
CREATE TEMP TABLE _stav (klic text PRIMARY KEY, hodnota text);
GRANT ALL ON _stav TO authenticated;

-- Fakturační údaje haly. Bez nich `issue_invoice` (správně) odmítne vystavit —
-- což se testuje níž jako samostatné tvrzení, proto se plní až za ním.
--
-- Nejdřív se ale VYPRÁZDNÍ, a to schválně: `supabase db reset` je nechá prázdné
-- (migrace A3 je tak zakládá), kdežto po `demo_setup.sql` jsou předvyplněné
-- demo skriptem. Test, který si předpoklad neudělá sám, by pak podle způsobu
-- naseedování jednou procházel a jednou ne — a vypadalo by to jako chyba v kódu.
-- Celý soubor běží v transakci s ROLLBACKem, takže si tím nic nerozbije.
UPDATE public.billing_settings SET
  supplier_name = NULL, supplier_address = NULL, supplier_ico = NULL,
  supplier_dic = NULL, supplier_registry = NULL,
  bank_account = NULL, bank_iban = NULL, payment_message = NULL;
CREATE OR REPLACE FUNCTION pg_temp.vypln_nastaveni() RETURNS void LANGUAGE sql AS $$
  UPDATE public.billing_settings SET
    supplier_name    = 'Curling Promo Ostrava z.s.',
    supplier_address = 'Ledová 1, 700 30 Ostrava',
    supplier_ico     = '12345678',
    bank_account     = '19-2000145399/0800',
    bank_iban        = 'CZ6508000000192000145399',
    payment_message  = 'Pronájem ledu';
$$;

-- -----------------------------------------------------------------------------
-- 0) Výchozí stav: kontrolní součet sedí i když se ještě nic nefakturovalo
--
-- Nula proti nule je taky shoda — a je důležité, aby platila, protože jinak by
-- se každý pozdější rozdíl dal svést na „to už tam bylo".
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _r record; _rozdilnych int := 0; _radku int := 0;
BEGIN
  FOR _r IN SELECT * FROM public.billing_reconcile('2026-07-01', '2026-07-31') LOOP
    _radku := _radku + 1;
    IF _r.rozdil <> 0 THEN _rozdilnych := _rozdilnych + 1; END IF;
    PERFORM pg_temp.tvrd(_r.fakturovano = 0,
      format('%s: před fakturací není nic vyfakturováno', _r.subjekt));
  END LOOP;
  PERFORM pg_temp.tvrd(_radku > 0, 'kontrolní součet vrací data (seed má rezervace v červenci)');
  PERFORM pg_temp.tvrd(_rozdilnych = 0, 'kontrolní součet sedí u všech subjektů před fakturací');
END $$;

-- -----------------------------------------------------------------------------
-- 1) Bez fakturačních údajů se doklad nevystaví (spec, okrajové případy)
--
-- Hláška musí vyjmenovat, CO chybí. „Nelze vystavit" bez důvodu je pro admina
-- slepá ulička — a přesně tohle je moment, kdy se u klienta zasekne první ostrá
-- faktura.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _inv uuid; _hlaska text; _detail text;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  _inv := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');
  INSERT INTO _stav VALUES ('subject', _sub::text), ('invoice', _inv::text);

  BEGIN
    PERFORM public.issue_invoice(_inv);
    RAISE EXCEPTION 'TEST SELHAL: faktura se vystavila bez fakturačních údajů';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS _hlaska = MESSAGE_TEXT, _detail = PG_EXCEPTION_DETAIL;
    IF _hlaska LIKE 'TEST SELHAL%' THEN RAISE; END IF;
  END;

  PERFORM pg_temp.tvrd(position('chybí' in _hlaska) > 0 AND position('dodavatel' in _hlaska) > 0,
    format('bez fakturačních údajů se doklad nevystaví a hláška řekne co chybí (%s)', left(_hlaska, 60)));
  PERFORM pg_temp.tvrd(position('Failing row' in COALESCE(_detail, '')) = 0,
    'odmítnutí nevysype obsah řádku (R11 — v tom řádku je IBAN)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Koncept: zabral rezervace, ale dokladem ještě není
-- -----------------------------------------------------------------------------
DO $$
DECLARE _inv uuid; _f record; _r record;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  SELECT * INTO _f FROM public.invoices WHERE id = _inv;

  PERFORM pg_temp.tvrd(_f.status = 'koncept', 'nová faktura je koncept');
  PERFORM pg_temp.tvrd(_f.cislo IS NULL, 'koncept NEMÁ číslo (jinak by smazání udělalo díru v řadě)');
  PERFORM pg_temp.tvrd(_f.datum_vystaveni IS NULL, 'koncept nemá datum vystavení');
  PERFORM pg_temp.tvrd(_f.subtotal > 0, 'součty konceptu dopočítala databáze z položek');
  PERFORM pg_temp.tvrd(_f.total_rounded = round(round(_f.total, 2), 0),
    'částka k úhradě je round(round(total,2),0) — kanonické pravidlo R3');
  PERFORM pg_temp.tvrd(_f.rounding_amount = _f.total_rounded - _f.total,
    'zaokrouhlovací rozdíl je dopočet, ne samostatná hodnota');

  -- Řádek musí sedět sám se sebou (N3): sazba × hodiny == částka.
  FOR _r IN SELECT * FROM public.invoice_items WHERE invoice_id = _inv LOOP
    PERFORM pg_temp.tvrd(_r.line_total = round(_r.hodiny * _r.sazba, 2),
      format('řádek sedí sám se sebou: %s h × %s Kč = %s Kč', _r.hodiny, _r.sazba, _r.line_total));
  END LOOP;

  PERFORM pg_temp.tvrd(
    (SELECT sum(line_total) FROM public.invoice_items WHERE invoice_id = _inv) = _f.subtotal,
    'mezisoučet faktury je přesný součet řádků');
END $$;

-- Kontrolní součet po založení konceptu: peníze se přesunuly z „k fakturaci"
-- do „v konceptu", ale rovnice pořád platí.
DO $$
DECLARE _r record; _sub uuid;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subject';
  SELECT * INTO _r FROM public.billing_reconcile('2026-07-01', '2026-07-31')
   WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.v_konceptu > 0, 'koncept je vidět ve sloupci v_konceptu');
  PERFORM pg_temp.tvrd(_r.fakturovano = 0, 'koncept se NEpočítá jako vyfakturováno');
  PERFORM pg_temp.tvrd(_r.rozdil = 0, 'kontrolní součet sedí i s otevřeným konceptem');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Souběh: druhý koncept za totéž období nesmí zabrat tytéž rezervace
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subject';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_invoice_draft_club(%L, ''2026-07-01'', ''2026-07-31'')', _sub),
    'není co fakturovat', 'druhý koncept za totéž období nezabere tytéž rezervace');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Vystavení: číslo, VS, splatnost, snapshot
-- -----------------------------------------------------------------------------
RESET ROLE;
SELECT pg_temp.vypln_nastaveni();
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

DO $$
DECLARE _inv uuid; _r jsonb; _f record;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  _r := public.issue_invoice(_inv);
  SELECT * INTO _f FROM public.invoices WHERE id = _inv;

  PERFORM pg_temp.tvrd(_f.status = 'vystaveno', 'doklad je vystavený');
  PERFORM pg_temp.tvrd(_f.cislo ~ '^\d{8}$', format('číslo má tvar RRRRNNNN (%s)', _f.cislo));
  PERFORM pg_temp.tvrd(left(_f.cislo, 4) = EXTRACT(year FROM current_date)::text,
    'číslo začíná aktuálním rokem');
  PERFORM pg_temp.tvrd(_f.variabilni_symbol = regexp_replace(_f.cislo, '\D', '', 'g'),
    'variabilní symbol je číslo bez nečíselných znaků');
  PERFORM pg_temp.tvrd(length(_f.variabilni_symbol) <= 10,
    'variabilní symbol se vejde do 10 číslic');
  PERFORM pg_temp.tvrd(_f.datum_splatnosti = _f.datum_vystaveni + 14,
    'splatnost je 14 dní podle nastavení');

  -- SNAPSHOT: doklad musí být obrazem stavu při vystavení, ne pohledem na dnešek.
  PERFORM pg_temp.tvrd(_f.dodavatel_nazev = 'Curling Promo Ostrava z.s.', 'snapshot dodavatele je na dokladu');
  PERFORM pg_temp.tvrd(_f.dodavatel_iban IS NOT NULL, 'snapshot IBANu je na dokladu (potřebuje ho QR)');
  PERFORM pg_temp.tvrd(_f.odberatel_nazev = 'CK Ostravské kameny', 'snapshot odběratele je na dokladu');
  PERFORM pg_temp.tvrd(_f.vat_mode = 'neplatce', 'režim DPH je zaznamenaný (dnes neplátce)');
  PERFORM pg_temp.tvrd((_r ->> 'cislo') = _f.cislo, 'RPC vrátí totéž číslo, jaké je v dokladu');
END $$;

-- Změna nastavení po vystavení NESMÍ přepsat historii (riziko 5 v plánu).
RESET ROLE;
UPDATE public.billing_settings SET supplier_name = 'Někdo Úplně Jiný s.r.o.';
DO $$
DECLARE _inv uuid; _nazev text;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  SELECT dodavatel_nazev INTO _nazev FROM public.invoices WHERE id = _inv;
  PERFORM pg_temp.tvrd(_nazev = 'Curling Promo Ostrava z.s.',
    'změna fakturačního nastavení nepřepsala už vystavený doklad');
END $$;
SELECT pg_temp.vypln_nastaveni();

-- -----------------------------------------------------------------------------
-- 5) AKCEPTAČNÍ KRITÉRIUM: suma faktur == „Kdo kolik dluží"
--
-- Tohle je věta, kvůli které celá Etapa 2 existuje. Obě strany se schválně
-- počítají z JINÉHO místa: faktura z uloženého řádku dokladu, dluh z aktuální
-- částky rezervace. Kdyby braly ze stejného, sedělo by to vždycky a netestovalo nic.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _r record; _sub uuid;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subject';
  SELECT * INTO _r FROM public.billing_reconcile('2026-07-01', '2026-07-31') WHERE subject_id = _sub;

  PERFORM pg_temp.tvrd(_r.fakturovano > 0, 'po vystavení je co započítat');
  PERFORM pg_temp.tvrd(_r.v_konceptu = 0, 'koncept se vystavením přesunul do vyfakturovaného');
  PERFORM pg_temp.tvrd(_r.rozdil = 0,
    format('AKCEPTAČNÍ KRITÉRIUM: dluží %s = fakturováno %s + k fakturaci %s + neschválené %s',
           _r.dluzi, _r.fakturovano, _r.k_fakturaci, _r.neschvalene));
  -- Když je vyfakturováno všechno schválené, musí prostá rovnost platit taky.
  PERFORM pg_temp.tvrd(_r.k_fakturaci = 0,
    'u tohohle subjektu a období nezůstalo nic k fakturaci');
  PERFORM pg_temp.tvrd(_r.fakturovano = _r.dluzi - _r.neschvalene,
    'suma vystavených faktur == Kdo kolik dluží (bez neschválených, rozhodnutí Q4)');
END $$;

-- Kontrolní součet musí sedět i napříč VŠEMI subjekty a delším obdobím.
DO $$
DECLARE _spatnych int;
BEGIN
  SELECT count(*) INTO _spatnych FROM public.billing_reconcile('2026-01-01', '2026-12-31')
   WHERE rozdil <> 0;
  PERFORM pg_temp.tvrd(_spatnych = 0, 'kontrolní součet sedí za celý rok u všech subjektů');
END $$;

-- -----------------------------------------------------------------------------
-- 6) Immutabilita vystaveného dokladu (rozhodnutí R8)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _inv uuid;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.issue_invoice(%L)', _inv),
    'jen koncept', 'vystavit už vystavený doklad nejde');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.delete_invoice_draft(%L)', _inv),
    'jen koncept', 'vystavený doklad se nemaže');
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.invoices SET odberatel_nazev = ''Podvrh'' WHERE id = %L', _inv),
    'permission denied', 'přímý zápis do faktur je pro authenticated zavřený');
  PERFORM pg_temp.ocekavej_chybu(
    format('INSERT INTO public.invoice_items (invoice_id, popis, hodiny, sazba, line_total) '
           'VALUES (%L, ''Podvrh'', 1, 1, 1)', _inv),
    'permission denied', 'přímý zápis položek je pro authenticated zavřený');
END $$;

-- Táž tvrzení pod databázovou rolí, kde granty neplatí a mluví až guard.
RESET ROLE;
DO $$
DECLARE _inv uuid;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.invoices SET odberatel_nazev = ''Podvrh'' WHERE id = %L', _inv),
    'needituje', 'guard nepustí editaci vystaveného dokladu ani pod postgres');
  PERFORM pg_temp.ocekavej_chybu(
    format('DELETE FROM public.invoices WHERE id = %L', _inv),
    'nemaže', 'guard nepustí smazání vystaveného dokladu');
  PERFORM pg_temp.ocekavej_chybu(
    format('INSERT INTO public.invoice_items (invoice_id, popis, hodiny, sazba, line_total) '
           'VALUES (%L, ''Podvrh'', 1, 1, 1)', _inv),
    'nemění', 'do vystaveného dokladu nejde přidat položku');
END $$;

-- Vazbu rezervace na fakturu nesmí přepsat ani přímý zápis (guard z B1+B2).
DO $$
DECLARE _inv uuid; _rez uuid;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  SELECT id INTO _rez FROM public.reservations WHERE invoice_id = _inv LIMIT 1;
  PERFORM pg_temp.tvrd(_rez IS NOT NULL, 'vyfakturovaná rezervace nese zámek invoice_id');

  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  SET LOCAL ROLE authenticated;
  -- Brání GUARD, ne granty: admin má na rezervace zápis, a je to tak správně.
  -- Zámek fakturace proto stojí NAD adminskou výjimkou (oprava z commitu 87b1f78).
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET invoice_id = NULL WHERE id = %L', _rez),
    'fakturační funkce', 'ani admin neodpojí rezervaci od faktury přímým zápisem');
  RESET ROLE;
END $$;

-- -----------------------------------------------------------------------------
-- 7) Mrtvý muž: `billing_health` pozná nález N1
--
-- Rezervace se po vyfakturování změní (posun, korekce hodin). Doklad je neměnný,
-- takže se obě strany rozejdou — a přesně tohle musí být vidět, ne se ztratit.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _inv uuid; _rez uuid; _h record; _sub uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subject';
  SELECT id INTO _rez FROM public.reservations WHERE invoice_id = _inv ORDER BY start_at LIMIT 1;

  SELECT * INTO _h FROM public.billing_health;
  PERFORM pg_temp.tvrd(_h.rozesle_castky = 0 AND _h.zamek_bez_radku = 0
                       AND _h.spatna_cisla = 0 AND _h.rozesle_soucty = 0,
    'billing_health je před zásahem čistý');

  -- Korekce hodin na už vyfakturované rezervaci.
  UPDATE public.reservations
     SET corrected_hours = 3, correction_reason = 'Test rozejití po vyfakturování'
   WHERE id = _rez;

  SELECT * INTO _h FROM public.billing_health;
  PERFORM pg_temp.tvrd(_h.rozesle_castky = 1,
    'billing_health ohlásí rezervaci, která se po vyfakturování změnila (nález N1)');

  SELECT * INTO _r FROM public.billing_reconcile('2026-07-01', '2026-07-31') WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.rozdil <> 0,
    format('kontrolní součet TAKY přestane sedět (rozdíl %s Kč) — nedá se to přehlédnout', _r.rozdil));

  -- Vrátit zpět, ať následující tvrzení neměří rozbitý stav.
  UPDATE public.reservations SET corrected_hours = NULL, correction_reason = NULL WHERE id = _rez;
  SELECT * INTO _h FROM public.billing_health;
  PERFORM pg_temp.tvrd(_h.rozesle_castky = 0, 'po vrácení korekce je billing_health zase čistý');
END $$;

-- -----------------------------------------------------------------------------
-- 7b) Jediná známá díra v kontrolním součtu: vyfakturovaná rezervace se zrušila
--
-- `billing_reconcile` počítá obě strany rovnice jen z potvrzených rezervací,
-- takže zrušená vyfakturovaná rezervace vypadne z „dluží" i z „fakturováno"
-- naráz — a `rozdil` vyjde 0, přestože vystavený doklad pořád účtuje led, který
-- se nekonal. Právě proto tuhle třídu hlídá `billing_health`, ne rovnice.
--
-- Test to schválně ověřuje z OBOU stran: že rovnice mlčí (a nesmí se na ni tedy
-- spoléhat samotnou) a že mrtvý muž mluví.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _inv uuid; _rez uuid; _sub uuid; _h record; _r record;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subject';
  SELECT id INTO _rez FROM public.reservations WHERE invoice_id = _inv ORDER BY start_at LIMIT 1;

  UPDATE public.reservations
     SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'Test zrušení po vyfakturování'
   WHERE id = _rez;

  SELECT * INTO _r FROM public.billing_reconcile('2026-07-01', '2026-07-31') WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(COALESCE(_r.rozdil, 0) = 0,
    'kontrolní součet tuhle třídu NEVIDÍ (proto se na něj nesmí spoléhat samotný)');

  SELECT * INTO _h FROM public.billing_health;
  PERFORM pg_temp.tvrd(_h.vyfakturovane_zrusene = 1,
    'billing_health ohlásí zrušenou rezervaci na vystaveném dokladu (čeká na dobropis)');

  UPDATE public.reservations
     SET status = 'confirmed', cancelled_at = NULL, cancel_reason = NULL
   WHERE id = _rez;
  SELECT * INTO _h FROM public.billing_health;
  PERFORM pg_temp.tvrd(_h.vyfakturovane_zrusene = 0, 'po obnovení rezervace je mrtvý muž zase zticha');
END $$;

-- -----------------------------------------------------------------------------
-- 7c) Stornovaný doklad nesmí rozbít rovnici napořád
--
-- Rezervace na stornované faktuře drží zámek `invoice_id`, takže není ani
-- „k fakturaci", ani vyfakturovaná. Bez vlastního sloupce by u toho subjektu
-- rovnice nesedla už navždy — a akceptační brána by to četla jako vadu modulu,
-- ne jako stav dokladu. (Storno RPC ještě není; stav se tu nastavuje přímo,
-- což guard u vystavené faktury povoluje — `status` je v jeho whitelistu.)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _inv uuid; _sub uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';
  SELECT hodnota::uuid INTO _sub FROM _stav WHERE klic = 'subject';

  UPDATE public.invoices SET status = 'stornovano' WHERE id = _inv;

  SELECT * INTO _r FROM public.billing_reconcile('2026-07-01', '2026-07-31') WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.ve_stornu > 0, 'storno je vidět ve vlastním sloupci ve_stornu');
  PERFORM pg_temp.tvrd(_r.fakturovano = 0, 'stornovaný doklad se nepočítá jako vyfakturováno');
  PERFORM pg_temp.tvrd(_r.rozdil = 0,
    format('rovnice sedí i se stornovaným dokladem (rozdíl %s)', _r.rozdil));

  UPDATE public.invoices SET status = 'vystaveno' WHERE id = _inv;
END $$;

-- -----------------------------------------------------------------------------
-- 7d) Oddělené číselné řady: raději chyba než doklad se špatným číslem
--
-- Přepínač `separate_series` sám o sobě nic nezmění — `next_invoice_number`
-- počítá nejvyšší použité pořadí přes všechny faktury roku a vydává vždycky
-- `RRRRNNNN`. Zapnutá volba by tedy vyrobila jednu prokládanou řadu ve formátu,
-- který pro tenhle režim ani není povolený. Rozhodnutí PM (Q6) zní „jedna
-- společná řada", takže správná reakce je zastavit se.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _inv uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Curling Ostrava';
  _inv := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');

  UPDATE public.billing_settings SET separate_series = true, number_format = 'RRRRSNNN';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.issue_invoice(%L)', _inv),
    'nejsou implementované', 'se zapnutými oddělenými řadami se doklad nevystaví');

  UPDATE public.billing_settings SET separate_series = false, number_format = 'RRRRNNNN';
  PERFORM public.delete_invoice_draft(_inv);
END $$;

-- -----------------------------------------------------------------------------
-- 7e) Náhled akcí ukazuje TOTÉŽ, co pak faktura zabere
--
-- Akce přes přelom měsíce: dialog v „Kdo dluží" nesmí ukázat jen tu část, která
-- spadla do zobrazeného období, protože `create_invoice_draft_commercial`
-- fakturuje celou akci. Admin by jinak odklikl číslo, které nikdy neviděl.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _akce uuid; _firma uuid; _nahled record; _inv uuid; _skutecnost numeric;
BEGIN
  SELECT e.id, r.subject_id INTO _akce, _firma
    FROM public.events e
    JOIN public.reservations r ON r.event_id = e.id
   WHERE e.event_type = 'commercial' AND r.status = 'confirmed'
     AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL AND r.invoice_id IS NULL
   ORDER BY r.start_at LIMIT 1;
  IF _akce IS NULL THEN
    RAISE NOTICE 'PŘESKOČENO: v seedu nezbyla nevyfakturovaná komerční akce';
    RETURN;
  END IF;

  -- Náhled za JEDEN DEN akce (schválně užší období, než akce zabírá).
  SELECT * INTO _nahled FROM public.nevyfakturovane_akce(
    _firma,
    (SELECT min((r.start_at AT TIME ZONE 'Europe/Prague')::date)
       FROM public.reservations r WHERE r.event_id = _akce),
    (SELECT min((r.start_at AT TIME ZONE 'Europe/Prague')::date)
       FROM public.reservations r WHERE r.event_id = _akce)
  ) WHERE event_id = _akce;
  PERFORM pg_temp.tvrd(_nahled IS NOT NULL, 'náhled akci najde i podle jediného dne');

  _inv := public.create_invoice_draft_commercial(_akce);
  SELECT subtotal INTO _skutecnost FROM public.invoices WHERE id = _inv;

  PERFORM pg_temp.tvrd(_nahled.castka = _skutecnost,
    format('náhled (%s Kč) sedí na to, co faktura opravdu zabrala (%s Kč)', _nahled.castka, _skutecnost));
  PERFORM public.delete_invoice_draft(_inv);
END $$;

-- -----------------------------------------------------------------------------
-- 8) Zahození konceptu odemkne rezervace
--
-- Běží pod databázovou rolí schválně: tvrzení tady je o DATECH (uvolnil se zámek?),
-- ne o právech, a `authenticated` na `reservations` přímo nevidí — tabulkový SELECT
-- jí vzala A2b, protože jsou v ní sazby a částky. Tvrzení o právech má blok 9.
-- SECURITY DEFINER RPC se volají stejně: rozhoduje `auth.uid()` z JWT, ne role spojení.
-- -----------------------------------------------------------------------------
RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _sub uuid; _inv uuid; _uvolneno int; _zbyva int;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Curling Ostrava';
  _inv := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations WHERE invoice_id = _inv) > 0,
    'koncept zabral rezervace');

  _uvolneno := public.delete_invoice_draft(_inv);
  PERFORM pg_temp.tvrd(_uvolneno > 0, format('zahození konceptu uvolnilo %s rezervací', _uvolneno));
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.invoices WHERE id = _inv) = 0,
    'koncept je pryč');

  SELECT count(*) INTO _zbyva FROM public.reservations WHERE invoice_id = _inv;
  PERFORM pg_temp.tvrd(_zbyva = 0, 'po zahození konceptu nedrží zámek žádná rezervace');

  -- A jde založit znovu — jinak by omyl znamenal nevyfakturovaný led navždy.
  _inv := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');
  PERFORM pg_temp.tvrd(_inv IS NOT NULL, 'po zahození jde koncept založit znovu');
  PERFORM public.delete_invoice_draft(_inv);
END $$;

-- -----------------------------------------------------------------------------
-- 8b) Komerční akce: 1 doklad = 1 akce (spec 2A)
--
-- Druhý typ dokladu má vlastní RPC, protože se liší v tom, co určuje období:
-- u klubu ho zadává admin, u akce vychází z akce samotné. Kdyby se to hádalo
-- z parametru, dala by se vystavit faktura za jiný den, než akce proběhla.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _akce uuid; _inv uuid; _f record; _r jsonb; _ocekavano numeric;
BEGIN
  SELECT e.id, sum(COALESCE(r.corrected_amount, r.amount))
    INTO _akce, _ocekavano
    FROM public.events e
    JOIN public.reservations r ON r.event_id = e.id
   WHERE e.event_type = 'commercial' AND r.status = 'confirmed'
     AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL AND r.invoice_id IS NULL
   GROUP BY e.id
   HAVING count(*) > 1
   ORDER BY min(r.start_at) LIMIT 1;
  PERFORM pg_temp.tvrd(_akce IS NOT NULL, 'seed má komerční akci o víc než jedné rezervaci');

  _inv := public.create_invoice_draft_commercial(_akce);
  SELECT * INTO _f FROM public.invoices WHERE id = _inv;

  PERFORM pg_temp.tvrd(_f.kind = 'komercni', 'faktura za akci je typu komercni');
  PERFORM pg_temp.tvrd(_f.event_id = _akce, 'faktura je navázaná na akci');
  PERFORM pg_temp.tvrd(_f.subtotal = _ocekavano,
    format('částka za akci sedí (%s Kč)', _f.subtotal));
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.invoice_items WHERE invoice_id = _inv) > 1,
    'akce na dvou drahách má na dokladu víc řádků');
  PERFORM pg_temp.tvrd(_f.obdobi_od = (SELECT min((r.start_at AT TIME ZONE 'Europe/Prague')::date)
                                         FROM public.reservations r WHERE r.invoice_id = _inv),
    'období dokladu vychází z akce, ne z parametru');

  -- Odběratelem komerční akce je firma, a ta MÁ mít IČO (spec, náležitosti).
  _r := public.issue_invoice(_inv);
  SELECT * INTO _f FROM public.invoices WHERE id = _inv;
  PERFORM pg_temp.tvrd(_f.odberatel_ico IS NOT NULL, 'na dokladu firmy je IČO odběratele');
  PERFORM pg_temp.tvrd(_f.cislo <> (SELECT cislo FROM public.invoices
                                     WHERE id = (SELECT hodnota::uuid FROM _stav WHERE klic = 'invoice')),
    'druhý doklad dostal jiné číslo než první');

  -- Řada musí být souvislá: dvě faktury = dvě po sobě jdoucí čísla.
  PERFORM pg_temp.tvrd(
    (SELECT count(DISTINCT cislo) FROM public.invoices WHERE cislo IS NOT NULL) =
    (SELECT count(*) FROM public.invoices WHERE cislo IS NOT NULL),
    'žádná dvě čísla faktur nejsou stejná');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_invoice_draft_commercial(%L)', _akce),
    'vyfakturovaná', 'druhá faktura za tutéž akci už nemá co zabrat');
END $$;

-- Firma bez IČO se nevyfakturuje (spec, okrajové případy), klub ano —
-- spolky ho v systému běžně vyplněné nemají a zablokovat jim fakturu by
-- znamenalo nevyfakturovat led.
DO $$
DECLARE _akce uuid; _inv uuid; _firma uuid; _puvodni text;
BEGIN
  SELECT e.id INTO _akce
    FROM public.events e
    JOIN public.reservations r ON r.event_id = e.id
   WHERE e.event_type = 'commercial' AND r.status = 'confirmed'
     AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL AND r.invoice_id IS NULL
   ORDER BY r.start_at LIMIT 1;
  IF _akce IS NULL THEN
    RAISE NOTICE 'PŘESKOČENO: v seedu nezbyla nevyfakturovaná komerční akce';
    RETURN;
  END IF;

  _inv := public.create_invoice_draft_commercial(_akce);
  SELECT subject_id INTO _firma FROM public.invoices WHERE id = _inv;
  SELECT ico INTO _puvodni FROM public.subjects WHERE id = _firma;

  UPDATE public.subjects SET ico = NULL WHERE id = _firma;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.issue_invoice(%L)', _inv),
    'IČO odběratele', 'firma bez IČO se nevyfakturuje');

  UPDATE public.subjects SET ico = _puvodni WHERE id = _firma;
  PERFORM public.delete_invoice_draft(_inv);
END $$;

-- -----------------------------------------------------------------------------
-- 9) Práva: fakturační RPC nesmí být dosažitelné pro ne-admina
--
-- Pod SKUTEČNOU rolí, ne jako postgres. Člen je `authenticated` úplně stejně
-- jako admin — jediné, co je dělí, je `has_role` uvnitř funkce.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _sub uuid; _inv uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  SELECT hodnota::uuid INTO _inv FROM _stav WHERE klic = 'invoice';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_invoice_draft_club(%L, ''2026-07-01'', ''2026-07-31'')', _sub),
    'jen správce', 'člen nezaloží fakturu');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.issue_invoice(%L)', _inv),
    'jen správce', 'člen nevystaví fakturu');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.delete_invoice_draft(%L)', _inv),
    'jen správce', 'člen nezahodí fakturu');
  PERFORM pg_temp.ocekavej_chybu(
    'SELECT * FROM public.billing_reconcile(''2026-07-01'', ''2026-07-31'')',
    'jen správce', 'člen nevidí kontrolní součet');

  -- Čtení faktur drží RLS, ne jen RPC.
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.invoices) = 0,
    'člen nevidí ani jednu fakturu (RLS invoices_select_admin)');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.invoice_items) = 0,
    'člen nevidí ani jednu položku faktury');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.invoices_list) = 0,
    'člen nevidí nic ani přes pohled invoices_list (security_invoker = on)');
END $$;
RESET ROLE;

-- Kontrolní součet nesmí vydat peníze tomu, kdo je jen `authenticated` bez `sub`
-- v tokenu. Výjimka uvnitř `billing_reconcile` je JEN pro běh pod databázovou
-- rolí (pg_cron ve fázi D), a musí stát na `session_user`, ne jen na prázdném
-- `auth.uid()`.
--
-- POD ROLÍ TO TADY OTESTOVAT NEJDE: `SET LOCAL ROLE` mění `current_user`, ale
-- `session_user` zůstává `postgres`, takže by test spadl do cronové větve a
-- tvrdil otevřeno tam, kde je zavřeno. Ověřuje se proto skutečným připojením
-- jako `authenticator` (tak se připojuje PostgREST) — příkaz je tady, ať ho
-- příští čtenář nemusí vymýšlet:
--
--   docker exec -e PGPASSWORD=postgres -i supabase_db_<project> \
--     psql -h 127.0.0.1 -U authenticator -d postgres -X -q -c \
--     "BEGIN; SET LOCAL ROLE authenticated;
--      SET LOCAL request.jwt.claims = '{\"role\":\"authenticated\"}';
--      SELECT count(*) FROM public.billing_reconcile('2026-07-01','2026-07-31'); ROLLBACK;"
--
--   → musí skončit „Kontrolní součet fakturace vidí jen správce haly."
--
-- Tady se aspoň přišpendlí, že se ta podmínka z funkce neztratí.
DO $$
DECLARE _def text;
BEGIN
  SELECT pg_get_functiondef('public.billing_reconcile(date, date)'::regprocedure) INTO _def;
  PERFORM pg_temp.tvrd(position('session_user' in _def) > 0,
    'billing_reconcile váže cronovou výjimku na session_user, ne jen na prázdné auth.uid()');
END $$;

-- Servisní klíč nesmí obejít admina: `service_role` ignoruje RLS, takže kdyby
-- na fakturační RPC dosáhl, vystaví doklad kdokoli s tím klíčem.
DO $$
DECLARE _chybne text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO _chybne
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('create_invoice_draft_club', 'create_invoice_draft_commercial',
                       'issue_invoice', 'delete_invoice_draft', 'billing_reconcile',
                       'fakturovatelne_rezervace', 'next_invoice_number')
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('service_role', p.oid, 'EXECUTE'));
  PERFORM pg_temp.tvrd(_chybne IS NULL,
    format('fakturační RPC jsou zavřené pro anon i service_role (%s)', COALESCE(_chybne, 'všechny')));
END $$;

ROLLBACK;
