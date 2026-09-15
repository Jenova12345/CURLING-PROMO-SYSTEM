-- NÁHLED „NEVYFAKTUROVANÉ AKCE" MUSÍ VIDĚT FAKTUROIDÍ DOKLADY
--
-- PROČ: `nevyfakturovane_akce` se ptá výhradně na INTERNÍ vazbu
-- (`reservations.invoice_id`). Fakturoidí cesta ale do `reservations` podle
-- rozhodnutí PM z 24. 8. 2026 NEZAPISUJE VŮBEC NIC — vazba žije v
-- `fakturoid_invoice_reservations`. Náhled tedy nabízel už vystavenou akci
-- pořád dokola.
--
-- Duplicitní doklad z toho nevznikne: `fakturoid_podklady_akce` tutéž vazbu
-- kontroluje a vrátí prázdno, takže server odmítne. Jenže tím UI TVRDÍ OPAK
-- SERVERU — admin vidí „Deloitte, 2 rezervace, 30 000 Kč", klikne a dostane
-- „není co fakturovat". To je přesně ta třída tichého rozdílu, kvůli které
-- v tomhle repu existuje kontrolní součet: `billing_reconcile` fakturoidí
-- doklady od vlny B (2. 9. 2026) ZNÁ (sloupce `fakturoid`, `fakturoid_rozdil`),
-- `nevyfakturovane_akce` na ni ale tehdy nikdo nenapojil.
--
-- CO SE MĚNÍ: do všech TŘÍ míst, kde se dnes stojí na `invoice_id IS NULL`,
-- přibývá `NOT EXISTS (… fakturoid_invoice_reservations …)`. Nic jiného.
-- Tělo je VYGENEROVANÉ z `pg_get_functiondef` živého schématu produkce
-- (pravidlo 7 v CLAUDE.md) — ruční přepis dlouhé funkce už v tomhle repu
-- dvakrát utnul kus guardu.
--
-- CO SE VĚDOMĚ NEMĚNÍ (a je to otázka na PM, ne opomenutí):
--
--   1) `invoice_id IS NULL` ZŮSTÁVÁ. Pod S2 má rezervace s interním dokladem
--      jít do Fakturoidu tak jako tak — `fakturoid_podklady_akce` se na
--      `invoice_id` schválně neptá. Kdyby tedy někdy existoval interní doklad,
--      náhled by ukázal MÉNĚ, než kolik by se vystavilo. Dnes je to
--      nedosažitelné: na produkci je `invoices` = 0 řádků a
--      `billing_settings.interni_engine_povolen` = false, takže `invoice_id`
--      je NULL u všech rezervací a odebrat tu podmínku by dnes nezměnilo ani
--      jeden řádek. Odebírat ji naslepo u peněz nebudu; patří to k ticketu
--      o vyřazení interního enginu.
--
--   2) REZERVACE ZA 0 Kč SE NOVĚ VYNECHÁVAJÍ I V NÁHLEDU.
--
--      Dřívější znění tohohle odstavce tvrdilo, že filtr na cenu zadarmo má
--      jen `fakturovatelne_rezervace` a že `fakturoid_podklady_akce` ho nemá.
--      NEPLATÍ TO — bylo to přečtené z původní migrace `20260824120000`, jenže
--      živá funkce je od té doby předefinovaná a filtr MÁ:
--
--          AND NOT (COALESCE(r.corrected_amount, r.amount, 0) = 0
--                   AND r.corrected_amount IS NULL)
--
--      Náhled ho neměl, takže se rozcházel se serverem. Změřeno na akci se
--      dvěma dráhami, z nichž jedna byla zadarmo (ukázková hodina):
--
--          náhled  2 rezervace / 20 000 Kč
--          server  1 rezervace / 20 000 Kč      ← tolik se doopravdy vystaví
--
--      Peníze to nerozcházelo (součet stejný), ale počet ano — a u akce CELÉ
--      zadarmo náhled nabídl řádek, po jehož odkliknutí přijde „není co
--      fakturovat". Frontend navíc na shodě náhledu se serverem staví příznak
--      `presna` (`src/pages/Dues.tsx`), kterým v potvrzovacím dialogu SKRÝVÁ
--      štítek „(odhad)" — tvrdil by tedy přesnost, kterou nemá.
--
--      Filtr je proto doslova zkopírovaný z `fakturoid_podklady_akce`
--      i `fakturovatelne_rezervace`. Poprvé se tím shodla všechna tři místa.
--      ⚠️ Kdo bude pravidlo „akce za nulu se nefakturuje" měnit, musí ho změnit
--      na VŠECH TŘECH místech, ne na jednom.
--
-- IDEMPOTENTNÍ: `CREATE OR REPLACE FUNCTION` plus kontrola na konci, která
-- ověřuje STRUKTURU, ne konkrétní částky (natvrdo zapsaná částka už jednou
-- rozbila opakovaný běh migrace ceníku).
--
-- BEZ `BEGIN`/`COMMIT` — obálku dodá CLI. Explicitní COMMIT v těle migrace ji
-- rozbije a migrace pak visí jako nenasazená (CLAUDE.md, pravidlo 6).

