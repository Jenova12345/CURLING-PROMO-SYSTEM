-- =============================================================================
-- Etapa 3 / PR 4 — vazba na Fakturoid (varianta S2)
-- =============================================================================
-- ROZHODNUTÍ PM 24. 8. 2026: jede se **S2**. Ostrý doklad vystavuje Fakturoid,
-- náš systém do něj posílá jen podklady. Interní fakturační engine
-- (`invoice_counter`, `invoices`, PDF, QR, storno) se na ostré doklady přestává
-- používat a zůstává nanejvýš jako interní přehled.
--
-- ČEHO SE TAHLE MIGRACE **NEDOTÝKÁ** (výslovný pokyn PM):
--   * `public.invoices`, `public.invoice_items`, `public.invoice_counter`,
--   * `reservations.invoice_id` ani guardu `app.trusted_booking`,
--   * žádné existující fakturační RPC.
-- Vyřazení interního enginu je samostatný pozdější ticket. Tahle migrace jen
-- PŘIDÁVÁ vedle něj druhou, nezávislou evidenci.
--
-- PROČ VLASTNÍ TABULKA A NE `reservations.invoice_id`
--   `invoice_id` je cizí klíč na naše `public.invoices` a zápis do něj odmítá
--   guard i adminovi (RPC si kvůli tomu nastavují `app.trusted_booking`).
--   Fakturoidí doklad tam tedy nepatří ani technicky, ani významově. Pod S2 navíc
--   platí, že rezervace MŮŽE mít interní `invoice_id` a **stejně má jít do
--   Fakturoidu** — o odeslání rozhoduje VÝHRADNĚ existence fakturoidí vazby.
--   Dvě nezávislé evidence jsou tu záměr, ne opomenutí.
--
-- IDEMPOTENCE JE V SCHÉMATU, NE V KÓDU
--   Za tři kola bran se v aplikační vrstvě našly čtyři různé cesty k duplicitní
--   faktuře. Poslední slovo proto musí mít databáze:
--     1) částečný UNIQUE na `idempotency_key` → jeden klíč, nejvýš jeden živý claim,
--     2) UNIQUE na `reservation_id` v `fakturoid_invoice_reservations` → jedna
--        rezervace nemůže viset na dvou fakturoidích dokladech.
--   Claim je JEDEN příkaz (`INSERT … ON CONFLICT DO NOTHING RETURNING`), nikdy
--   „SELECT, a když nic, tak INSERT" — to je závod, ne zámek.
--
-- VRATNOST (nic z toho neztrácí data mimo tyhle dvě nové tabulky):
--   DROP FUNCTION IF EXISTS public.fakturoid_zkus_zabrat(text,text,uuid,uuid,date,date,numeric,integer,text,uuid[]);
--   DROP FUNCTION IF EXISTS public.fakturoid_uvolni_zabrani(text,text);
--   DROP FUNCTION IF EXISTS public.fakturoid_zapis_vazbu(text,text,text,text,text,text,text,numeric,text,text,uuid,uuid,date,date,numeric,integer,text,uuid[]);
--   DROP FUNCTION IF EXISTS public.fakturoid_zapis_pdf(text,text,text);
--   DROP FUNCTION IF EXISTS public.fakturoid_oznac_odeslano(text);
--   DROP FUNCTION IF EXISTS public.fakturoid_je_vyfakturovana(uuid);
--   DROP FUNCTION IF EXISTS public.fakturoid_najdi_podle_klice(text);
--   DROP FUNCTION IF EXISTS public.fakturoid_podklady_klub(uuid,date,date);
--   DROP FUNCTION IF EXISTS public.fakturoid_podklady_akce(uuid);
--   DROP FUNCTION IF EXISTS public.fakturoid_subjekt(uuid);
--   DROP FUNCTION IF EXISTS public.fakturoid_smi_volat();
--   DROP VIEW IF EXISTS public.fakturoid_invoices_list;
--   -- POZOR NA SIGNATURY: `DROP FUNCTION` se špatným seznamem typů je TICHÝ
--   -- no-op, takže funkce revert přežije a nikdo si toho nevšimne. DEFAULT
--   -- parametr signaturu NEZKRACUJE — `fakturoid_uvolni_zabrani` má (text,text).
--   DROP TRIGGER IF EXISTS trg_fakturoid_invoices_audit ON public.fakturoid_invoices;
--   DROP TRIGGER IF EXISTS trg_fakturoid_rezervace_audit ON public.fakturoid_invoice_reservations;
--   DROP TABLE IF EXISTS public.fakturoid_invoice_reservations;
--   DROP TABLE IF EXISTS public.fakturoid_invoices;
--   -- POZOR: DROP TABLE ztratí vazbu „co už bylo posláno do Fakturoidu".
--   -- Doklady u Fakturoidu tím nezmizí, takže po revertu hrozí DVOJÍ ODESLÁNÍ.
--   -- Před revertem si evidenci vyexportuj.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Hlavička fakturoidího dokladu
--
-- Řádek vzniká UŽ PŘI CLAIMU, tedy dřív, než doklad u Fakturoidu existuje.
-- `provider_invoice_id IS NULL` proto znamená „zabráno, ještě nevystaveno".
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fakturoid_invoices (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Klíč idempotence z aplikační vrstvy: `akce-{eventId}` / `klub-{clubId}-{RRRRMM}`.
  idempotency_key     text NOT NULL,
  druh                text NOT NULL CHECK (druh IN ('commercial_event', 'club_monthly')),

  subject_id          uuid NOT NULL REFERENCES public.subjects(id),
  event_id            uuid REFERENCES public.events(id),
  obdobi_od           date,
  obdobi_do           date,

  -- ---- Náš podklad v okamžiku claimu -------------------------------------
  -- Drží se schválně, i když se dá dopočítat: kontrolní součet musí umět
  -- porovnat, co jsme POSLALI, s tím, co Fakturoid VYTISKL — a to i za měsíc,
  -- kdy se rezervace mezitím mohla změnit.
  nas_soucet          numeric(12,2) NOT NULL CHECK (nas_soucet >= 0),
  -- `radku` i `nas_soucet` posílá volající. Počet řádků si databáze aspoň ověří
  -- proti poli rezervací; součet ověřit neumí (sazby zná jen mapovací vrstva),
  -- takže kontrolní součet zůstává na `varovani` po vystavení.
  radku               integer NOT NULL CHECK (radku > 0),
  -- Rezervace, na které claim zněl. Historie; vynucuje to tabulka níž.
  rezervace           uuid[] NOT NULL CHECK (cardinality(rezervace) > 0),

  -- ---- Odpověď providera ---------------------------------------------------
  provider            text NOT NULL DEFAULT 'fakturoid',
  provider_subject_id text,
  provider_invoice_id text,                       -- NULL = zabráno, nevystaveno
  cislo               text,
  variabilni_symbol   text,
  public_url          text,
  status              text,
  provider_total      numeric(12,2),

  -- ---- Režim vystavení -----------------------------------------------------
  -- `koncept`  — doklad se u Fakturoidu jen založí, e-mail se NEPOSÍLÁ.
  --              Člověk si ho ve Fakturoidu prohlédne a odešle sám.
  -- `odeslat`  — po založení se rovnou volá `POST /invoices/{id}/message.json`.
  -- POZOR NA SLOVO „KONCEPT": Fakturoid API stav koncept NEZNÁ. Doklad
  -- vytvořený přes `POST /invoices.json` je plnohodnotný a UŽ MÁ ČÍSLO v ostré
  -- řadě. „Koncept" u nás tedy znamená „vystaveno, ale neodesláno", ne „nezávazný
  -- návrh". Viz docs/ETAPA3-STAV.md.
  rezim               text NOT NULL DEFAULT 'koncept' CHECK (rezim IN ('koncept', 'odeslat')),
  odeslano_at         timestamptz,

  -- ---- Kopie PDF v našem úložišti -----------------------------------------
  pdf_path            text,
  pdf_sha256          text,

  -- Rozpor kontrolního součtu proti providerovi. Tichý rozpor u peněz je horší
  -- než hlasitý, takže se ukládá a je vidět v přehledu.
  varovani            text,

  -- ---- Životní cyklus claimu ----------------------------------------------
  zabrano_at          timestamptz NOT NULL DEFAULT now(),
  -- Uvolněný claim se NEMAŽE (zásada „nic natvrdo"), jen se označí — a tím
  -- vypadne z částečného UNIQUE indexu, takže klíč jde zabrat znovu.
  uvolneno_at         timestamptz,
  uvolneni_duvod      text,
  vystaveno_at        timestamptz,

  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid REFERENCES public.profiles(user_id),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid REFERENCES public.profiles(user_id),
  deleted_at          timestamptz,

  -- Uvolnit se smí jen claim, na kterém doklad nevznikl. Kdyby šlo uvolnit
  -- i vystavený, uvolnil by se klíč a příští běh by vystavil druhý doklad.
  CONSTRAINT fakturoid_uvolneni_jen_bez_dokladu
    CHECK (uvolneno_at IS NULL OR provider_invoice_id IS NULL),
  -- Vystavený doklad musí nést, co z něj dělá doklad.
  CONSTRAINT fakturoid_vystaveny_ma_udaje
    CHECK (provider_invoice_id IS NULL OR (cislo IS NOT NULL AND vystaveno_at IS NOT NULL)),
  CONSTRAINT fakturoid_odeslano_jen_vystavene
    CHECK (odeslano_at IS NULL OR provider_invoice_id IS NOT NULL),
  CONSTRAINT fakturoid_obdobi CHECK (obdobi_do IS NULL OR obdobi_od IS NULL OR obdobi_do >= obdobi_od),
  CONSTRAINT fakturoid_komercni_ma_akci CHECK (druh <> 'commercial_event' OR event_id IS NOT NULL),
  -- Řádek dokladu je u obou typů právě jedna rezervace, takže se ty počty musí
  -- rovnat. Kdyby se rozešly, poslali jsme jinam jiný počet položek, než na kolik
  -- zní naše evidence — a kontrolní součet by to zjistil až u částky.
  CONSTRAINT fakturoid_radku_sedi CHECK (radku = cardinality(rezervace))
);

-- ZÁMEK 3 V SCHÉMATU. Částečný, ne plný: uvolněný claim smí být v tabulce
-- podruhé, protože ten klíč se legitimně zabírá znovu.
CREATE UNIQUE INDEX IF NOT EXISTS idx_fakturoid_invoices_klic
  ON public.fakturoid_invoices (idempotency_key)
  WHERE uvolneno_at IS NULL AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_fakturoid_invoices_subject
  ON public.fakturoid_invoices (subject_id, obdobi_od);
CREATE INDEX IF NOT EXISTS idx_fakturoid_invoices_bez_pdf
  ON public.fakturoid_invoices (vystaveno_at)
  WHERE provider_invoice_id IS NOT NULL AND pdf_path IS NULL AND deleted_at IS NULL;

COMMENT ON TABLE public.fakturoid_invoices IS
  'Vazba na doklady u Fakturoidu (varianta S2). NEZÁVISLÁ na public.invoices a na reservations.invoice_id — rezervace může mít interní doklad a stejně jde do Fakturoidu.';
COMMENT ON COLUMN public.fakturoid_invoices.rezim IS
  'koncept = doklad se jen založí, e-mail se neposílá (Fakturoid stav „koncept" nezná, doklad UŽ MÁ číslo). odeslat = po založení se volá message.json.';

-- -----------------------------------------------------------------------------
-- 2) Které rezervace doklad pokrývá
--
-- UNIQUE na `reservation_id` je ZÁMEK 1 v schématu: jedna rezervace nemůže viset
-- na dvou fakturoidích dokladech ani při souběhu dvou běhů.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fakturoid_invoice_reservations (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fakturoid_invoice_id uuid NOT NULL REFERENCES public.fakturoid_invoices(id) ON DELETE CASCADE,
  reservation_id uuid NOT NULL REFERENCES public.reservations(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fakturoid_rezervace_unikat UNIQUE (reservation_id)
);

CREATE INDEX IF NOT EXISTS idx_fakturoid_rezervace_doklad
  ON public.fakturoid_invoice_reservations (fakturoid_invoice_id);

COMMENT ON TABLE public.fakturoid_invoice_reservations IS
  'Zámek 1 v schématu: UNIQUE(reservation_id) brání tomu, aby rezervace visela na dvou fakturoidích dokladech. Řádky se při uvolnění claimu mažou — claim v hlavičce si historii drží v poli `rezervace`.';

-- -----------------------------------------------------------------------------
-- 2b) Audit
--
-- CLAUDE.md §3: u klíčových tabulek se drží historie změn. `invoices`
-- i `invoice_items` mají `trg_*_audit` odjakživa a peněžní tabulka bez auditní
-- stopy je proti precedentu i proti požadavku zákazníka („musí být vidět, kdo
-- co zadával"). RPC sice `updated_at` nastavují samy, ale spoléhat na to, že to
-- každá budoucí cesta udělá taky, je přesně ten druh předpokladu, který jednou
-- někdo poruší.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_fakturoid_invoices_audit ON public.fakturoid_invoices;
CREATE TRIGGER trg_fakturoid_invoices_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.fakturoid_invoices
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

DROP TRIGGER IF EXISTS trg_fakturoid_rezervace_audit ON public.fakturoid_invoice_reservations;
CREATE TRIGGER trg_fakturoid_rezervace_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.fakturoid_invoice_reservations
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- -----------------------------------------------------------------------------
-- 3) Práva
--
-- Číst smí admin. Zapisovat NIKDO přímo — jen přes RPC níž, aby zápis šel jedním
-- auditovatelným místem a aby se claim nedal obejít.
-- -----------------------------------------------------------------------------
ALTER TABLE public.fakturoid_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fakturoid_invoice_reservations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.fakturoid_invoices FROM anon, authenticated, public, service_role;
REVOKE ALL ON public.fakturoid_invoice_reservations FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.fakturoid_invoices TO authenticated;
GRANT SELECT ON public.fakturoid_invoice_reservations TO authenticated;

