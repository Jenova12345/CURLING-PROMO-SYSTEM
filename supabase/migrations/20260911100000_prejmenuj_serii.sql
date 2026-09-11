-- =============================================================================
-- Přejmenování celé série — název a poznámka najednou (zadání 11. 9. 2026)
-- =============================================================================
-- CO SE MĚNÍ
--
-- Dneska přejmenování akce, která je součástí opakované série, změní JEN TEN
-- JEDEN termín: `update_booking` sáhne na `events.title` jedné akce. Kdo chtěl
-- přejmenovat celý trénink, musel obejít dvacet termínů ručně. Tahle migrace
-- přidává druhou možnost — `prejmenuj_serii` přepíše název a poznámku na všech
-- BUDOUCÍCH termínech série najednou.
--
-- CO SE NEMĚNÍ
--
--   * `update_booking` se NEDOTÝKÁ. Volba „jen tato akce" jde pořád přes ni
--     a chová se bit po bitu stejně jako dřív. Kdo tuhle funkci nezavolá,
--     nepozná, že vznikla.
--   * PLATÍ TO JEN NA NÁZEV A POZNÁMKU. Čas, dráhy, sazba, odběratel ani typ
--     akce se hromadně neměnit nedají a tahle funkce na ně nesahá. Hromadný
--     přesun času série je vědomě NEPOSTAVENÝ (zadání 11. 9. 2026) — kolize,
--     otevírací doba a ceník se u každého termínu řeší zvlášť.
--   * PRÁVA ZŮSTÁVAJÍ DNEŠNÍ. Rozhoduje `can_manage_reservation`, tedy totéž,
--     co rozhoduje u `update_booking`: admin, zástupce klubu, nebo člen na
--     rezervaci, kterou sám založil.
--
-- JEN BUDOUCÍ TERMÍNY (rozhodnutí zákazníka, 11. 9. 2026)
--
-- Minulé termíny si nechají název, pod kterým proběhly. Důvod je účetní: název
-- akce se tiskne na doklad, a přepsat ho zpětně by znamenalo, že vystavená
-- faktura mluví o něčem jiném než záznam pod ní. ČASOVÁ hranice je
-- `start_at >= now()`, tedy táž, jakou používá `cancel_booking` pro
-- `p_scope = 'series'` — „celá série" znamená v obou místech totéž období.
--
-- VE DVOU VĚCECH SE OD `cancel_booking` LIŠÍME, a obě jsou vědomé:
--   * `cancel_booking` bere jen `status = 'confirmed'` (stornovat už stornované
--     nejde). Přejmenování se týká i STORNOVANÝCH budoucích termínů — patří do
--     série a mají se jmenovat stejně jako zbytek. Je to shodné s rozhodnutím
--     u `zmen_firmu_akce`, kde se odběratel přepisuje i u stornovaných drah.
--     Důvod storna tím netrpí, ten žije v `cancel_reason`, ne v `note`.
--     Změřeno v `supabase/tests/prejmenuj_serii_test.sql`, ať je to rozhodnutí,
--     a ne náhoda. (Rozdíl doměřila brána code review 11. 9. 2026; dřívější
--     znění tvrdilo, že jsou ty hranice totožné. Nebyla to pravda.)
--   * `cancel_booking` ruší jen to, na co volající PRÁVO MÁ. Přejmenování je
--     naopak fail-closed — viz níž.
--
-- FAIL-CLOSED NA PRÁVA (rozhodnutí zákazníka, 11. 9. 2026)
--
-- Když volající nesmí editovat byť jediný z dotčených termínů, NEPROJDE NIC
-- a dozví se, kolika termínů se to týká. Alternativa „přejmenuj, na co máš
-- právo" by uměla tiše vyrobit sérii se dvěma názvy, které si nikdo nevšimne —
-- a série je právě ta věc, u které se na jednotlivé termíny nekouká.
--
-- NEŽ SE TOHLE NASADÍ (změřeno bezpečnostní bránou na produkci 11. 9. 2026,
-- jen pro čtení)
--
-- Sebekontrola níž se na produkci PROMĚŘÍ CELÁ — nebude nic přiznávat jako
-- nedoměřené. Znamená to ale, že uvnitř shozené podtransakce doopravdy přepíše
-- a zase vrátí 54 živých řádků `events` (série `MBL mix boomer liga`) a drží na
-- nich řádkové zámky až do commitu migrace. Bez rezidua, ověřeno — ale:
--
--   * `scripts/safe-deploy.sh` se u téhle migrace nepřeskakuje. Ne kvůli riziku
--     ztráty, ale protože sahá na živé řádky.
--   * NEPOUŠTĚT V DOBĚ, KDY HALA ZADÁVÁ REZERVACE. `SET LOCAL lock_timeout`
--     chrání jen proti čekání na cizí transakci, ne naopak — po dobu migrace
--     bude těch 54 akcí nezapisovatelných.
--   * Vstupní stav si před pushem PŘEMĚŘ, neber ho z těchhle čísel. Kterou sérii
--     kontrola vybere, rozhoduje `ORDER BY budoucich DESC` nad živými daty
--     v okamžiku pushe, a klient mezitím zadává. Ze 14 živých sérií měly
--     11. 9. 2026 dvě mezi budoucími termíny víc různých názvů.
--
-- Peněžní stránka byla v tu chvíli čistá: ze 297 budoucích termínů sérií nebyla
-- ani jedna rezervace navázaná na doklad. Předpoklad „název je na dokladu" se
-- tedy dnes týká výhradně minulých termínů — přesně tak, jak funkce počítá.
--
-- POZOR NA JEDNU VĚC, KTERÁ JE V POVAZE SCHÉMATU
--
-- `series_id` je na REZERVACÍCH, ne na akcích: série osmi tréninků je osm
-- rezervací a OSM samostatných akcí. Název přitom žije na akci (`events.title`)
-- a poznámka na rezervaci (`reservations.note`). Když tedy k některému termínu
-- někdo později přidal druhou dráhu, ta druhá dráha do série nepatří — ale
-- název akce se jí změní taky, protože název je společný pro celou akci.
-- Poznámka se jí nezmění. Je to důsledek toho, kde ta dvě pole leží, ne volba;
-- kdyby to zákazníkovi vadilo, je to samostatný ticket na přesun názvu.
--
-- Že by se tím dal přepsat název NĚKOMU CIZÍMU, dnes nehrozí: `uprav_drahy_akce`
-- kopíruje `subject_id`, takže druhá dráha patří téže firmě a práva vyjdou
-- stejně. Na produkci bylo 11. 9. 2026 nula akcí s různým subjektem i nula akcí
-- míchajících série. NENÍ TO ALE VYNUCENÉ CONSTRAINTEM — až někdo sáhne na
-- `uprav_drahy_akce`, je tohle místo k přeměření.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.prejmenuj_serii(
  _reservation_id uuid,
  _title text DEFAULT NULL,
  _note text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _res        public.reservations%ROWTYPE;
  _nazev      text := nullif(btrim(coalesce(_title, '')), '');
  _terminu    int;
  _bez_prava  int;
  _akci       int;
  _poznamek   int;
BEGIN
  SELECT * INTO _res FROM public.reservations
   WHERE id = _reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN
    RAISE EXCEPTION 'Rezervace nenalezena.';
  END IF;

  IF _res.series_id IS NULL THEN
    RAISE EXCEPTION 'Tahle rezervace není součástí opakované série, takže není co přejmenovat hromadně.'
      USING HINT = 'Použijte běžnou úpravu akce.';
  END IF;

  -- DOTČENÉ TERMÍNY: jen budoucí, jen živé, jen z téže série.
  -- `start_at >= now()` schválně shodně s `cancel_booking(p_scope => 'series')`.
  SELECT count(*),
         count(*) FILTER (WHERE NOT public.can_manage_reservation(r.id))
    INTO _terminu, _bez_prava
    FROM public.reservations r
   WHERE r.series_id = _res.series_id
     AND r.deleted_at IS NULL
     AND r.start_at >= now();

  IF _terminu = 0 THEN
    RAISE EXCEPTION 'Série už nemá žádný budoucí termín, takže hromadně není co přejmenovat.'
      USING HINT = 'Minulé termíny si název nechávají — je na dokladech. Tenhle termín upravte jednotlivě.';
  END IF;

  -- FAIL-CLOSED: buď všechny, nebo žádný.
  IF _bez_prava > 0 THEN
    RAISE EXCEPTION 'Na % z % budoucích termínů téhle série nemáte právo, takže se nepřejmenoval žádný.',
      _bez_prava, _terminu
      USING HINT = 'Přejmenujte termíny jednotlivě, nebo o hromadnou změnu požádejte správce haly.';
  END IF;

  -- Nic k zápisu: `_title` prázdný a `_note` nezadaná („neměň"). Není to chyba,
  -- jen se nemá co dít — a hlásit úspěch nad nulou zápisů by lhalo.
  --
  -- Stojí to AŽ ZA kontrolou práv schválně: kdyby se vracelo dřív, poznal by
  -- kdokoli přihlášený podle toho, jestli dostane `zmena: false` nebo hlášku
  -- „není součástí série", že dané UUID existuje a v jaké je sérii — a to bez
  -- jediného oprávnění k ní. (Nález brány code review, 11. 9. 2026.)
  IF _nazev IS NULL AND _note IS NULL THEN
    RETURN jsonb_build_object('zmena', false, 'terminu', 0, 'akci', 0);
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  -- NÁZEV se píše na AKCE, a každá akce jen JEDNOU — proto `DISTINCT`.
  -- Bez něj by se u termínu na dvou drahách tentýž řádek `events` přepsal
  -- dvakrát, což by nadělalo dvojité záznamy v auditu o změně, která je jedna.
  IF _nazev IS NOT NULL THEN
    UPDATE public.events e
       SET title = _nazev
     WHERE e.id IN (SELECT DISTINCT r.event_id
                      FROM public.reservations r
                     WHERE r.series_id = _res.series_id
                       AND r.deleted_at IS NULL
                       AND r.start_at >= now()
                       AND r.event_id IS NOT NULL);
    GET DIAGNOSTICS _akci = ROW_COUNT;
  ELSE
    _akci := 0;
  END IF;

  -- POZNÁMKA se píše na REZERVACE, a jen na ty ze série — druhá dráha, kterou
  -- k termínu někdo přidal mimo sérii, si svou poznámku nechá.
  -- Prázdný řetězec znamená „smaž poznámku", `NULL` znamená „neměň" — stejná
  -- úmluva jako v `update_booking`, ať se to nechová na dvou místech jinak.
  IF _note IS NOT NULL THEN
    UPDATE public.reservations r
       SET note = nullif(btrim(_note), '')
     WHERE r.series_id = _res.series_id
       AND r.deleted_at IS NULL
       AND r.start_at >= now();
    GET DIAGNOSTICS _poznamek = ROW_COUNT;
  ELSE
    _poznamek := 0;
  END IF;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object(
    'zmena', true,
    'terminu', _terminu,
    'akci', _akci,
    'poznamek', _poznamek,
    'nazev', _nazev
  );
EXCEPTION
  -- Táž ochrana jako v `update_booking` (A5): uvnitř SECURITY DEFINER neplatí
  -- RLS, takže by Postgres do chyby integrity doplnil „Failing row contains …"
  -- s celým řádkem rezervace — včetně sazby a částky — a PostgREST by to
  -- přeposlal volajícímu.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Sérii se nepodařilo přejmenovat — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte název a poznámku. Když potíž trvá, řekněte to správci.';
END;
$function$;

COMMENT ON FUNCTION public.prejmenuj_serii(uuid, text, text) IS
  'Přepíše název (events.title) a poznámku (reservations.note) na všech BUDOUCÍCH '
  'termínech opakované série. Práva jsou dnešní (can_manage_reservation) a jsou '
  'fail-closed: kdo nesmí na jeden termín, nepřejmenuje žádný. Času, drah, sazby '
  'ani odběratele se nedotýká — hromadný přesun série vědomě neexistuje.';

REVOKE ALL ON FUNCTION public.prejmenuj_serii(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prejmenuj_serii(uuid, text, text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- SEBEKONTROLA — měří se chování, ne tvar
--
-- VŠECHNY ZÁPISY BĚŽÍ V PODTRANSAKCI, KTERÁ SE VŽDYCKY SHODÍ (`ZS001`), takže
-- po kontrole nezůstane v datech ani znak — a hlavně se nemusí nic uklízet.
--
-- První verze tohohle bloku uklízela ručně: uložila si JEDEN název a tím jedním
-- pak přepsala všechny budoucí termíny série. Na produkci by to nenávratně
-- sjednotilo názvy termínů, které se dneska legitimně liší — dnešní jediná
-- cesta k přejmenování je totiž „jen tato akce", takže série s odlišnými názvy
-- je normální stav (a právě proto se tahle funkce staví). `events` navíc nemá
-- audit trigger, takže původní názvy by nebylo kde dohledat. Změřeno
-- a zachyceno bránou code review, 11. 9. 2026 — v tomhle souboru to nikdy
-- nasazené nebylo. Poučení: kontrola, která po sobě uklízí PŘEPISEM, je
-- nebezpečnější než ta, která se celá zahodí.
--
-- Proměnné plpgsql pád podtransakce PŘEŽIJÍ (nejsou transakční), takže výsledky
-- měření se z ní dostanou ven, kdežto zápisy do tabulek ne. Přesně o to jde.
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE
  _serie uuid; _rez uuid; _admin uuid; _neadmin uuid;
  _budoucich int; _minulych int;
  _v jsonb; _chyba text; _nedomereno text; _spatne text;
  _ruznych int; _zprava text; _otisk_pred text; _otisk_po text;
BEGIN
  SET LOCAL lock_timeout = '3s';

  SELECT ur.user_id INTO _admin FROM public.user_roles ur WHERE ur.role = 'admin' LIMIT 1;

  -- Série, která má aspoň DVA budoucí termíny — na jednom by se „propsalo se to
  -- na všechny" změřit nedalo.
  SELECT x.series_id, x.budoucich INTO _serie, _budoucich
    FROM (SELECT r.series_id,
                 count(*) FILTER (WHERE r.start_at >= now()) AS budoucich
            FROM public.reservations r
           WHERE r.series_id IS NOT NULL AND r.deleted_at IS NULL
           GROUP BY r.series_id) x
   WHERE x.budoucich >= 2
   ORDER BY x.budoucich DESC, x.series_id
   LIMIT 1;

  IF _admin IS NULL OR _serie IS NULL THEN
    RAISE NOTICE 'Přejmenování série: tvar OK, chování NEPROMĚŘENO — chybí admin nebo série se dvěma budoucími termíny.';
    RETURN;
  END IF;

  SELECT r.id INTO _rez FROM public.reservations r
   WHERE r.series_id = _serie AND r.deleted_at IS NULL AND r.start_at >= now()
   ORDER BY r.start_at LIMIT 1;
  SELECT count(*) INTO _minulych FROM public.reservations r
   WHERE r.series_id = _serie AND r.deleted_at IS NULL AND r.start_at < now();

  -- Neadmin, který NENÍ zástupcem žádného subjektu téhle série — tedy ten, komu
  -- série opravdu nepatří. `is_subject_rep()` se použít nedá, čte `auth.uid()`,
  -- ne zadaného uživatele; ptáme se proto rovnou tabulky.
  SELECT sr.user_id INTO _neadmin FROM public.subject_reps sr
   WHERE NOT public.has_role(sr.user_id, 'admin')
     AND sr.subject_id NOT IN (SELECT DISTINCT r.subject_id
                                 FROM public.reservations r
                                WHERE r.series_id = _serie AND r.deleted_at IS NULL
                                  AND r.subject_id IS NOT NULL)
   LIMIT 1;

  -- OTISK PŘED MĚŘENÍM. Porovná se za shozenou podtransakcí a je to BRÁNA NAD
  -- SAMOTNOU OPRAVOU: celá tahle kontrola stojí na jediném řádku
  -- (`RAISE … ERRCODE = 'ZS001'` níž), a kdyby ten řádek někdo vyndal,
  -- podtransakce by se zakomitovala, osmi akcím by zůstal název
  -- `__kontrola migrace__` — a hláška by přitom doslova tvrdila opak.
  -- Bez tohohle otisku projde takové vyndání zeleně. (Nález brány code review,
  -- 11. 9. 2026, po předchozí opravě téhož bloku.)
  --
  -- Otiskuje se md5 celé série, ne jen výskyt testovacího názvu — chytí to
  -- i přepis na jiný text.
  SELECT md5(string_agg(e.title, ',' ORDER BY e.id)) INTO _otisk_pred
    FROM public.events e
   WHERE e.id IN (SELECT r.event_id FROM public.reservations r
                   WHERE r.series_id = _serie AND r.deleted_at IS NULL
                     AND r.event_id IS NOT NULL);

  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);

    _v := public.prejmenuj_serii(_rez, '__kontrola migrace__');

    IF (_v ->> 'terminu')::int <> _budoucich THEN
      _spatne := format('přejmenovalo se %s termínů z %s', _v ->> 'terminu', _budoucich);
    END IF;

    SELECT count(*) INTO _ruznych
      FROM public.reservations r JOIN public.events e ON e.id = r.event_id
     WHERE r.series_id = _serie AND r.deleted_at IS NULL AND r.start_at >= now()
       AND e.title IS DISTINCT FROM '__kontrola migrace__';
    IF _spatne IS NULL AND _ruznych > 0 THEN
      _spatne := format('%s budoucích termínů série si nechalo starý název', _ruznych);
    END IF;

    -- MINULÉ TERMÍNY SE MĚNIT NESMĚLY. Tohle je ta noha, kvůli které je
    -- rozhodnutí „jen budoucí" vůbec rozhodnutím — název je na dokladu.
    IF _spatne IS NULL AND _minulych > 0 THEN
      SELECT count(*) INTO _ruznych
        FROM public.reservations r JOIN public.events e ON e.id = r.event_id
       WHERE r.series_id = _serie AND r.deleted_at IS NULL AND r.start_at < now()
         AND e.title = '__kontrola migrace__';
      IF _ruznych > 0 THEN
        _spatne := format('přejmenovalo se i %s MINULÝCH termínů série', _ruznych);
      END IF;
    END IF;

    -- CIZÍ NEADMIN NEPROJDE. Měřeno pod reálnou rolí — jako `postgres` projde
    -- všechno a test by tvrdil zavřeno o otevřených dveřích (CLAUDE.md, 3 a 9).
    IF _spatne IS NULL AND _neadmin IS NOT NULL THEN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', _neadmin, 'role', 'authenticated')::text, true);
      _chyba := NULL;
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM public.prejmenuj_serii(_rez, '__cizi pokus__');
        EXECUTE 'RESET ROLE';
      EXCEPTION WHEN OTHERS THEN
        _chyba := SQLERRM;
        EXECUTE 'RESET ROLE';
      END;
      IF _chyba IS NULL THEN
        _spatne := 'cizí neadmin sérii přejmenoval';
      END IF;
    END IF;

    -- Konec měření: podtransakce se shodí a všechno zapsané zmizí.
    RAISE EXCEPTION 'hotovo' USING ERRCODE = 'ZS001';
  EXCEPTION
    WHEN sqlstate 'ZS001' THEN NULL;   -- v pořádku, zápisy se zahodily
    WHEN OTHERS THEN _nedomereno := SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims', NULL, true);

  -- PO SHOZENÉ PODTRANSAKCI SE NESMĚLO ZMĚNIT NIC. Viz komentář u otisku výš —
  -- tohle je brána nad opravou samotnou, ne nad měřenou funkcí.
  SELECT md5(string_agg(e.title, ',' ORDER BY e.id)) INTO _otisk_po
    FROM public.events e
   WHERE e.id IN (SELECT r.event_id FROM public.reservations r
                   WHERE r.series_id = _serie AND r.deleted_at IS NULL
                     AND r.event_id IS NOT NULL);
  IF _otisk_po IS DISTINCT FROM _otisk_pred THEN
    RAISE EXCEPTION 'GUARD NEDRŽÍ: sebekontrola po sobě nechala změněné názvy akcí — '
                    'podtransakce se neshodila.';
  END IF;

  -- Guard nedrží → migrace NESMÍ projít. Musí to být AŽ TADY, za shozenou
  -- podtransakcí: kdyby to letělo uvnitř, spadlo by to do `WHEN OTHERS` výš
  -- a skončilo jako neškodné „NEDOMĚŘENO" — přestože je to přesně ten stav,
  -- kvůli kterému kontrola existuje.
  IF _spatne IS NOT NULL THEN
    RAISE EXCEPTION 'GUARD NEDRŽÍ: %.', _spatne;
  END IF;

  IF _nedomereno IS NOT NULL THEN
    RAISE NOTICE 'Přejmenování série: tvar OK, chování NEDOMĚŘENO — %', _nedomereno;
    RETURN;
  END IF;

  -- Hláška se skládá do proměnné a vypisuje jedním zástupným znakem: nárokuje
  -- si JEN TO, CO SE OPRAVDU ZMĚŘILO, a skládat ji přímo v `RAISE` znamená
  -- počítat `%` proti argumentům. To se tu už jednou nepovedlo.
  _zprava := format('Přejmenování série OK: název se propsal na všech %s budoucích termínech',
                    _budoucich);
  IF _minulych > 0 THEN
    _zprava := _zprava || format(', %s minulých zůstalo beze změny', _minulych);
  END IF;
  IF _neadmin IS NOT NULL THEN
    _zprava := _zprava || ', cizí neadmin neprojde.';
  ELSE
    _zprava := _zprava || '. POZOR: cizí neadmin NEPROMĚŘEN — v databázi není'
                       || ' zástupce mimo tuhle sérii; hlídá ho jen'
                       || ' supabase/tests/prejmenuj_serii_test.sql.';
  END IF;
  _zprava := _zprava || ' (Měřeno v podtransakci, která se shodila — v datech nezůstalo nic.)';
  RAISE NOTICE '%', _zprava;
END $kontrola$;