CREATE OR REPLACE FUNCTION public.nevyfakturovane_akce(_subject_id uuid, _obdobi_od date, _obdobi_do date)
 RETURNS TABLE(event_id uuid, nazev text, den date, rezervaci bigint, castka numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _od timestamptz; _do timestamptz; _jen_schvalene boolean;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Podklady k fakturaci vidí jen správce haly.';
  END IF;
  SELECT zacatek, konec INTO _od, _do FROM public.obdobi_hranice(_obdobi_od, _obdobi_do);
  SELECT COALESCE(bs.invoice_only_approved, true) INTO _jen_schvalene
    FROM public.billing_settings bs LIMIT 1;
  _jen_schvalene := COALESCE(_jen_schvalene, true);

  -- OBDOBÍ VYBÍRÁ AKCE, ALE NEOŘEZÁVÁ ČÁSTKU.
  --
  -- `create_invoice_draft_commercial` fakturuje CELOU akci (spec 2A: 1 doklad =
  -- 1 akce) a datum v ní nefiguruje. Kdyby náhled sčítal jen rezervace spadlé do
  -- zobrazeného období, akce přes přelom měsíce by v dialogu ukázala „1 rezervace,
  -- 3 400 Kč" a vystavila by doklad na dvě položky a 6 800 Kč — admin by odklikl
  -- číslo, které nikdy neviděl. Podmnožinu `WHERE` proto mají obě funkce
  -- TOTOŽNOU; období se uplatní jen na výběr akcí přes `EXISTS`.
  --
  -- TOTÉŽ PLATÍ OD 15. 9. 2026 I PRO FAKTUROIDÍ CESTU: `fakturoid_podklady_akce`
  -- vynechává rezervace, které už nesou fakturoidí vazbu. Kdyby se náhled ptal
  -- jen na interní `invoice_id`, nabízel by vystavenou akci donekonečna.
  RETURN QUERY
  SELECT e.id,
         e.title,
         min((r.start_at AT TIME ZONE 'Europe/Prague')::date),
         count(*),
         sum(COALESCE(r.corrected_amount, r.amount))
    FROM public.reservations r
    JOIN public.events e ON e.id = r.event_id
   WHERE r.subject_id = _subject_id
     AND r.invoice_id IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.fakturoid_invoice_reservations fr
        WHERE fr.reservation_id = r.id
     )
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND (NOT _jen_schvalene OR r.approved_at IS NOT NULL)
     -- AKCE ZA NULU SE NEFAKTURUJE — tentýž filtr má `fakturoid_podklady_akce`
     -- i `fakturovatelne_rezervace`. Vynechává se JEN cena zadarmo, ne nulová
     -- korekce (`corrected_hours = 0` znamená „nedorazili" a má ji vyřešit
     -- guard A5, ne tichý filtr).
     AND NOT (COALESCE(r.corrected_amount, r.amount, 0) = 0
              AND r.corrected_amount IS NULL)
     AND EXISTS (
       SELECT 1 FROM public.reservations r2
        WHERE r2.event_id = e.id
          AND r2.invoice_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM public.fakturoid_invoice_reservations fr2
             WHERE fr2.reservation_id = r2.id
          )
          AND r2.status = 'confirmed'
          AND r2.deleted_at IS NULL
          AND NOT (COALESCE(r2.corrected_amount, r2.amount, 0) = 0
                   AND r2.corrected_amount IS NULL)
          AND r2.start_at >= _od
          AND r2.start_at <  _do
     )
   GROUP BY e.id, e.title

  UNION ALL

  -- REZERVACE BEZ AKCE. Bez tohohle řádku byly nevyfakturovatelné vůbec:
  -- UI posílá každý nekulubový subjekt do dialogu akcí a ten je (přes INNER JOIN
  -- na `events`) neviděl. Peníze pak zůstaly v `k_fakturaci` navždy a `rozdil`
  -- byl přitom nula — přesně ta třída tichého rozdílu, kvůli které kontrolní
  -- součet existuje. `event_id IS NULL` říká volajícímu „na tohle použij
  -- souhrnnou fakturu za období", ne „za akci".
  SELECT NULL::uuid,
         'Rezervace bez akce',
         min((r.start_at AT TIME ZONE 'Europe/Prague')::date),
         count(*),
         sum(COALESCE(r.corrected_amount, r.amount))
    FROM public.reservations r
   WHERE r.subject_id = _subject_id
     AND r.event_id IS NULL
     AND r.invoice_id IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.fakturoid_invoice_reservations fr
        WHERE fr.reservation_id = r.id
     )
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND (NOT _jen_schvalene OR r.approved_at IS NOT NULL)
     AND NOT (COALESCE(r.corrected_amount, r.amount, 0) = 0
              AND r.corrected_amount IS NULL)
     AND r.start_at >= _od
     AND r.start_at <  _do
  HAVING count(*) > 0

   ORDER BY 3, 2;

