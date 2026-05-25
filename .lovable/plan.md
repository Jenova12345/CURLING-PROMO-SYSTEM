## Cíl

Sjednotit logiku přihlašování na směny v Kalendáři s tou v Směnách a povolit opětovné přihlášení po zamítnutí nebo odebrání.

---

## 1) `src/hooks/useShiftApplications.ts` — upsert v `applyToShift`

Současná verze dělá `INSERT`, což padá na `UNIQUE (shift_id, user_id)`, pokud uživatel měl dřív přihlášku (i `rejected` / `cancelled`).

Změna:
- Před vložením zkontrolovat existující záznam pro `(shift_id, user_id)`.
  - Pokud existuje → `UPDATE` status na `pending` (a `updated_at` se přepíše triggerem).
  - Pokud neexistuje → `INSERT` jako dnes.
- Alternativně použít `.upsert({...}, { onConflict: 'shift_id,user_id' })` s `status: 'pending'`. Zvolím tuto variantu — jeden round-trip.
- Zachovat hlášení chyb, ale odstranit speciální handling `23505`.

## 2) `src/pages/IceCalendar.tsx` — napojit nový hook

Nahradit volání `requestShift` z `useShifts` za `applyToShift` z `useShiftApplications` a zrcadlit UI ze `Shifts.tsx`.

Změny:
- Importovat `useShiftApplications`, získat `myApplications`, `applyToShift`, `cancelMyApplication`, `isApplying`, `isCancelling`.
- Odstranit `requestShift, isRequesting` z destrukce `useShifts`.
- `handleRequestShift(shiftId)` → volá `applyToShift(shiftId)`, toast „Přihláška odeslána! Čeká na schválení adminem."
- Přidat `handleCancelApplication(appId)` → volá `cancelMyApplication`.
- `myEventIds` ponechat tak, jak je (vychází ze `shifts.claimed_by`, ne z aplikací) — tím zůstává směna viditelná i po `rejected`/`cancelled`.
- `canRequestShift(shift)` ponechat (true pro grouped, jinak `status === 'open' && !myEventIds.has(event_id)`).
- V buňce směny (řádky 989–1034) místo jediného tlačítka „Přihlásit" vykreslit stejný switch jako v `Shifts.tsx`:
  - Najít `myApp = myApplications.find(a => a.shift_id === shiftIdToRequest && (a.status === 'pending' || a.status === 'approved'))`.
  - Pokud `pending` → badge „Čeká na schválení" + tlačítko „Zrušit zájem" (volá `handleCancelApplication`).
  - Pokud `approved` → badge „Schváleno" (read-only).
  - Jinak (žádná aplikace, `rejected`, `cancelled`) → tlačítko „Mám zájem" (disabled při `isApplying`).
- Pro grouped entry (více volných slotů na akci) použít první `_availableShiftIds[0]` jako cíl aplikace (zachovat dnešní chování), `myApp` u grouped záznamu se nehledá.

## 3) `src/pages/Shifts.tsx` — povolit re-apply

Logika dnes už zobrazuje „Mám zájem", když `myApp` (pending/approved) neexistuje, takže pro `rejected`/`cancelled` aplikace se tlačítko ukáže automaticky. Po opravě upsertu v bodě 1 bude re-apply fungovat bez dalších změn.

Drobná úprava jen pro jistotu:
- V sekci „Mám zájem" tlačítko jasně vystihne re-apply — text necháme „Mám zájem" (jednotné), žádné rozlišení.

---

## Co se NEdotýká

- Databáze, RLS, triggery — beze změny.
- `useShifts.ts` — beze změny (`requestShift` zůstane jako legacy alias pro zpětnou kompatibilitu, jen se z Kalendáře přestane volat).
- Admin sekce (zájemci, odebrat) — beze změny.

---

## Akceptační kritéria

- Z detailu dne v Kalendáři vidí brigádník u volné směny tlačítko „Mám zájem". Po kliku se zobrazí „Čeká na schválení" + „Zrušit zájem", směna zůstává viditelná dalším zájemcům.
- Když admin schválí jiného brigádníka (a tím tohoto zamítne), uvidí dotyčný u směny opět „Mám zájem" jakmile admin schváleného odebere a směna se vrátí do `open`.
- `applyToShift` nepadá na unikátním klíči ani při opakovaných pokusech.
