-- =============================================================================
-- ZÁMEK PŘÍJEMCE NA FAKTUROIDÍM DOKLADU — testy k migraci 20260914220000
-- =============================================================================
--
-- Hlídá OBĚ cesty a OBĚ strany každé z nich:
--   A) přímý UPDATE `reservations.subject_id`  … zavřeno s dokladem, OTEVŘENO bez
--   B) `fakturoid_zkus_zabrat`                 … zavřeno s cizím podkladem, OTEVŘENO se svým
--
-- „Otevřeno bez dokladu" je tu stejně důležité jako „zavřeno s ním". Zámek,
-- který zakáže i legitimní přehození klubu, by zastavil `zmen_firmu_akce`
-- a s ním normální provoz — a mutační test, který měří jen zákaz, by to
-- odbil zeleně.
--
-- VŠECHNO POD REÁLNÝM TOKENEM ADMINA (`SET LOCAL ROLE authenticated` +
-- `request.jwt.claims`). Jako `postgres` obchází guard i RLS výjimka hned
-- na začátku `guard_reservation_rep_changes`, takže by test tvrdil zavřeno
-- o dveřích, které vůbec neotevíral. CLAUDE.md, pravidlo 3 a 9.
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

-- Kulisy: rezervace klubu A (BEZ fakturoidího dokladu) a jiný subjekt B.
CREATE TEMP TABLE t_kul AS
WITH a AS (
  SELECT r.id, r.subject_id, r.event_id, COALESCE(r.corrected_amount, r.amount) AS castka
    FROM public.reservations r
   WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
     AND COALESCE(r.corrected_amount, r.amount) > 0
     AND NOT EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations f
                      WHERE f.reservation_id = r.id)
   ORDER BY r.start_at DESC, r.id LIMIT 1
), b AS (
  SELECT s.id FROM public.subjects s, a
   WHERE s.id <> a.subject_id AND s.deleted_at IS NULL ORDER BY s.id LIMIT 1
), adm AS (
  SELECT ur.user_id FROM public.user_roles ur WHERE ur.role = 'admin' ORDER BY ur.user_id LIMIT 1
)
SELECT a.id AS ra, a.subject_id AS sa, a.castka AS ca, b.id AS sb, adm.user_id AS admin
  FROM a, b, adm;

DO $$
DECLARE _k record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.tvrd(_k.ra IS NOT NULL,    'kulisa) je rezervace bez fakturoidího dokladu');
  PERFORM pg_temp.tvrd(_k.sb IS NOT NULL,    'kulisa) je druhý subjekt, na který jde přehodit');
  PERFORM pg_temp.tvrd(_k.sa <> _k.sb,       'kulisa) a ty subjekty jsou různé');
  PERFORM pg_temp.tvrd(_k.admin IS NOT NULL, 'kulisa) je reálný admin, pod kterým se testuje');
END $$;

-- `_vystaveny` rozlišuje DVA RŮZNÉ STAVY, ne kosmetiku:
--   true  → provider_invoice_id je vyplněné; takový doklad NEJDE uvolnit
--           (CHECK `fakturoid_uvolneni_jen_bez_dokladu`) a zámek je trvalý.
--   false → jen zabraný claim; `fakturoid_uvolni_zabrani` ho pustí a vazby smaže.
-- Původní verze téhle kulisy uměla jen ten první a test A5 na tom spadl —
-- testoval cestu ven na dokladu, který ji ze zákona nemá.
CREATE OR REPLACE FUNCTION pg_temp.doklad(_id uuid, _prijemce uuid, _suma numeric, _rez uuid[],
                                          _vystaveny boolean DEFAULT true)
 RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.fakturoid_invoices (id, idempotency_key, druh, subject_id, nas_soucet,
         radku, rezervace, rezim, provider_invoice_id, cislo, vystaveno_at)
  VALUES (_id, 'TEST-zamek-' || _id::text, 'club_monthly', _prijemce, round(_suma, 0),
          cardinality(_rez), _rez, 'koncept',
          CASE WHEN _vystaveny THEN 'PROV-' || left(_id::text, 8) END,
          CASE WHEN _vystaveny THEN 'T-' || left(_id::text, 8) END,
          CASE WHEN _vystaveny THEN now() END);
  INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
  SELECT _id, r FROM unnest(_rez) AS r;
