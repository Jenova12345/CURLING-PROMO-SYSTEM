-- =============================================================================
-- Výchozí ceník ledu pro NEKOMERČNÍ akce (zadání Jakuba, 5. 9. 2026)
-- =============================================================================
-- Kč / DRÁHA / HODINA. Že je to za dráhu a ne za celou akci, není domněnka:
-- `create_booking(p_sheet_ids uuid[], …)` zakládá JEDEN řádek `reservations`
-- na každou vybranou dráhu a `set_reservation_pricing` ocení každý zvlášť.
-- Změřeno na produkci: akce 0c70e30c, 3 h na dvou drahách → 2× 3 600 = 7 200.
--
--   vsedni  6–14 =  700   14–17 = 900   17–22 = 1000
--   vikend  6–14 =  900   14–22 = 1000
--
-- POSLEDNÍ PÁSMO JDE DO 22:00, NE DO 21:00, JAK ZNĚL CENÍK.
-- Otevírací doba je 07:00–22:00 na všech sedm dní a `trg_cenik_pokryva_provoz`
-- ceník, který ji nepokrývá, ODMÍTNE — změřeno:
--   „Ceník ledu nepokrývá celou otevírací dobu — chybí pásmo na: Po 21:00, …"
-- Druhá cesta (zkrátit halu na 21:00) by rozbila 7 živých budoucích rezervací,
-- které dnes končí ve 22:00 (turnaje ČSC) — jakýkoli jejich přesun by spadl na
-- „Led na víkend v 21 h nemá v ceníku cenu". Jestli se má hala opravdu zavírat
-- ve 21:00, je to samostatné rozhodnutí o otevírací době, ne o ceníku.
--
-- KOMERČNÍHO CENÍKU SE TO NEDOTÝKÁ. Pásmová větev v `set_reservation_pricing`
-- běží jen pro `subject_type='club'` bez vlastní `default_rate` a jen když typ
-- akce není `commercial` ani `recruitment`; komerce jede přes
-- `settings.commercial_default_rate`, na který tahle migrace nesahá.
--
-- CENA JE SNAPSHOT — ALE POZOR, VĚTŠINA DOTČENÝCH REZERVACÍ JE V BUDOUCNU.
--
-- `amount` a rozpis v `cenove_pasma` vznikly při založení; `set_reservation_pricing`
-- je znovu počítá jen při vzniku, při přecenění typu akce (`app.preceneni`),
-- nebo když se rezervace POSUNE V ČASE. Změna ceníku sama o sobě nic nepřepočítá.
--
-- Dřívější znění tohohle odstavce mluvilo o „historických rezervacích" a tím
-- svádělo. Změřeno na produkci 6. 9. 2026:
--   * 107 ŽIVÝCH POTVRZENÝCH pásmových rezervací má start v BUDOUCNU
--     (nejbližší 7. 9. 2026 17:00 místního času, nejzazší březen 2027),
--   * dnes za 825 600 Kč, podle tohoto ceníku by to bylo 748 000 Kč
--     → rozdíl 77 600 Kč,
--   * ani jedna zatím není na dokladu (`invoice_id IS NOT NULL` = 0).
--
-- Ty zůstanou na STARÉ ceně, dokud s nimi někdo nehne. Jakmile se některá
-- posune v čase, přecení se podle TOHOTO ceníku — dvě rezervace na stejný
-- termín pak mohou mít různou cenu podle toho, jestli s nimi někdo hýbal.
--
-- ⚠ JESTLI SE MAJÍ TY BUDOUCÍ REZERVACE PŘECENIT, JE TO PRODUKTOVÉ ROZHODNUTÍ
--   PRO PM/KLIENTA — tahle migrace je NEPŘECEŇUJE. Teď je na to čistá chvíle
--   (nic není fakturované); po prvním dokladu už ne. Přecenění by šlo zvlášť,
--   řízeně pod `app.preceneni`, ne mimochodem tady.
-- =============================================================================

-- 0) Kolik řádků tabulka měla, než jsme na ni sáhli. Slouží jen sebekontrole
--    níž k důkazu, že se staré pásmo opravdu jen ZAVŘELO a nesmazalo.
--    (Migrace běží jako jedna transakce — změřeno — takže temp tabulka
--    přežije až k sebekontrole a `ON COMMIT DROP` ji pak uklidí.)
CREATE TEMP TABLE _cenik_pred_migraci ON COMMIT DROP AS
  SELECT count(*) AS n FROM public.cenik_pasma;

-- 1) Staré pásmo se NEMAŽE, jen zavře. `cenik_pasma_bez_prekryvu` je EXCLUDE
--    jen nad živými řádky (`WHERE deleted_at IS NULL`), takže tohle musí
--    proběhnout PŘED vložením nových — jinak by se nová pásma potkala se
--    starými a constraint by je odmítl.
UPDATE public.cenik_pasma
   SET deleted_at = now()
 WHERE deleted_at IS NULL;