DROP POLICY IF EXISTS fakturoid_invoices_select_admin ON public.fakturoid_invoices;
CREATE POLICY fakturoid_invoices_select_admin ON public.fakturoid_invoices
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS fakturoid_rezervace_select_admin ON public.fakturoid_invoice_reservations;
CREATE POLICY fakturoid_rezervace_select_admin ON public.fakturoid_invoice_reservations
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- 4) Kdo smí volat fakturoidí RPC
--
-- Táž trojice jako u fronty PDF (C1): admin z webu, servisní klíč z Edge funkce,
-- databázová role z plánovače. Z webu je poslední větev nedosažitelná —
-- PostgREST se připojuje jako `authenticator`, takže `session_user` nikdy
-- nebude `postgres`.
-- -----------------------------------------------------------------------------
-- KAŽDÁ VĚTEV JE OBALENÁ `COALESCE(…, false)` A NENÍ TO KOSMETIKA.
--
-- Bez toho je celý guard děravý kvůli trojhodnotové logice. Mimo PostgREST není
-- `request.jwt.claims` nastavené, takže `current_setting(…, true)` vrátí NULL
-- a porovnání `NULL::jsonb->>'role' = 'service_role'` je taky NULL. Výraz
-- `false OR NULL OR false` je pak NULL — a `IF NOT NULL THEN RAISE` se
-- NEPROVEDE, protože NULL není pravda. Guard tedy TIŠE PROPUSTÍ.
--
-- Změřeno na živé databázi přes `authenticator` (věrný kanál, viz pravidlo 8
-- v CLAUDE.md): pod rolí `authenticated` vracel guard NULL, `je_vyfakturovana`
-- odpověděla místo chyby, a `zkus_zabrat` se dostala až na cizí klíč — tedy
-- běžný přihlášený uživatel by založil claim. Přes `psql -U postgres` to vidět
-- nebylo, protože tam projde větev pro cron.
CREATE OR REPLACE FUNCTION public.fakturoid_smi_volat()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(has_role(auth.uid(), 'admin'), false)
      OR COALESCE(current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role', false)
      OR COALESCE(auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'), false);
$$;

REVOKE ALL ON FUNCTION public.fakturoid_smi_volat() FROM anon, authenticated, public, service_role;

-- -----------------------------------------------------------------------------
-- 5) ZÁMEK 3 — atomický claim
--
-- JEDEN příkaz, ne „SELECT, a když nic, tak INSERT". `ON CONFLICT DO NOTHING
-- RETURNING` vrátí řádek jen tomu běhu, který claim opravdu založil; druhý
-- dostane prázdno a skončí.
--
-- Vazby na rezervace se zakládají ve STEJNÉ funkci, uvnitř bloku s EXCEPTION:
-- ten dělá subtransakci, takže když UNIQUE na `reservation_id` narazí, odroluje
-- se i INSERT hlavičky. Bez toho by po kolizi zůstal viset claim bez rezervací
-- a klíč by byl zablokovaný.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_zkus_zabrat(
  _klic       text,
  _druh       text,
  _subject    uuid,
  _event      uuid,
  _od         date,
  _do         date,
  _nas_soucet numeric,
  _radku      integer,
  _rezim      text,
  _rezervace  uuid[]
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění zakládat fakturoidí doklady.';
  END IF;

  -- Duplicita v poli by spadla na UNIQUE a vrátila nerozlišitelné `false`,
  -- takže by to vypadalo jako prohraný závod a volající by to zkoušel dokola.
  IF cardinality(_rezervace) <> cardinality(ARRAY(SELECT DISTINCT unnest(_rezervace))) THEN
    RAISE EXCEPTION 'Podklad obsahuje tutéž rezervaci víckrát — doklad by na ni zněl dvojnásobně.';
  END IF;

  BEGIN
    INSERT INTO public.fakturoid_invoices
      (idempotency_key, druh, subject_id, event_id, obdobi_od, obdobi_do,
       nas_soucet, radku, rezervace, rezim, created_by)
    VALUES
      (_klic, _druh, _subject, _event, _od, _do,
       _nas_soucet, _radku, _rezervace, coalesce(_rezim, 'koncept'), auth.uid())
    -- Cíl konfliktu je vyjmenovaný SCHVÁLNĚ. Holé `ON CONFLICT DO NOTHING` chytá
    -- JAKÝKOLI unikátní konflikt, takže by tiše spolklo i chybu, o které nevíme,
    -- a tvářilo se jako „klíč už drží někdo jiný".
    ON CONFLICT (idempotency_key) WHERE uvolneno_at IS NULL AND deleted_at IS NULL
    DO NOTHING
    RETURNING id INTO _id;

    -- Klíč už drží jiný živý claim.
    IF _id IS NULL THEN RETURN false; END IF;

    INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
    SELECT _id, r FROM unnest(_rezervace) AS r;

  EXCEPTION WHEN unique_violation THEN
    -- Některá rezervace už visí na jiném fakturoidím dokladu. Subtransakce
    -- se odroluje celá, takže hlavička po sobě nenechá zablokovaný klíč.
    --
    -- `false` tu znamená totéž co výš („nezabrali jsme") a je to správně:
    -- do téhle větve se dá dostat jen ZÁVODEM, protože stav „rezervace už je
    -- na dokladu" odchytí zámek 1 (`fakturoid_je_vyfakturovana`) dřív, než se
    -- k claimu vůbec dojde. Rozlišovat to tady na chybu by z běžného souběhu
    -- udělalo poruchu.
    RETURN false;
  END;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fakturoid_zkus_zabrat(text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])
  FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_zkus_zabrat(text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6) Uvolnění claimu
--
-- Volá se po selhaném vystavení: NEVÍME, jestli doklad u Fakturoidu vznikl,
-- takže se klíč pustí a rozhodne až příští běh (zámek 2 ho buď najde, nebo ne).
-- Držet claim navždy by fakturaci toho klubu zastavilo do zásahu člověka.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_uvolni_zabrani(_klic text, _duvod text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění uvolnit fakturoidí claim.';
  END IF;

  -- Vystavený doklad se uvolnit NESMÍ — uvolnil by klíč a příští běh
  -- by vystavil druhý. Hlídá to i CHECK, tohle je jen srozumitelnější cesta.
  UPDATE public.fakturoid_invoices
     SET uvolneno_at = now(), uvolneni_duvod = _duvod, updated_at = now(), updated_by = auth.uid()
   WHERE idempotency_key = _klic
     AND uvolneno_at IS NULL
     AND deleted_at IS NULL
     AND provider_invoice_id IS NULL
  RETURNING id INTO _id;

  IF _id IS NULL THEN RETURN false; END IF;

  -- Vazby padají; historii drží pole `rezervace` v hlavičce.
  DELETE FROM public.fakturoid_invoice_reservations WHERE fakturoid_invoice_id = _id;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fakturoid_uvolni_zabrani(text,text) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_uvolni_zabrani(text,text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7) Zápis odpovědi providera
-- -----------------------------------------------------------------------------
-- ZAPISUJE DVA RŮZNÉ STAVY, ne jeden:
--
--   A) DOROVNÁNÍ ŽIVÉHO CLAIMU — běžná cesta. Claim vznikl v `zkus_zabrat`,
--      doklad se právě vystavil, doplní se odpověď providera.
--
--   B) ZÁPIS NÁLEZU — cesta zotavení po ztracené odpovědi, a ta je pro
--      idempotenci nosná. Běh A zabral claim, POSTnul doklad, Fakturoid ho
--      ZALOŽIL a spadl na 5xx → A claim správně uvolnil (nevěděl, jak to
--      dopadlo) a vazby na rezervace se přitom smazaly. Běh B pak doklad najde
--      přes `findExistingInvoice`, jenže ŽÁDNÝ CLAIM UŽ NEEXISTUJE. Kdyby
--      funkce uměla jen UPDATE, vrátila by `false`, volající by hlásil chybu
--      a **každý další běh by dopadl stejně** — doklad by u Fakturoidu zůstal
--      navždy nezaevidovaný a rozjelo by ho až ruční sáhnutí do databáze.
--
-- Ve větvi B se musí založit i VAZBY NA REZERVACE. Bez nich zůstane zámek 1
-- (`fakturoid_je_vyfakturovana`) po zotavení mrtvý a příští běh vystaví druhý
-- doklad — tedy přesně to, čemu celá tahle vrstva brání.
CREATE OR REPLACE FUNCTION public.fakturoid_zapis_vazbu(
  _klic text,
  _provider_invoice_id text,
  _provider_subject_id text,
  _cislo text,
  _vs text,
  _public_url text,
  _status text,
  _provider_total numeric,
  _varovani text DEFAULT NULL,
  -- Kontext pro větev B. Ve větvi A se nepoužije (řádek už existuje).
  _druh text DEFAULT NULL,
  _subject uuid DEFAULT NULL,
  _event uuid DEFAULT NULL,
  _od date DEFAULT NULL,
  _do date DEFAULT NULL,
  _nas_soucet numeric DEFAULT NULL,
  _radku integer DEFAULT NULL,
  _rezim text DEFAULT NULL,
  _rezervace uuid[] DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění zapisovat fakturoidí doklady.';
  END IF;

  IF _provider_invoice_id IS NULL OR _cislo IS NULL THEN
    RAISE EXCEPTION 'Doklad bez id nebo čísla se zapsat nedá.';
  END IF;

  -- ---- A) dorovnání živého claimu ------------------------------------------
  UPDATE public.fakturoid_invoices
     SET provider_invoice_id = _provider_invoice_id,
         provider_subject_id = _provider_subject_id,
         cislo = _cislo,
         variabilni_symbol = _vs,
         public_url = _public_url,
         status = _status,
         provider_total = _provider_total,
         varovani = _varovani,
         vystaveno_at = now(),
         updated_at = now(),
         updated_by = auth.uid()
   WHERE idempotency_key = _klic
     AND uvolneno_at IS NULL
     AND deleted_at IS NULL
     -- Přepsat už zapsaný doklad by zahodilo stopu po tom prvním.
     AND provider_invoice_id IS NULL
  RETURNING id INTO _id;

  IF _id IS NOT NULL THEN RETURN true; END IF;

  -- ---- B) zápis nálezu -----------------------------------------------------
  -- Bez kontextu to nejde: sloupce `druh`, `subject_id`, `nas_soucet`, `radku`
  -- a `rezervace` jsou NOT NULL. Volající ho má, protože právě sestavil draft.
  IF _druh IS NULL OR _subject IS NULL OR _rezervace IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    INSERT INTO public.fakturoid_invoices
      (idempotency_key, druh, subject_id, event_id, obdobi_od, obdobi_do,
       nas_soucet, radku, rezervace, rezim, created_by,
       provider_invoice_id, provider_subject_id, cislo, variabilni_symbol,
       public_url, status, provider_total, varovani, vystaveno_at)
    VALUES
      (_klic, _druh, _subject, _event, _od, _do,
       coalesce(_nas_soucet, 0), coalesce(_radku, cardinality(_rezervace)),
       _rezervace, coalesce(_rezim, 'koncept'), auth.uid(),
       _provider_invoice_id, _provider_subject_id, _cislo, _vs,
       _public_url, _status, _provider_total, _varovani, now())
    ON CONFLICT (idempotency_key) WHERE uvolneno_at IS NULL AND deleted_at IS NULL
    DO NOTHING
    RETURNING id INTO _id;

    -- Někdo jiný nález zapsal dřív. Není to chyba: doklad je zaevidovaný,
    -- jen ne námi.
    IF _id IS NULL THEN RETURN false; END IF;

    INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
    SELECT _id, r FROM unnest(_rezervace) AS r;

  EXCEPTION WHEN unique_violation THEN
    -- Rezervace už visí na jiném dokladu. Subtransakce se odroluje celá.
    RETURN false;
  END;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fakturoid_zapis_vazbu(text,text,text,text,text,text,text,numeric,text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])
  FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_zapis_vazbu(text,text,text,text,text,text,text,numeric,text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 8) PDF a odeslání
-- -----------------------------------------------------------------------------
-- `_sha` je volitelné, ale když přijde NULL, otisk se NEPŘEPÍŠE. Dřív tu bylo
-- prosté `SET pdf_sha256 = _sha`, takže druhé volání bez otisku (a to dělá
-- `zapisPdf` z pipeline) smazalo hodnotu, kterou o řádek dřív uložila Edge funkce.
CREATE OR REPLACE FUNCTION public.fakturoid_zapis_pdf(_klic text, _cesta text, _sha text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění zapisovat PDF.';
  END IF;

  -- FILTR MUSÍ BÝT ÚZKÝ. Se stejným klíčem může existovat VÍC řádků: částečný
  -- UNIQUE index pokrývá jen `uvolneno_at IS NULL`, takže uvolněné claimy
  -- v tabulce zůstávají. Bez těchhle dvou podmínek by UPDATE přepsal `pdf_path`
  -- na všech historických claimech i na zabraném-nevystaveném a `RETURNING`
  -- by vrátil libovolný z nich.
  UPDATE public.fakturoid_invoices
     SET pdf_path = _cesta, pdf_sha256 = coalesce(_sha, pdf_sha256), updated_at = now()
   WHERE idempotency_key = _klic
     AND deleted_at IS NULL
     AND uvolneno_at IS NULL
     AND provider_invoice_id IS NOT NULL
  RETURNING id INTO _id;

  RETURN _id IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.fakturoid_oznac_odeslano(_klic text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _id uuid;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění označit doklad za odeslaný.';
  END IF;

  UPDATE public.fakturoid_invoices
     SET odeslano_at = now(), updated_at = now()
   WHERE idempotency_key = _klic
     AND deleted_at IS NULL
     AND provider_invoice_id IS NOT NULL
     AND odeslano_at IS NULL          -- podruhé se e-mail neposílá
  RETURNING id INTO _id;

  RETURN _id IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.fakturoid_zapis_pdf(text,text,text) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_zapis_pdf(text,text,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fakturoid_oznac_odeslano(text) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_oznac_odeslano(text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 9) Čtení pro aplikační vrstvu
--
-- ZÁMEK 1 se pod S2 ptá VÝHRADNĚ na fakturoidí vazbu, NIKDY na
-- `reservations.invoice_id`. Rezervace může mít interní doklad a stejně má jít
-- do Fakturoidu — rozhodnutí PM 24. 8. 2026.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_je_vyfakturovana(_reservation uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- GUARD PATŘÍ I SEM. Bez něj je tahle funkce SECURITY DEFINER s EXECUTE pro
  -- `authenticated` — tedy obchvat RLS, který si kdokoli přihlášený zavolá.
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturoidí doklady.';
  END IF;

  -- `deleted_at` se tu ZÁMĚRNĚ NEFILTRUJE. Vazba znamená „tahle rezervace už je
  -- na dokladu u Fakturoidu" a to platí bez ohledu na to, jestli jsme si hlavičku
  -- schovali. S filtrem by nastal mrtvý bod: po soft-deletu by tahle funkce řekla
  -- „nevyfakturováno", ale řádek ve vazbě zůstane a nový claim by spadl na UNIQUE —
  -- rezervace by byla trvale nefakturovatelná a nikde by to nebylo vidět.
  RETURN EXISTS (
    SELECT 1
      FROM public.fakturoid_invoice_reservations fr
     WHERE fr.reservation_id = _reservation
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.fakturoid_najdi_podle_klice(_klic text)
RETURNS TABLE (
  idempotency_key text, provider_invoice_id text, provider_subject_id text,
  cislo text, variabilni_symbol text, public_url text, status text,
  provider_total numeric, pdf_path text, rezim text, odeslano_at timestamptz,
  rezervace uuid[], varovani text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- BEZ TOHOHLE GUARDU JE TO ÚNIK CELÉHO DOKLADU. Funkce vrací mimo jiné
  -- `public_url` — veřejný odkaz Fakturoidu na PDF, který funguje BEZ PŘIHLÁŠENÍ.
  -- Klíč se dá uhodnout: tvar je `klub-{subjectId}-{RRRRMM}` a `subjects.id`
  -- přečte přes RLS každý přihlášený. Hobby hráč by si tak stáhl doklady klubů.
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturoidí doklady.';
  END IF;

  RETURN QUERY
    SELECT fi.idempotency_key, fi.provider_invoice_id, fi.provider_subject_id,
           fi.cislo, fi.variabilni_symbol, fi.public_url, fi.status,
           fi.provider_total, fi.pdf_path, fi.rezim, fi.odeslano_at,
           fi.rezervace, fi.varovani
      FROM public.fakturoid_invoices fi
     WHERE fi.idempotency_key = _klic
       AND fi.uvolneno_at IS NULL
       AND fi.deleted_at IS NULL
       -- Zabraný, ale ještě nevystavený claim NENÍ vazba. Vrátit ho jako nález
       -- by zastavilo běh, který ho sám před chvílí založil.
       AND fi.provider_invoice_id IS NOT NULL;
END;
$$;

-- REVOKE srovnaný s ostatními funkcemi. Dřív tu bylo jen `FROM anon, public`,
-- takže výchozí `EXECUTE` pro `authenticated` a `service_role` zůstávalo v platnosti
-- ještě předtím, než ho GRANT níž udělil vědomě.
REVOKE ALL ON FUNCTION public.fakturoid_je_vyfakturovana(uuid) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_je_vyfakturovana(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fakturoid_najdi_podle_klice(text) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_najdi_podle_klice(text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 10) Přehled pro admina
-- -----------------------------------------------------------------------------
-- DROP + CREATE, ne CREATE OR REPLACE: `REPLACE` neumí změnit seznam sloupců,
-- takže by opakovaný běh po úpravě pohledu spadl. Vzor z ostatních migrací.
DROP VIEW IF EXISTS public.fakturoid_invoices_list;
CREATE VIEW public.fakturoid_invoices_list
WITH (security_invoker = on) AS
  SELECT fi.id, fi.idempotency_key, fi.druh, fi.cislo, fi.variabilni_symbol,
         fi.status, fi.rezim, fi.public_url,
         fi.nas_soucet, fi.provider_total,
         -- Rozdíl proti tomu, co jsme poslali. Do 0,50 Kč je to rozdíl
         -- zaokrouhlovacích pravidel, nad to jiný podklad.
         (fi.provider_total - fi.nas_soucet) AS rozdil,
         fi.varovani,
         fi.obdobi_od, fi.obdobi_do,
         fi.vystaveno_at, fi.odeslano_at, fi.pdf_path,
         s.name AS subjekt,
         cardinality(fi.rezervace) AS rezervaci
    FROM public.fakturoid_invoices fi
    JOIN public.subjects s ON s.id = fi.subject_id
   WHERE fi.deleted_at IS NULL
     AND fi.uvolneno_at IS NULL
     AND fi.provider_invoice_id IS NOT NULL;

-- BEZ TOHOHLE REVOKE dostane nový objekt v `public` výchozí práva Supabase,
-- tedy plné `arwdDxtm` pro anon i authenticated. Data by neutekla
-- (`security_invoker` + anon nemá SELECT na základní tabulce), ale rozbilo by to
-- regresní test `security_hardening_test.sql` („žádný pohled není zapisovatelný
-- ani přístupný anonovi") — a ten test tam je právě proto, aby se na tohle
-- nezapomínalo.
REVOKE ALL ON public.fakturoid_invoices_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.fakturoid_invoices_list TO authenticated;

COMMENT ON VIEW public.fakturoid_invoices_list IS
  'Přehled dokladů odeslaných do Fakturoidu. Sloupec `rozdil` je kontrolní součet: co jsme poslali vs. co Fakturoid vytiskl.';

-- -----------------------------------------------------------------------------
-- 11) Podklady pro Edge funkci
--
-- PROČ OBAL A NE PŘÍMÉ VOLÁNÍ: `fakturovatelne_rezervace` má EXECUTE odebrané
-- úplně všem — `service_role` včetně. Je to schválně (viz komentář u ní): je to
-- SECURITY DEFINER funkce, která vidí na všechny rezervace bez ohledu na RLS,
-- a smí ji volat jen jiná SECURITY DEFINER funkce, která si práva ověří sama.
-- Tyhle dva obaly jsou přesně to.
--
-- FILTR „UŽ V EVIDENCI" SE PTÁ JEN NA FAKTUROIDÍ VAZBU. Rezervace, která má
-- interní `invoices.id`, se sem DOSTANE — pod S2 má jít do Fakturoidu tak jako
-- tak. To je celý rozdíl proti interní cestě a je záměrný.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_podklady_klub(
  _subject uuid,
  _od      date,
  _do      date
)
RETURNS TABLE (
  id uuid, start_at timestamptz, end_at timestamptz,
  sheet_name text, event_title text,
  hodiny numeric, sazba numeric, castka numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _zac timestamptz; _kon timestamptz;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační podklady.';
  END IF;

  -- Období v PRAŽSKÉM čase, jedním sdíleným místem. Kdyby si to tahle cesta
  -- počítala po svém, „srpen" pro Fakturoid a „srpen" pro kontrolní součet
  -- by se rozešly o dvě hodiny — a projevilo by se to jen u rezervací kolem
  -- půlnoci na přelomu měsíce, tedy tam, kde si toho nikdo nevšimne.
  SELECT h.zacatek, h.konec INTO _zac, _kon FROM public.obdobi_hranice(_od, _do) h;

  RETURN QUERY
    SELECT f.id, f.start_at, f.end_at, f.sheet_name, f.event_title,
           f.hodiny, f.sazba, f.castka
      FROM public.fakturovatelne_rezervace(_subject, _zac, _kon) f
     WHERE NOT EXISTS (
             SELECT 1 FROM public.fakturoid_invoice_reservations fr
              WHERE fr.reservation_id = f.id
           )
     ORDER BY f.start_at, f.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fakturoid_podklady_akce(_event uuid)
RETURNS TABLE (
  id uuid, start_at timestamptz, end_at timestamptz,
  sheet_name text, event_title text,
  hodiny numeric, sazba numeric, castka numeric,
  subject_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační podklady.';
  END IF;

  RETURN QUERY
    SELECT r.id, r.start_at, r.end_at, sh.name, e.title,
           COALESCE(r.corrected_hours, r.hours),
           r.rate_per_hour,
           COALESCE(r.corrected_amount, r.amount),
           r.subject_id
      FROM public.reservations r
      JOIN public.sheets sh ON sh.id = r.sheet_id
      JOIN public.events e  ON e.id = r.event_id
     WHERE r.event_id = _event
       AND r.status = 'confirmed'
       AND r.deleted_at IS NULL
       AND r.subject_id IS NOT NULL
       AND (r.approved_at IS NOT NULL
            OR NOT COALESCE((SELECT bs.invoice_only_approved FROM public.billing_settings bs LIMIT 1), true))
       AND NOT EXISTS (
             SELECT 1 FROM public.fakturoid_invoice_reservations fr
              WHERE fr.reservation_id = r.id
           )
     ORDER BY r.start_at, r.id;
END;
$$;

-- Fakturační údaje odběratele. Vlastní funkce proto, že `service_role` má na
-- `subjects` po A5 odebraná práva a číst je naslepo přes tabulku by tu záplatu
-- obcházelo.
CREATE OR REPLACE FUNCTION public.fakturoid_subjekt(_id uuid)
RETURNS TABLE (id uuid, name text, ico text, dic text, address text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační údaje subjektu.';
  END IF;

  -- Bez filtru na `deleted_at` schválně: doklad za starší období musí mít
  -- adresu a IČO i pro subjekt, který byl mezitím skrytý.
  RETURN QUERY
    SELECT s.id, s.name, s.ico, s.dic, s.address
      FROM public.subjects s
     WHERE s.id = _id;
END;
$$;

REVOKE ALL ON FUNCTION public.fakturoid_podklady_klub(uuid,date,date) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_podklady_klub(uuid,date,date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fakturoid_podklady_akce(uuid) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_podklady_akce(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fakturoid_subjekt(uuid) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_subjekt(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.fakturoid_podklady_klub(uuid,date,date) IS
  'Rezervace klubu za období, které ještě NEJSOU u Fakturoidu. Filtr se ptá jen na fakturoidí vazbu — rezervace s interním invoice_id sem pod S2 patří taky.';