EXCEPTION
  -- Tentýž důvod jako u `delete_invoice_draft`: čte se přes `reservations`, ale
  -- funkce je SECURITY DEFINER a R11 platí plošně, ne jen tam, kde je dnes vidět
  -- konkrétní cesta.
  WHEN check_violation OR not_null_violation THEN
    RAISE EXCEPTION 'Podklady k fakturaci se nepodařilo sestavit.'
      USING ERRCODE = '22023';
END;
$function$;

-- Práva se NEMĚNÍ — `CREATE OR REPLACE` je zachovává. Zopakováno explicitně,
-- aby opakovaný běh na databázi, kde je někdo omylem přenastavil, srovnal zpět.
REVOKE ALL ON FUNCTION public.nevyfakturovane_akce(uuid, date, date) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.nevyfakturovane_akce(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION public.nevyfakturovane_akce(uuid, date, date) IS
  'Akce subjektu, které v období čekají na fakturu. Od 15. 9. 2026 vynechává i to, '
  'co už nese fakturoidí vazbu — náhled musí ukazovat totéž, co vystaví fakturoid_podklady_akce.';

-- ── Kontrola: STRUKTURA, ne konkrétní částky ────────────────────────────────
DO $kontrola$
DECLARE
  -- KOMENTÁŘE SE ODSTŘIHNOU, JINAK KONTROLA MĚŘÍ VLASTNÍ VYSVĚTLIVKY.
  --
  -- Tělo funkce je plné komentářů, které zmiňují `fakturoid_invoice_reservations`
  -- i podmínku na cenu zadarmo. Počítat výskyty v syrovém textu je tedy slepé
  -- oběma směry: dobře okomentovaná úprava shodí migraci, kdežto smazaný filtr
  -- se dá zamaskovat zmínkou v komentáři. Přesně na tomhle spadla 14. 9. 2026
  -- kontrola uvnitř jiné migrace.
  _telo   text := regexp_replace(
                    pg_get_functiondef('public.nevyfakturovane_akce(uuid,date,date)'::regprocedure),
                    '--[^\n]*', '', 'g');
  _vazeb  integer;
  _prava  text;
BEGIN
  -- Tři místa, kde se filtruje na už vystavený doklad: hlavní dotaz, EXISTS
  -- pro výběr období a větev „rezervace bez akce". Když jich bude míň, někdo
  -- při další úpravě jedno vynechal — a chybějící filtr se pozná jedině tím,
  -- že se akce nabídne podruhé.
  _vazeb := (length(_telo) - length(replace(_telo, 'fakturoid_invoice_reservations', ''))) / length('fakturoid_invoice_reservations');
  IF _vazeb <> 3 THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: čekám 3 odkazy na fakturoid_invoice_reservations, našel jsem %', _vazeb;
  END IF;

  -- Původní zábrana na interní doklad se odebrat nesměla (viz hlavička, bod 1).
  IF (length(_telo) - length(replace(_telo, 'invoice_id IS NULL', ''))) / length('invoice_id IS NULL') <> 3 THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: zmizela některá z podmínek invoice_id IS NULL';
  END IF;

  -- Filtr „akce za nulu se nefakturuje" taky na třech místech — kdyby zmizel,
  -- náhled se zase rozejde se serverem a `presna` ve frontendu začne lhát.
  IF (length(_telo) - length(replace(_telo, 'COALESCE(r.corrected_amount, r.amount, 0) = 0', ''))) 
     / length('COALESCE(r.corrected_amount, r.amount, 0) = 0')
     + (length(_telo) - length(replace(_telo, 'COALESCE(r2.corrected_amount, r2.amount, 0) = 0', '')))
     / length('COALESCE(r2.corrected_amount, r2.amount, 0) = 0') <> 3 THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: filtr na cenu zadarmo není na všech třech místech';
  END IF;

  -- Guard na admina musí zůstat. Přepis dlouhé funkce už tady jednou guard utnul.
  IF _telo NOT LIKE '%Podklady k fakturaci vidí jen správce haly%' THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: chybí kontrola role admina';
  END IF;

  IF _telo NOT LIKE '%SECURITY DEFINER%' OR _telo NOT LIKE '%search_path%' THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: ztratila SECURITY DEFINER nebo search_path';
  END IF;

  -- `has_function_privilege`, NE `proacl LIKE '%anon=%'`.
  --
  -- `LIKE` je vůči grantu přes PUBLIC falešně zelený: `GRANT … TO PUBLIC` zapíše
  -- do ACL `=X/postgres` (bez jména role), takže `anon` EXECUTE má, ale řetězec
  -- „anon=" v ACL není a kontrola projde. Navíc `array_to_string(NULL, ',')` je
  -- NULL a všechna tři `IF` by tiše prošla. Tohle se ptá na skutečné právo.
  SELECT array_to_string(proacl, ',') INTO _prava
    FROM pg_proc WHERE oid = 'public.nevyfakturovane_akce(uuid,date,date)'::regprocedure;
  IF has_function_privilege('anon', 'public.nevyfakturovane_akce(uuid,date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: anon má EXECUTE (%)', coalesce(_prava, '<NULL acl>');
  END IF;
  IF has_function_privilege('service_role', 'public.nevyfakturovane_akce(uuid,date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: service_role má EXECUTE (%)', coalesce(_prava, '<NULL acl>');
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.nevyfakturovane_akce(uuid,date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'nevyfakturovane_akce: authenticated přišel o EXECUTE (%)', coalesce(_prava, '<NULL acl>');
  END IF;

  RAISE NOTICE 'nevyfakturovane_akce: fakturoidí filtr 3× ✔, filtr ceny zadarmo 3× ✔, invoice_id ✔, guard ✔, práva ✔ (%)', _prava;
END;
$kontrola$;
