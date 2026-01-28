

## Oprava zobrazení směn a logiky přihlášení

Rozumím architektuře. Poskytuji **pouze**:
1. RLS SQL jako textový snippet (k manuálnímu spuštění)
2. Frontend kód (React/TypeScript)

Databázové sloupce `role_reqs` (events) a `required_role` (shifts) **již existují**. Nebudu generovat žádné `ALTER TABLE` ani `CREATE TRIGGER` příkazy.

---

## Část 1: RLS SQL (textový snippet - spustíte manuálně)

Zkopírujte a spusťte tento SQL v Supabase SQL Editoru:

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
      ((status = 'pending'::shift_status) AND (claimed_by = auth.uid())) OR
      ((status = 'completed'::shift_status) AND (claimed_by = auth.uid())) OR
      ((status = 'open'::shift_status) AND (claimed_by IS NULL))
    )
  )
);
```

---

## Část 2: Frontend změny

### Soubory k úpravě

| Soubor | Změny |
|--------|-------|
| `src/hooks/useShifts.ts` | Přidat `roles` z AuthContext, filtrovat směny podle rolí, rozšířit `openShiftsByEvent` o `availableShifts` |
| `src/pages/Shifts.tsx` | Přidat role konstanty, zobrazit Badge s rolí na 5 místech v UI |

---

### 2.1 useShifts.ts změny

**Řádek 6 - Přidat `roles` do importu:**
```typescript
const { user, isAdmin, isStaff, roles } = useAuth();
```

**Řádky 359-362 - Nahradit filtrování openShifts:**
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

**Řádky 364-388 - Rozšířit `openShiftsByEvent` o `availableShifts`:**
```typescript
// Group open shifts by event_id for staff view (show one entry per event)
const openShiftsByEvent = Object.values(
  openShifts.reduce((acc, shift) => {
    const eventId = shift.event_id;
    if (!acc[eventId]) {
      // Count total slots for this event (all shifts regardless of status)
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
).sort((a, b) => {
  const aTime = a.event?.start_time ? new Date(a.event.start_time).getTime() : 0;
  const bTime = b.event?.start_time ? new Date(b.event.start_time).getTime() : 0;
  return aTime - bTime;
});
```

---

### 2.2 Shifts.tsx změny

**Po řádku 29 - Přidat konstanty pro role:**
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

**Řádek 569 - Staff Available Shifts - přidat role badge:**
```tsx
<div className="flex items-center gap-2 flex-wrap">
  <p className="font-medium text-base md:text-lg">{eventItem.event?.title || 'Směna'}</p>
  {/* Show role badge if available shifts have required_role */}
  {(eventItem as any).availableShifts?.[0]?.required_role && (
    <Badge className={`${staffRoleColors[(eventItem as any).availableShifts[0].required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(eventItem as any).availableShifts[0].required_role] || (eventItem as any).availableShifts[0].required_role}
    </Badge>
  )}
</div>
```

**Řádek 639 - Staff My Pending Shifts - přidat role badge:**
```tsx
<div className="flex items-center gap-2 flex-wrap">
  <p className="font-medium text-base">{shift.event?.title || 'Směna'}</p>
  {(shift as any).required_role && (
    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
    </Badge>
  )}
</div>
```

**Řádek 698 - Staff My Confirmed Shifts - přidat role badge:**
```tsx
<div className="flex items-center gap-2 flex-wrap">
  <p className="font-medium text-base">{shift.event?.title || 'Směna'}</p>
  {(shift as any).required_role && (
    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
    </Badge>
  )}
</div>
```

**Řádky 876-877 - Admin Pending Shifts - přidat role badge:**
```tsx
<div className="flex items-center gap-2 flex-wrap">
  <p className="font-medium">{shift.event?.title || 'Směna'}</p>
  {(shift as any).required_role && (
    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
    </Badge>
  )}
</div>
```

**Řádky 991 a 1007-1008 - Admin Open Shifts - přidat role badge a aktualizovat tlačítko:**
```tsx
{/* Line 991 - název s badge */}
<div className="flex items-center gap-2 flex-wrap">
  <p className="font-medium">{shift.event?.title || 'Směna'}</p>
  {(shift as any).required_role && (
    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
    </Badge>
  )}
</div>

{/* Lines 1007-1008 - tlačítko s dynamickým textem */}
<Button 
  size="sm"
  onClick={() => openAssignDialog(shift)}
>
  <UserPlus className="h-4 w-4 mr-1" />
  Přiřadit {staffRoleLabels[(shift as any).required_role] || 'brigádníka'}
</Button>
```

**Řádky 1305-1306 - Assign Dialog - zobrazit požadovanou roli:**
```tsx
<div className="flex items-center gap-2 flex-wrap">
  <p className="font-medium text-lg">{shiftToAssign.event?.title || 'Směna'}</p>
  {(shiftToAssign as any).required_role && (
    <Badge className={`${staffRoleColors[(shiftToAssign as any).required_role] || 'bg-gray-500'} text-white`}>
      {staffRoleLabels[(shiftToAssign as any).required_role] || (shiftToAssign as any).required_role}
    </Badge>
  )}
</div>
```

---

## Výsledek po implementaci

| Oblast | Před | Po |
|--------|------|-----|
| **Staff Available** | Zobrazí všechny směny | Zobrazí jen směny pro role uživatele + badge |
| **Staff My Shifts** | Bez role | S badge u každé směny |
| **Admin Pending** | Bez role | S badge "Instruktor" atd. |
| **Admin Open** | "Přiřadit brigádníka" | "Přiřadit Instruktora" + badge |
| **Assign Dialog** | Bez role | S badge požadované role |
| **RLS** | Jen admin + part_time_staff | + instructor, bar_staff, manager |

---

## TypeScript Note

Používám `(shift as any).required_role` pro přístup k `required_role`, protože auto-generované typy neobsahují nový sloupec. Toto je bezpečný workaround bez nutnosti regenerovat typy.

