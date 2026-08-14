-- =============================================================================
-- Evidence úhrady — „Označit jako zaplaceno" (výřez z E2)
-- =============================================================================
-- Klient chce v seznamu faktur vidět, co je zaplacené, a umět to jedním klikem
-- zapsat. Plná evidence plateb (E2) je vlastní tabulka `invoice_payments`
-- s částečnými úhradami a přeplatky — TA SE TÍMHLE NEDĚLÁ a schválně. Tady jde
-- o tři sloupce na faktuře: datum úhrady a kdo ji zapsal.
--
-- PROČ TO NENÍ PŘEDBÍHÁNÍ E2: `invoice_payments` bude o částkách (kolik, kdy,
-- z jakého výpisu). Tohle je stav dokladu (zaplaceno/nezaplaceno) a ten na
-- faktuře být musí tak jako tak — enum `invoice_status` hodnotu `zaplaceno`
-- nese od B1+B2. Až E2 přijde, `datum_uhrady` se z plateb dopočítá; migrovat
-- se bude jedno pole, ne model.
--
-- SLOUPCE A GUARD JSOU V JEDNÉ MIGRACI, a není to volba stylu. B1+B2 si to samo
-- předepsalo v komentáři u `guard_invoice_immutable`:
--
--     „až přijde evidence plateb (E2), musí se `_povolene` rozšířit ZÁROVEŇ
--      s `ADD COLUMN` — jinak nepůjde zaplatit."
--
-- Vystavený doklad je neměnný i pro admina (rozhodnutí R8) a whitelist guardu
-- dnes pouští jen `status`, PDF a razítka. `ADD COLUMN` bez rozšíření whitelistu
-- by tedy vyrobil sloupec, do kterého nejde zapsat — a chyba by se ukázala až
-- při prvním kliknutí na „Označit jako zaplaceno".
--
-- ÚHRADA JE VRATNÁ, na rozdíl od vystavení. Vystavení je nevratné ze zákona
-- (číslo se spálí, doklad je neměnný); označení úhrady je provozní poznámka
-- admina, a překlik v ní nesmí být slepá ulička. Proto `unmark_invoice_paid`.
--
-- PRO BUDOUCÍ STORNO A DOBROPIS: `datum_uhrady` se stornem NEMAŽE — constraint
-- to dovoluje schválně. Storno zaplaceného dokladu je právě ten případ, kdy je
-- potřeba vědět, že peníze dorazily (jde se vracet). Kdo bude psát storno RPC,
-- ať to nevynuluje ze setrvačnosti.
--
-- VRATNOST:
--   DROP FUNCTION IF EXISTS public.mark_invoice_paid(uuid, date);
--   DROP FUNCTION IF EXISTS public.unmark_invoice_paid(uuid);
--   ALTER TABLE public.invoices
--     DROP CONSTRAINT invoices_uhrada_dle_stavu,
--     DROP CONSTRAINT invoices_uhrada_ne_pred_vystavenim,
--     DROP COLUMN datum_uhrady, DROP COLUMN paid_at, DROP COLUMN paid_by;
--   -- a `guard_invoice_immutable` zpátky do znění z 20260813090000_faktury_zaklad.sql
--   -- POZOR: revert ZTRATÍ evidenci, kdo a kdy úhradu zapsal.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Sloupce
--
-- `datum_uhrady` je `date`, ne `timestamptz`: admin opisuje datum z bankovního
-- výpisu, ne okamžik. `paid_at`/`paid_by` je naproti tomu auditní razítko —
-- „kdo označil zaplaceno" žádá spec (bod 12) i zásada auditovatelnosti.
-- -----------------------------------------------------------------------------
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS datum_uhrady date,
  ADD COLUMN IF NOT EXISTS paid_at      timestamptz,
  ADD COLUMN IF NOT EXISTS paid_by      uuid REFERENCES public.profiles(user_id);

COMMENT ON COLUMN public.invoices.datum_uhrady IS
  'Datum úhrady podle bankovního výpisu (opisuje admin). Plná evidence plateb s částkami je E2 — tohle je stav dokladu, ne platební historie.';