END $$;

-- ===========================================================================
-- A1) S FAKTUROIDÍM DOKLADEM SE ODBĚRATEL PŘEHODIT NESMÍ
-- ===========================================================================
SAVEPOINT a1;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fb00000-0000-0000-0000-00000000a001', _k.sa, _k.ca, ARRAY[_k.ra]);

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
    UPDATE public.reservations SET subject_id = _k.sb WHERE id = _k.ra;
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(NOT _preslo,
    'A1a) přímý UPDATE subject_id nad vyfakturovanou rezervací NEPROJDE');
  PERFORM pg_temp.tvrd(_hlaska LIKE '%dokladu z Fakturoidu%',
    'A1b) a řekne proč — hláška mluví o fakturoidím dokladu, ne o právech');
  -- Hláška musí ukázat cestu ven, jinak je zámek slepá ulička.
  PERFORM pg_temp.tvrd(_hlaska IS NOT NULL,
    'A1c) hláška vůbec dorazila');
  PERFORM pg_temp.tvrd(
    (SELECT subject_id FROM public.reservations WHERE id = _k.ra) = _k.sa,
    'A1d) a rezervace opravdu zůstala u původního odběratele');
END $$;
ROLLBACK TO a1;

-- ===========================================================================
-- A2) BEZ DOKLADU SE ODBĚRATEL PŘEHODIT MUSÍ (jinak je zámek přes cíl)
-- ===========================================================================
SAVEPOINT a2;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
    UPDATE public.reservations SET subject_id = _k.sb WHERE id = _k.ra;
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(_preslo,
    'A2a) legitimní přehození u rezervace BEZ dokladu dál projde (zámek '
    || 'nezavřel provoz). Hláška: ' || COALESCE(_hlaska, '—'));
  PERFORM pg_temp.tvrd(
    (SELECT subject_id FROM public.reservations WHERE id = _k.ra) = _k.sb,
    'A2b) a odběratel se opravdu změnil');
END $$;
ROLLBACK TO a2;

-- ===========================================================================
-- A3) ZÁMEK SE TÝKÁ JEN ODBĚRATELE, NE VŠECH ZMĚN
--     Vyfakturovanou rezervaci musí jít dál editovat jinak (třeba poznámka).
--     Kdyby zámek zakázal všechno, nešlo by na dokladu nic doupravit.
-- ===========================================================================
SAVEPOINT a3;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fb00000-0000-0000-0000-00000000a003', _k.sa, _k.ca, ARRAY[_k.ra]);
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
    UPDATE public.reservations SET note = 'TEST-zamek-poznamka' WHERE id = _k.ra;
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;
  PERFORM pg_temp.tvrd(_preslo,
    'A3) jiná změna na vyfakturované rezervaci dál projde. Hláška: ' || COALESCE(_hlaska, '—'));
END $$;
ROLLBACK TO a3;

-- ===========================================================================
-- A4) PŘEHOZENÍ NA „ŽÁDNÝ ODBĚRATEL" JE TAKY ROZEJITÍ S HLAVIČKOU
-- ===========================================================================
SAVEPOINT a4;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fb00000-0000-0000-0000-00000000a004', _k.sa, _k.ca, ARRAY[_k.ra]);
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
    UPDATE public.reservations SET subject_id = NULL WHERE id = _k.ra;
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(NOT _preslo,
    'A4a) ani přehození na NULL (bez odběratele) neprojde — IS DISTINCT FROM kryje i tuhle stranu');

  -- HLÁŠKA SE MUSÍ OVĚŘIT, JINAK TENHLE SCÉNÁŘ NEMĚŘÍ NIC.
  -- Změřeno 14. 9. 2026: původní verze jen zahodila chybu (`WHEN OTHERS THEN NULL`)
  -- a byla zelená i se zámkem zmutovaným na `<>`, u kterého NULL propadne —
  -- protože přehození na NULL tak jako tak shodí nesouvisející CHECK
  -- `reservations_cenove_pasma_sedi`. Scénář tedy tvrdil „zámek drží" o pádu,
  -- který se zámkem neměl co do činění. BEFORE trigger běží před kontrolou
  -- constraintů, takže se správným kódem přijde nejdřív ta naše hláška.
  PERFORM pg_temp.tvrd(_hlaska LIKE '%dokladu z Fakturoidu%',
    'A4b) a spadne to na NAŠEM zámku, ne na cenových pásmech. Hláška: '
    || COALESCE(_hlaska, '—'));
