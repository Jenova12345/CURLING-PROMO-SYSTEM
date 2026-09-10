-- ---------------------------------------------------------------------------
-- ZMĚNA ODBĚRATELE (FIRMY) U KOMERČNÍ AKCE
--
-- Admin potřebuje opravit, KOMU se akce naúčtuje: objednala ji jedna firma,
-- platí druhá, nebo se při zakládání sáhlo vedle. Dnes to nejde vůbec —
-- `subject_id` sedí na rezervaci, je mimo whitelist v `guard_reservation_rep_changes`
-- („Pole „subject_id" smí měnit jen správce") a žádné RPC ho nemění. V UI je
-- výběr firmy při editaci natvrdo `disabled`. Jediná cesta byla storno a
-- založit znovu — což u akce, která už proběhla, znamená přepsat historii.
--
-- CO TAHLE FUNKCE DĚLÁ A CO SCHVÁLNĚ NE:
--   • mění odběratele na VŠECH drahách akce najednou (jeden UPDATE nad
--     `event_id`), ne na jedné rezervaci — akce na dvou drahách by jinak
--     skončila se dvěma různými odběrateli a rozpadla by se na dva doklady;
--   • ČÁSTKU NECHÁVÁ BÝT. Nenastavuje `app.preceneni`, takže
--     `set_reservation_pricing` nesáhne ani na sazbu, ani na `amount`, ani na
--     `cena_bez_dph`. Je to oprava adresáta, ne přecenění — dohodnutá cena
--     s změnou plátce nesouvisí a přepočet z ceníku by tiše posunul dluh;
--   • funguje na MINULÉ i BUDOUCÍ akce. Právě u minulých to má smysl:
--     opravuje se adresát faktury, která se teprve vystaví. Okno 48 h se sem
--     nevztahuje — to hlídá čas a dráhy ledu, ne to, komu se účtuje, a je
--     stejně adminské, kdežto tahle funkce je adminská celá.
--
-- FAIL-CLOSED NAD VYSTAVENÝM DOKLADEM — to je tady ta hlavní pojistka.
-- Když už na některou rezervaci akce visí doklad (interní `invoice_id` NEBO
-- podklad z Fakturoidu ve `fakturoid_invoice_reservations`), změna odběratele
-- se ODMÍTNE. Jinak by faktura zněla na jednu firmu a „Kdo kolik dluží" na
-- druhou — dluh by se přeložil na někoho, komu ho nikdo nevystavil, a
-- kontrolní součet Etapy 2 by se rozešel bez jediné hlášky. Hlídá to
-- `over_neni_vyfakturovano`, tedy TÁŽ brána, kterou používá `zmen_typ_akce`;
-- bere si `FOR UPDATE` na rezervacích akce, takže nezávodí s `fakturoid_zkus_zabrat`.
--
-- NOVÝ SUBJEKT MUSÍ BÝT KOMERČNÍ. Komerční akce se účtuje komerční sazbou;
-- podstrčený klub by z ní udělal útvar, který ceník nezná (a u kterého
-- `cena_je_bez_dph` odpovídá jinak).
--
-- DAŇOVÝ VÝZNAM SE NESMÍ POSUNOUT. `cena_bez_dph` je snapshot pořízený spolu
-- se sazbou a tahle funkce sazbu nepřepočítává, takže ho drží. Kdyby k nové
-- firmě ten snapshot nepatřil, doklad by odvedl daň z jiného základu.
-- Fail-closed: taková změna se odmítne s tím, ať se udělá storno a nové
-- založení.
--
-- KUDY SE TO DÁ SPUSTIT, je dobré vědět přesně. NE novým odběratelem: ten je
-- vždycky `commercial`, a `cena_je_bez_dph` pro komerční subjekt vrací `true`
-- bez ohledu na to, jestli má vlastní `default_rate`. Spustí to STARÝ stav —
-- typicky klub s vlastní `default_rate` na komerční akci, u kterého snapshot
-- vyšel `false`. Nebo dráha úplně bez odběratele (`cena_je_bez_dph(NULL, …)`
-- je z definice `false`), což je zároveň jediné, co projde přes kontrolu
-- jednoho odběratele — `count(DISTINCT)` NULL nepočítá. Na produkci k tomu
-- 10. 9. 2026 dojít nemůže (žádný subjekt nemá vyplněnou `default_rate`).
-- (Směr opravila brána code review, NULL roh doměřila bezpečnostní brána.)
--
-- Porovnává se proti SNAPSHOTU na rezervacích, ne proti hodnotě dopočítané
-- z dnešních `subjects`: mezi zápisem částky a touhle změnou se sazba subjektu
-- mohla změnit, a pak by guard srovnával dvě čísla, z nichž ani jedno není to
-- zapsané. Akce, jejíž dráhy se v daňovém významu mezi sebou neshodují, se
-- odmítne rovnou — je rozbitá už teď. (Nález bezpečnostní brány, 10. 9. 2026.)
--
-- STORNOVANÉ DRÁHY SE MĚNÍ TAKY (`deleted_at IS NULL`, bez ohledu na `status`).
-- Je to vědomé a shodné s `zmen_typ_akce` i `over_neni_vyfakturovano`: akce má
-- JEDNOHO odběratele, a kdyby stornovaná dráha zůstala na staré firmě, měla by
-- akce dva — přesně ten stav, kterému tahle funkce brání. Na peníze to nemá
-- vliv, stornovaná dráha se nefakturuje. Kdyby PM chtěl, aby storno zůstalo
-- viset na původní firmě jako historie, je to změna na jeden řádek (`AND
-- status <> 'cancelled'`), ale znamená to připustit akci se dvěma odběrateli.
--
-- RAZÍTKO SCHVÁLENÍ PŘEŽIJE. `subject_id` je ve výčtu, na který kouká
-- `zrus_schvaleni_pri_uprave`, takže by se `approved_at` shodilo — a protože
-- komerční firma nemá v `subject_reps` nikoho, kdo by ho vrátil, akce by při
-- `invoice_only_approved = true` tiše vypadla z „Kdo kolik dluží". Razítko se
-- proto přerazí na admina, ale JEN tam, kde už bylo; neschválené rezervaci ho
-- tahle funkce vyrobit nesmí. Podrobně u samotného UPDATE.
--
-- SEBEKONTROLA PO ZÁPISU MĚŘÍ ČÁSTKU *I* FAKTUROVATELNOST. Součet za akci
-- a počet schválených drah se změří před i po UPDATE, a když se pohne
-- kterékoli z toho, funkce spadne a celá změna se vrátí. Že to musí být obojí,
-- ukázal nález bezpečnostní brány: částka se nehnula ani o korunu, zatímco
-- akce mezitím přestala být fakturovatelná. U peněz nestačí měřit číslo — musí
-- se měřit i to, jestli to číslo vůbec někam vstupuje.
--
-- ZÁMKY PŘI BĚHU MIGRACE. `over_neni_vyfakturovano` bere `FOR UPDATE` na
-- rezervacích akce, kterou si sebekontrola dole vybere (ne na celé tabulce).
--
-- DRŽÍ SE ALE JEN DO KONCE TOHO DO BLOKU, ne do konce souboru: sebekontrola
-- končí `RAISE EXCEPTION … ZF001`, což je abort podtransakce, a Postgres na něm
-- zámky pouští. Změřeno migrační bránou 10. 9. 2026: po doběhnutí bloku drží
-- sezení migrace na `reservations` jen `AccessShareLock` a souběžné sezení si
-- `FOR UPDATE` vezme bez čekání. (Dřívější znění tvrdilo „až do konce
-- migračního souboru" — to NEPLATÍ, je to jinak než u `ADD COLUMN`
-- v `20260910120000_okno_48h.sql`, kde se zámek opravdu drží celý soubor.)
--
-- Opačný směr — že by na cizím zámku čekala MIGRACE — je ošetřený
-- `lock_timeout` uvnitř sebekontroly. Bez něj by `db push` čekal, dokud neskončí
-- cizí transakce (typicky `fakturoid_zkus_zabrat`); změřeno 10 s v testu.
-- Zaseknutý push je horší než spadlý, a nedoměřená kontrola je lepší než obojí.
--
-- ROLLBACK:
--   DROP FUNCTION public.zmen_firmu_akce(uuid, uuid);
--   Nic jiného tahle migrace nemění — žádný sloupec, žádný trigger, žádná
--   úprava existující funkce, a ACL zaniká s funkcí (`REVOKE` je přitom nosný:
--   `pg_default_acl` dává `anon` EXECUTE na každou novou funkci v `public`).
--
--   VRACÍ TO ALE SCHÉMA, NE DATA. Rezervace, kterým funkce mezitím přerazila
--   razítko na admina nebo změnila odběratele, zůstanou v novém stavu i po
--   dropnutí — je to úmyslná změna dat, ne vedlejší efekt migrace. Zpátky se
--   dostanou jedině ručně, podle `audit_log`. (Nález migrační brány.)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.zmen_firmu_akce(_event_id uuid, _subject_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _typ            public.event_type;
  _stary_subjekt  uuid;
  _stary_nazev    text;
  _novy_typ       public.subject_type;
  _novy_nazev     text;
  _novy_rate      numeric;
  _zmeneno        int;
  _celkem_pred    numeric;
  _celkem_po      numeric;
  _schvalenych_pred int;
  _schvalenych_po   int;
  _ruznych_dph    int;
  _ruznych_firem  int;
  _dph_snapshot   boolean;
BEGIN
  -- Odběratel rozhoduje o tom, komu přijde faktura. Táž úvaha jako u sazby
  -- (`uprav_sazbu_akce`) a typu akce (`zmen_typ_akce`) — mění to jen správce.
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Odběratele akce může změnit jen správce haly.';
  END IF;

  SELECT e.event_type INTO _typ FROM public.events e WHERE e.id = _event_id;
  IF _typ IS NULL THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  -- Jen komerční akce (zadání). U klubového tréninku je odběratel klub, jehož
  -- členové na led chodí — přepsat ho na firmu by odpojilo rezervaci od
  -- členství, potvrzování i od klubového ceníku.
  IF _typ <> 'commercial' THEN
    RAISE EXCEPTION 'Odběratele lze měnit jen u komerční akce (tahle je „%").', _typ
      USING HINT = 'Když má akci platit firma, přepni ji nejdřív na komerční.';
  END IF;

  SELECT s.type, s.name, s.default_rate INTO _novy_typ, _novy_nazev, _novy_rate
    FROM public.subjects s
   WHERE s.id = _subject_id AND s.deleted_at IS NULL;
  IF _novy_typ IS NULL THEN
    RAISE EXCEPTION 'Firma nenalezena (nebo je smazaná).';
  END IF;
  IF _novy_typ <> 'commercial' THEN
    RAISE EXCEPTION 'Odběratelem komerční akce může být jen firma, ne klub („%").', _novy_nazev;
  END IF;

  -- Původní odběratel. Bere se z rezervací, ne z akce — `events` subjekt vůbec
  -- nemá, drží ho každá rezervace zvlášť.
  --
  -- Zjišťuje se přitom i to, jestli je JEDEN. Akce se smíšenými odběrateli
  -- existovat nemá, ale `faktura_z_akce` na ni umí narazit (má na to vlastní
  -- hlášku), takže se to stát může. Vzít z ní „ten první podle id" by znamenalo
  -- udělat daňovou kontrolu proti jednomu z nich a druhého tiše přepsat — u
  -- akce, která je rozbitá, a bez zmínky komukoli. Fail-closed: takovou akci
  -- odmítneme a řekneme to. (Nález bezpečnostní brány, 10. 9. 2026.)
  SELECT count(DISTINCT r.subject_id),
         min(r.subject_id::text)::uuid
    INTO _ruznych_firem, _stary_subjekt
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL;

  IF _stary_subjekt IS NULL THEN
    -- Rozlišuje se, PROČ odběratel není: akce bez živých rezervací vs. akce,
    -- která rezervace má, ale žádný odběratel na nich není. Dřív tu byla jedna
    -- hláška o „žádné živé rezervaci", což u druhého případu lhalo.
    -- Přiřadit plátce akci, která ho nikdy neměla, tahle funkce ZÁMĚRNĚ neumí —
    -- je na opravu adresáta, ne na jeho doplnění (bez odběratele je `amount`
    -- NULL, takže by to nebyla oprava, ale ocenění). Kdyby to PM chtěl, je to
    -- samostatný ticket. (Nález migrační brány, 10. 9. 2026.)
    IF EXISTS (SELECT 1 FROM public.reservations r
                WHERE r.event_id = _event_id AND r.deleted_at IS NULL) THEN
      RAISE EXCEPTION 'Tahle akce nemá žádného odběratele, takže není co měnit.'
        USING HINT = 'Doplnit plátce akci, která ho nikdy neměla, tímhle způsobem nejde — akci stornuj a založ znovu.';
    END IF;
    RAISE EXCEPTION 'Akce nemá žádnou živou rezervaci, u které by šlo odběratele změnit.';
  END IF;
  IF _ruznych_firem > 1 THEN
    RAISE EXCEPTION 'Dráhy téhle akce mají každá jiného odběratele (%). To je potřeba spravit dřív, než se odběratel mění.', _ruznych_firem
      USING HINT = 'Obrať se na správce systému, akce má nekonzistentní data.';
  END IF;

  IF _stary_subjekt = _subject_id THEN
    RETURN jsonb_build_object('zmena', false, 'firma', _novy_nazev, 'firma_id', _subject_id);
  END IF;

  -- FAIL-CLOSED NAD VYSTAVENÝM DOKLADEM. Musí být PŘED zápisem a je to táž
  -- brána jako u změny typu akce — pokrývá interní `invoice_id` i podklad
  -- z Fakturoidu a bere si zámek, takže nezávodí se zabíráním dokladu.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Odběratele akce');

  -- DAŇOVÝ VÝZNAM SE NESMÍ POSUNOUT — viz hlavička.
  --
  -- POROVNÁVÁ SE PROTI SNAPSHOTU NA REZERVACÍCH, ne proti hodnotě dopočítané
  -- z dnešních `subjects`. Rozhodující je to, co u částky OPRAVDU LEŽÍ:
  -- `cena_bez_dph` je snapshot pořízený v okamžiku, kdy se vybírala sazba, a od
  -- té doby se `subjects.default_rate` mohla klidně změnit. Dopočítat si obě
  -- strany znovu ze `subjects` znamená porovnat dvě čísla, z nichž ani jedno
  -- nemusí být to zapsané — a guard by pustil změnu, po které řádek zůstane
  -- ve stavu, jaký kontrola v `20260902264000_dph_i_pri_rucni_sazbe.sql`
  -- označuje za vadný příznak DPH. (Nález bezpečnostní brány, 10. 9. 2026.)
  -- Ze staré firmy potřebujeme UŽ JEN JMÉNO, do návratové hodnoty. Její typ ani
  -- sazbu k porovnání daňového významu nebereme — rozhoduje snapshot níž.
  SELECT s.name INTO _stary_nazev FROM public.subjects s WHERE s.id = _stary_subjekt;

  SELECT count(DISTINCT r.cena_bez_dph), min(r.cena_bez_dph::int)::boolean
    INTO _ruznych_dph, _dph_snapshot
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL;

  -- Akce, jejíž dráhy se v daňovém významu neshodují, je rozbitá už teď a
  -- změna odběratele by to jen zhoršila. Fail-closed.
  IF _ruznych_dph > 1 THEN
    RAISE EXCEPTION 'Dráhy téhle akce mají různý daňový význam částky — to je potřeba spravit dřív, než se změní odběratel.'
      USING HINT = 'Obrať se na správce systému, akce má nekonzistentní data.';
  END IF;

  IF public.cena_je_bez_dph(_novy_typ, _typ, _novy_rate) IS DISTINCT FROM _dph_snapshot THEN
    RAISE EXCEPTION 'U téhle akce nesedí daňový význam zapsané částky s odběratelem „%".', _novy_nazev
      USING HINT = 'Částka by po změně znamenala něco jiného, než na co byla spočítaná — typicky u akce s klubem nebo bez plátce. Akci stornuj a založ znovu.';
  END IF;

  -- MĚŘÍ SE OBOJÍ: kolik akce stojí A kolik jejích drah je schválených.
  --
  -- Původní verze hlídala jen částku — a přesně tím prošel nález, kdy se
  -- částka nehnula ani o korunu, zatímco akce vypadla z fakturace shozeným
  -- razítkem. U peněz nestačí měřit číslo, musí se měřit i to, jestli to číslo
  -- vůbec někam vstupuje.
  SELECT COALESCE(sum(COALESCE(r.corrected_amount, r.amount)), 0),
         count(*) FILTER (WHERE r.approved_at IS NOT NULL)
    INTO _celkem_pred, _schvalenych_pred
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL;

  -- SAMOTNÁ ZMĚNA. `app.preceneni` se ZÁMĚRNĚ NENASTAVUJE — bez něj
  -- `set_reservation_pricing` nesáhne na sazbu, částku ani daňový význam.
  --
  -- A `app.trusted_booking` se tu ZÁMĚRNĚ NENASTAVUJE TAKY. Volající je vždycky
  -- admin (ověřeno hned na začátku funkce) a `guard_reservation_rep_changes`
  -- pouští admina dřív, než se dostane k whitelistu sloupců — změřeno
  -- 10. 9. 2026: přímý `UPDATE subject_id` pod rolí `authenticated` jako admin
  -- projde i s markerem NENASTAVENÝM. Marker by tedy jen na zbytek transakce
  -- vypnul guard rezervací a k ničemu by to nebylo; jeho bezpečnost stojí na
  -- tom, jak zřídka se používá (pravidlo 8 v CLAUDE.md).
  --
  -- RAZÍTKO SCHVÁLENÍ MUSÍ PŘEŽÍT — a tohle je ta část, která hlídá peníze.
  --
  -- `subject_id` je ve výčtu, na který kouká `zrus_schvaleni_pri_uprave`, takže
  -- by se `approved_at` shodilo na NULL. Je to jinak správné pravidlo (když
  -- cenu změní hala, klub to má znovu odsouhlasit), jenže tady se cena NEMĚNÍ
  -- a odběratelem je FIRMA, která v `subject_reps` nemá nikoho — razítko by
  -- nikdo nevrátil. Při `billing_settings.invoice_only_approved = true` by akce
  -- tiše vypadla z `fakturovatelne_rezervace` i z „Kdo kolik dluží": admin by
  -- opravil adresáta faktury a přišel by o celou pohledávku, bez jediné hlášky.
  -- Naměřeno bezpečnostní bránou 10. 9. 2026 (10 000 Kč → 0 fakturovatelných
  -- řádků) a ověřeno vlastním měřením.
  --
  -- Razítko se proto PŘERAZÍ NA ADMINA, který změnu dělá — stejně, jako to
  -- `zrus_schvaleni_pri_uprave` dělá pro správce klubu. Auditní stopa tím nic
  -- neztrácí: `approved_by` ukazuje toho, kdo tuhle podobu akce odsouhlasil.
  --
  -- ⚠️ JEN TAM, KDE RAZÍTKO UŽ BYLO. Neschválené rezervaci ho tahle funkce
  -- vyrobit nesmí — to by byl tichý posun opačným směrem: akce by se dostala
  -- do fakturace, aniž ji kdo potvrdil.
  --
  -- `GREATEST(...)` proto, že `now()` je v celé transakci stejné. Kdyby
  -- rezervace byla schválená v TÉŽE transakci, vyšlo by nové razítko shodné se
  -- starým, trigger by to nepovažoval za „hýbe se schválením" a razítko by
  -- přesto spadl. O mikrosekundu se tomu vyhneme.
  UPDATE public.reservations
     SET subject_id = _subject_id,
         approved_at = CASE WHEN approved_at IS NOT NULL
                            THEN GREATEST(now(), approved_at + interval '1 microsecond')
                            END,
         approved_by = CASE WHEN approved_at IS NOT NULL THEN auth.uid() END
   WHERE event_id = _event_id AND deleted_at IS NULL;
  GET DIAGNOSTICS _zmeneno = ROW_COUNT;

  -- SEBEKONTROLA: ani částka, ani fakturovatelnost se hnout nesměly. Kdyby se
  -- hnuly, je to tichý posun dluhu — tak ať je z toho hlasitý pád a celá změna
  -- se vrátí.
  SELECT COALESCE(sum(COALESCE(r.corrected_amount, r.amount)), 0),
         count(*) FILTER (WHERE r.approved_at IS NOT NULL)
    INTO _celkem_po, _schvalenych_po
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.deleted_at IS NULL;

  IF _celkem_po IS DISTINCT FROM _celkem_pred THEN
    RAISE EXCEPTION 'Změnou odběratele by se posunula částka akce (z % na %). Změna se neprovedla.',
      _celkem_pred, _celkem_po;
  END IF;

  IF _schvalenych_po IS DISTINCT FROM _schvalenych_pred THEN
    RAISE EXCEPTION 'Změnou odběratele by se posunul počet schválených drah akce (z % na %) a akce by tím vypadla z fakturace. Změna se neprovedla.',
      _schvalenych_pred, _schvalenych_po;
  END IF;

  RETURN jsonb_build_object(
    'zmena', true,
    'firma', _novy_nazev,
    'firma_id', _subject_id,
    'puvodni', _stary_nazev,
    'puvodni_id', _stary_subjekt,
    'drah', _zmeneno,
    'celkem', _celkem_po,
    -- Ať volající pozná, že razítko schválení má nově pod sebou admin.
    'schvaleni_prerazeno', _schvalenych_pred > 0
  );
END;
$function$;

COMMENT ON FUNCTION public.zmen_firmu_akce(uuid, uuid) IS
  'Změní odběratele (firmu) na všech drahách komerční akce. Admin-only, částku nemění, nad vystaveným dokladem odmítne.';

-- Práva jako u ostatních akčních RPC: `authenticated` smí volat (roli si funkce
-- ověří sama), `anon` ne.
REVOKE ALL ON FUNCTION public.zmen_firmu_akce(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.zmen_firmu_akce(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VLASTNÍ KONTROLA
--
-- Měří TVAR (funkce existuje, je definer, granty sedí) a CHOVÁNÍ na skutečném
-- zápisu. Měřicí zápis se vrací zpátky přes vnořený blok s vlastním SQLSTATE —
-- na produkci po téhle migraci nezůstane změněný ani jeden odběratel.
--
-- Selhání GUARDU je fatální (migrace nesmí projít). Selhání z jiného důvodu —
-- na prázdné lokální databázi nejsou akce, na produkci můžou být všechny
-- komerční akce vyfakturované — se přizná jako NEDOMĚŘENO a `db push` neshodí.
-- Táž úvaha i tentýž vzor jako v `20260910120000_okno_48h.sql`.
-- ---------------------------------------------------------------------------
DO $kontrola$
DECLARE
  _admin uuid; _neadmin uuid; _akce uuid; _stara uuid; _nova uuid;
  _pred numeric; _po numeric; _drah int; _v jsonb;
  _schvalenych_pred int; _schvalenych_po int;
  _nedomereno text; _chyba text;
BEGIN
  -- (a) tvar
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'zmen_firmu_akce') THEN
    RAISE EXCEPTION 'Funkce zmen_firmu_akce nevznikla.';
  END IF;
  IF NOT (SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'zmen_firmu_akce') THEN
    RAISE EXCEPTION 'zmen_firmu_akce musí být SECURITY DEFINER — jinak neprojde přes guard rezervací.';
  END IF;
  IF has_function_privilege('anon', 'public.zmen_firmu_akce(uuid, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon nesmí mít EXECUTE na zmen_firmu_akce.';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.zmen_firmu_akce(uuid, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated musí mít EXECUTE na zmen_firmu_akce.';
  END IF;

  -- (b) chování
  SELECT ur.user_id INTO _admin FROM public.user_roles ur WHERE ur.role = 'admin' LIMIT 1;
  SELECT sr.user_id INTO _neadmin
    FROM public.subject_reps sr
   WHERE NOT EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = sr.user_id AND ur.role = 'admin')
   LIMIT 1;

  -- Komerční akce BEZ dokladu, u které existuje jiná komerční firma se stejným
  -- daňovým významem — tedy akce, na které změna opravdu má projít.
  --
  -- ŘADÍ SE PODLE POČTU DRAH SESTUPNĚ, a je to to podstatné na celém dotazu.
  -- Dřív se bralo jen `ORDER BY created_at DESC`, což lokálně i na produkci
  -- vybere jednodráhovou akci — a noha „propsalo se to na VŠECHNY dráhy" pak
  -- neměří vůbec nic. Mutační test to ukázal černé na bílém: s funkcí okleštěnou
  -- na `UPDATE … LIMIT 1` prošla sebekontrola zeleně a NOTICE hlásil „na všech
  -- 1 drahách". (Nález migrační brány, 10. 9. 2026.)
  --
  -- Dvoudráhová akce nemusí existovat; pak se vezme jednodráhová a NOTICE dole
  -- to přizná, místo aby si nárokoval něco, co nezměřil.
  SELECT x.event_id, x.subject_id INTO _akce, _stara
    FROM (
      SELECT r.event_id, min(r.subject_id::text)::uuid AS subject_id,
             count(*) AS drah, max(r.created_at) AS zalozeno
        FROM public.reservations r
        JOIN public.events e ON e.id = r.event_id
       WHERE e.event_type = 'commercial'
         AND r.deleted_at IS NULL
         AND NOT EXISTS (
           SELECT 1 FROM public.reservations r2
            WHERE r2.event_id = r.event_id AND r2.deleted_at IS NULL
              AND (r2.invoice_id IS NOT NULL
                   OR EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations fr
                               WHERE fr.reservation_id = r2.id)))
       GROUP BY r.event_id
      HAVING count(DISTINCT r.subject_id) = 1   -- akce se smíšenými odběrateli neměříme
    ) x
   -- `event_id` na konci schválně: bez něj je při shodě počtu drah I času
   -- založení (série založená v jedné transakci) výběr nedeterministický.
   -- Lokálně to dnes vychází stabilně, ale to je vlastnost dat, ne dotazu.
   ORDER BY x.drah DESC, x.zalozeno DESC, x.event_id
   LIMIT 1;

  IF _admin IS NULL OR _akce IS NULL THEN
    RAISE NOTICE 'Změna firmy: tvar OK, chování NEPROMĚŘENO — chybí admin nebo nevyfakturovaná komerční akce.';
    RETURN;
  END IF;

  SELECT s.id INTO _nova
    FROM public.subjects s
   WHERE s.type = 'commercial' AND s.deleted_at IS NULL AND s.id <> _stara
     AND public.cena_je_bez_dph('commercial', 'commercial', s.default_rate)
         = public.cena_je_bez_dph('commercial', 'commercial',
             (SELECT s2.default_rate FROM public.subjects s2 WHERE s2.id = _stara))
   ORDER BY s.created_at
   LIMIT 1;

  IF _nova IS NULL THEN
    RAISE NOTICE 'Změna firmy: tvar OK, chování NEPROMĚŘENO — není druhá komerční firma se shodným daňovým významem.';
    RETURN;
  END IF;

  BEGIN
    -- ZASEKNUTÝ `db push` JE HORŠÍ NEŽ SPADLÝ. `over_neni_vyfakturovano` uvnitř
    -- funkce bere `FOR UPDATE`, takže kdyby v tu chvíli držela rezervace téhle
    -- akce cizí transakce (typicky `fakturoid_zkus_zabrat`), migrace by na ni
    -- čekala, jak dlouho by ta transakce běžela — změřeno 10 s v testu migrační
    -- brány. S timeoutem se z toho stane obyčejná chyba, kterou `WHEN OTHERS`
    -- níž převede na NEDOMĚŘENO, a push doběhne.
    PERFORM set_config('lock_timeout', '3s', true);

    SELECT COALESCE(sum(COALESCE(r.corrected_amount, r.amount)), 0),
           count(*),
           count(*) FILTER (WHERE r.approved_at IS NOT NULL)
      INTO _pred, _drah, _schvalenych_pred
      FROM public.reservations r
     WHERE r.event_id = _akce AND r.deleted_at IS NULL;

    -- NEADMIN NESMÍ.
    --
    -- Běží to pod `SET LOCAL ROLE authenticated`, ne jako `postgres` (pravidla
    -- 3 a 9). U TÉHLE konkrétní brány by na výsledku nezáleželo — `has_role` je
    -- obyčejný lookup do `user_roles` a odpoví stejně pod jakoukoli rolí —
    -- ale jako `postgres` by se míjely GRANTy, takže by kontrola neřekla nic
    -- o tom, jestli se k funkci vůbec dá zvenčí dostat. Dřívější komentář tady
    -- tvrdil, že „jako postgres by has_role prošlo přes všechno"; to NEPLATÍ.
    -- (Nález brány code review, 10. 9. 2026.)
    --
    -- `EXECUTE` schválně: `SET LOCAL ROLE` je v `DO` bloku příkaz jako každý
    -- jiný, ale roli je potřeba vrátit i při pádu, proto vlastní handler.
    IF _neadmin IS NOT NULL THEN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', _neadmin, 'role', 'authenticated')::text, true);
      _chyba := NULL;
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM public.zmen_firmu_akce(_akce, _nova);
        EXECUTE 'RESET ROLE';
      EXCEPTION WHEN OTHERS THEN
        _chyba := SQLERRM;
        EXECUTE 'RESET ROLE';
      END;
      IF _chyba IS NULL THEN
        RAISE EXCEPTION 'GUARD NEDRŽÍ: neadmin změnil odběratele akce.' USING ERRCODE = 'ZF002';
      END IF;
      IF position('jen správce haly' in _chyba) = 0 THEN
        RAISE EXCEPTION 'Neadmin sice neprošel, ale z jiného důvodu: %', _chyba USING ERRCODE = 'ZF003';
      END IF;
    END IF;

    -- ADMIN SMÍ a změna se propíše na VŠECHNY dráhy akce.
    --
    -- VOLÁNÍ MÁ VLASTNÍ HANDLER, a je to podstatné. Bez něj by pád VLASTNÍCH
    -- peněžních bran funkce („posunula by se částka", „posunul počet schválených
    -- drah") spadl do `WHEN OTHERS` níž a skončil jako NEDOMĚŘENO — tedy jako
    -- neškodná poznámka, přestože je to přesně ten stav, kvůli kterému ta
    -- kontrola existuje. Rozlišuje se proto podle textu: peněžní brána = ZF002
    -- (migrace NESMÍ projít), cokoli jiného (obsazený led, chybějící ceník,
    -- cizí zámek) = NEDOMĚŘENO. (Nález brány code review, 10. 9. 2026.)
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
    BEGIN
      _v := public.zmen_firmu_akce(_akce, _nova);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%posunula by se částka%'
         OR SQLERRM LIKE '%posunul počet schválených drah%' THEN
        RAISE EXCEPTION 'GUARD NEDRŽÍ: vlastní peněžní brána funkce spadla — %', SQLERRM
          USING ERRCODE = 'ZF002';
      END IF;
      RAISE;   -- ostatní důvody ať doputují do WHEN OTHERS níž jako NEDOMĚŘENO
    END;

    IF (_v ->> 'zmena') <> 'true' THEN
      RAISE EXCEPTION 'GUARD NEDRŽÍ: admin dostal „beze změny" (%).', _v::text USING ERRCODE = 'ZF002';
    END IF;

    IF EXISTS (SELECT 1 FROM public.reservations r
                WHERE r.event_id = _akce AND r.deleted_at IS NULL
                  AND r.subject_id IS DISTINCT FROM _nova) THEN
      RAISE EXCEPTION 'GUARD NEDRŽÍ: odběratel se nepropsal na všechny dráhy akce.' USING ERRCODE = 'ZF002';
    END IF;

    SELECT COALESCE(sum(COALESCE(r.corrected_amount, r.amount)), 0),
           count(*) FILTER (WHERE r.approved_at IS NOT NULL)
      INTO _po, _schvalenych_po
      FROM public.reservations r
     WHERE r.event_id = _akce AND r.deleted_at IS NULL;
    IF _po IS DISTINCT FROM _pred THEN
      RAISE EXCEPTION 'GUARD NEDRŽÍ: částka akce se změnou odběratele pohnula (% → %).', _pred, _po
        USING ERRCODE = 'ZF002';
    END IF;

    -- FAKTUROVATELNOST. Tohle je ta noha, která tu původně chyběla a pustila
    -- dál shozené razítko schválení: částka seděla na haléř, zatímco akce
    -- vypadla z „Kdo kolik dluží". Měřit číslo nestačí.
    IF _schvalenych_po IS DISTINCT FROM _schvalenych_pred THEN
      RAISE EXCEPTION 'GUARD NEDRŽÍ: změnou odběratele se posunul počet schválených drah (% → %) a akce by vypadla z fakturace.',
        _schvalenych_pred, _schvalenych_po USING ERRCODE = 'ZF002';
    END IF;

    RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZF001';
  EXCEPTION
    WHEN SQLSTATE 'ZF001' THEN NULL;    -- úklid: měřicí zápis se vrací zpátky
    WHEN SQLSTATE 'ZF002' THEN RAISE;   -- guard nedrží → migrace NESMÍ projít
    WHEN SQLSTATE 'ZF003' THEN _nedomereno := SQLERRM;
    WHEN OTHERS THEN
      -- Sebekontrola nesmí shodit `db push` z důvodu, který s touhle funkcí
      -- nesouvisí (chybějící ceník, cizí zámek, prázdná databáze).
      _nedomereno := SQLERRM;
  END;
  PERFORM set_config('request.jwt.claims', NULL, true);

  IF _nedomereno IS NOT NULL THEN
    RAISE NOTICE 'Změna firmy: tvar OK, chování NEDOMĚŘENO — %', _nedomereno;
  ELSE
    -- NOTICE si nárokuje jen to, co se opravdu změřilo. U jednodráhové akce
    -- neříká „na všech drahách" — to by znělo jako tvrzení o propsání na víc
    -- drah, které se na jedné dráze změřit nedá (nález migrační brány).
    IF _drah > 1 THEN
      RAISE NOTICE 'Změna firmy OK: neadmin neprojde, admin změní odběratele na všech % drahách akce, částka i schválení zůstaly.', _drah;
    ELSE
      RAISE NOTICE 'Změna firmy OK: neadmin neprojde, admin změní odběratele, částka i schválení zůstaly. POZOR: měřeno na JEDNODRÁHOVÉ akci, propsání na víc drah hlídá jen supabase/tests/zmen_firmu_akce_test.sql.';
    END IF;
  END IF;
END $kontrola$;
