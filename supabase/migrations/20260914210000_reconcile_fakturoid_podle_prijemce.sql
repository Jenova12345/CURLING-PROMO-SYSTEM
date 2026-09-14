-- =============================================================================
-- Kontrolní součet: fakturoidí větev se řídí PŘÍJEMCEM Z HLAVIČKY DOKLADU
-- =============================================================================
--
-- NÁLEZ (14. 9. 2026, KROK 0 před go-live Fakturoidu).
--
-- `billing_reconcile` má dvě větve a každá brala příjemce odjinud:
--   * interní  (`radky`)       → `i.subject_id`   … hlavička dokladu  ✔
--   * Fakturoid (`fakt_doklady`) → `rez.subject_id` … majitel rezervace ✘
--
-- Interní větev přitom TENTÝŽ defekt už jednou měla a byla kvůli němu
-- opravena — komentář u ní to popisuje doslova: „S `rez.subject_id` vyšla
-- rovnice OBĚMA klubům: jednomu se »vyfakturovalo« to, co má na dokladu druhý,
-- a `rozdil` byl u obou nula." Fakturoidí větev tu opravu nikdy nedostala.
--
-- ZMĚŘENO na replice produkce (rezervace 2 000 Kč, doklad vystavený klubu A,
-- admin pak rezervaci přehodil na klub B — což mu nic nebrání, protože
-- fakturoidí cesta do `reservations.invoice_id` z rozhodnutí PM nezapisuje,
-- takže guard `trg_reservations_jeden_doklad` se na ni nevztahuje):
--
--   PŘED:  Hybridní vzdělávání │ fakturoid 2000 │ f_rozdil 0 │ rozdil    0
--          Mladé Kameny        │ ——— ze sestavy ZMIZEL ———
--
--   PO:    Hybridní vzdělávání │ fakturoid    0 │ f_rozdil 0 │ rozdil +2000
--          Mladé Kameny        │ fakturoid 2000 │ f_rozdil 0 │ rozdil -2000
--
-- Tedy: dřív tichá nula u špatného klubu a druhý klub pryč ze sestavy; teď
-- hlasitý nesoulad u obou a klub z hlavičky dokladu v sestavě ZŮSTÁVÁ.
--
-- DRUHÁ VĚC, KTEROU TATÁŽ ZMĚNA SPRAVÍ. Vnitřní dotaz se seskupoval podle
-- (subjekt rezervace, doklad), takže doklad nesoucí rezervace dvou klubů vešel
-- do součtu DVAKRÁT a každé straně se od jeho části odečetl CELÝ `nas_soucet`.
-- Změřeno: doklad 4 000 Kč přes dva kluby hlásil `fakturoid_rozdil` +2 000
-- u obou, přestože doklad seděl. Nově se `nas_soucet` započte jednou za doklad.
--
-- CO SE NEMĚNÍ:
--   * `k_fakturaci` / `neschvalene` se dál ptají na členství REZERVACE
--     („je zabraná?"), ne na příjemce — to je správně a zůstává.
--   * interní větev, její data ani její chování.
--   * návratový typ funkce (stejné sloupce ve stejném pořadí).
--
-- POZOR NA FALEŠNÝ POPLACH U DOKLADŮ PŘES HRANICI MĚSÍCE. `fakturoid_rozdil`
-- porovnává CELÝ `nas_soucet` dokladu proti jen TĚM jeho rezervacím, které
-- padnou do dotazovaného období. Doklad, který kryje rezervace z 5. 9. i z
-- 1. 10., proto v zářijové sestavě hlásí rozdíl, přestože je v pořádku.
-- Změřeno 14. 9. 2026 na replice: rozdíl 2 000, po rozšíření období na obě
-- části spadne na nulu. NENÍ TO REGRESE TÉHLE MIGRACE — chová se tak i funkce
-- před ní (změřeno na obou verzích vedle sebe); tahle změna ten sloupec jen
-- poprvé pouští do UI, takže od teď je ten poplach vidět. Omezit porovnání na
-- doklady, které se do období vejdou celé (`obdobi_od`/`obdobi_do` v hlavičce
-- na to jsou), je produktové rozhodnutí PM a NENÍ součástí téhle migrace.
-- Do té doby to říká nápověda i banner v `Invoices.tsx` (hlídá to brána
-- v `branyFrontendu.test.ts`), aby obrazovka netvrdila o zdravém dokladu,
-- že se rozešel s podkladem.
--
-- CO TO NEŘEŠÍ — VĚDOMĚ, PATŘÍ TO DO SAMOSTATNÉHO ROZHODNUTÍ:
--   * Přehodit `subject_id` na rezervaci, která visí na fakturoidím dokladu,
--     jde dál. Tahle migrace to jen ZVIDITELNÍ, nezakáže. Zámek (obdoba
--     `over_neni_vyfakturovano`) je samostatný ticket.
--   * Interní větev má tutéž mezeru se „subjektem, který má v období jen
--     doklad a žádnou rezervaci" — ze sestavy vypadne. Sjednocení klíčů níž
--     ji schválně řeší JEN pro fakturoidí větev; u peněz nad interním enginem
--     se chování nemění bez rozhodnutí PM.
--
-- OVĚŘENO PŘED NASAZENÍM: na reálných datech repliky (19 řádků) dává stará
-- i nová funkce identický výsledek — 0 nenulových `rozdil` i `fakturoid_rozdil`.
-- Na produkci je dnes 0 fakturoidích dokladů, takže změna nemá na čem hnout.
--
-- IDEMPOTENTNÍ: `CREATE OR REPLACE FUNCTION`. Viz CLAUDE.md, pravidlo 6 —
-- dávka migrací není atomická, opakovaný push musí projít.
--
-- VRATNOST:
--   `billing_reconcile(date,date)` zpět z migrace
--   `20260902200000_reconcile_vidi_fakturoid.sql` — to je poslední verze
--   před touhle změnou.
--   ⚠️ PO PUSHI už staré tělo z `pg_get_functiondef` nedostaneš, vrátí se nové.
--   Funkce nic nezapisuje (je `STABLE`), takže rollback je bezztrátový.
--
-- Tělo je vygenerované z `pg_get_functiondef` živé produkce a jsou do něj
-- vložené POUZE čtyři zásahy níž (CLAUDE.md, pravidlo 7); ověřeno diffem.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.billing_reconcile(_od date, _do date)
 RETURNS TABLE(subject_id uuid, subjekt text, fakturovano numeric, v_konceptu numeric, ve_stornu numeric, dobropisovano numeric, k_fakturaci numeric, neschvalene numeric, fakturoid numeric, fakturoid_rozdil numeric, dluzi numeric, rozdil numeric, rezervaci bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _zacatek timestamptz;
  _konec   timestamptz;
  _jen_schvalene boolean;
BEGIN
  -- Kontrolní součet ukazuje peníze všech subjektů — tedy adminská věc.
  --
  -- Výjimka je JEN pro běh pod databázovou rolí (pg_cron ve fázi D poběží jako
  -- `postgres`, kde `auth.uid()` je NULL). Podmínka schválně NESTOJÍ jen na
  -- „auth.uid() IS NULL": to by z chybějícího `sub` v tokenu udělalo klíč
  -- k obratům všech klubů. Že se takový token přes PostgREST dnes nesloží, je
  -- shoda okolností v konfiguraci, ne vlastnost téhle funkce — a `session_user`
  -- je totéž kritérium, jaké používá guard v rezervacích (booking_core.sql).
  IF NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Kontrolní součet fakturace vidí jen správce haly.';
  END IF;
  IF _od IS NULL OR _do IS NULL OR _do < _od THEN
    RAISE EXCEPTION 'Neplatné období (od % do %).', _od, _do;
  END IF;

  SELECT zacatek, konec INTO _zacatek, _konec FROM public.obdobi_hranice(_od, _do);
  SELECT COALESCE(bs.invoice_only_approved, true) INTO _jen_schvalene
    FROM public.billing_settings bs LIMIT 1;
  _jen_schvalene := COALESCE(_jen_schvalene, true);

  RETURN QUERY
  WITH rez AS (
    -- Jedna definice „co je zpoplatněné" pro obě strany rovnice.
    SELECT r.id, r.subject_id,
           COALESCE(r.corrected_amount, r.amount) AS castka,
           r.invoice_id,
           (r.approved_at IS NOT NULL) AS schvalena
      FROM public.reservations r
     WHERE r.status = 'confirmed'
       AND r.deleted_at IS NULL
       AND r.subject_id IS NOT NULL
       AND r.start_at >= _zacatek
       AND r.start_at <  _konec
  ),
  radky AS (
    -- Řádky dokladů patřící rezervacím v období. `LEFT JOIN` schválně NE:
    -- řádek bez rezervace (sleva, storno poplatek) do porovnání s „Kdo dluží"
    -- nepatří, protože na druhé straně rovnice žádnou rezervaci nemá.
    -- (Že je pak nepočítá vůbec nikdo, hlídá `billing_health.radky_bez_rezervace`.)
    --
    -- SESKUPUJE SE PODLE `i.subject_id`, ne podle subjektu rezervace. Admin smí
    -- rezervaci přepsat subjekt i po vyfakturování (guard mu brání jen v `invoice_id`),
    -- a pak se peníze na dokladu a dnešní příslušnost rezervace rozejdou. S
    -- `rez.subject_id` vyšla rovnice OBĚMA klubům: jednomu se „vyfakturovalo" to,
    -- co má na dokladu druhý, a `rozdil` byl u obou nula. Doklad ví, komu je
    -- vystavený — tak ať rozhoduje on.
    SELECT i.subject_id,
           i.status,
           it.line_total,
           -- Zámek rezervace. Rozhoduje o tom, jestli řádek stornovaného dokladu
           -- ještě někoho zavazuje, nebo je to už jen historie (viz `ve_stornu`).
           rez.invoice_id AS zamek,
           (i.opravuje_id IS NOT NULL) AS je_dobropis
      FROM rez
      JOIN public.invoice_items it ON it.reservation_id = rez.id
      JOIN public.invoices i       ON i.id = it.invoice_id
     -- OPRAVNÉ DOKLADY SE NEPOČÍTAJÍ. Zrcadlí řádky původní faktury, takže by
     -- tutéž rezervaci naúčtovaly podruhé. Že opravný doklad sedí s originálem,
     -- hlídá `billing_health.opravne_nesedi` — ať ta výjimka není slepé místo.
     LEFT JOIN public.invoices puv ON puv.id = i.opravuje_id
     WHERE i.opravuje_id IS NULL
        -- Dobropis se vykazuje, JEN dokud doklad, který opravuje, platí.
        -- U stornovaného originálu by šlo o dvojí započtení téhož zrušení.
        OR puv.status IN ('vystaveno', 'zaplaceno')
  ),
  -- REZERVACE ZABRANÉ FAKTUROIDEM.
  --
  -- Zámek je samotná VAZBA (`fakturoid_invoice_reservations`, UNIQUE na
  -- `reservation_id`), ne stav dokladu u poskytovatele: jakmile je rezervace
  -- zabraná, není „k fakturaci", ani kdyby doklad zůstal konceptem.
  -- `subject_id` se tu ZÁMĚRNĚ NEBERE. Tahle CTE odpovídá jen na otázku
  -- „je tahle rezervace zabraná, a kterým dokladem" — komu doklad patří,
  -- rozhoduje jeho hlavička o kus níž.
  fakt AS (
    SELECT rez.id, rez.castka, fr.fakturoid_invoice_id AS doklad_id
      FROM rez
      JOIN public.fakturoid_invoice_reservations fr ON fr.reservation_id = rez.id
  ),
  -- SEDÍ, CO JSME POSLALI, S TÍM, CO SI ÚČTUJEME?
  --
  -- `nas_soucet` je náš vlastní součet z okamžiku vystavení, zaokrouhlený na
  -- celé koruny (`roundCzk` v pipeline) — proto se porovnává se zaokrouhleným
  -- součtem částek, ne kvůli toleranci, ale aby se srovnávalo totéž.
  -- Kdyby se to rozešlo, je to přesně ten tichý rozjezd, kvůli kterému
  -- kontrolní součet existuje.
  --
  -- SESKUPUJE SE PODLE `fi.subject_id`, NE PODLE SUBJEKTU REZERVACE.
  -- Je to táž oprava, jakou o kus výš dostala interní větev (`i.subject_id`) —
  -- fakturoidí větev ji do 14. 9. 2026 neměla. Změřeno na replice produkce:
  -- doklad vystavený klubu A, admin pak rezervaci přehodil na klub B, a
  -- protože se obě strany rovnice braly z rezervace, vyšlo `fakturoid_rozdil`
  -- i `rozdil` NULA klubu B — zatímco klub A, kterému doklad fakticky patří,
  -- ze sestavy zmizel úplně. Doklad ví, komu je vystavený; ať rozhoduje on.
  --
  -- Vedlejší efekt téže změny: `nas_soucet` se teď započítá JEDNOU za doklad.
  -- Dřív se vnitřní dotaz seskupoval podle (subjekt rezervace, doklad), takže
  -- doklad nesoucí rezervace dvou klubů vešel do součtu dvakrát a obě strany
  -- dostaly celý `nas_soucet` proti své části — hlásilo to rozdíl i tam, kde
  -- doklad seděl.
  fakt_po_dokladech AS (
    SELECT fi.subject_id, f.doklad_id, fi.nas_soucet, sum(f.castka) AS suma
      FROM fakt f
      JOIN public.fakturoid_invoices fi ON fi.id = f.doklad_id
     GROUP BY fi.subject_id, f.doklad_id, fi.nas_soucet
  ),
  fakt_doklady AS (
    SELECT fd.subject_id,
           -- Co za subjekt drží fakturoidí doklady. Do rovnice vstupuje stejně
           -- jako `fakturovano` u interní větve, proto se i klíčuje stejně.
           sum(fd.suma)                           AS fakturoid,
           sum(fd.nas_soucet - round(fd.suma, 0)) AS rozdil
      FROM fakt_po_dokladech fd
     GROUP BY fd.subject_id
  ),
  souhrn AS (
    SELECT rez.subject_id,
           count(*)                                                    AS rezervaci,
           sum(rez.castka)                                             AS dluzi,
           -- Co drží Fakturoid, NENÍ k fakturaci. Bez téhle podmínky tam
           -- rezervace visela napořád — fakturoidí cesta do `invoice_id`
           -- schválně nezapisuje, takže ji nic jiného neodečetlo.
           sum(rez.castka) FILTER (WHERE rez.invoice_id IS NULL
                                     AND NOT EXISTS (SELECT 1 FROM fakt WHERE fakt.id = rez.id)
                                     AND (rez.schvalena OR NOT _jen_schvalene)) AS k_fakturaci,
           sum(rez.castka) FILTER (WHERE rez.invoice_id IS NULL
                                     AND NOT EXISTS (SELECT 1 FROM fakt WHERE fakt.id = rez.id)
                                     AND NOT rez.schvalena AND _jen_schvalene)  AS neschvalene
      FROM rez GROUP BY rez.subject_id
  ),
  doklady AS (
    SELECT radky.subject_id,
           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')
                                             AND NOT radky.je_dobropis)                AS fakturovano,
           sum(radky.line_total) FILTER (WHERE radky.status IN ('vystaveno', 'zaplaceno')
                                             AND radky.je_dobropis)                    AS dobropisovano,
           sum(radky.line_total) FILTER (WHERE radky.status = 'koncept'
                                             AND NOT radky.je_dobropis)                AS v_konceptu,
           sum(radky.line_total) FILTER (WHERE radky.status = 'stornovano'
                                     -- Jen dokud rezervace na stornovaném dokladu VISÍ
                                     -- (částečný dobropis). Po plném stornu se zámek
                                     -- uvolní a rezervace se vrací do `k_fakturaci`;
                                     -- bez téhle podmínky by se počítala dvakrát
                                     -- a `rozdil` vyšel o celou fakturu vedle.
                                     AND radky.zamek IS NOT NULL)                AS ve_stornu
      FROM radky GROUP BY radky.subject_id
  )
  ,
  -- KDO SE V SESTAVĚ OBJEVÍ.
  --
  -- Nestačí subjekty, které mají v období rezervace. Jakmile se příjemce
  -- dokladu a majitel rezervace rozejdou, je klub z hlavičky dokladu ten,
  -- koho je potřeba vidět NEJVÍC — a `FROM souhrn` ho zahodí, protože žádnou
  -- rezervaci nemá. Přesně tak zmizel klub A v měření výš.
  --
  -- POZOR, ROVNOU CO TO NEŘEŠÍ: interní větev má tutéž mezeru (subjekt, který
  -- má v období jen doklad a žádnou rezervaci, ze sestavy vypadne). Tahle
  -- migrace ji vědomě NEMĚNÍ — je to peněžní chování nad interním enginem
  -- a patří do samostatného rozhodnutí PM, ne do opravy fakturoidí větve.
  subjekty AS (
    SELECT souhrn.subject_id FROM souhrn
    UNION
    SELECT fakt_doklady.subject_id FROM fakt_doklady
  )
  SELECT k.subject_id,
         sub.name,
         COALESCE(d.fakturovano, 0),
         COALESCE(d.v_konceptu, 0),
         COALESCE(d.ve_stornu, 0),
         COALESCE(d.dobropisovano, 0),
         COALESCE(s.k_fakturaci, 0),
         COALESCE(s.neschvalene, 0),
         COALESCE(fd.fakturoid, 0),
         COALESCE(fd.rozdil, 0),
         COALESCE(s.dluzi, 0),
         COALESCE(s.dluzi, 0)
           - (COALESCE(d.fakturovano, 0) + COALESCE(d.v_konceptu, 0) + COALESCE(d.ve_stornu, 0)
              + COALESCE(s.k_fakturaci, 0) + COALESCE(s.neschvalene, 0)
              + COALESCE(fd.fakturoid, 0)),
         COALESCE(s.rezervaci, 0::bigint)
    FROM subjekty k
    LEFT JOIN souhrn s        ON s.subject_id  = k.subject_id
    LEFT JOIN doklady d       ON d.subject_id  = k.subject_id
    LEFT JOIN fakt_doklady fd ON fd.subject_id = k.subject_id
    LEFT JOIN public.subjects sub ON sub.id = k.subject_id
   ORDER BY sub.name;
END;
$function$

;

-- -----------------------------------------------------------------------------
-- PRÁVA. `CREATE OR REPLACE FUNCTION` ACL zachovává, takže tenhle blok nic
-- nemění — je tu proto, aby stav práv byl v migraci ČERNÝ NA BÍLÉM a aby
-- případný budoucí `DROP + CREATE` (který ACL naopak zahodí) nezůstal bez
-- záchytu. Odpovídá doslova tomu, co je 14. 9. 2026 na produkci:
--   acl={postgres=X/postgres,authenticated=X/postgres}
-- tedy PUBLIC ani `anon` na tuhle funkci nesmí. Je `SECURITY DEFINER`, takže
-- EXECUTE pro PUBLIC by z ní udělal veřejný výpis toho, kdo kolik dluží.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.billing_reconcile(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.billing_reconcile(date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- POST-CHECK. Migrace, která „proběhla" a nic neudělala, je horší než ta, co
-- spadne — 14. 9. 2026 přesně takhle tiše propadl `CREATE INDEX IF NOT EXISTS`
-- při obnově po mutačním testu a nechal za sebou zmutovaný index. Tenhle blok
-- proto ověří VÝSLEDEK, ne to, že příkaz doběhl.
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE
  _telo  text;
  _acl   text;
  _sloupcu int;
BEGIN
  -- Přes `regprocedure`, ne přes `pg_get_function_identity_arguments` — ta
  -- vrací i JMÉNA parametrů (`_od date, _do date`), takže porovnání s
  -- 'date, date' nikdy nesedí a kontrola by hlásila „funkce neexistuje"
  -- o funkci, která tam je. (Změřeno na replice 14. 9. 2026 — první běh
  -- tohohle bloku spadl přesně na tom.)
  SELECT pg_get_functiondef(p.oid), COALESCE(p.proacl::text, '(default)')
    INTO _telo, _acl
    FROM pg_proc p
   WHERE p.oid = to_regprocedure('public.billing_reconcile(date,date)');

  IF _telo IS NULL THEN
    RAISE EXCEPTION 'billing_reconcile(date,date) po migraci neexistuje.';
  END IF;

  -- 1) Fakturoidí větev opravdu seskupuje podle PŘÍJEMCE Z HLAVIČKY.
  -- Ptát se jen na výskyt `fi.subject_id` NESTAČÍ: `rez.subject_id` je v těle
  -- legitimně jinde (interní větev `souhrn`) a `fi.subject_id` zase v SELECTu,
  -- takže obojí projde i po přehození klíče. Mutační test 14. 9. 2026 to
  -- ukázal — stráž byla zelená nad tělem, které seskupovalo zase podle
  -- rezervace. Hlídá se proto CELÁ klauzule GROUP BY fakturoidí větve.
  IF _telo NOT LIKE '%GROUP BY fi.subject_id, f.doklad_id, fi.nas_soucet%' THEN
    RAISE EXCEPTION 'Fakturoidí větev se neseskupuje podle fi.subject_id (příjemce z hlavičky) — migrace neudělala to hlavní.';
  END IF;

  -- 2) Subjekt, který má v období jen doklad a žádnou rezervaci, ze sestavy
  --    nevypadne. Bez tohohle UNIONu je celá oprava k ničemu: zmizelý klub
  --    zůstane zmizelý, jen se nula přesune jinam.
  IF _telo NOT LIKE '%fakt_doklady.subject_id%' THEN
    RAISE EXCEPTION 'Sjednocení klíčů (UNION nad fakt_doklady) v těle chybí.';
  END IF;

  -- 3) Práva: PUBLIC ani anon se k SECURITY DEFINER funkci nesmí dostat.
  --    Pozor na `proacl IS NULL` — to NENÍ „nikdo nemá", ale „platí výchozí
  --    stav", a ten u funkcí znamená EXECUTE pro PUBLIC. Proto je '(default)'
  --    taky chyba, ne v pořádku.
  IF _acl = '(default)' THEN
    RAISE EXCEPTION 'billing_reconcile má výchozí ACL, tedy EXECUTE pro PUBLIC. REVOKE výš neproběhl.';
  END IF;
  IF _acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'billing_reconcile má EXECUTE pro anon: %', _acl;
  END IF;
  --    Grant pro PUBLIC se v ACL píše s PRÁZDNÝM jménem příjemce, tedy jako
  --    `{=X/postgres,…}` nebo `…,=X/postgres`.
  IF _acl LIKE '{=%' OR _acl LIKE '%,=%' THEN
    RAISE EXCEPTION 'billing_reconcile má EXECUTE pro PUBLIC: %', _acl;
  END IF;
  IF _acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'billing_reconcile ztratila EXECUTE pro authenticated — kontrolní součet by přestal jít otevřít: %', _acl;
  END IF;

  -- 4) Návratový typ se nesměl hnout — na sloupcích visí UI i testy.
  SELECT count(*) INTO _sloupcu
    FROM pg_proc p, unnest(p.proargmodes) m
   WHERE p.oid = 'public.billing_reconcile(date,date)'::regprocedure AND m = 't';
  IF _sloupcu <> 13 THEN
    RAISE EXCEPTION 'billing_reconcile vrací % sloupců místo 13 — návratový typ se změnil.', _sloupcu;
  END IF;

  RAISE NOTICE 'billing_reconcile: příjemce z hlavičky ✔, UNION ✔, práva ✔ (%), 13 sloupců ✔', _acl;
END
$kontrola$;