END $$;
ROLLBACK TO a4;

-- ===========================================================================
-- A5) ZABRANÝ (NEVYSTAVENÝ) DOKLAD — uvolnění zámek zase otevře
--     Tady cesta ven opravdu je a hláška na ni ukazuje.
-- ===========================================================================
SAVEPOINT a5;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text; _uvolneno boolean;
BEGIN
  SELECT * INTO _k FROM t_kul;
  -- `_vystaveny => false`: jen zabraný claim, tedy ten stav, který JDE uvolnit.
  PERFORM pg_temp.doklad('0fb00000-0000-0000-0000-00000000a005', _k.sa, _k.ca, ARRAY[_k.ra], false);

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);

  -- Nejdřív ověřit, že zámek DRŽÍ i u nevystaveného dokladu…
  BEGIN
    UPDATE public.reservations SET subject_id = _k.sb WHERE id = _k.ra;
  EXCEPTION WHEN OTHERS THEN _hlaska := SQLERRM;
  END;
  PERFORM pg_temp.tvrd(_hlaska IS NOT NULL,
    'A5a) zámek drží i u zabraného (nevystaveného) dokladu');

  SELECT public.fakturoid_uvolni_zabrani(
    'TEST-zamek-0fb00000-0000-0000-0000-00000000a005', 'test cesty ven') INTO _uvolneno;
  PERFORM pg_temp.tvrd(_uvolneno, 'A5b) zabraný doklad se uvolnit dá');

  BEGIN
    UPDATE public.reservations SET subject_id = _k.sb WHERE id = _k.ra;
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN _hlaska := SQLERRM;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(_preslo,
    'A5c) …a po uvolnění jde odběratele změnit — u zabraného dokladu zámek '
    || 'není slepá ulička. Hláška: ' || COALESCE(_hlaska, '—'));
END $$;
ROLLBACK TO a5;

-- ===========================================================================
-- A6) VYSTAVENÝ DOKLAD — zámek je TRVALÝ a hláška to musí přiznat
--
--     Změřeno 14. 9. 2026: vystavený fakturoidí doklad neuvolní nic.
--     `fakturoid_uvolni_zabrani` ho odmítá (CHECK `fakturoid_uvolneni_jen_bez_dokladu`),
--     `storno_invoice`/`dobropis_invoice` se fakturoidích tabulek netýkají
--     a vazební tabulka nemá grant pro `authenticated`.
--     Zámek je tím pádem trvalý — to je v pořádku (rozhodnutí PM), ale hláška
--     nesmí slibovat postup, který neexistuje. Právě na tomhle spadla první
--     verze, která radila „storno nebo dobropis" i tady.
-- ===========================================================================
SAVEPOINT a6;
DO $$
DECLARE _k record; _hlaska text; _hint text; _uvolneno boolean;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.doklad('0fb00000-0000-0000-0000-00000000a006', _k.sa, _k.ca, ARRAY[_k.ra], true);

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);

  SELECT public.fakturoid_uvolni_zabrani(
    'TEST-zamek-0fb00000-0000-0000-0000-00000000a006', 'pokus') INTO _uvolneno;
  PERFORM pg_temp.tvrd(NOT _uvolneno,
    'A6a) vystavený doklad se uvolnit NEDÁ (kdyby šel, byl by tenhle scénář zbytečný)');

  BEGIN
    UPDATE public.reservations SET subject_id = _k.sb WHERE id = _k.ra;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS _hlaska = MESSAGE_TEXT, _hint = PG_EXCEPTION_HINT;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(_hlaska LIKE '%VYSTAVENÉM%',
    'A6b) hláška u vystaveného dokladu se liší od té u zabraného');
  PERFORM pg_temp.tvrd(_hint NOT LIKE '%fakturoid_uvolni_zabrani%',
    'A6c) a NERADÍ uvolnit doklad — to u vystaveného nefunguje');
  PERFORM pg_temp.tvrd(_hint LIKE '%dobropis%' AND _hint LIKE '%servisní%',
    'A6d) místo toho ukáže na Fakturoid a servisní zásah');
