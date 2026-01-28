

## Odstranění role "Brigádník" (part_time_staff) z UI

### Přehled

Role `part_time_staff` byla nahrazena rolí `instructor` a všichni uživatelé byli migrováni. Nyní je potřeba odstranit tuto roli z UI, aby nedocházelo ke zmatení administrátorů.

### Strategie

| Soubor | Přístup |
|--------|---------|
| `Members.tsx` | Oddělit "zobrazitelné" role od "všech" rolí - nezobrazovat `part_time_staff` v checkboxech |
| `navigation.ts` | Ponechat v `NAV_ITEMS` pro kompatibilitu, ale odstranit z `ROLE_LABELS` |
| `AuthContext.tsx` | Ponechat beze změny - systém musí stále rozpoznávat existující záznamy |
| `validation.ts` | Ponechat beze změny - validace musí akceptovat existující data |

---

### Změny v souborech

#### 1. `src/pages/Members.tsx`

**Vytvořit oddělené objekty pro UI vs. systém:**

```typescript
// Roles visible in admin UI (for assignment)
const visibleRoleLabels: Record<string, string> = {
  admin: 'Správce',
  trainer: 'Trenér',
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  pro_player: 'Profi hráč',
  hobby_player: 'Hobby hráč',
};

// All roles (including legacy) for display in badges
const allRoleLabels: Record<string, string> = {
  ...visibleRoleLabels,
  part_time_staff: 'Brigádník', // Legacy - only for displaying existing badges
};

// Colors for all roles (including legacy)
const roleColors: Record<string, string> = {
  admin: 'bg-red-500',
  trainer: 'bg-purple-500',
  part_time_staff: 'bg-blue-500', // Keep for badge display
  instructor: 'bg-teal-500',
  bar_staff: 'bg-amber-500',
  manager: 'bg-indigo-500',
  pro_player: 'bg-green-500',
  hobby_player: 'bg-gray-500',
};
```

**Stats grid:** Použít `visibleRoleLabels` (nezobrazovat Brigádníka ve statistikách)

**Filter dropdown:** Použít `visibleRoleLabels` (nezobrazovat Brigádníka ve filtru)

**Role edit dialog (checkboxy):** Použít `visibleRoleLabels` (admin nemůže přiřadit Brigádníka)

**Member badges display:** Použít `allRoleLabels` (pokud někdo stále má tuto roli, zobrazí se správně)

---

#### 2. `src/config/navigation.ts`

**Odstranit z `ROLE_LABELS`:**

```typescript
export const ROLE_LABELS: Record<string, string> = {
  admin: 'Správce',
  trainer: 'Trenér',
  // part_time_staff removed - no longer used
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  pro_player: 'Profi hráč',
  hobby_player: 'Hobby hráč',
};
```

**`NAV_ITEMS`:** Ponechat `part_time_staff` v permissions - kdyby existovali nějací zbylí uživatelé, stále uvidí navigaci. Systém funguje přes `.some()` logiku, takže to nezpůsobí problémy.

---

### Co zůstane beze změny

| Soubor | Důvod |
|--------|-------|
| `AuthContext.tsx` | Musí rozpoznávat `part_time_staff` v `AppRole` type a `isStaff` check |
| `validation.ts` | `appRoleSchema` musí validovat existující data v DB |
| `useShifts.ts` | Query pro staff stále zahrnuje `part_time_staff` pro kompatibilitu |

---

### Výsledek

Po implementaci:
- Admin **neuvidí** "Brigádník" v:
  - Statistikách rolí
  - Filtru podle rolí  
  - Dialogu pro přiřazení rolí
- Admin **uvidí** "Brigádník" badge u uživatelů, kteří tuto roli stále mají (edge case)
- Navigace a oprávnění zůstanou funkční pro případ zbylých `part_time_staff` uživatelů

