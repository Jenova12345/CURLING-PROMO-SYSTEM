## Cíl

Při úpravě události (Admin změní Konfiguraci týmu) synchronizovat řádky v tabulce `shifts` tak, aby jejich počet odpovídal nově požadovanému počtu brigádníků. Bez zásahu do DB triggerů — vše ve frontend logice po `updateEvent`.

## Důležitá poznámka k datovému modelu

Tabulka `shifts` **nemá sloupec `role`** — sloty jsou bez rozlišení role (viz schéma: `id, event_id, status, claimed_by, ...`). Per‑role konfigurace žije pouze v `events.role_reqs` (JSONB) a slouží UI. Synchronizace proto poběží podle **celkového počtu** slotů na event (`getTotalStaff()` = součet `role_reqs`, tj. hodnota ukládaná do `events.required_staff`).

Pokud později přibude `shifts.role`, sync se rozšíří na párování per role — teď to není možné bez migrace, kterou jsi v zadání vyloučil.

## 1) `src/hooks/useEvents.ts` — sync slotů v `updateEvent`

Po úspěšném `UPDATE events`:

1. Načíst stávající sloty:
   ```ts
   const { data: existing } = await supabase
     .from('shifts')
     .select('id, status')
     .eq('event_id', id);
   ```
2. Spočítat `desired = updates.required_staff ?? data.required_staff ?? 0` (pro `commercial` / `recruitment`; pro ostatní typy přeskočit sync).
3. `currentCount = existing.length`, `openIds = existing.filter(s => s.status === 'open').map(s => s.id)`.
4. **Přidat** (`desired > currentCount`):
   ```ts
   const toInsert = Array.from({ length: desired - currentCount }, () => ({
     event_id: id, status: 'open' as const,
   }));
   await supabase.from('shifts').insert(toInsert);
   ```
5. **Odebrat** (`desired < currentCount`):
   - `removeCount = Math.min(currentCount - desired, openIds.length)`
   - `await supabase.from('shifts').delete().in('id', openIds.slice(0, removeCount))`
   - Pokud `removeCount < (currentCount - desired)` (tj. víc obsazených než nová kapacita), tiše ponechat — admin musí nejprve obsazené ručně uvolnit. (Volitelně vrátit warning přes toast v UI, ale to je mimo zadání.)
6. Invalidace cache:
   ```ts
   queryClient.invalidateQueries({ queryKey: ['shifts'] });
   queryClient.invalidateQueries({ queryKey: ['events'] });
   ```
   (`events` invalidace už tam je, doplnit `shifts`.)

Celý sync zabalit do try/catch a chybu jen logovat — update události samotný nesmí spadnout kvůli sync chybě (akce už byla uložená).

## 2) `src/pages/IceCalendar.tsx`

Bez změn — `handleEditEvent` posílá nové `required_staff` přes `updateEvent`, hook se postará o zbytek.

## Co se NEdotýká

- DB migrace, triggery, RLS — beze změny.
- `handle_new_commercial_event` trigger (vytvoření slotů při INSERTu) — beze změny.
- `Shifts.tsx`, `useShifts.ts`, `useShiftApplications.ts` — beze změny.

## Akceptační kritéria

- Zvýšení počtu brigádníků v editaci → v `shifts` přibydou nové `open` řádky, v Kalendáři i Směnách se okamžitě objeví.
- Snížení počtu → smažou se jen `open` sloty (claimed/completed zůstanou nedotčené).
- Při totálním updatu nedojde k duplicitnímu volání invalidate (queryClient.invalidateQueries je idempotentní).
- Pokud admin sníží kapacitu pod počet již obsazených, systém smaže všechny volné `open` sloty, obsazené ponechá.
