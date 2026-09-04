# 🟠 Ticket: kontrola v `20260903120000` shodí nasazení na čisté DB / demu

**Zapsáno:** 4. 9. 2026 · **Stav:** ⏸ otevřené, NEOPRAVENO
**Závažnost:** střední (blokuje nasazení na demo, produkce se netýká)
**Původ:** migrace `20260903120000` — už NASAZENÁ, editovat ji nelze

> Našla to brána pro kontrolu migrací při review `20260903180000` a doměřila
> to na replice produkce. Na produkci se to **nestalo a stát nemůže** (migrace
> tam prošla), ale kdokoli bude stavět demo nebo čistou databázi od nuly,
> narazí.

---

## Co se stane

Při běhu řetězu od nuly `20260903120000` spadne hláškou:

```
Na zrušených akcích pořád visí 1 živých přihlášek.
```

a `20260903160000` ani `20260903180000` se už nespustí.

## Proč

Uvnitř `20260903120000` se rozcházejí dvě věty o `completed`:

| část migrace | jak zachází s odpracovanou směnou |
|---|---|
| datová náprava | `WHERE status IN ('open','pending','claimed')` — na `completed` **nesáhne**, správně |
| závěrečná kontrola | počítá `pending`/`approved` přihlášky na zrušených akcích **bez ohledu na stav směny** |

Takže `approved` přihláška u **odpracované** směny na zrušené akci projde
nápravou nedotčená (jak má) a vzápětí tutéž migraci shodí kontrola, která ji
započítá. Náprava a kontrola měří každá něco jiného.

## Kdy takový řádek vznikne

Přihláška na už zrušenou směnu byla možná až do `20260903120000` — tu díru
zavírá právě ona. Na demu nebo v seed datech, kde takový řádek leží, se pak
migrace nedá aplikovat.

## Co s tím

`20260903120000` je nasazená, takže se **needituje** (dopředné migrace,
CLAUDE.md bod 6). Možnosti:

1. **Dopředná migrace, která stav dorovná dřív** — ale ta se spustí až po
   `120000`, takže při běhu od nuly nepomůže. Řeší jen existující DB.
2. **Ruční úklid před nasazením na demo** (dnes reálná cesta):
   ```sql
   -- kolik jich visí
   SELECT count(*) FROM shift_applications a JOIN shifts s ON s.id = a.shift_id
    WHERE a.status IN ('pending','approved') AND akce_je_zrusena(s.event_id);
   -- dorovnat (stejný predikát jako 20260903180000, tedy bez completed)
   UPDATE shift_applications a SET status='cancelled', updated_at=now()
     FROM shifts s
    WHERE s.id = a.shift_id AND a.status IN ('pending','approved')
      AND s.status <> 'completed' AND akce_je_zrusena(s.event_id);
   ```
   Pozor: `akce_je_zrusena` vzniká až v `120000`, takže před jejím během se
   musí predikát rozepsat ručně.
3. **Do seed dat takový řádek nedávat.**

Rozhodnutí, kterou cestou jít, je na PM — týká se to postupu stavby dema,
ne produkčního kódu.

## Na co nezapomenout

- Stejnou nesrovnalost (náprava vs. kontrola měří jiný predikát) hlídat
  i u dalších migrací — je to táž třída chyby jako „kontrola, která projde
  i bez opravy".
- `20260903180000` už svou datovou část s `completed` sjednocenou má; tenhle
  ticket je jen o tom, že `120000` se opravit nedá.
