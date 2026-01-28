

## Oprava zobrazení směn a logiky přihlášení

### Přehled

Implementuji dvě části:
1. **RLS Politiky (Database)** - Aktualizace pro podporu nových staff rolí
2. **Frontend změny** - Role badges a filtrování směn podle rolí uživatele

---

### Část 1: Aktualizace RLS politik pro shifts

Provedu SQL migraci pro aktualizaci RLS politik na tabulce `shifts`:

```sql
-- 1. Aktualizovat SELECT politiku - přidat nové staff role
DROP POLICY IF EXISTS "Staff and admins can view shifts" ON public.shifts;
CREATE POLICY "Staff and admins can view shifts" ON public.shifts
FOR SELECT USING (
  has_role(auth.uid(), 'admin'::app_role) OR 
  has_role(auth.uid(), 'part_time_staff'::app_role) OR
  has_role(auth.uid(), 'instructor'::app_role) OR
  has_role(auth.uid(), 'bar_staff'::app_role) OR
  has_role(auth.uid(), 'manager'::app_role) OR
  (claimed_by = auth.uid())
);

-- 2. Aktualizovat UPDATE politiku - přidat nové staff role
DROP POLICY IF EXISTS "Staff can update shifts" ON public.shifts;
CREATE POLICY "Staff can update shifts" ON public.shifts
FOR UPDATE 
USING (
  has_role(auth.uid(), 'admin'::app_role) OR 
  has_role(auth.uid(), 'part_time_staff'::app_role) OR
  has_role(auth.uid(), 'instructor'::app_role) OR
  has_role(auth.uid(), 'bar_staff'::app_role) OR
  has_role(auth.uid(), 'manager'::app_role)
)
WITH CHECK (
  has_role(auth.uid(), 'admin'::app_role) OR 
  (
    (has_role(auth.uid(), 'part_time_staff'::app_role) OR
     has_role(auth.uid(), 'instructor'::app_role) OR
     has_role(auth.uid(), 'bar_staff'::app_role) OR
     has_role(auth.uid(), 'manager'::app_role)) 
    AND 
    (
      ((status = 'pending') AND (claimed_by = auth.uid())) OR
      ((status = 'completed') AND (claimed_by = auth.uid())) OR
      ((status = 'open') AND (claimed_by IS NULL))
    )
  )
);
```

---

### Část 2: Frontend změny

#### 2.1. Aktualizace `src/hooks/useShifts.ts`

| Změna | Popis |
|-------|-------|
| Import `roles` z AuthContext | Potřebujeme array rolí pro filtrování |
| Rozšířit shifts select | Přidat `required_role` do výběru |
| Filtrování openShifts | Staff vidí jen směny pro své role |

**Kód - import:**
```typescript
const { user, isAdmin, isStaff, roles } = useAuth();
```

**Kód - filtrování openShifts (nahradit řádky 359-362):**
```typescript
// Filter open shifts - exclude events where user already has a shift
// Staff sees only shifts matching their roles (or shifts without required_role for backward compat)
const openShifts = shifts.filter(s => {
  if (s.status !== 'open') return false;
  if (myEventIds.has(s.event_id)) return false;
  
  // Admin sees all
  if (isAdmin) return true;
  
  // If shift has no required_role, show to all staff (legacy)
  const requiredRole = (s as any).required_role;
  if (!requiredRole) return true;
  
  // Show only if user has the required role
  return roles.includes(requiredRole);
});
```

---

#### 2.2. Aktualizace `src/pages/Shifts.tsx`

| Změna | Řádky | Popis |
|-------|-------|-------|
| Přidat konstanty pro role | Po řádku 29 | staffRoleLabels a staffRoleColors |
| Staff Available tab | 563-597 | Přidat Badge s požadovanou rolí |
| Admin Open shifts tab | 986-1011 | Přidat Badge a aktualizovat text tlačítka |
| Admin Pending tab | 871-906 | Přidat Badge u čekajících směn |
| Assign dialog | 1303-1314 | Zobrazit požadovanou roli |