-- 2) Nový ceník. `popis` je NOT NULL a neprázdný (`cenik_pasma_popis`),
--    `sazba` musí být celé koruny (`cenik_pasma_cele`).
INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis) VALUES
  ('vsedni',  6, 14,  700, 'Po–Pá 06–14'),
  ('vsedni', 14, 17,  900, 'Po–Pá 14–17'),
  ('vsedni', 17, 22, 1000, 'Po–Pá 17–22'),
  ('vikend',  6, 14,  900, 'So+Ne 06–14'),
  ('vikend', 14, 22, 1000, 'So+Ne 14–22');

-- 3) `SET CONSTRAINTS ALL IMMEDIATE` tu SCHVÁLNĚ NENÍ.
--    Strážce pokrytí (`trg_cenik_pasma_pokryti`) je DEFERRABLE INITIALLY
--    DEFERRED, takže se ozve až při commitu. To stačí — migrace je atomická:
--    změřeno 6. 9. 2026 dočasnou migrací, která zapsala řádek a pak spadla;
--    po pádu po ní nezbyl ani ten zápis. Půlka ceníku se na produkci dostat
--    nemůže.
--
--    Proč ten příkaz nepřidávat: pod `supabase` CLI vypsal jen
--    „WARNING: SET CONSTRAINTS can only be used in transaction blocks",
--    tedy se netvářil jako ochrana a žádnou by neposkytl. (Přes `psql -c`
--    s víc příkazy naopak funguje — je to rozdíl cesty, ne Postgresu.
--    Nespoléhat na něj tady je tak jako tak bezpečnější.)
--    Že strážce pod CLI opravdu funguje, je změřené, ne předpokládané:
--    dočasná migrace, která jen soft-smazala pásmo 17–22 a NEMĚLA žádnou
--    sebekontrolu, spadla při commitu na
--    „Ceník ledu nepokrývá celou otevírací dobu — chybí pásmo na: Po 17:00…".
--    CLI drží soubor i zápis do `schema_migrations` v jedné transakci.
--    Ochrana je tedy dvojitá: sebekontrola níž (dřív a s konkrétnější
--    hláškou) a odložený trigger při commitu.
--
--    (V RUČNÍM testu přes psql s BEGIN/ROLLBACK `SET CONSTRAINTS ALL IMMEDIATE`
--    nutný JE — bez něj odložený strážce při ROLLBACKu vůbec neproběhne
--    a test hlásí falešnou zelenou.)

-- 4) Sebekontrola — měří CENU, ne obsah tabulky. Že v ní je pět řádků,
--    neznamená, že engine počítá, co má.
DO $kontrola$
DECLARE
  _zivych int;
  _po_rano numeric; _po_odpo numeric; _po_vecer numeric; _po_pozde numeric;
  _vik_rano numeric; _vik_odpo numeric; _vik_vecer numeric;
  _komercni numeric;
  _rozdil   text;
  _pred     int;
  _po       int;