END $$;
ROLLBACK TO a6;

-- ===========================================================================
-- B1) CLAIM S CIZÍM PODKLADEM NEPROJDE
-- ===========================================================================
SAVEPOINT b1;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
  BEGIN
    -- hlavička na KLUB B, podklad rezervace KLUBU A
    PERFORM public.fakturoid_zkus_zabrat('TEST-zamek-b1', 'club_monthly', _k.sb, NULL,
      '2026-01-01', '2026-12-31', _k.ca, 1, 'koncept', ARRAY[_k.ra]);
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(NOT _preslo,
    'B1a) claim s hlavičkou na jiný subjekt, než komu patří podklad, NEPROJDE');
  PERFORM pg_temp.tvrd(_hlaska LIKE '%jiný subjekt%',
    'B1b) a řekne proč');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.fakturoid_invoices WHERE idempotency_key = 'TEST-zamek-b1'),
    'B1c) a žádná hlavička po sobě nezůstala');
END $$;
ROLLBACK TO b1;

-- ===========================================================================
-- B2) CLAIM SE SVÝM PODKLADEM PROJDE (jinak je zámek přes cíl)
-- ===========================================================================
SAVEPOINT b2;
DO $$
DECLARE _k record; _vysledek boolean; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
  BEGIN
    SELECT public.fakturoid_zkus_zabrat('TEST-zamek-b2', 'club_monthly', _k.sa, NULL,
      '2026-01-01', '2026-12-31', _k.ca, 1, 'koncept', ARRAY[_k.ra]) INTO _vysledek;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;

  PERFORM pg_temp.tvrd(COALESCE(_vysledek, false),
    'B2a) claim se správným příjemcem dál projde. Hláška: ' || COALESCE(_hlaska, '—'));
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations fr
             JOIN public.fakturoid_invoices fi ON fi.id = fr.fakturoid_invoice_id
            WHERE fi.idempotency_key = 'TEST-zamek-b2' AND fr.reservation_id = _k.ra),
    'B2b) a vazba na rezervaci vznikla');
END $$;
ROLLBACK TO b2;

-- ===========================================================================
-- B3) NEEXISTUJÍCÍ REZERVACE V PODKLADU — fail-closed
--     Bez téhle větve by to spadlo až na cizí klíč, s hláškou, ze které
--     není poznat, co se stalo.
-- ===========================================================================
SAVEPOINT b3;
DO $$
DECLARE _k record; _preslo boolean := false; _hlaska text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _k.admin, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.fakturoid_zkus_zabrat('TEST-zamek-b3', 'club_monthly', _k.sa, NULL,
      '2026-01-01', '2026-12-31', _k.ca, 1, 'koncept',
      ARRAY['00000000-0000-0000-0000-0000000000ff'::uuid]);
    _preslo := true;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;
  PERFORM pg_temp.tvrd(NOT _preslo,
    'B3a) claim s rezervací, která neexistuje, NEPROJDE');
  PERFORM pg_temp.tvrd(_hlaska LIKE '%jiný subjekt%',
    'B3b) a spadne na našem zámku, ne až na cizím klíči');
END $$;
ROLLBACK TO b3;

ROLLBACK;
