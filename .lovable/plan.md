

## Team Configuration UI - Frontend Implementation

### Overview

Replace the single "Počet potřebných brigádníků" number input with a new Team Configuration UI that allows admins to specify exact counts for each staff role (instructor, bar_staff, manager).

**Database constraint**: The column is named `role_reqs` (not `role_requirements`), and the SQL trigger is already configured.

---

### Files to Modify

| File | Changes |
|------|---------|
| `src/pages/IceCalendar.tsx` | Replace state, add counter UI, update handlers |
| `src/hooks/useEvents.ts` | Add `role_reqs` to interface |

---

### Step 1: Update useEvents.ts - Add role_reqs to Interface

**Add role_reqs to CreateEventData (line 8-15):**

```typescript
interface CreateEventData {
  title: string;
  description?: string;
  event_type: EventType;
  start_time: string;
  end_time: string;
  required_staff?: number;
  role_reqs?: Record<string, number>;  // NEW - matches DB column name
}
```

---

### Step 2: Update IceCalendar.tsx - State Changes

**Replace single requiredStaff state (line 53):**

```typescript
// REMOVE
const [requiredStaff, setRequiredStaff] = useState('0');

// ADD
const [roleCounts, setRoleCounts] = useState<Record<string, number>>({
  instructor: 0,
  bar_staff: 0,
  manager: 0,
});
```

**Add new imports (line 16):**

```typescript
import { Plus, ChevronLeft, ChevronRight, Trash2, User, Clock, Pencil, Minus } from 'lucide-react';
```

**Add role labels constant (after line 128):**

```typescript
const staffRoleLabels: Record<string, string> = {
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
};
```

**Add helper functions (after staffRoleLabels):**

```typescript
// Increment/decrement role count
const adjustRoleCount = (role: string, delta: number) => {
  setRoleCounts(prev => ({
    ...prev,
    [role]: Math.max(0, Math.min(VALIDATION_LIMITS.STAFF_COUNT_MAX, (prev[role] || 0) + delta))
  }));
};

// Calculate total staff (for backward compatibility)
const getTotalStaff = () => Object.values(roleCounts).reduce((sum, count) => sum + count, 0);
```

---

### Step 3: Update Create Dialog UI

**Replace lines 490-505 (single number input) with counter UI:**

```tsx
{(eventType === 'commercial' || eventType === 'recruitment') && (
  <div className="space-y-3">
    <Label>Konfigurace týmu</Label>
    <p className="text-xs text-muted-foreground">
      Vyberte počet osob pro každou roli.
    </p>
    
    {Object.entries(staffRoleLabels).map(([role, label]) => (
      <div key={role} className="flex items-center justify-between p-3 rounded-lg bg-muted/50">
        <span className="font-medium text-sm">{label}</span>
        <div className="flex items-center gap-3">
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="h-8 w-8"
            onClick={() => adjustRoleCount(role, -1)}
            disabled={roleCounts[role] <= 0}
          >
            <Minus className="h-4 w-4" />
          </Button>
          <span className="w-8 text-center font-semibold">
            {roleCounts[role]}
          </span>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="h-8 w-8"
            onClick={() => adjustRoleCount(role, 1)}
            disabled={roleCounts[role] >= VALIDATION_LIMITS.STAFF_COUNT_MAX}
          >
            <Plus className="h-4 w-4" />
          </Button>
        </div>
      </div>
    ))}
    
    {getTotalStaff() > 0 && (
      <p className="text-sm text-muted-foreground text-right">
        Celkem: <strong>{getTotalStaff()}</strong> osob
      </p>
    )}
  </div>
)}
```

---

### Step 4: Update Edit Dialog UI

**Replace lines 1097-1109 with same counter UI as create dialog.**

---

### Step 5: Update handleCreateEvent (lines 240-248)

**Modify to include role_reqs:**

```typescript
// Build role_reqs object (filter out zeros)
const roleReqs = Object.fromEntries(
  Object.entries(roleCounts).filter(([_, count]) => count > 0)
);

await createEvent({
  title: validation.data.title,
  description: validation.data.description,
  event_type: validation.data.event_type as Database['public']['Enums']['event_type'],
  start_time: validation.data.start_time,
  end_time: validation.data.end_time,
  required_staff: getTotalStaff(),  // Sum for backward compatibility
  role_reqs: Object.keys(roleReqs).length > 0 ? roleReqs : undefined,
});
```

---

### Step 6: Update handleUpdateEvent (lines 371-380)

**Same logic as create:**

```typescript
const roleReqs = Object.fromEntries(
  Object.entries(roleCounts).filter(([_, count]) => count > 0)
);

await updateEvent({
  id: editingEvent.id,
  title: validation.data.title,
  description: validation.data.description,
  event_type: validation.data.event_type as Database['public']['Enums']['event_type'],
  start_time: validation.data.start_time,
  end_time: validation.data.end_time,
  required_staff: getTotalStaff(),
  role_reqs: Object.keys(roleReqs).length > 0 ? roleReqs : undefined,
});
```

---

### Step 7: Update handleOpenEditDialog (lines 329-339)

**Parse existing role_reqs when editing:**

```typescript
const handleOpenEditDialog = (event: Event) => {
  setEditingEvent(event);
  setTitle(event.title);
  setDescription(event.description || '');
  setEventType(event.event_type);
  setStartTime(format(new Date(event.start_time), 'HH:mm'));
  setEndTime(format(new Date(event.end_time), 'HH:mm'));
  
  // Parse role_reqs or fallback to legacy distribution
  const eventRoleReqs = (event as any).role_reqs;
  if (eventRoleReqs && typeof eventRoleReqs === 'object' && Object.keys(eventRoleReqs).length > 0) {
    setRoleCounts({
      instructor: eventRoleReqs.instructor || 0,
      bar_staff: eventRoleReqs.bar_staff || 0,
      manager: eventRoleReqs.manager || 0,
    });
  } else {
    // Legacy events: assign all required_staff to instructor
    const legacyCount = event.required_staff || 0;
    setRoleCounts({
      instructor: legacyCount,
      bar_staff: 0,
      manager: 0,
    });
  }
  
  setSelectedDate(new Date(event.start_time));
  setIsEditDialogOpen(true);
};
```

---

### Step 8: Update resetForm (lines 317-326)

```typescript
const resetForm = () => {
  setTitle('');
  setDescription('');
  setEventType('commercial');
  setStartTime('09:00');
  setEndTime('11:00');
  setRoleCounts({ instructor: 0, bar_staff: 0, manager: 0 });
  setSelectedDate(null);
  setEditingEvent(null);
};
```

---

### UI Preview

```text
Konfigurace týmu

┌─────────────────────────────────────────┐
│ Instruktor            [ - ]  1  [ + ]   │
├─────────────────────────────────────────┤
│ Obsluha baru          [ - ]  2  [ + ]   │
├─────────────────────────────────────────┤
│ Provozní hospoda      [ - ]  0  [ + ]   │
└─────────────────────────────────────────┘
                              Celkem: 3 osob
```

---

### Technical Notes

- **Column name**: Uses `role_reqs` to match your existing DB column
- **Backward compatibility**: `required_staff` stores the sum of all roles (your trigger depends on this)
- **JSONB format**: `role_reqs = { "instructor": 2, "bar_staff": 1 }` (zeros are filtered out)
- **Legacy events**: When editing old events, all `required_staff` are assigned to `instructor` role
- **Validation**: Each counter bounded by 0 and VALIDATION_LIMITS.STAFF_COUNT_MAX (50)
- **No database migration**: Skipped per your instruction - column already exists

