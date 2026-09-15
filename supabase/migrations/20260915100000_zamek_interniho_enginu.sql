-- ZÁMEK INTERNÍHO FAKTURAČNÍHO ENGINU — NEZÁVISLÝ NA DAŇOVÉM REŽIMU
--
-- PROČ: dnes je interní engine zavřený jen jako VEDLEJŠÍ ÚČINEK toho, že hala
-- je v systému vedená jako plátce DPH. Pět vstupních bodů má guard
-- `vat_mode <> 'neplatce'` → RAISE. Jenže hala je ve skutečnosti NEPLÁTCE
-- (ověřeno 4 registry, viz CLAUDE.md) a migrace 20260915090000 to srovnává.
-- Ve chvíli, kdy `vat_mode` přepne na `neplatce`, těch pět guardů zmlkne
-- a tlačítka „Vygenerovat fakturu" (Dues.tsx) a „Vystavit fakturu"
-- (Invoices.tsx) OŽIJÍ. To nikdo nechce: podle rozhodnutí o Etapě 3 vystavuje
-- ostré doklady Fakturoid, interní engine se na ně už nepoužívá.
--
-- Zámek `vat_mode` se přitom RUŠIT NESMÍ a tahle migrace na něj nesahá. Je to
-- záměr z `20260830140000_vat_mode_platce.sql` („interní engine se ZAVŘE pro
-- nové doklady. Není to vedlejší škoda, je to ZÁMĚR.") a po přepnutí na
-- neplátce prostě zmlkne. Od té chvíle drží engine zavřený tenhle druhý,
-- na daňovém režimu NEZÁVISLÝ zámek.
--
-- KUDY MŮŽE VZNIKNOUT INTERNÍ DOKLAD (změřeno na produkci 15. 9. 2026):
-- `authenticated` má na `public.invoices` jen SELECT, žádný INSERT ani UPDATE.
-- Jediná cesta k novému dokladu tedy vede přes SECURITY DEFINER funkce, a ty
-- jsou právě tyhle:
--     create_invoice_draft_club, create_invoice_draft_commercial  (INSERT)
--     issue_invoice                                               (koncept → doklad)
--     dobropis_invoice, storno_invoice                            (INSERT opravného dokladu)
-- Zamykáme všech pět. `billing_automation_tick` sem nepřidáváme schválně —
-- sám do `invoices` nezapisuje, jde přes tyhle funkce, takže ho zavřou ony.
-- (Na produkci je stejně `automation_enabled = false`.)
--
-- DOBROPIS A STORNO JSOU V TOM TAKY, ZÁMĚRNĚ. Vyrábějí nový číslovaný opravný
-- doklad, což je ostrý doklad jako každý jiný. Provozně to dnes nic nestojí:
-- v produkci je `invoices` = 0 řádků, takže není co stornovat ani dobropisovat.
--
-- FAIL-CLOSED. Zámek nedrží seznam „co je zakázané", ale vyžaduje výslovné
-- povolení. Chybí-li řádek nastavení, je hodnota NULL, nebo se `billing_settings`
-- nedá přečíst → engine je ZAVŘENÝ. Otevře ho jedině `interni_engine_povolen = true`.
--
-- PROČ NOVÝ SLOUPEC A NE JEN NATVRDO RAISE: kdyby se engine někdy potřeboval
-- na jeden zásah pustit (třeba dokončit rozdělaný doklad), nemá to stát další
-- migraci. Sloupec je ale ÚMYSLNĚ NEDOSAŽITELNÝ Z APLIKACE — `authenticated`
-- na něj dostane SELECT (bez toho by se rozbil `select('*')` v nastavení
-- fakturace), ale NE UPDATE. Přepnout ho jde jedině servisním zásahem do
-- databáze. `vat_mode` má `authenticated` ve sloupcových grantech na UPDATE,
-- takže ho admin přepne z obrazovky Nastavení → kdyby zámek visel na něm,
-- otevřel by se omylem jedním kliknutím. Tenhle se takhle otevřít nedá.

-- ── 1) Přepínač ──────────────────────────────────────────────────────────────

ALTER TABLE public.billing_settings
  ADD COLUMN IF NOT EXISTS interni_engine_povolen boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.billing_settings.interni_engine_povolen IS
  'Smí interní fakturační engine vystavovat doklady? Výchozí false — ostré doklady '
  'dělá Fakturoid (Etapa 3). Nezávislé na vat_mode. Z aplikace jen ke čtení, '
  'přepnutí je servisní zásah.';

-- SELECT ano (jinak spadne `select(''*'')` v Nastavení → Fakturace), UPDATE NE.
GRANT SELECT (interni_engine_povolen) ON public.billing_settings TO authenticated;
REVOKE UPDATE (interni_engine_povolen) ON public.billing_settings FROM authenticated;

-- ── 2) Zámek ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.over_interni_engine()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  _povolen boolean;
BEGIN
  SELECT bs.interni_engine_povolen INTO _povolen
    FROM public.billing_settings bs
   WHERE bs.singleton;

  -- FAIL-CLOSED: `NOT FOUND` nechá `_povolen` na NULL a COALESCE ho srazí na
  -- false. Chybějící nastavení tedy engine ZAVÍRÁ, ne otevírá.
  IF COALESCE(_povolen, false) THEN
    RETURN;
  END IF;

  -- RADA JE V `message`, NE JEN V `HINT`: frontend (`useInvoices.ts`) propouští
  -- `error.message` a `hint` z PostgrestError zahazuje. Bez toho by se admin
  -- dozvěděl, že to nejde, ale ne proč a kudy jinudy.
  RAISE EXCEPTION 'Interní fakturační engine je vyřazený — ostré doklady vystavuje Fakturoid. Doklad založ tam.'
    USING HINT = 'Povolit ho jde jedině servisním zásahem do databáze '
               || '(billing_settings.interni_engine_povolen), z aplikace to nejde.';
END;
$$;

COMMENT ON FUNCTION public.over_interni_engine() IS
  'Fail-closed zámek interního fakturačního enginu. Nezávislý na vat_mode. '
  'Volá se ze všech pěti funkcí, které umí založit interní doklad.';

REVOKE ALL ON FUNCTION public.over_interni_engine() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.over_interni_engine() TO authenticated;

-- ── 3) Pět vstupních bodů ────────────────────────────────────────────────────
--
-- Těla jsou VYGENEROVANÁ z `pg_get_functiondef` živého schématu (pravidlo 7
-- v CLAUDE.md) a je do nich vložený JEDINÝ řádek: `PERFORM public.over_interni_engine();`
-- hned za kontrolou admina. Nic jiného se v nich nemění — původní zábrana na
-- `vat_mode` v nich zůstává beze změny.

