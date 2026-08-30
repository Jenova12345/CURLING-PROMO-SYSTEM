# 🔴 Ticket: brigádník přepíše hodinovou sazbu na LIBOVOLNÉ směně

**Zapsáno:** 30. 8. 2026 · **Aktualizováno:** 30. 8. 2026 po 2. kole bran
**Stav:** ⏸ otevřené, NEOPRAVENO
**Závažnost:** vysoká (peníze, cizí záznamy) · **Původ:** předchází Etapě 3

> ⚠️ **Původní znění tohohle ticketu bylo MÍRNĚJŠÍ, než jaká je skutečnost.**
> Psalo se v něm „na vlastní zabrané směně". Bezpečnostní brána ve 2. kole
> ukázala, že omezení na vlastní směnu neexistuje vůbec — jde to i na CIZÍ,
> včetně směny, kterou má zabranou někdo jiný. Ověřeno:
>
> ```
> SET LOCAL ROLE authenticated;
> SET LOCAL request.jwt.claims = '{"sub":"33333333-…"}';   -- brigádník
> UPDATE public.shifts SET hourly_rate = 10000
>  WHERE id = '<směna instruktora 22222222-…>';            -- UPDATE 1
> → sazba 250,00 → 10000
> ```

> Našla to bezpečnostní brána při kontrole ceníku rolí a nezávisle to potvrdila
> code review. **Není to regrese z Etapy 3** — díra je v repu od baseline. Sem
> se zapisuje proto, že ji ceník rolí odhaluje jako podstatnější, než vypadala:
> celý smysl ceníku je, že sazba pochází z řízeného seznamu, a tohle to obchází.
>
> Vědomě se to **neopravilo v rámci ceníku ani dorovnání štábu** — je to jiná
> funkce, jiná příčina a zaslouží si vlastní změnu s vlastními branami.
> Podle CLAUDE.md (bod 7) se navíc `validate_shift_claim` nesmí přepisovat
> z paměti; musí se vygenerovat z `pg_get_functiondef` a zasáhnout jen bodově.

---

## Co se stane

Kdokoli s pracovní rolí (`part_time_staff`, `instructor`, `bar_staff`,
`manager`) přepíše `hourly_rate` až na **10 000 Kč/h** na **libovolné směně** —
vlastní, cizí, zabrané někým jiným.

Ověřeno na živé lokální databázi obojí: na vlastní `pending` směně 250 → 10 000
a na CIZÍ `claimed` směně instruktora 250 → 10 000, vždy 1 dotčený řádek.

Pak `src/pages/Shifts.tsx:284` tu podvrženou sazbu **předvyplní adminovi**
do uzavíracího formuláře:

```tsx
rate: shift.hourly_rate?.toString() || '150',
```

Takže admin při uzavírání směny vidí číslo, které si tam napsal příjemce výplaty,
a musí si všimnout sám.

## Proč to projde

Dvě zábrany, ani jedna neřeší sazbu:

1. **Na `shifts` jsou DVĚ permisivní UPDATE politiky a permisivní politiky se
   OR-ují.** Ta úzká („Staff can update shifts") řeší jen `status`
   a `claimed_by` a o `hourly_rate` neví nic:

   ```sql
   (status = 'pending'  AND claimed_by = auth.uid())
   OR (status = 'completed' AND claimed_by = auth.uid())
   OR (status = 'open'  AND claimed_by IS NULL)
   ```

   Jenže vedle ní stojí **„Staff and admins can update shifts"**, jejíž
   `WITH CHECK` je jen členství v roli, **bez jakéhokoli omezení na řádek**.
   Protože se politiky OR-ují, ta široká tu úzkou úplně přebíjí — a proto to
   projde i na cizí směně. Úzká politika vedle široké nezavírá nic; tohle je
   obecné poučení, ne jen detail téhle tabulky.

2. **Trigger `validate_shift_claim`** kontroluje jen ROZSAH (1–10 000), ne to,
   **kdo** sazbu mění. Rozsah 10 000 je přitom strop pro trenéra, ne pro
   brigádníka za 150.

## Kde je oprava

Do `validate_shift_claim`, kde je k dispozici `OLD` — tedy tam, kde jde poznat
*změnu*, ne jen hodnotu:

```sql
IF NEW.hourly_rate IS DISTINCT FROM OLD.hourly_rate
   AND NOT has_role(auth.uid(), 'admin') THEN
  RAISE EXCEPTION 'Hodinovou sazbu směny mění jen správce haly.';
END IF;
```

**RLS to samo nezavře** — a to ani po zúžení té úzké politiky, dokud vedle ní
stojí ta široká. Sloupcový `GRANT UPDATE` bez `hourly_rate` by zabral, ale jen
pro `authenticated`; `service_role` granty obchází. Trigger platí na obě cesty,
stejně jako u `sazby_roli`. Nejčistší je oprava na všech třech místech naráz:
zúžit širokou politiku, odebrat sloupcový grant a přidat guard do triggeru.

**Co už na tom Etapa 3 zlepšila** (ani jedno díru nezavírá):
- `shifts_hourly_rate_rozsah` (migrace 20260827090000) zastropuje škodu na
  10 000 Kč/h — dřív šlo zapsat 99 999 999.
- `trg_shifts_audit` (migrace 20260827100000) to poprvé zapíše do `audit_log`
  se správným `changed_by`, takže je to dohledatelné.

### Než se to nasadí, ověř data

Jestli už někdo sazbu přepsal, je to vidět v auditní stopě — tu `shifts` dostaly
až migrací `20260827100000_dorovnani_stabu.sql`, takže **starší přepisy v ní
nejsou**. Co za tu dobu vzniklo:

```sql
SELECT record_id, changed_by, changed_at,
       old_data ->> 'hourly_rate' AS puvodni,
       new_data ->> 'hourly_rate' AS nova
  FROM public.audit_log
 WHERE table_name = 'shifts' AND action = 'update'
   AND old_data ->> 'hourly_rate' IS DISTINCT FROM new_data ->> 'hourly_rate'
 ORDER BY changed_at DESC;
```

Pro dobu před ní zbývá jen porovnat sazby proti ceníku:

```sql
SELECT s.id, s.required_role, s.hourly_rate, z.sazba AS cenikova, s.claimed_by
  FROM public.shifts s
  LEFT JOIN public.sazby_roli z ON z.role = s.required_role
 WHERE s.hourly_rate IS DISTINCT FROM z.sazba
 ORDER BY s.hourly_rate DESC;
```

Rozdíl **nemusí** znamenat podvod — ruční přepsání sazby je legitimní a ceník se
mohl mezitím změnit (sazby jsou snapshot). Je to podklad ke kontrole, ne důkaz.

## Na co si dát pozor při opravě

- **Test musí běžet pod `SET LOCAL ROLE authenticated`.** Jako `postgres` projde
  všechno; přesně tahle past už v repu dvakrát propustila blokér (CLAUDE.md, bod 8).
- **Nesmí to zavřít legitimní cestu.** `useShifts.ts:244`
  (`completeShiftsIndividually`) dopočítává sazbu zpátky z ručně zadané částky
  (`manualAmount / hoursWorked`) — to dělá **admin** při uzavírání směny a musí
  to fungovat dál. Test na to patří do téhož kola.
- Souvisí: `src/pages/Shifts.tsx:284` může po opravě přestat potřebovat fallback
  `|| '150'` — `shifts.hourly_rate` je od migrace `20260827090000` `NOT NULL`.
