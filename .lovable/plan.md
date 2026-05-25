## Approval workflow + revoke + nové notifikace

Změna z modelu "1 worker = update slot" na "N workerů aplikuje na 1 slot". Stávající `shifts` zůstává jako pre-vytvořený slot (status `open`/`claimed`/`completed`), nová tabulka `shift_applications` drží jednotlivé přihlášky.

---

### 1. Databáze (SQL migrace)

Nová tabulka:

```sql
CREATE TABLE public.shift_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id uuid NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shift_id, user_id)
);

ALTER TABLE public.shift_applications ENABLE ROW LEVEL SECURITY;

-- Worker vidí svoje + admin vše + worker vidí aplikace na sloty kde sám aplikoval (volitelné)
CREATE POLICY "view own or admin" ON public.shift_applications
  FOR SELECT USING (user_id = auth.uid() OR has_role(auth.uid(),'admin'));

CREATE POLICY "user insert own" ON public.shift_applications
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "user cancel own / admin update" ON public.shift_applications
  FOR UPDATE USING (user_id = auth.uid() OR has_role(auth.uid(),'admin'));

CREATE POLICY "admin delete" ON public.shift_applications
  FOR DELETE USING (has_role(auth.uid(),'admin'));

CREATE TRIGGER trg_updated_at_apps BEFORE UPDATE ON public.shift_applications
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
```

Validační trigger zabrání duplicitní pending aplikaci na sloty stejného eventu pro téhož usera (zachová stávající pravidlo "max 1 směna per event").

---

### 2. Hook: `src/hooks/useShiftApplications.ts` (nový)

```text
useShiftApplications()
 ├── applications        – všechny (admin) / moje (staff)
 ├── myApplications      – moje pending/approved/rejected
 ├── applicationsByShift – Record<shiftId, Application[]>
 ├── applyToShift(shiftId)         INSERT {user_id, shift_id, status:'pending'}
 ├── cancelMyApplication(appId)    UPDATE status='cancelled' (vlastní)
 ├── approveApplication(appId)     – admin: UPDATE app → 'approved'
 │                                  + UPDATE shift → status='claimed', claimed_by=app.user_id
 │                                  + UPDATE ostatní pending apps stejného shiftu → 'rejected'
 ├── rejectApplication(appId)      UPDATE app → 'rejected'
 └── revokeApproval(appId)         – admin: UPDATE app → 'cancelled'
                                    + UPDATE shift → status='open', claimed_by=null, claimed_at=null
```

Všechno přes react-query s `invalidateQueries(['shift_applications'])` + `['shifts']`.

---

### 3. `src/hooks/useShifts.ts` – úpravy

- Ponechat existující `requestShift`/`cancelRequest` ale **přesměrovat** na `useShiftApplications.applyToShift` (legacy alias).
- `openShifts` zůstává (sloty kde `status='open'`).
- Pro staff filter: slot zůstane viditelný **i když na něj uživatel už podal žádost** — místo skrytí přidat příznak `hasApplied`/`applicationStatus` z join s `shift_applications`.
- `myEventIds` přestat blokovat zobrazení slotu jen kvůli pending aplikaci (nyní víc apps možných).

---

### 4. `src/pages/Shifts.tsx` – frontend

**Staff – Volné směny (cca ř. 567–633):**
- Tlačítko `Přihlásit se` → **`Mám zájem`** (volá `applyToShift`).
- Pokud user už má pending application na daný shift: tlačítko nahradit badge `Čeká na schválení` + button `Zrušit zájem`.
- Pokud `rejected`: badge `Zamítnuto` (read-only).
- Slot zůstává viditelný pro ostatní dokud nemá `status='claimed'`.

**Staff – Moje směny:**
- Sekce "Čeká na potvrzení" napojit na `myApplications` (status='pending') místo `myPendingShifts`.
- "Potvrzené" napojit na shifty kde `claimed_by = me` (beze změny logiky).

**Admin – Brigádníci k potvrzení:**
- Nová sekce "Zájemci o směny": grupuj `applications` podle `shift_id`/eventu.
- U každého zájemce 2 tlačítka: **Schválit** (`approveApplication`) + **Zamítnout** (`rejectApplication`).
- Zobrazovat jméno, roli, čas podání žádosti.

**Admin – Nadcházející / přiřazené směny (REVOKE):**
- Pro každou `claimed` směnu přidat tlačítko **Odebrat** (`revokeApproval` na odpovídající approved application).
- Po revoke se slot vrátí na `open` a viditelný v "Směny kde chybí brigádníci".

---

### 5. Dashboard banner – nové směny

Nový komponent `src/components/NewShiftsAlert.tsx`:

```text
Logika:
1. Z useShifts vezmi openShifts pro budoucí events (event.start_time > now()).
2. Filtruj jen takové, kde required_role ∈ user.roles (nebo bez role).
3. Spočítej hash = JSON.stringify(sorted(shift.id)).
4. localStorage key: "newShiftsSeenHash:<userId>"
5. Pokud hash !== uložený hash → render Alert (shadcn) s message:
   "🔔 Jsou vypsány nové směny! Podívejte se do nabídky a přihlaste se."
   + button "Zobrazit" → /shifts
   + dismiss X → uloží aktuální hash do localStorage.
6. Pokud hash === uložený → nic.
```

Render v `src/pages/Dashboard.tsx` nad Stats Grid, jen pro `isStaff` (kromě admin-only).

---

### 6. Typy

`src/integrations/supabase/types.ts` se regeneruje po migraci; mezitím použít `as any` u shift_applications volání (stejně jako u `required_role`).

---

### Soubory

| Soubor | Akce |
|---|---|
| SQL migrace `shift_applications` + RLS | nová |
| `src/hooks/useShiftApplications.ts` | nový |
| `src/hooks/useShifts.ts` | filtr openShifts, expose applicationStatus |
| `src/pages/Shifts.tsx` | staff tlačítko "Mám zájem", admin Schválit/Zamítnout/Odebrat |
| `src/components/NewShiftsAlert.tsx` | nový – dashboard banner |
| `src/pages/Dashboard.tsx` | mount NewShiftsAlert |

### Otevřené body / poznámky

- Při schválení aplikace na slot, který mezitím někdo jiný obsadil (`shift.status != 'open'`), vrátit chybu a invalidovat queries.
- Po `approveApplication` automaticky ostatní pending na témž slotu → `rejected` (aby workeři viděli výsledek).
- Revoke neresetuje historii applications, jen vrátí slot do `open` a danou aplikaci na `cancelled`; ostatní rejected zůstanou jako audit trail.
