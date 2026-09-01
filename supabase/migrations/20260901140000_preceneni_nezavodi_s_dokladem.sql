-- =============================================================================
-- Přecenění akce a zabrání pro doklad se musí vzájemně vyloučit
-- Nález 1 z ultra review (1. 9. 2026) — 6 000 Kč tichého rozdílu
-- =============================================================================
-- CO SE DĚLO:
--
-- `over_neni_vyfakturovano()` (brána z 20260831232000) je neuzamčený
-- `SELECT count(*)`, `fakturoid_zkus_zabrat()` je INSERT do vazební tabulky.
-- Pod READ COMMITTED se míjejí: brána nevidí nezakomitovaný claim, claim nevidí
-- chystané přecenění, obojí commitne. Změřeno v souběhu — claim prošel,
-- `uprav_sazbu_akce` se ani nezablokovala (11,9 ms):
--
--     rezervace:  sazba 4 000 Kč/h, částka 8 000 Kč
--     doklad:     nas_soucet 2 000 Kč
--     rozdíl:     6 000 Kč na jedné akci, bez chyby komukoli na obrazovce
--
-- Sekvenčně brána odmítne správně. Je to čistě souběh — a přesně to, co
-- CLAUDE.md zakazuje: „doklad zní na jinou částku než ‚Kdo kolik dluží'".
--
-- Týká se všech tří editačních cest: `uprav_sazbu_akce`, `zmen_typ_akce`
-- i `uprav_drahy_akce` — všechny volají tutéž bránu.
--
-- -----------------------------------------------------------------------------
-- PROČ SE ZAMYKÁ NA OBOU STRANÁCH, KDYŽ BY STAČILA JEDNA
-- -----------------------------------------------------------------------------
-- Nosný je zámek v BRÁNĚ. `fakturoid_zkus_zabrat` sice na `reservations` nikde
-- nesahá explicitně — píše jen do `fakturoid_invoices` a do vazební tabulky —
-- ale ta má cizí klíč `reservation_id REFERENCES reservations(id)`, a INSERT
-- přes cizí klíč si na odkazovaném řádku bere `FOR KEY SHARE`. To s `FOR
-- UPDATE` v bráně koliduje, takže se obě cesty serializují i bez druhé půlky.
--
-- OVĚŘENO MUTACÍ, ne úvahou: s opravenou bránou a claimem BEZ zámku závod
-- neprošel — B čekalo 3 042 ms a bylo odmítnuto. (Původní znění téhle hlavičky
-- tvrdilo opak, tedy že jednostranná oprava nefunguje. Byl to omyl: díval jsem
-- se jen na explicitní přístupy k tabulce a na implicitní zámek z cizího klíče
-- jsem zapomněl.)
--
-- Explicitní `FOR UPDATE` v claimu tu přesto NECHÁVÁM, a to vědomě: bez něj
-- celá záruka visí na cizím klíči, který může kdokoli příští migrací zahodit
-- (třeba kvůli archivaci starých rezervací) — a nic by nespadlo. Závod by se
-- tiše vrátil a peníze by se rozešly znovu. Radši mít pravidlo napsané tam,
-- kde platí, než ho odvozovat z constraintu na jiné tabulce.
--
-- Obě strany mají `ORDER BY id`, takže shodné pořadí zámků = žádné uváznutí.
--
-- -----------------------------------------------------------------------------
-- ⚠️ PROČ SE MĚNÍ VOLATILITA
-- -----------------------------------------------------------------------------
-- `over_neni_vyfakturovano` byla `STABLE`. `SELECT … FOR UPDATE` v ní skončí
-- chybou „SELECT FOR UPDATE is not allowed in a non-volatile function"
-- (ověřeno empiricky, ne z dokumentace), takže by se rozbily všechny tři
-- editační RPC naráz. Volatilita se proto shazuje na `VOLATILE` TOUTÉŽ
-- změnou. `fakturoid_zkus_zabrat` už `VOLATILE` je.
--
-- Ztráta `STABLE` nemá jinou cenu: funkce se volá jednou za operaci přes
-- `PERFORM`, není v žádném indexu ani pohledu (ověřeno v `pg_depend`).
--
-- -----------------------------------------------------------------------------
-- CO SE NEMĚNÍ
-- -----------------------------------------------------------------------------
-- Podmínka brány ani chování při sekvenčním běhu. Kdo edituje akci, která na
-- dokladu není, nepozná rozdíl; kdo edituje vyfakturovanou, dostane tutéž
-- hlášku co dřív. Mění se jen to, že mezi dotazem a zápisem se už nikdo
-- nevejde.
--
-- VRATNOST: obě funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef);
--   u brány nezapomenout vrátit i `STABLE`. Tím se závod vrátí.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Brána: VOLATILE + zámek jako první, ve vlastním příkazu
--
-- Tělo z `pg_get_functiondef` živého schématu (pravidlo 7); zásah je změna
-- volatility a jeden vložený `PERFORM … FOR UPDATE`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.over_neni_vyfakturovano(_event_id uuid, _co text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _kolik int;
BEGIN
  -- ZÁMEK MUSÍ BÝT PRVNÍ A VE VLASTNÍM PŘÍKAZU.
  --
  -- Bez něj tahle brána závodila s `fakturoid_zkus_zabrat` a prohrávala tiše:
  -- pod READ COMMITTED její `count(*)` nevidí nezakomitovaný claim, claim
  -- nevidí chystané přecenění, obojí commitne — a rezervace skončí na 8 000 Kč
  -- proti dokladu na 2 000 Kč. Nikomu se přitom nic nezobrazí.
  --
  -- Tenhle zámek je ten NOSNÝ. Claim se o něj otře i bez vlastního `FOR
  -- UPDATE`, protože INSERT do vazební tabulky si přes cizí klíč bere na
  -- řádku rezervace `FOR KEY SHARE` — a to s `FOR UPDATE` koliduje.
  -- Druhá půlka v claimu je pojistka pro případ, že by ten cizí klíč někdy
  -- zmizel; podrobně v hlavičce migrace.
  --
  -- `ORDER BY id` na obou stranách drží stejné pořadí, takže nevzniká uváznutí.
  --
  -- A JE TO SAMOSTATNÝ PŘÍKAZ SCHVÁLNĚ: pod READ COMMITTED dostane každý
  -- příkaz vlastní snapshot. Kdyby se zamykalo uvnitř dotazu níž, počítal by
  -- se `count(*)` ze snapshotu pořízeného PŘED čekáním na zámek a claim, který
  -- mezitím zakomitoval, by v něm pořád nebyl. Takhle se zámek získá teď
  -- a ptáme se až potom, tedy nad novým snapshotem.
  PERFORM 1
     FROM public.reservations r
    WHERE r.event_id = _event_id AND r.deleted_at IS NULL
    ORDER BY r.id
      FOR UPDATE;

  SELECT count(*) INTO _kolik
    FROM public.reservations r
   WHERE r.event_id = _event_id
     AND r.deleted_at IS NULL
     AND (r.invoice_id IS NOT NULL
          OR EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations fr
                      WHERE fr.reservation_id = r.id));

  IF _kolik > 0 THEN
    RAISE EXCEPTION '% už měnit nejde — % z jejích rezervací je na vystaveném dokladu.', _co, _kolik
      USING HINT = 'Doklad nejdřív stornuj nebo dobropisuj; jinak by faktura zněla na jinou částku než rozvrh.';
  END IF;
