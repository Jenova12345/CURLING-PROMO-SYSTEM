# 🔴 Ticket HIGH: dvě cesty, kterými se dá obejít zámek fakturace

**Zapsáno:** 10. 9. 2026 · **Stav:** ⏸ otevřené, NEOPRAVENO
**Závažnost:** 🔴 **HIGH — vyřešit PŘED ostrým provozem Fakturoidu.**
Rozhodnutí zákazníka 10. 9. 2026: drží se jako samostatný ticket, do úkolu B
(změna odběratele) se nemíchá.

Dvě adminské/servisní cesty, jak obejít zámek fakturace. Cesta A navíc umí
**odstranit vystavenou fakturu z kontrolního součtu, aniž by se zvedl rozdíl** —
viz kapitolu „Proč to přesto opravit". To je přesně to, co podle CLAUDE.md
u fakturace selhat nesmí.
**Původ:** obojí pre-existující, **není to regrese** — nezakládá to migrace
`20260910180000_zmen_firmu_akce.sql`, jen se to při jejím review našlo.

> Obojí našla bezpečnostní brána při kontrole změny odběratele — cestu A ve
> druhém kole, cestu B ve třetím. Ověřeno měřením, že se obojí týká **všech tří**
> RPC, které sdílejí `over_neni_vyfakturovano`, ne jen té nové.

---

## Cesta A — soft-smazání vyfakturované dráhy

`over_neni_vyfakturovano(_event_id, _co)` — brána, která u akce s vystaveným
dokladem zakáže přecenění, změnu typu i změnu odběratele — počítá jen rezervace
s `deleted_at IS NULL`:

```sql
SELECT count(*) FROM public.reservations r
 WHERE r.event_id = _event_id
   AND r.deleted_at IS NULL          -- ← tady
   AND (r.invoice_id IS NOT NULL OR EXISTS (… fakturoid_invoice_reservations …));
```

Admin přitom **smí vyfakturovanou rezervaci soft-smazat**: v
`guard_reservation_rep_changes` odchází adminská větev (`RETURN NEW`) dřív, než
se dojde k whitelistu sloupců. Zámek fakturace stojí sice nad adminskou
výjimkou, ale hlídá jen změnu `invoice_id`, ne `deleted_at`.

Dohromady: **soft-smazáním dokladové dráhy zámek zmizí i pro dráhy, které
zůstaly.**

## Změřeno (lokální seed, 10. 9. 2026)

Vícedráhová komerční akce, doklad z Fakturoidu na dráhu 1:

| krok | výsledek |
|---|---|
| `zmen_firmu_akce` s dokladem | ✅ zablokováno („1 z jejích rezervací je na vystaveném dokladu") |
| admin: `UPDATE reservations SET deleted_at = now()` na dokladové dráze | projde |
| `zmen_firmu_akce` znovu | ❌ **PROJDE** |
| stav po tom | dráha na dokladu drží firmu A, živá dráha firmu B |

Tedy jedna akce, dva odběratelé, a doklad zní na jiného než rozvrh.

**Není to specifické pro změnu odběratele** — týž postup projde i u sesterských
RPC, které tutéž bránu sdílejí (změřeno v témž běhu):

| RPC | s dokladem | po soft-smazání dokladové dráhy |
|---|---|---|
| `uprav_sazbu_akce` | zablokováno | **projde** |
| `zmen_typ_akce` | zablokováno | **projde** |
| `zmen_firmu_akce` | zablokováno | **projde** |

## Proč to není blokér

- Vyžaduje **dva vědomé adminské kroky**, z nichž první (smazat rezervaci, na
  kterou už je vystavená faktura) nedává provozně smysl sám o sobě.
- Možnost soft-smazat vyfakturovanou rezervaci je **starší než všechny tři RPC**.
- U jednodráhové akce se to zastaví samo — po smazání zbývá nula živých
  rezervací a funkce skončí na „Akce nemá žádnou živou rezervaci".

## Proč to přesto opravit — a proč je to horší, než to vypadá

Rozejde to kontrolní součet Etapy 2: doklad je vystavený na firmu A, ale
rozvrh, ze kterého se skládají podklady, ukazuje firmu B. A protože je to
adminská cesta, nezůstane po ní žádná hláška.

**Není to ale „tichý rozdíl" — kontrolní součet ten rozdíl vůbec neuvidí.**
Změřeno 10. 9. 2026 na lokálním seedu, komerční akce na dvou drahách, ostrý
doklad z Fakturoidu (`provider_invoice_id` i `vystaveno_at` vyplněné) na dráhu 1:

| krok | `fakturoid` | `fakturoid_rozdil` |
|---|---|---|
| doklad na 10 000 Kč vystavený | 10 000 | 0 |
| admin dokladovou dráhu soft-smaže | **0** | **0** |

Vystavená faktura na 10 000 Kč **zmizí ze sestavy, a `fakturoid_rozdil` zůstane
nula**. Když se pak ještě změní odběratel, zmizí ze sestavy i celá původní firma.
K tomu, aby doklad vypadl, přitom stačí **samotné soft-smazání** — žádná z těch
tří RPC k tomu není potřeba.

Je to tím, že fakturoidí větev `billing_reconcile` staví obě strany rovnice na
`rez.subject_id` a odběratele z hlavičky (`fi.subject_id`) **nikdy nečte**
(ověřeno: nula výskytů v těle funkce). Interní větev to dělá naopak — grupuje
podle `i.subject_id` a v komentáři přesně tenhle scénář popisuje („Doklad ví,
komu je vystavený — tak ať rozhoduje on."). Fakturoidí větev tu ochranu nemá.

Praktický dopad: u sesterských RPC `uprav_sazbu_akce` a `zmen_typ_akce` se rozjezd
aspoň projeví na `fakturoid_rozdil`, protože hýbou částkou. `zmen_firmu_akce`
částkou vědomě nehýbe — je to tedy jediná z těch tří, u které kontrolní součet
mlčí úplně.

## Cesta B — okno po uvolněném claimu Fakturoidu

⚠ **Znění se ještě upřesňuje** — bezpečnostní brána opravila moji první formulaci
a čekám na její doplnění. Co je změřené a jisté:

`fakturoid_uvolni_zabrani()` po neúspěšném volání API smaže vazební řádky
v `fakturoid_invoice_reservations` (`20260824120000_fakturoid_vazba.sql:377`)
a na hlavičce nastaví `uvolneno_at`. Hlavička zůstane s `event_id` a `rezervace`,
ale **bez** `cislo`, `vystaveno_at` i `provider_invoice_id` — uvolnit jde totiž
jen claim, který `provider_invoice_id` nemá (WHERE ve funkci + CHECK
`fakturoid_uvolneni_jen_bez_dokladu`), a číslo s datem vystavení se zapisují
výhradně současně s ním.

`over_neni_vyfakturovano` se ptá **jen** vazební tabulky a `reservations.invoice_id`,
nikdy `fakturoid_invoices.event_id` ani `.rezervace`. Po uvolnění tedy o té akci
neví nic:

```
SELECT public.fakturoid_uvolni_zabrani('sis2-…', '5xx pri POST');  -- → t, vazeb 0
SELECT public.zmen_firmu_akce(…);                                   -- → PROJDE
```

Nebezpečí není v tom, že by u nás zůstal doklad — ten u nás není. Je v tom, že se
uvolňuje **právě po 5xx**, tedy ve chvíli, kdy Fakturoid doklad mohl založit
a jen nám o tom nestihl říct. Do doby, než claim někdo doreconciluje, u nás akce
vypadá jako nedotčená a odběratel se na ní dá přepsat.

Do ticketu to zapisuju jako otevřené, protože **návrh řešení „ptát se i hlavičky"
může mířit vedle**: hlavička uvolněného claimu vypadá stejně jako pokus, který se
prostě nepovedl odeslat, a blokovat kvůli němu změny by bylo příliš široké.
Čeká na doměření.

## Kudy NE

**Nesahat rovnou do `over_neni_vyfakturovano`.** Sdílejí ji tři RPC a jedna
z nich (`zmen_typ_akce`) na jejím dnešním chování stojí i v jiných větvích;
rozšíření filtru na `deleted_at IS NOT NULL` by mohlo zablokovat legitimní
opravy u akcí, kde se dráha smazala dávno před fakturací.

## Návrh řešení (k rozhodnutí PM)

**Cesta A** — zavřít u zdroje: v `guard_reservation_rep_changes` zakázat změnu
`deleted_at` na rezervaci, která je na vystaveném dokladu — i adminovi, stejně
jako se dnes zakazuje odpojení `invoice_id`. Uvolnit ji smí jen storno nebo
dobropis. Je to užší i bezpečnější než sahat do sdílené brány: řeší to na jednom
místě pro všechny tři RPC i pro přímý zápis.

**Cesta B** — ⏸ návrh se upřesňuje, viz poznámka v kapitole výš. Kandidáti:
rozšířit `over_neni_vyfakturovano` o hlavičku, nebo blokovat jen po dobu, než je
uvolněný claim doreconcilovaný. To druhé je užší a nejspíš správnější.

Ke každé variantě **mutační test**: u A smazat vyfakturovanou dráhu a ověřit, že
změna neprojde; u B uvolnit claim a ověřit totéž.

## Poznámka na okraj (není součást tohohle ticketu)

Brána migrací při témže kole změřila, že v sebekontrole migrace
`20260910180000_zmen_firmu_akce.sql` se **selhání admin-only brány degraduje na
ZF003 „NEDOMĚŘENO"**, ne na červenou: neadmina zastaví až
`guard_reservation_rep_changes` („Nemáte právo měnit tuto rezervaci"), což
sebekontrola vyhodnotí jako nedoměřeno a migraci pustí. Dveře drží druhá vrstva
a `supabase/tests/zmen_firmu_akce_test.sql` tu hlášku testuje explicitně
u zástupce i člena klubu, takže to není nález. Utažení (ZF003 → `RAISE`) by šlo
proti záměru „nedoměřená kontrola je lepší než zaseknutý push", takže je to
rozhodnutí pro PM, ne oprava.