BEGIN
  SELECT count(*) INTO _zivych FROM public.cenik_pasma WHERE deleted_at IS NULL;
  IF _zivych <> 5 THEN
    RAISE EXCEPTION 'Ceník má mít 5 živých pásem, má %.', _zivych;
  END IF;

  -- STARÉ PÁSMO SE SMÍ JEN ZAVŘÍT, NE SMAZAT.
  --
  -- Bez tohohle tvrzení by `DELETE` místo `UPDATE … SET deleted_at` prošel
  -- úplně tiše — ceny by seděly, pokrytí taky, jen by byl starý ceník
  -- nenávratně pryč a s ním návratová cesta (revert je dnes „odklikni
  -- `deleted_at` u starých řádků", ne obnova ze zálohy). Nález migrační brány.
  --
  -- Neměří se „musí zbýt aspoň 4 smazané" — to by shodilo každé ČISTÉ
  -- prostředí, kde žádné staré pásmo není. Táž past, na kterou tahle migrace
  -- už jednou spadla u `commercial_default_rate`. Měří se, že tabulka
  -- nezmenšila: co v ní bylo, tam zůstalo, a přibylo přesně 5 nových.
  SELECT n INTO _pred FROM _cenik_pred_migraci;   -- uložená hodnota, ne počet řádků
  SELECT count(*) INTO _po   FROM public.cenik_pasma;
  IF _po < _pred + 5 THEN
    RAISE EXCEPTION 'Ceník se zmenšil — staré pásmo se smazalo natvrdo místo `deleted_at` (bylo %, je %, mělo být %).',
      _pred, _po, _pred + 5;
  END IF;

  -- Pondělí 7. 9. 2026 a sobota 5. 9. 2026 (ověřeno: pondělí / sobota).
  -- MĚŘÍ SE KAŽDÉ PÁSMO, VČETNĚ `vsedni 14–17`. Ta hodina tu dřív chyběla
  -- a migrační brána to našla mutací: sazba přepsaná z 900 na 950 prošla
  -- bez jediného slova. U ceníku je neměřené pásmo díra v bráně.
  -- Hodina 21:00 je tu navíc jako hlídka toho, že poslední pásmo sahá do 22:00
  -- (kvůli otevírací době) — kdyby ho někdo zkrátil na 21, spadne to tady.
  SELECT castka INTO _po_rano  FROM public.cena_ledu('2026-09-07 08:00+02','2026-09-07 09:00+02');
  SELECT castka INTO _po_odpo  FROM public.cena_ledu('2026-09-07 15:00+02','2026-09-07 16:00+02');
  SELECT castka INTO _po_vecer FROM public.cena_ledu('2026-09-07 18:00+02','2026-09-07 19:00+02');
  SELECT castka INTO _po_pozde FROM public.cena_ledu('2026-09-07 21:00+02','2026-09-07 22:00+02');
  SELECT castka INTO _vik_rano FROM public.cena_ledu('2026-09-05 08:00+02','2026-09-05 09:00+02');
  SELECT castka INTO _vik_odpo FROM public.cena_ledu('2026-09-05 15:00+02','2026-09-05 16:00+02');
  SELECT castka INTO _vik_vecer FROM public.cena_ledu('2026-09-05 21:00+02','2026-09-05 22:00+02');

  IF _po_rano <> 700 OR _po_odpo <> 900 OR _po_vecer <> 1000 OR _po_pozde <> 1000
     OR _vik_rano <> 900 OR _vik_odpo <> 1000 OR _vik_vecer <> 1000 THEN
    RAISE EXCEPTION 'Ceník nepočítá podle zadání: vš. %/%/%/% (má být 700/900/1000/1000), vík. %/%/% (má být 900/1000/1000).',
      _po_rano, _po_odpo, _po_vecer, _po_pozde, _vik_rano, _vik_odpo, _vik_vecer;
  END IF;

  -- HRANICE PÁSEM, NE JEN SAZBY.
  --
  -- Sondy výš měří cenu v 08/15/18/21 h, jenže pásma se lámou v 6/14/17/22 —
  -- žádná sonda tedy nestojí tam, kde se cena mění. Migrační brána to dokázala:
  -- posunout `vsedni` hranici ze 14 na 15 (hodina 14:00 zlevní z 900 na 700)
  -- prošlo bez jediného slova, protože sonda v 15:00 vrátí 900 tak jako tak.
  -- Tohle tvrzení proto přišpendlí CELOU tabulku na zadání, včetně hranic.
  -- `popis` se schválně neporovnává — je kosmetický.
  SELECT string_agg(hlaska, '; ' ORDER BY hlaska) INTO _rozdil FROM (
    SELECT format('v tabulce navíc: %s %s-%s za %s', den_typ, od_hodina, do_hodina, sazba) AS hlaska
      FROM (SELECT den_typ::text, od_hodina::int, do_hodina::int, sazba
              FROM public.cenik_pasma WHERE deleted_at IS NULL
            EXCEPT ALL
            SELECT * FROM (VALUES
              ('vsedni', 6,14, 700::numeric),('vsedni',14,17, 900),('vsedni',17,22,1000),
              ('vikend', 6,14, 900),        ('vikend',14,22,1000)) z) a(den_typ,od_hodina,do_hodina,sazba)
    UNION ALL
    SELECT format('v tabulce chybí: %s %s-%s za %s', den_typ, od_hodina, do_hodina, sazba)
      FROM (SELECT * FROM (VALUES
              ('vsedni', 6,14, 700::numeric),('vsedni',14,17, 900),('vsedni',17,22,1000),
              ('vikend', 6,14, 900),        ('vikend',14,22,1000)) z
            EXCEPT ALL
            SELECT den_typ::text, od_hodina::int, do_hodina::int, sazba
              FROM public.cenik_pasma WHERE deleted_at IS NULL) b(den_typ,od_hodina,do_hodina,sazba)
  ) r;
  IF _rozdil IS NOT NULL THEN
    RAISE EXCEPTION 'Ceník se rozešel se zadáním (kontroluje se i HRANICE pásem): %', _rozdil;
  END IF;

  -- Poslední hodina otevírací doby musí mít cenu, jinak by v ní klubová
  -- rezervace skončila chybou (a strážce výš by migraci stejně neprosadil).
  IF EXISTS (SELECT 1 FROM public.hodiny_bez_pasma(
               (SELECT opening_hours FROM public.settings LIMIT 1))) THEN
    RAISE EXCEPTION 'Ceník nepokrývá celou otevírací dobu.';
  END IF;

  -- Komerce: NEKONTROLUJE se, že je vyplněná. Na čisté databázi je
  -- `commercial_default_rate` schválně NULL (vyplní ji admin v Nastavení),
  -- takže takové tvrzení by shodilo každé nové prostředí — ověřeno, tahle
  -- migrace na tom `supabase db reset` napoprvé spadla.
  -- Že se komerce nehnula, plyne z toho, že tady žádný UPDATE na `settings`
  -- není; hlídá se jen to, že pásma na komerční akce vůbec nesahají.
  SELECT commercial_default_rate INTO _komercni FROM public.settings LIMIT 1;

  RAISE NOTICE 'Ceník ledu: 5 pásem, ceny sedí (700/900/1000 × 900/1000), pokrytí OK, komerční sazba beze změny (%).',
    COALESCE(_komercni::text, 'zatím nevyplněná');
END $kontrola$;