END;
$function$

;

-- -----------------------------------------------------------------------------
-- 2) Claim: druhá polovina zámku
--
-- Tělo z živého schématu; zásah je jediný `PERFORM … FOR UPDATE` těsně před
-- vložením vazeb.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_zkus_zabrat(_klic text, _druh text, _subject uuid, _event uuid, _od date, _do date, _nas_soucet numeric, _radku integer, _rezim text, _rezervace uuid[])
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

    -- DRUHÁ POLOVINA ZÁMKU (viz `over_neni_vyfakturovano`).
    --
    -- POJISTKA, ne nosný prvek. Serializaci dnes drží už samotný cizí klíč
    -- `reservation_id → reservations(id)`: INSERT přes něj si bere na řádku
    -- rezervace `FOR KEY SHARE`, což koliduje s `FOR UPDATE` v bráně.
    -- Tenhle řádek to říká nahlas, aby záruka nezávisela na constraintu,
    -- který může příští migrace zahodit, aniž by cokoli spadlo.
    --
    -- `ORDER BY id` shodně s druhou stranou, aby nevzniklo uváznutí.
    PERFORM 1
       FROM public.reservations r
      WHERE r.id = ANY (_rezervace)
      ORDER BY r.id
        FOR UPDATE;

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
$function$

;

-- -----------------------------------------------------------------------------
-- 3) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
BEGIN
  IF (SELECT provolatile FROM pg_proc WHERE oid = 'public.over_neni_vyfakturovano(uuid,text)'::regprocedure) <> 'v' THEN
    RAISE EXCEPTION 'over_neni_vyfakturovano není VOLATILE — FOR UPDATE v ní spadne a editační RPC přestanou fungovat.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.over_neni_vyfakturovano(uuid,text)'::regprocedure)
     NOT LIKE '%FOR UPDATE%' THEN
    RAISE EXCEPTION 'Brána nemá zámek — závod s fakturoidím claimem je zpátky.';
  END IF;

  -- Pojistka v claimu. Není nosná (drží to cizí klíč, viz hlavička), ale
  -- hlídá se schválně: kdyby ji někdo odstranil zároveň s tím cizím klíčem,
  -- závod se vrátí a nikdo si toho nevšimne.
  IF (SELECT prosrc FROM pg_proc
        WHERE oid = 'public.fakturoid_zkus_zabrat(text,text,uuid,uuid,date,date,numeric,integer,text,uuid[])'::regprocedure)
     NOT LIKE '%FOR UPDATE%' THEN
    RAISE EXCEPTION 'Claim přišel o pojistný zámek nad reservations.';
  END IF;

  RAISE NOTICE 'Přecenění akce a zabrání pro doklad se vzájemně vylučují.';
END $kontrola$;