**Konstanty (přidat po importech):**
```typescript
// Staff role labels and colors for badges
const staffRoleLabels: Record<string, string> = {
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  part_time_staff: 'Brigádník',
};

const staffRoleColors: Record<string, string> = {
  instructor: 'bg-teal-500',
  bar_staff: 'bg-amber-500',
  manager: 'bg-indigo-500',
  part_time_staff: 'bg-blue-500',
};
```

**Staff Available Shifts - přidat Badge (řádek 569):**
```tsx
<div className="flex items-center gap-2">
  <p className="font-medium text-base md:text-lg">{eventItem.event?.title || 'Směna'}</p>
  {/* Show role badge if available shifts have required_role */}
  {eventItem.availableShifts?.[0]?.required_role && (
    <Badge className={`${staffRoleColors[eventItem.availableShifts[0].required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[eventItem.availableShifts[0].required_role] || eventItem.availableShifts[0].required_role}
    </Badge>
  )}
</div>
```

**Admin Open Shifts - přidat Badge (řádek 991):**
```tsx
<div className="flex items-center gap-2">
  <p className="font-medium">{shift.event?.title || 'Směna'}</p>
  {(shift as any).required_role && (
    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
    </Badge>
  )}
</div>
```

**Admin Open Shifts - aktualizovat text tlačítka (řádek 1007-1008):**
```tsx
<Button size="sm" onClick={() => openAssignDialog(shift)}>
  <UserPlus className="h-4 w-4 mr-1" />
  Přiřadit {staffRoleLabels[(shift as any).required_role] || 'brigádníka'}
</Button>
```

**Admin Pending Shifts - přidat Badge (řádek 876):**
```tsx
<div className="flex items-center gap-2">
  <p className="font-medium">{shift.event?.title || 'Směna'}</p>
  {(shift as any).required_role && (
    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
    </Badge>
  )}
</div>
```

**Assign Dialog - zobrazit požadovanou roli (řádek 1306):**
```tsx
<div className="flex items-center gap-2">
  <p className="font-medium text-lg">{shiftToAssign.event?.title || 'Směna'}</p>
  {(shiftToAssign as any).required_role && (
    <Badge className={`${staffRoleColors[(shiftToAssign as any).required_role] || 'bg-gray-500'} text-white`}>
      {staffRoleLabels[(shiftToAssign as any).required_role] || (shiftToAssign as any).required_role}
    </Badge>
  )}
</div>
```

---

#### 2.3. Aktualizace `openShiftsByEvent` v useShifts.ts

Pro správné zobrazení rolí ve staff view potřebujeme předat shifts do groupu:

```typescript
const openShiftsByEvent = Object.values(
  openShifts.reduce((acc, shift) => {
    const eventId = shift.event_id;
    if (!acc[eventId]) {
      const totalSlots = shifts.filter(s => s.event_id === eventId).length;
      acc[eventId] = {
        eventId,
        event: shift.event,
        hourlyRate: shift.hourly_rate,
        availableShiftIds: [],
        availableShifts: [],  // NEW - include shift data for role display
        openCount: 0,
        totalSlots,
      };
    }
    acc[eventId].availableShiftIds.push(shift.id);
    acc[eventId].availableShifts.push(shift);  // NEW
    acc[eventId].openCount += 1;
    return acc;
  }, {} as Record<string, { eventId: string; event: any; hourlyRate: number | null; availableShiftIds: string[]; availableShifts: any[]; openCount: number; totalSlots: number }>)
).sort(/* ... existing sort ... */);
```

---

### Souhrn změn

| Soubor | Typ změny |
|--------|-----------|
| **Database** | RLS politiky SELECT a UPDATE pro shifts |
| `src/hooks/useShifts.ts` | Import roles, filtrování podle rolí, rozšíření groupy |
| `src/pages/Shifts.tsx` | Role konstanty, Badge komponenty na 4 místech |

---

### Výsledek po implementaci

**Staff pohled:**
- Uživatel vidí pouze směny pro své role
- U každé směny je vidět badge s požadovanou rolí (např. "Instruktor")
- Přihlášení na směnu funguje bez chyby díky opraveným RLS

**Admin pohled:**
- Každá směna v seznamu zobrazuje badge s rolí
- Tlačítko zobrazuje "Přiřadit Instruktora" místo "Přiřadit brigádníka"
- Duplicitní řádky jsou rozlišeny podle role