-- Stav a datum se nesmí rozejít: „zaplaceno" bez data by nešlo doložit a datum
-- u nezaplacené faktury je rozpor. Constrainty se přidávají idempotentně, protože
-- `scripts/build-demo-sql.sh` pouští migrace opakovaně.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_uhrada_dle_stavu') THEN
    -- STORNO JE VÝJIMKA, A JE TO SPRÁVNĚ. Kdyby constraint žádal prázdné datum
    -- u všeho kromě `zaplaceno`, nešlo by stornovat doklad, který už byl
    -- zaplacený — a to je právě ten případ, kdy je storno potřeba (peníze přišly,
    -- plnění se nekonalo, jde se vracet). Stornem by se navíc smazala informace,
    -- že peníze DORAZILY, což je přesně to, co si u dobropisu potřebujeme pamatovat.
    -- CHECK constrainty navíc neobchází ani `app.invoice_repair`, takže by to byla
    -- past i pro opravnou migraci.
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_uhrada_dle_stavu
      CHECK ((status = 'zaplaceno'  AND datum_uhrady IS NOT NULL)
          OR (status = 'stornovano')
          OR (status IN ('koncept', 'vystaveno') AND datum_uhrady IS NULL));
  END IF;

  -- Zaplatit dřív, než byl doklad vystavený, nejde. Chytá to překlep v roce,
  -- který by jinak prošel bez povšimnutí (2025 místo 2026).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_uhrada_ne_pred_vystavenim') THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_uhrada_ne_pred_vystavenim
      CHECK (datum_uhrady IS NULL OR datum_vystaveni IS NULL OR datum_uhrady >= datum_vystaveni);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_invoices_nezaplacene
  ON public.invoices (datum_splatnosti)
  WHERE status = 'vystaveno';

-- -----------------------------------------------------------------------------
-- 2) Guard: whitelist musí o nových sloupcích vědět
--
-- Tělo je vygenerované z `pg_get_functiondef` živého schématu (pravidlo 7
-- v CLAUDE.md) a vložený je do něj JEN zásah do whitelistu. Přepis z paměti
-- už jednou utnul půlku guardu (commit 87b1f78).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_invoice_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  -- Rozšířeno o evidenci úhrady. Zápis do těchhle polí NENÍ editace dokladu:
  -- částky, strany ani číslo se nemění, mění se poznámka o tom, že přišly peníze.
  _povolene text[] := ARRAY['status', 'pdf_path', 'pdf_sha256', 'updated_at', 'updated_by',
                            'datum_uhrady', 'paid_at', 'paid_by'];
  -- Sloupce, které dopočítává výhradně `recalc_invoice_totals` z položek.
  _dopocitane text[] := ARRAY['subtotal', 'total', 'total_rounded', 'rounding_amount'];
BEGIN
  -- GUC si smí nastavit jakákoli role, takže samotný přepínač by byl globální
  -- vypínač ZÁKONNÉ neměnnosti. Platí proto jen pod databázovou rolí — tedy
  -- z migrace nebo z psql, ne z klienta.
  IF current_setting('app.invoice_repair', true) = 'on'
     AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'koncept' THEN
      RETURN OLD;   -- koncept zahodit lze, ten ještě dokladem není
    END IF;
    -- `USING HINT` nedělá substituci `%`, takže se hodnoty skládají dopředu.
    RAISE EXCEPTION 'Vystavený doklad se nemaže. Řeší se opravným dokladem.'
      USING HINT = format('Faktura %s je ve stavu %s.', COALESCE(OLD.cislo, '(koncept)'), OLD.status);
  END IF;

  -- Součty se NIKDY nepíšou zvenčí, ani u konceptu. Dopočítává je `recalc_invoice_totals`
  -- z položek a ta si nastaví GUC. Bez téhle kontroly šlo u konceptu přepsat
  -- `subtotal` na cokoli a pak fakturu vystavit — a immutabilita by pak chránila
  -- to špatné číslo.
  IF current_setting('app.invoice_recalc', true) IS DISTINCT FROM 'on'
     AND EXISTS (
       SELECT 1
         FROM jsonb_each_text(to_jsonb(OLD)) o
         JOIN jsonb_each_text(to_jsonb(NEW)) n ON n.key = o.key
        WHERE o.value IS DISTINCT FROM n.value
          AND o.key = ANY (_dopocitane)
     ) THEN
    RAISE EXCEPTION 'Součty faktury se nezapisují ručně — dopočítávají se z položek.';
  END IF;

  -- Koncept je pracovní verze, ta se měnit smí.
  IF OLD.status = 'koncept' THEN
    RETURN NEW;
  END IF;

  -- U vystaveného dokladu smí měnit jen whitelist.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(to_jsonb(OLD)) o
      JOIN jsonb_each_text(to_jsonb(NEW)) n ON n.key = o.key
     WHERE o.value IS DISTINCT FROM n.value
       AND o.key <> ALL (_povolene)
  ) THEN
    RAISE EXCEPTION 'Vystavený doklad se needituje — měnit lze jen stav, PDF a evidenci úhrady.'
      USING HINT = 'Oprava vystavené faktury se dělá opravným dokladem, ne přepsáním.';
  END IF;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) RPC