-- ---- create_invoice_draft_club ----
CREATE OR REPLACE FUNCTION public.create_invoice_draft_club(_subject_id uuid, _obdobi_od date, _obdobi_do date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid      uuid := auth.uid();
  _invoice  uuid;
  _od       timestamptz;
  _do       timestamptz;
  _pocet    integer;
  _bez_ceny integer;
  _ukazky   text;
BEGIN
  -- Výjimka pro plánovač: běh BEZ tokenu a pod databázovou rolí.
  -- Z webu nedosažitelná (PostgREST se připojuje jako `authenticator`).
  IF NOT (_uid IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;

  -- ZÁMEK INTERNÍHO ENGINU. Nezávislý na daňovém režimu — viz migrace
  -- 20260915100000_zamek_interniho_enginu.sql. Stojí AŽ ZA kontrolou admina
  -- schválně: neadminovi nemá co prozrazovat, jak je hala nakonfigurovaná.
  PERFORM public.over_interni_engine();

  -- REŽIM DPH — TÁŽ ZÁBRANA JAKO V `issue_invoice`, jen o krok dřív.
  --
  -- Bez ní vznikla past: pod plátcem koncept normálně vznikl, ZAMKL rezervace
  -- (`invoice_id` + `invoiced_at`) a vystavit ho pak už nešlo. Admin v „Kdo
  -- dluží" klikl, dostal „Koncept faktury založen" a o obrazovku dál narazil —
  -- s rezervacemi visícími na dokladu, který nikdy nevznikne. `k_fakturaci`
  -- u toho subjektu přitom spadlo na nulu, zatímco fakturoidí strana měla
  -- pořád co fakturovat. Ověřeno: 6 zamčených rezervací.
  --
  -- Zábrana je ZÁMĚRNĚ PŘED zabráním rezervací: odmítnout se musí dřív, než se
  -- něco zamkne, jinak by po sobě musela uklízet.
  IF COALESCE((SELECT vat_mode FROM public.billing_settings WHERE singleton),
              'neplatce') <> 'neplatce' THEN
    -- RADA JE V `message`, NE JEN V `HINT`. Frontend (`useInvoices.ts`) propouští
    -- `error.message` a `hint` z PostgrestError zahazuje, takže by se admin
    -- dozvěděl, že to nejde, ale ne kudy jinudy. `HINT` zůstává pro psql a logy.
    RAISE EXCEPTION 'Doklad umí zatím jen režim neplátce DPH (nastaveno: %). Ostré doklady vystavuje Fakturoid, ne tenhle interní engine.',
      (SELECT vat_mode FROM public.billing_settings WHERE singleton)
      USING HINT = 'Hala je vedená jako plátce — ostré doklady vystavuje Fakturoid, ne interní engine.';
  END IF;
  IF _obdobi_od IS NULL OR _obdobi_do IS NULL OR _obdobi_do < _obdobi_od THEN
    RAISE EXCEPTION 'Neplatné období faktury (od % do %).', _obdobi_od, _obdobi_do;
  END IF;
  -- `deleted_at` schválně: fakturovat za skrytý subjekt je skoro jistě omyl.
  -- (Doklad na už vystavené faktuře zůstane čitelný — snapshot odběratele je na ní.)
  IF NOT EXISTS (SELECT 1 FROM public.subjects WHERE id = _subject_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Subjekt neexistuje nebo je skrytý.';
  END IF;

  SELECT zacatek, konec INTO _od, _do FROM public.obdobi_hranice(_obdobi_od, _obdobi_do);

  -- Rezervace bez sazby by se do dokladu nedostala (`sazba` je NOT NULL) a tiše
  -- by z faktury vypadla — což je přesně ten rozdíl, který má kontrolní součet
  -- odhalit. Radši nevystavit nic než vystavit neúplné.
  -- Kontroluje se i NULA, ne jen NULL: A2 pouští `corrected_hours = 0` a odepsat
  -- klubu hodinu na nulu („nedorazili, neúčtujeme") je přirozený postup. Položka
  -- by pak narazila na `invoice_items_hodiny_kladne` a celá měsíční faktura by
  -- spadla na neutrální hlášku z EXCEPTION bloku — admin by neměl jak zjistit,
  -- KTERÁ rezervace za to může. Hláška proto rovnou jmenuje termíny.
  SELECT count(*), string_agg(to_char(f.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI'), ', '
                              ORDER BY f.start_at)
    INTO _bez_ceny, _ukazky
    FROM public.fakturovatelne_rezervace(_subject_id, _od, _do) f
   WHERE f.invoice_id IS NULL
     AND (f.sazba IS NULL OR f.hodiny IS NULL OR f.hodiny <= 0);
  IF _bez_ceny > 0 THEN
    RAISE EXCEPTION 'Období obsahuje % rezervací bez sazby nebo s nulovými hodinami (%).', _bez_ceny, _ukazky
      USING HINT = 'Nulovou korekci zruš, nebo rezervaci stornuj — na doklad nulový řádek nepatří.';
  END IF;

  INSERT INTO public.invoices (kind, status, subject_id, obdobi_od, obdobi_do, created_by, updated_by)
  VALUES ('klub', 'koncept', _subject_id, _obdobi_od, _obdobi_do, _uid, _uid)
  RETURNING id INTO _invoice;

  -- Zabrání rezervací a naplnění položek v JEDNOM příkazu: co se nepodařilo
  -- zabrat (mezitím je zabral jiný běh), se do položek vůbec nedostane.
  PERFORM set_config('app.trusted_booking', 'on', true);

  WITH zabrane AS (
    UPDATE public.reservations r
       SET invoice_id  = _invoice,
           invoiced_at = now()
     -- `ORDER BY id FOR UPDATE` v poddotazu: obě fakturační RPC musí zamykat řádky
     -- ve STEJNÉM pořadí. Bez toho jely každá po jiném plánu (klub přes function
     -- scan, komerce přes index na `event_id`) a při souběhu o tytéž rezervace
     -- vznikl deadlock — reprodukovatelně. Data se nerozbila, ale poražený dostal
     -- holou postgresovou hlášku; ve fázi D (běh vedle ručního kliknutí) by to
     -- trefovalo pravidelně.
     WHERE r.id IN (
       SELECT r2.id FROM public.reservations r2
        WHERE r2.id IN (SELECT f.id FROM public.fakturovatelne_rezervace(_subject_id, _od, _do) f
                         WHERE f.invoice_id IS NULL)
        ORDER BY r2.id
        FOR UPDATE
     )
       -- NOSNÁ PODMÍNKA, NE DUPLICITA. V READ COMMITTED se po čekání na zámek
       -- přehodnocuje jen kvalifikace nad NOVOU verzí cílového řádku; podmínka
       -- schovaná uvnitř funkce se vyhodnocuje proti PŮVODNÍMU snapshotu příkazu,
       -- tedy proti stavu před cizím COMMITem. Kdo tenhle řádek uklidí jako
       -- nadbytečný, otevře dvojí fakturaci.
       AND r.invoice_id IS NULL          -- ← vlastní atomický claim (R1)
    RETURNING r.id, r.start_at, r.end_at, r.sheet_id, r.event_id,
              COALESCE(r.corrected_hours, r.hours)   AS hodiny,
              r.rate_per_hour                        AS sazba,
              COALESCE(r.corrected_amount, r.amount) AS castka
  )
  INSERT INTO public.invoice_items
    (invoice_id, reservation_id, popis, datum, cas_od, cas_do, hodiny, sazba, line_total, poradi)
  SELECT _invoice,
         z.id,
         concat_ws(' — ',
           'Pronájem ledové plochy',
           sh.name,
           nullif(e.title, '')),
         (z.start_at AT TIME ZONE 'Europe/Prague')::date,
         z.start_at,
         z.end_at,
         z.hodiny,
         z.sazba,
         z.castka,
         row_number() OVER (ORDER BY z.start_at, z.id)
    FROM zabrane z
    JOIN public.sheets sh ON sh.id = z.sheet_id
    LEFT JOIN public.events e ON e.id = z.event_id;

  GET DIAGNOSTICS _pocet = ROW_COUNT;
  PERFORM set_config('app.trusted_booking', 'off', true);

  IF _pocet = 0 THEN
    -- Prázdná faktura se nevystavuje (spec, okrajové případy).
    --
    -- Koncept se schválně NEMAŽE ručně: `RAISE` má SQLSTATE P0001, takže ho
    -- vlastní EXCEPTION blok téhle funkce (chytá jen porušení constraintů)
    -- nezachytí — propadne ven, subtransakce se odrolluje a INSERT hlavičky
    -- zmizí s ní. `DELETE` navíc by byl kód, který nikdy nic neudělá.
    RAISE EXCEPTION 'Za zvolené období není co fakturovat.'
      USING HINT = 'Buď v období nejsou zpoplatněné rezervace, nebo už jsou všechny vyfakturované, nebo čekají na schválení zástupcem klubu.';
  END IF;

  RETURN _invoice;

EXCEPTION
  -- Deadlock je dostupnostní věc, ne účetní: data zůstanou v pořádku, ale
  -- poražený by jinak dostal holou postgresovou hlášku. Ať aspoň ví, co má udělat.
  WHEN deadlock_detected THEN
    RAISE EXCEPTION 'Fakturu právě zakládá někdo jiný — zkus to prosím znovu.'
      USING ERRCODE = '40P01';
  -- Uvnitř SECURITY DEFINER neplatí RLS, takže Postgres do chyby doplní
  -- „Failing row contains (…)" s celým řádkem — a PostgREST ho u RPC pošle
  -- klientovi. U faktury je v tom řádku snapshot dodavatele i s IBANem
  -- (rozhodnutí R11, nález 8b). Chyba se proto překládá na neutrální hlášku.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Fakturu se nepodařilo sestavit — data rezervací neodpovídají pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj hodiny, sazbu a částky rezervací v období.';
END;
$function$;

-- ---- create_invoice_draft_commercial ----
CREATE OR REPLACE FUNCTION public.create_invoice_draft_commercial(_event_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid        uuid := auth.uid();
  _invoice    uuid;
  _subject_id uuid;
  _subjektu   integer;
  _od         date;
  _do         date;
  _pocet      integer;
  _bez_ceny   integer;
  _jen_schvalene boolean;
BEGIN
  -- Výjimka pro plánovač: běh BEZ tokenu a pod databázovou rolí.
  -- Z webu nedosažitelná (PostgREST se připojuje jako `authenticator`).
  IF NOT (_uid IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;

  -- ZÁMEK INTERNÍHO ENGINU. Nezávislý na daňovém režimu — viz migrace
  -- 20260915100000_zamek_interniho_enginu.sql. Stojí AŽ ZA kontrolou admina
  -- schválně: neadminovi nemá co prozrazovat, jak je hala nakonfigurovaná.
  PERFORM public.over_interni_engine();

  -- REŽIM DPH — TÁŽ ZÁBRANA JAKO V `issue_invoice`, jen o krok dřív.
  --
  -- Bez ní vznikla past: pod plátcem koncept normálně vznikl, ZAMKL rezervace
  -- (`invoice_id` + `invoiced_at`) a vystavit ho pak už nešlo. Admin v „Kdo
  -- dluží" klikl, dostal „Koncept faktury založen" a o obrazovku dál narazil —
  -- s rezervacemi visícími na dokladu, který nikdy nevznikne. `k_fakturaci`
  -- u toho subjektu přitom spadlo na nulu, zatímco fakturoidí strana měla
  -- pořád co fakturovat. Ověřeno: 6 zamčených rezervací.
  --
  -- Zábrana je ZÁMĚRNĚ PŘED zabráním rezervací: odmítnout se musí dřív, než se
  -- něco zamkne, jinak by po sobě musela uklízet.
  IF COALESCE((SELECT vat_mode FROM public.billing_settings WHERE singleton),
              'neplatce') <> 'neplatce' THEN
    -- RADA JE V `message`, NE JEN V `HINT`. Frontend (`useInvoices.ts`) propouští
    -- `error.message` a `hint` z PostgrestError zahazuje, takže by se admin
    -- dozvěděl, že to nejde, ale ne kudy jinudy. `HINT` zůstává pro psql a logy.
    RAISE EXCEPTION 'Doklad umí zatím jen režim neplátce DPH (nastaveno: %). Ostré doklady vystavuje Fakturoid, ne tenhle interní engine.',
      (SELECT vat_mode FROM public.billing_settings WHERE singleton)
      USING HINT = 'Hala je vedená jako plátce — ostré doklady vystavuje Fakturoid, ne interní engine.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = _event_id) THEN
    RAISE EXCEPTION 'Akce neexistuje.';
  END IF;

  -- `min()` na uuid v Postgresu není, proto `array_agg(DISTINCT …)[1]`. Prvek se
  -- bere až po kontrole, že je subjekt právě jeden, takže na pořadí nezáleží.
  SELECT count(DISTINCT r.subject_id),
         (array_agg(DISTINCT r.subject_id))[1],
         min((r.start_at AT TIME ZONE 'Europe/Prague')::date),
         max((r.start_at AT TIME ZONE 'Europe/Prague')::date)
    INTO _subjektu, _subject_id, _od, _do
    FROM public.reservations r
   WHERE r.event_id = _event_id
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL;

  IF COALESCE(_subjektu, 0) = 0 THEN
    RAISE EXCEPTION 'K akci nejsou žádné zpoplatněné rezervace.'
      USING HINT = 'Buď je akce bez zákazníka, nebo jsou její rezervace stornované.';
  END IF;
  IF _subjektu > 1 THEN
    -- Nikdy by nemělo nastat (create_booking drží jeden subjekt na akci), ale
    -- hádat, komu se má doklad vystavit, je horší než se zeptat.
    RAISE EXCEPTION 'Akce má rezervace pro víc odběratelů — fakturu vystav ručně po subjektech.';
  END IF;

  SELECT COALESCE(bs.invoice_only_approved, true) INTO _jen_schvalene
    FROM public.billing_settings bs LIMIT 1;
  _jen_schvalene := COALESCE(_jen_schvalene, true);

  SELECT count(*) INTO _bez_ceny
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.status = 'confirmed' AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL AND r.invoice_id IS NULL
     AND (NOT _jen_schvalene OR r.approved_at IS NOT NULL)
     AND (r.rate_per_hour IS NULL OR COALESCE(r.corrected_hours, r.hours) IS NULL);
  IF _bez_ceny > 0 THEN
    RAISE EXCEPTION 'Akce obsahuje % rezervací bez sazby nebo bez hodin — doklad by byl neúplný.', _bez_ceny
      USING HINT = 'Doplň sazbu u rezervace (nebo ceník) a založ fakturu znovu.';
  END IF;

  INSERT INTO public.invoices (kind, status, subject_id, event_id, obdobi_od, obdobi_do, created_by, updated_by)
  VALUES ('komercni', 'koncept', _subject_id, _event_id, _od, _do, _uid, _uid)
  RETURNING id INTO _invoice;

  PERFORM set_config('app.trusted_booking', 'on', true);

  WITH zabrane AS (
    UPDATE public.reservations r
       SET invoice_id  = _invoice,
           invoiced_at = now()
     -- Totéž pořadí zámků jako u klubové cesty, ze stejného důvodu (deadlock).
     WHERE r.id IN (
       SELECT r2.id FROM public.reservations r2
        WHERE r2.event_id = _event_id
          AND r2.status = 'confirmed'
          AND r2.deleted_at IS NULL
          AND r2.subject_id IS NOT NULL
          AND r2.invoice_id IS NULL
          -- Rozhodnutí PM k Q4 platí na OBOU cestách. Dřív ho ctila jen klubová,
          -- takže by komerční akce vyfakturovala i neschválenou rezervaci — a rozdíl
          -- by se objevil až v kontrolním součtu jako nevysvětlitelný.
          AND (NOT _jen_schvalene OR r2.approved_at IS NOT NULL)
        ORDER BY r2.id
        FOR UPDATE
     )
       AND r.invoice_id IS NULL          -- ← nosná podmínka, viz klubová cesta
    RETURNING r.id, r.start_at, r.end_at, r.sheet_id,
              COALESCE(r.corrected_hours, r.hours)   AS hodiny,
              r.rate_per_hour                        AS sazba,
              COALESCE(r.corrected_amount, r.amount) AS castka
  )
  INSERT INTO public.invoice_items
    (invoice_id, reservation_id, popis, datum, cas_od, cas_do, hodiny, sazba, line_total, poradi)
  SELECT _invoice,
         z.id,
         concat_ws(' — ', 'Pronájem ledové plochy', sh.name,
                   nullif((SELECT e.title FROM public.events e WHERE e.id = _event_id), '')),
         (z.start_at AT TIME ZONE 'Europe/Prague')::date,
         z.start_at,
         z.end_at,
         z.hodiny,
         z.sazba,
         z.castka,
         row_number() OVER (ORDER BY z.start_at, z.id)
    FROM zabrane z
    JOIN public.sheets sh ON sh.id = z.sheet_id;

  GET DIAGNOSTICS _pocet = ROW_COUNT;
  PERFORM set_config('app.trusted_booking', 'off', true);

  IF _pocet = 0 THEN
    -- Hlavičku netřeba mazat, viz tentýž případ v `create_invoice_draft_club`.
    RAISE EXCEPTION 'Akce je už celá vyfakturovaná.';
  END IF;

  RETURN _invoice;

EXCEPTION
  WHEN deadlock_detected THEN
    RAISE EXCEPTION 'Fakturu právě zakládá někdo jiný — zkus to prosím znovu.'
      USING ERRCODE = '40P01';
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Fakturu se nepodařilo sestavit — data rezervací neodpovídají pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj hodiny, sazbu a částky rezervací akce.';
END;
$function$;

-- ---- issue_invoice ----
CREATE OR REPLACE FUNCTION public.issue_invoice(_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid      uuid := auth.uid();
  _f        record;
  _bs       record;
  _sub      record;
  _cislo    text;
  _rada     text;
  _rok      integer;
  _dnes     date;
  _chybi    text[] := ARRAY[]::text[];
  _splatnost date;
  _zrusenych integer;
  _ukazky    text;
BEGIN
  -- Výjimka pro plánovač: běh BEZ tokenu a pod databázovou rolí.
  -- Z webu nedosažitelná (PostgREST se připojuje jako `authenticator`).
  IF NOT (_uid IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;

  -- ZÁMEK INTERNÍHO ENGINU. Nezávislý na daňovém režimu — viz migrace
  -- 20260915100000_zamek_interniho_enginu.sql. Stojí AŽ ZA kontrolou admina
  -- schválně: neadminovi nemá co prozrazovat, jak je hala nakonfigurovaná.
  PERFORM public.over_interni_engine();

  -- Zámek řádku: dvě souběžná kliknutí na „Vystavit" jinak vyrobí dvě čísla,
  -- z nichž jedno spadne na immutabilitě — a v řadě zůstane díra.
  SELECT * INTO _f FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Faktura neexistuje.';
  END IF;
  IF _f.status <> 'koncept' THEN
    RAISE EXCEPTION 'Vystavit lze jen koncept (tenhle doklad je ve stavu %).', _f.status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.invoice_items WHERE invoice_id = _invoice_id) THEN
    RAISE EXCEPTION 'Prázdná faktura se nevystavuje.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;
  SELECT * INTO _sub FROM public.subjects WHERE id = _f.subject_id;

  -- ÚPLNOST ÚDAJŮ. Spec (okrajové případy) to žádá výslovně: neúplné údaje →
  -- fakturu nevystavit a upozornit admina. Hláška proto vyjmenuje, CO chybí —
  -- „nelze vystavit" bez důvodu je pro admina slepá ulička.
  IF _bs IS NULL OR nullif(btrim(coalesce(_bs.supplier_name, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'název dodavatele');
  END IF;
  IF _bs IS NULL OR nullif(btrim(coalesce(_bs.supplier_address, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'sídlo dodavatele');
  END IF;
  IF _bs IS NULL OR nullif(btrim(coalesce(_bs.supplier_ico, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'IČO dodavatele');
  END IF;
  IF _bs IS NULL OR (nullif(btrim(coalesce(_bs.bank_account, '')), '') IS NULL
                     AND nullif(btrim(coalesce(_bs.bank_iban, '')), '') IS NULL) THEN
    _chybi := array_append(_chybi, 'bankovní účet dodavatele');
  END IF;
  IF nullif(btrim(coalesce(_sub.name, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'název odběratele');
  END IF;
  -- IČO odběratele se vyžaduje u FIRMY, ne u klubu. Spolky ho v systému běžně
  -- vyplněné nemají a zablokovat jim fakturu by znamenalo nevyfakturovat led —
  -- kdežto u komerční akce je odběratelem firma a IČO je náležitost dokladu.
  IF _sub.type = 'commercial' AND nullif(btrim(coalesce(_sub.ico, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'IČO odběratele (firmy)');
  END IF;
  -- Sídlo odběratele je náležitost dokladu (spec, bod 3) u klubu i u firmy.
  IF nullif(btrim(coalesce(_sub.address, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'sídlo odběratele');
  END IF;

  -- REŽIM DPH: doklad umí zatím jen neplátce. Sloupce `vat_*` na položkách jsou
  -- prázdné místo (čekají na otázku Q7 od účetní), takže v plátcovském režimu by
  -- doklad vyšel bez vyčíslené daně A ZÁROVEŇ bez doložky — vypadal by jako
  -- neplátcovský, aniž by to řekl. Radši nevystavit než vystavit doklad, který
  -- o svém daňovém režimu mlčí.
  IF COALESCE(_bs.vat_mode, 'neplatce') <> 'neplatce' THEN
    RAISE EXCEPTION 'Doklad umí zatím jen režim neplátce DPH (nastaveno: %).', _bs.vat_mode
      USING HINT = 'Plátcovský režim potřebuje dopočet DPH na položkách — čeká na rozhodnutí účetní (otázka Q7).';
  END IF;

  IF array_length(_chybi, 1) > 0 THEN
    RAISE EXCEPTION 'Fakturu nelze vystavit — chybí: %.', array_to_string(_chybi, ', ')
      USING HINT = 'Doplň údaje v Nastavení → Fakturace, případně u odběratele (načtením z ARESu).';
  END IF;

  -- ZRUŠENÁ REZERVACE NA KONCEPTU. Klub odvolá termín, který zrovna visí na
  -- konceptu — běžná posloupnost, ne exotika. Bez téhle kontroly se doklad
  -- vystaví, stane se neměnným, a `billing_health.vyfakturovane_zrusene` se ozve
  -- AŽ POTOM: hlásí přesně ve chvíli, kdy se s tím už nedá nic dělat, protože
  -- storno ani dobropis v tomhle rozsahu nejsou. Detekce po činu je u nevratného
  -- kroku k ničemu — tady musí stát prevence.
  SELECT count(*), string_agg(to_char(r.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI'), ', '
                              ORDER BY r.start_at)
    INTO _zrusenych, _ukazky
    FROM public.invoice_items it
    JOIN public.reservations r ON r.id = it.reservation_id
   WHERE it.invoice_id = _invoice_id
     AND (r.deleted_at IS NOT NULL OR r.status <> 'confirmed');

  IF _zrusenych > 0 THEN
    RAISE EXCEPTION 'Na konceptu je % zrušených rezervací (%) — doklad by účtoval led, který se nekonal.',
      _zrusenych, _ukazky
      USING HINT = 'Zahoď koncept a založ ho znovu; zrušené rezervace už do něj nespadnou.';
  END IF;

  -- Číslo až tady, ne u konceptu: smazaný koncept by jinak udělal v řadě díru.
  --
  -- POZOR NA `current_date`: databáze běží v UTC, takže 1. ledna v 00:30 pražského
  -- času je `current_date` pořád 31. prosince. Doklad by dostal LOŇSKÝ rok v čísle
  -- a včerejší datum vystavení — chyba, která se stane jednou za rok, projeví se
  -- na číselné řadě a odhalí se v únoru. Zbytek modulu počítá pražsky
  -- (`obdobi_hranice`), tak ať i tohle.
  _dnes := (now() AT TIME ZONE 'Europe/Prague')::date;
  _rok  := EXTRACT(year FROM _dnes)::integer;

  -- ODDĚLENÉ ŘADY NEJSOU IMPLEMENTOVANÉ a tenhle blok to říká nahlas, místo aby
  -- je předstíral. Přepínač `separate_series` sám o sobě dělá jen to, že se
  -- pořadí bere z jiného řádku počítadla — jenže `next_invoice_number` počítá
  -- nejvyšší použité pořadí přes VŠECHNY faktury roku a vydává vždycky tvar
  -- `RRRRNNNN`. Zapnutá volba by tedy vyrobila jednu prokládanou řadu ve formátu,
  -- který CHECK `billing_settings_series_format` pro tenhle režim ani nepovoluje
  -- (žádá `RRRRSNNN`). Rozhodnutí PM (Q6) zní „jedna společná řada", takže
  -- správná reakce je zastavit se, ne vystavit doklad se špatným číslem.
  IF COALESCE(_bs.separate_series, false) THEN
    RAISE EXCEPTION 'Oddělené číselné řady zatím nejsou implementované.'
      USING HINT = 'V Nastavení → Fakturace nech „jedna společná řada" (rozhodnutí PM k otázce Q6).';
  END IF;
  _rada := 'spolecna';
  _cislo := public.next_invoice_number(_rada, _rok);
  _splatnost := _dnes + COALESCE(_bs.due_days, 14);

  UPDATE public.invoices SET
      status            = 'vystaveno',
      cislo             = _cislo,
      -- Variabilní symbol = číslo bez nečíselných znaků (spec, bod 4).
      variabilni_symbol = regexp_replace(_cislo, '\D', '', 'g'),
      datum_vystaveni   = _dnes,
      datum_splatnosti  = _splatnost,
      issued_at         = now(),
      issued_by         = _uid,
      -- Doklad jde rovnou do fronty na PDF. Render se dělá až potom (R4/R5):
      -- číslo je vytištěné v PDF, takže musí být přidělené dřív, a selhání
      -- renderu nesmí udělat díru v řadě.
      pdf_status        = 'pending',
      -- ---- snapshot dodavatele ----
      dodavatel_nazev    = _bs.supplier_name,
      dodavatel_adresa   = _bs.supplier_address,
      dodavatel_ico      = _bs.supplier_ico,
      dodavatel_dic      = _bs.supplier_dic,
      dodavatel_rejstrik = _bs.supplier_registry,
      dodavatel_ucet     = _bs.bank_account,
      dodavatel_iban     = _bs.bank_iban,
      dodavatel_zprava   = _bs.payment_message,
      vat_mode           = COALESCE(_bs.vat_mode, 'neplatce'),
      -- ---- snapshot odběratele ----
      odberatel_nazev  = _sub.name,
      odberatel_adresa = _sub.address,
      odberatel_ico    = _sub.ico,
      odberatel_dic    = _sub.dic
   WHERE id = _invoice_id;

  RETURN jsonb_build_object(
    'id', _invoice_id,
    'cislo', _cislo,
    'variabilni_symbol', regexp_replace(_cislo, '\D', '', 'g'),
    'datum_splatnosti', _splatnost,
    'total', (SELECT total FROM public.invoices WHERE id = _invoice_id),
    'total_rounded', (SELECT total_rounded FROM public.invoices WHERE id = _invoice_id)
  );

EXCEPTION
  -- R11 doslova: tahle funkce sahá na `billing_settings` uvnitř SECURITY DEFINER,
  -- takže při porušení constraintu by PostgREST poslal klientovi celý řádek
  -- i s IBANem a číslem účtu.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Doklad se nepodařilo vystavit — údaje neodpovídají pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj fakturační nastavení a údaje odběratele.';
END;
$function$;

-- ---- dobropis_invoice ----
CREATE OR REPLACE FUNCTION public.dobropis_invoice(_invoice_id uuid, _polozky uuid[], _duvod text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid    uuid := auth.uid();
  _p      record;
  _bs     record;
  _opr    uuid;
  _cislo  text;
  _dnes   date;
  _radku  integer;
  _castka numeric(12,2);
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Opravné doklady vystavuje jen správce haly.';
  END IF;

  -- ZÁMEK INTERNÍHO ENGINU. Nezávislý na daňovém režimu — viz migrace
  -- 20260915100000_zamek_interniho_enginu.sql. Stojí AŽ ZA kontrolou admina
  -- schválně: neadminovi nemá co prozrazovat, jak je hala nakonfigurovaná.
  PERFORM public.over_interni_engine();

  SELECT * INTO _p FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Doklad neexistuje.';
  END IF;
  IF _p.status = 'koncept' THEN
    RAISE EXCEPTION 'Koncept se nedobropisuje — uprav ho, nebo zahoď.';
  END IF;
  IF _p.status = 'stornovano' THEN
    RAISE EXCEPTION 'Doklad % je celý stornovaný, není co dobropisovat.', _p.cislo;
  END IF;
  IF _p.opravuje_id IS NOT NULL THEN
    RAISE EXCEPTION 'Opravný doklad se sám nedobropisuje.';
  END IF;
  IF _polozky IS NULL OR array_length(_polozky, 1) IS NULL THEN
    RAISE EXCEPTION 'Vyber aspoň jednu položku k dobropisu.'
      USING HINT = 'Na celý doklad je storno, ne dobropis.';
  END IF;

  -- Všechny vybrané položky musí patřit TOMUHLE dokladu. Bez téhle kontroly by
  -- šlo dobropisovat řádky z cizí faktury a částky by se rozešly u obou.
  SELECT count(*), COALESCE(sum(line_total), 0) INTO _radku, _castka
    FROM public.invoice_items
   WHERE id = ANY (_polozky) AND invoice_id = _invoice_id;

  IF _radku <> array_length(_polozky, 1) THEN
    RAISE EXCEPTION 'Některé vybrané položky na dokladu % nejsou.', _p.cislo
      USING HINT = 'Dobropisovat jde jen řádky téhle faktury.';
  END IF;
  IF _castka <= 0 THEN
    RAISE EXCEPTION 'Dobropis na nulovou částku nedává smysl.';
  END IF;

  -- Celý doklad = storno, ne dobropis. Jinak by vznikl opravný doklad na plnou
  -- částku, ale originál by dál platil a rezervace zůstaly zamčené — stav,
  -- ze kterého není cesta ven.
  IF _radku = (SELECT count(*) FROM public.invoice_items WHERE invoice_id = _invoice_id) THEN
    RAISE EXCEPTION 'Vybral jsi všechny položky — na celý doklad použij storno.'
      USING HINT = 'Storno navíc uvolní rezervace zpět k fakturaci; dobropis je schválně nechává zamčené.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;
  IF COALESCE(_bs.separate_series, false) THEN
    RAISE EXCEPTION 'Oddělené číselné řady zatím nejsou implementované.';
  END IF;

  _dnes := (now() AT TIME ZONE 'Europe/Prague')::date;

  INSERT INTO public.invoices (
      kind, status, subject_id, event_id, obdobi_od, obdobi_do,
      dodavatel_nazev, dodavatel_adresa, dodavatel_ico, dodavatel_dic,
      dodavatel_rejstrik, dodavatel_ucet, dodavatel_iban, dodavatel_zprava,
      vat_mode, odberatel_nazev, odberatel_adresa, odberatel_ico, odberatel_dic,
      opravuje_id, storno_duvod, created_by, je_plne_storno)
  VALUES (
      _p.kind, 'koncept', _p.subject_id, _p.event_id, _p.obdobi_od, _p.obdobi_do,
      _p.dodavatel_nazev, _p.dodavatel_adresa, _p.dodavatel_ico, _p.dodavatel_dic,
      _p.dodavatel_rejstrik, _p.dodavatel_ucet, _p.dodavatel_iban, _p.dodavatel_zprava,
      _p.vat_mode, _p.odberatel_nazev, _p.odberatel_adresa, _p.odberatel_ico, _p.odberatel_dic,
      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid, false)
  RETURNING id INTO _opr;

  -- Zrcadlo VYBRANÝCH řádků.
  INSERT INTO public.invoice_items (
      invoice_id, reservation_id, popis, datum, cas_od, cas_do,
      hodiny, sazba, line_total, vat_rate, vat_base, vat_amount, poradi)
  SELECT _opr, it.reservation_id, it.popis, it.datum, it.cas_od, it.cas_do,
         it.hodiny, it.sazba, it.line_total, it.vat_rate, it.vat_base, it.vat_amount, it.poradi
    FROM public.invoice_items it
   WHERE it.id = ANY (_polozky)
   ORDER BY it.poradi, it.datum;

  _cislo := public.next_invoice_number('spolecna', EXTRACT(year FROM _dnes)::integer);

  UPDATE public.invoices SET
      status = 'vystaveno', cislo = _cislo,
      variabilni_symbol = regexp_replace(_cislo, '\D', '', 'g'),
      datum_vystaveni = _dnes, datum_splatnosti = _dnes,
      issued_at = now(), issued_by = _uid,
      pdf_status = 'pending'
   WHERE id = _opr;

  -- CO SE SCHVÁLNĚ NEDĚJE: nesráží se částka na rezervaci.
  --
  -- Zkusil jsem to a schéma to odmítlo — `corrected_amount` PŘEPISUJE cenový
  -- trigger, protože je odvozený z `corrected_hours`. A hlavně to není potřeba:
  -- rovnice kontrolního součtu porovnává rezervace proti řádkům dokladů, a ani
  -- jedno se dobropisem nemění. Rezervace zůstává zamčená na původní faktuře
  -- (R1) a její řádek na ní dál je.
  --
  -- Kolik z vyfakturovaného se vrátilo, tedy NENÍ v rovnici — je to vlastní
  -- sloupec `dobropisovano`. Rovnice hlídá rozejití rezervací a dokladů;
  -- „kolik klub po dobropisu opravdu zaplatí" je jiná otázka a zaslouží si
  -- vlastní číslo, ne schované v `fakturovano`.

  RETURN jsonb_build_object(
    'opravny_id', _opr,
    'opravny_cislo', _cislo,
    'dobropisovano', _castka,
    'radku', _radku,
    'puvodni_cislo', _p.cislo);

EXCEPTION
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Opravný doklad se nepodařilo vystavit.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj vybrané položky a stav dokladu v Přehledu fakturace.';
END;
$function$;

-- ---- storno_invoice ----
CREATE OR REPLACE FUNCTION public.storno_invoice(_invoice_id uuid, _duvod text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid    uuid := auth.uid();
  _p      record;      -- původní doklad
  _bs     record;
  _opr    uuid;        -- opravný doklad
  _cislo  text;
  _dnes   date;
  _uvolneno integer;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Doklady stornuje jen správce haly.';
  END IF;

  -- ZÁMEK INTERNÍHO ENGINU. Nezávislý na daňovém režimu — viz migrace
  -- 20260915100000_zamek_interniho_enginu.sql. Stojí AŽ ZA kontrolou admina
  -- schválně: neadminovi nemá co prozrazovat, jak je hala nakonfigurovaná.
  PERFORM public.over_interni_engine();

  -- Zámek: dvě souběžná kliknutí na „Stornovat" by jinak vyrobila dva opravné
  -- doklady, tedy dvě čísla v řadě a dvojí vrácení téže částky.
  SELECT * INTO _p FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Doklad neexistuje.';
  END IF;

  -- Koncept se stornovat nedá, protože ještě není dokladem — ten se zahazuje
  -- (`delete_invoice_draft`). Kdyby se na něj vystavil opravný doklad, vzniklo by
  -- číslo v řadě k dokladu, který nikdy neexistoval.
  IF _p.status = 'koncept' THEN
    RAISE EXCEPTION 'Koncept se nestornuje — zahoď ho.'
      USING HINT = 'Storno je na vystavené doklady; koncept ještě dokladem není.';
  END IF;
  IF _p.status = 'stornovano' THEN
    RAISE EXCEPTION 'Doklad % je už stornovaný.', _p.cislo;
  END IF;
  IF _p.opravuje_id IS NOT NULL THEN
    RAISE EXCEPTION 'Opravný doklad se sám nestornuje.'
      USING HINT = 'Ruší se jím původní faktura; další opravný doklad na něj nepatří.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;
  IF COALESCE(_bs.separate_series, false) THEN
    RAISE EXCEPTION 'Oddělené číselné řady zatím nejsou implementované.'
      USING HINT = 'V Nastavení → Fakturace nech „jedna společná řada" (rozhodnutí PM k otázce Q6).';
  END IF;

  -- Pražské datum, ne `current_date`: databáze běží v UTC, takže 1. ledna po
  -- půlnoci by doklad dostal loňský rok v čísle (týž důvod jako v `issue_invoice`).
  _dnes := (now() AT TIME ZONE 'Europe/Prague')::date;

  -- Opravný doklad vzniká jako KONCEPT, protože do vystaveného dokladu už
  -- `guard_invoice_item_immutable` položky nepustí. Číslo dostane až na konci.
  INSERT INTO public.invoices (
      kind, status, subject_id, event_id, obdobi_od, obdobi_do,
      dodavatel_nazev, dodavatel_adresa, dodavatel_ico, dodavatel_dic,
      dodavatel_rejstrik, dodavatel_ucet, dodavatel_iban, dodavatel_zprava,
      vat_mode, odberatel_nazev, odberatel_adresa, odberatel_ico, odberatel_dic,
      opravuje_id, storno_duvod, created_by, je_plne_storno)
  VALUES (
      _p.kind, 'koncept', _p.subject_id, _p.event_id, _p.obdobi_od, _p.obdobi_do,
      _p.dodavatel_nazev, _p.dodavatel_adresa, _p.dodavatel_ico, _p.dodavatel_dic,
      _p.dodavatel_rejstrik, _p.dodavatel_ucet, _p.dodavatel_iban, _p.dodavatel_zprava,
      _p.vat_mode, _p.odberatel_nazev, _p.odberatel_adresa, _p.odberatel_ico, _p.odberatel_dic,
      _invoice_id, nullif(btrim(coalesce(_duvod, '')), ''), _uid, true)
  RETURNING id INTO _opr;

  -- Zrcadlo řádků. Snapshot údajů se přebírá z ORIGINÁLU, ne z dnešních rezervací:
  -- opravný doklad musí ukazovat totéž, co se rušilo, i když se rezervace mezitím
  -- změnila nebo zrušila (což je jeden z hlavních důvodů, proč se storno dělá).
  INSERT INTO public.invoice_items (
      invoice_id, reservation_id, popis, datum, cas_od, cas_do,
      hodiny, sazba, line_total, vat_rate, vat_base, vat_amount, poradi)
  SELECT _opr, it.reservation_id, it.popis, it.datum, it.cas_od, it.cas_do,
         it.hodiny, it.sazba, it.line_total, it.vat_rate, it.vat_base, it.vat_amount, it.poradi
    FROM public.invoice_items it
   WHERE it.invoice_id = _invoice_id
   ORDER BY it.poradi, it.datum;

  -- Součty dopočítal trigger `recalc_invoice_totals` z položek; ručně se nepíšou.
  _cislo := public.next_invoice_number('spolecna', EXTRACT(year FROM _dnes)::integer);

  UPDATE public.invoices SET
      status            = 'vystaveno',
      cislo             = _cislo,
      variabilni_symbol = regexp_replace(_cislo, '\D', '', 'g'),
      datum_vystaveni   = _dnes,
      -- Splatnost = datum vystavení: opravným dokladem se nic neplatí, ale
      -- `invoices_cislo_dle_stavu` ji u vystaveného dokladu vyžaduje.
      datum_splatnosti  = _dnes,
      issued_at         = now(),
      issued_by         = _uid,
      pdf_status        = 'pending'   -- opravný doklad se posílá odběrateli, taky potřebuje PDF
   WHERE id = _opr;

  -- Původní doklad do storna. `status` je ve whitelistu guardu, takže tohle
  -- immutabilitu neporušuje — částky, strany ani číslo se nemění.
  UPDATE public.invoices SET status = 'stornovano' WHERE id = _invoice_id;

  -- Uvolnění rezervací. `app.trusted_booking` je jediná cesta, jak zámek pustit:
  -- `guard_reservation_rep_changes` ho jinak brání i adminovi právě proto, aby
  -- se rezervace nedala odpojit od neměnného dokladu jinudy než stornem.
  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET invoice_id = NULL, invoiced_at = NULL
   WHERE invoice_id = _invoice_id;
  GET DIAGNOSTICS _uvolneno = ROW_COUNT;
  -- Vypnout hned: zvýšené oprávnění nesmí platit pro zbytek transakce.
  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object(
    'opravny_id',    _opr,
    'opravny_cislo', _cislo,
    'stornovana_id', _invoice_id,
    'stornovane_cislo', _p.cislo,
    'castka',        (SELECT total_rounded FROM public.invoices WHERE id = _opr),
    'uvolneno_rezervaci', _uvolneno);

EXCEPTION
  -- R11: uvnitř SECURITY DEFINER neplatí RLS, takže by Postgres do chyby doplnil
  -- celý řádek dokladu — včetně IBANu dodavatele a jména odběratele.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Doklad se nepodařilo stornovat.'
      USING ERRCODE = '22023',
            HINT = 'Zkus to znovu; když to potrvá, zkontroluj stav dokladu v Přehledu fakturace.';
END;
$function$;

-- ── 4) Kontrola po sobě ──────────────────────────────────────────────────────
--
-- Nedělá to jen `position()` nad zdrojákem. Funkci taky OPRAVDU ZAVOLÁ a trvá
-- na tom, že vyhodí výjimku — tvrzení „zámek existuje" a „zámek drží" jsou dvě
-- různé věci a projít musí obě.
--
-- Komentáře se ze zdrojáku před hledáním ODSTRAŇUJÍ. Bez toho by tahle kontrola
-- měřila vlastní vysvětlivky: 14. 9. 2026 přesně takhle prohlásila správnou
-- migraci za rozbitou, protože našla hledaný tvar v komentáři nad ním.

DO $kontrola$
DECLARE
  _fn        text;
  _telo      text;
  _povolen   boolean;
  _drzi      boolean := false;
  _chyba     text;
BEGIN
  -- a) sloupec je tam, je NOT NULL a výchozí hodnota ZAVÍRÁ
  SELECT interni_engine_povolen INTO _povolen
    FROM public.billing_settings WHERE singleton;
  IF _povolen IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'KONTROLA: interni_engine_povolen je %, čekal jsem false.', _povolen;
  END IF;
  IF NOT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'public.billing_settings'::regclass
           AND attname = 'interni_engine_povolen' AND attnotnull) THEN
    RAISE EXCEPTION 'KONTROLA: sloupec interni_engine_povolen není NOT NULL — NULL by zámek obešel.';
  END IF;

  -- b) z aplikace se přepnout nedá
  IF has_column_privilege('authenticated', 'public.billing_settings',
                          'interni_engine_povolen', 'UPDATE') THEN
    RAISE EXCEPTION 'KONTROLA: authenticated smí UPDATE interni_engine_povolen — zámek by šel vypnout z webu.';
  END IF;
  IF NOT has_column_privilege('authenticated', 'public.billing_settings',
                              'interni_engine_povolen', 'SELECT') THEN
    RAISE EXCEPTION 'KONTROLA: authenticated nesmí SELECT interni_engine_povolen — rozbije to select(*) v nastavení.';
  END IF;

  -- c) zámek existuje a JE FAIL-CLOSED (opravdu zavolaný, ne jen přečtený)
  IF to_regprocedure('public.over_interni_engine()') IS NULL THEN
    RAISE EXCEPTION 'KONTROLA: funkce over_interni_engine() neexistuje.';
  END IF;
  BEGIN
    PERFORM public.over_interni_engine();
  EXCEPTION WHEN OTHERS THEN
    _drzi := true;
    _chyba := SQLERRM;
  END;
  IF NOT _drzi THEN
    RAISE EXCEPTION 'KONTROLA: over_interni_engine() prošla bez výjimky — zámek nedrží.';
  END IF;
  IF _chyba NOT LIKE '%vyřazený%' THEN
    RAISE EXCEPTION 'KONTROLA: zámek spadl na něčem jiném, než na čem měl: %', _chyba;
  END IF;

  -- d) všech pět vstupních bodů zámek opravdu volá
  FOREACH _fn IN ARRAY ARRAY[
      'public.create_invoice_draft_club(uuid,date,date)',
      'public.create_invoice_draft_commercial(uuid)',
      'public.issue_invoice(uuid)',
      'public.dobropis_invoice(uuid,uuid[],text)',
      'public.storno_invoice(uuid,text)'] LOOP
    IF to_regprocedure(_fn) IS NULL THEN
      RAISE EXCEPTION 'KONTROLA: funkce % neexistuje.', _fn;
    END IF;
    SELECT regexp_replace(prosrc, '--[^\n]*', '', 'g') INTO _telo
      FROM pg_proc WHERE oid = to_regprocedure(_fn);
    IF position('PERFORM public.over_interni_engine();' IN _telo) = 0 THEN
      RAISE EXCEPTION 'KONTROLA: % zámek nevolá (mimo komentáře).', _fn;
    END IF;
    -- e) a původní zábrana na vat_mode v nich zůstala
    IF _fn LIKE '%create_invoice_draft%' OR _fn LIKE '%issue_invoice%' THEN
      IF position('neplatce' IN _telo) = 0 THEN
        RAISE EXCEPTION 'KONTROLA: % přišla o původní zábranu na vat_mode.', _fn;
      END IF;
    END IF;
  END LOOP;

  RAISE NOTICE 'KONTROLA OK: zámek interního enginu drží, volá ho všech 5 vstupních bodů, z webu se nevypne.';
END
$kontrola$;
