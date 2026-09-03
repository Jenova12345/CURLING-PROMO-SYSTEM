# 🟡 Ticket: „zrušená akce" má v databázi dvě různé definice

**Zapsáno:** 3. 9. 2026 · **Stav:** ⏸ otevřené, NEOPRAVENO
**Závažnost:** nízká dnes, střední po první změně enumu · **Původ:** předchází opravě z 3. 9. 2026

> Našla to brána pro kontrolu migrací při review commitu `0faac1b`.
> **Není to regrese** — nesoulad tu je od migrace `20260902120000`.
> Sem se zapisuje proto, že invariant „na zrušené akci nežije žádná směna"
> (migrace `20260903120000`) na téhle definici stojí, takže rozdíl, který je
> dnes neškodný, se z něj stane dírou ve chvíli, kdy někdo sáhne na enum.

---

## O co jde

Dvě místa se ptají na totéž a každé jinak:

| kde | co považuje za ŽIVOU rezervaci |
|---|---|
| `akce_je_zrusena()` (nová, 3. 9. 2026) | `status <> 'cancelled' AND deleted_at IS NULL` |
| `cancel_open_shifts_on_reservation_cancel()` (starší) | `status = 'confirmed' AND deleted_at IS NULL` |

Komentář v migraci `20260903120000` tvrdí, že definice je „shodná se stávajícím
triggerem". **Doslova to neplatí.**

## Proč to dnes nevadí

`reservation_status` má na produkci právě dvě hodnoty — ověřeno 3. 9. 2026:

```
confirmed, cancelled
```

Pro dvouhodnotový enum jsou obě podmínky rovnocenné, takže se rozdíl nikde
neprojeví.

## Kdy to začne vadit

Jakmile přibude třetí hodnota. Nasnadě je „čeká na schválení" — schvalovací
cesta už v systému existuje (`approve_reservation`), jen zatím nemá vlastní
stav rezervace. V ten okamžik:

1. Akce má rezervace `confirmed` + `pending`.
2. Zruší se ta `confirmed`. Starší trigger se ptá jen na `confirmed`, žádnou
   další nenajde → **zavře směny akce**.
3. `akce_je_zrusena()` ale `pending` počítá jako živou → vrátí `false`.
4. Nová brána se tedy na tu akci nevztahuje a `cancelled → open` nehlídá
   ve `validate_shift_claim` žádná větev. Kterýkoli člen štábu si takovou
   zavřenou směnu **znovu otevře** — přesně to, čemu má invariant bránit.

Bug se tím vrátí, ale jen pro akce s rezervací v tom novém stavu, takže se to
bude hledat hůř než původně.

## Co s tím

Rozhodnout, která definice je ta správná, a mít jen jednu. Můj názor:
`akce_je_zrusena()` je věcně správnější — rezervace, která není zrušená, akci
drží při životě, i když ještě čeká na schválení. Pak je přeurčený ten starší
trigger: dnes zavírá směny i tehdy, když akci drží nepotvrzená rezervace.

Nezávisle na tom stojí za zvážení dohlídat `cancelled → open` obecně (dnes
ten přechod na živé akci nehlídá nic — je to starší mezera, ne součást
tohohle nesouladu).

## Na co nezapomenout při opravě

- `validate_shift_claim` se **nesmí přepisovat z paměti** — vygenerovat
  z `pg_get_functiondef` a zasáhnout bodově (CLAUDE.md, bod 7).
- Mutační test musí pokrýt scénář s třetím stavem enumu, ne jen dnešní dva —
  jinak projde zeleně, protože dnes jsou definice rovnocenné.
- Test na `cancelled → open` patří do `supabase/tests/zrusena_akce_nenabizi_test.sql`
  vedle stávajících scénářů 1–12.