--
-- Přímý zápis do `invoices` je pro `authenticated` zavřený (R8, druhá vrstva),
-- takže i tahle cesta musí jít přes SECURITY DEFINER funkci s kontrolou role.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_invoice_paid(_invoice_id uuid, _datum date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid   uuid := auth.uid();
  _f     record;
  _dnes  date := (now() AT TIME ZONE 'Europe/Prague')::date;
  _datum_uhrady date;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Úhradu eviduje jen správce haly.';
  END IF;

  -- Zámek řádku: dvě souběžná kliknutí by jinak zapsala dvě různá data úhrady.
  SELECT * INTO _f FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Faktura neexistuje.';
  END IF;

  IF _f.status = 'koncept' THEN
    RAISE EXCEPTION 'Koncept se neplatí — nejdřív ho vystav.';
  END IF;
  IF _f.status = 'stornovano' THEN
    RAISE EXCEPTION 'Stornovaný doklad se neoznačuje jako zaplacený.';
  END IF;
  IF _f.status = 'zaplaceno' THEN
    RAISE EXCEPTION 'Faktura je označená jako zaplacená už od %.', _f.datum_uhrady;
  END IF;

  -- Pražský den, ne `current_date`: databáze běží v UTC, takže by úhrada zapsaná
  -- po půlnoci dostala včerejší datum.
  _datum_uhrady := COALESCE(_datum, _dnes);

  IF _datum_uhrady > _dnes THEN
    RAISE EXCEPTION 'Datum úhrady nemůže být v budoucnosti (dostal jsem %).', _datum_uhrady;
  END IF;
  IF _f.datum_vystaveni IS NOT NULL AND _datum_uhrady < _f.datum_vystaveni THEN
    RAISE EXCEPTION 'Úhrada nemůže být dřív, než byl doklad vystavený (% < %).',
      _datum_uhrady, _f.datum_vystaveni;
  END IF;

  UPDATE public.invoices
     SET status       = 'zaplaceno',
         datum_uhrady = _datum_uhrady,
         paid_at      = now(),
         paid_by      = _uid
   WHERE id = _invoice_id;

  RETURN jsonb_build_object('id', _invoice_id, 'cislo', _f.cislo, 'datum_uhrady', _datum_uhrady);

EXCEPTION
  -- Jediný cizí klíč v tom UPDATE je `paid_by → profiles(user_id)`. Poslat
  -- účet bez profilu do hlášky o datu je slepá ulička: žádné datum mu nepomůže.
  WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'Účet, který úhradu zapisuje, nemá profil v systému.'
      USING ERRCODE = '22023',
            HINT = 'Přihlas se znovu, případně ať správce profil doplní.';
  -- R11: uvnitř SECURITY DEFINER neplatí RLS, takže by Postgres do chyby doplnil
  -- celý řádek faktury i se snapshotem dodavatele včetně IBANu.
  WHEN check_violation OR not_null_violation THEN
    RAISE EXCEPTION 'Úhradu se nepodařilo zapsat — datum neodpovídá pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Datum úhrady musí být mezi vystavením dokladu a dneškem.';
END;
$$;

REVOKE ALL ON FUNCTION public.mark_invoice_paid(uuid, date) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_invoice_paid(uuid, date) TO authenticated;

/**
 * Zrušení označení úhrady.
 *
 * Vystavení je nevratné ze zákona, tohle ne: je to provozní poznámka admina
 * a překlik v ní nesmí být slepá ulička (jediná cesta zpět by jinak vedla přes
 * `app.invoice_repair` z psql). Auditní stopa zůstává v `audit_log`, takže
 * „zaplaceno → nezaplaceno" je dohledatelné.
 */
CREATE OR REPLACE FUNCTION public.unmark_invoice_paid(_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _stav public.invoice_status;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Úhradu eviduje jen správce haly.';
  END IF;

  SELECT status INTO _stav FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Faktura neexistuje.';
  END IF;
  IF _stav <> 'zaplaceno' THEN
    RAISE EXCEPTION 'Tahle faktura jako zaplacená označená není.';
  END IF;

  UPDATE public.invoices
     SET status = 'vystaveno', datum_uhrady = NULL, paid_at = NULL, paid_by = NULL
   WHERE id = _invoice_id;

EXCEPTION
  WHEN check_violation OR not_null_violation THEN
    RAISE EXCEPTION 'Označení úhrady se nepodařilo zrušit.'
      USING ERRCODE = '22023';
END;
$$;

REVOKE ALL ON FUNCTION public.unmark_invoice_paid(uuid) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.unmark_invoice_paid(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4) Pohled pro seznam — doplnit datum úhrady
--
-- `po_splatnosti` zůstává odvozený stav (spec, bod 9) a nově se počítá JEN
-- u nezaplacených: zaplacená faktura po splatnosti už po splatnosti není,
-- byla zaplacena pozdě. To je rozdíl, který klient na obrazovce pozná.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.invoices_list;
CREATE VIEW public.invoices_list WITH (security_invoker = on) AS
  SELECT i.id,
         i.cislo,
         i.variabilni_symbol,
         i.kind,
         i.status,
         i.subject_id,
         COALESCE(i.odberatel_nazev, s.name) AS odberatel,
         i.obdobi_od,
         i.obdobi_do,
         i.datum_vystaveni,
         i.datum_splatnosti,
         i.datum_uhrady,
         i.subtotal,
         i.total,
         i.total_rounded,
         i.pdf_path,
         (SELECT count(*) FROM public.invoice_items it WHERE it.invoice_id = i.id) AS polozek,
         -- Pražský den, ne `current_date`: databáze běží v UTC, takže by se doklad
         -- na hraně splatnosti tvářil po splatnosti o dvě hodiny dřív.
         (i.status = 'vystaveno'
          AND i.datum_splatnosti < (now() AT TIME ZONE 'Europe/Prague')::date) AS po_splatnosti,
         i.created_at,
         i.issued_at
    FROM public.invoices i
    LEFT JOIN public.subjects s ON s.id = i.subject_id;

REVOKE ALL ON public.invoices_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.invoices_list TO authenticated;

-- -----------------------------------------------------------------------------
-- 5) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _chybi text;
BEGIN
  SELECT string_agg(c, ', ') INTO _chybi
    FROM unnest(ARRAY['datum_uhrady', 'paid_at', 'paid_by']) c
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'invoices' AND column_name = c);
  IF _chybi IS NOT NULL THEN
    RAISE EXCEPTION 'Evidence úhrady selhala: chybí sloupce %.', _chybi;
  END IF;

  -- Bez tohohle by šlo vystavit doklad, který nejde zaplatit.
  IF position('datum_uhrady' in pg_get_functiondef('public.guard_invoice_immutable()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Evidence úhrady selhala: guard o nových sloupcích neví, zápis by neprošel.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('mark_invoice_paid', 'unmark_invoice_paid')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('service_role', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'Evidence úhrady selhala: RPC jsou dosažitelná pro anon nebo service_role.';
  END IF;

  RAISE NOTICE 'Evidence úhrady nasazena (datum úhrady, kdo zapsal, RPC).';
END $$;
