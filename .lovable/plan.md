
## Multi-Role Architecture Implementation

### Overview

This implementation converts the application from a single-role to a multi-role system where users can have multiple roles simultaneously (e.g., "Instructor" + "Bar Staff").

### Files to Modify

| File | Key Changes |
|------|-------------|
| `src/contexts/AuthContext.tsx` | Fetch ALL roles as array, add `roles: AppRole[]` + `hasAnyRole()` |
| `src/config/navigation.ts` | Add new role labels, create `filterNavItemsByRoles()` function |
| `src/pages/Members.tsx` | Multi-checkbox UI for role management with INSERT/DELETE |
| `src/components/layout/Sidebar.tsx` | Use `roles` array for filtering |
| `src/components/layout/MobileNav.tsx` | Use `roles` array for filtering |
| `src/components/layout/MobileHeader.tsx` | Use `roles` array for filtering, display roles |
| `src/pages/Dashboard.tsx` | Display multiple role badges, use new role labels |
| `src/hooks/useShifts.ts` | Query for all staff roles, update superfeed logic |
| `src/lib/validation.ts` | Add new roles to schemas |

---

### Step 1: AuthContext.tsx - Multi-Role State

**Current state (line 6, 37):**
```typescript
type AppRole = 'admin' | 'trainer' | 'part_time_staff' | 'pro_player' | 'hobby_player';
const [role, setRole] = useState<AppRole | null>(null);
```

**New state:**
```typescript
type AppRole = 'admin' | 'trainer' | 'part_time_staff' | 'instructor' | 'bar_staff' | 'manager' | 'pro_player' | 'hobby_player';

// Add new state
const [roles, setRoles] = useState<AppRole[]>([]);

// Keep single role for backward compatibility (primary role)
const [role, setRole] = useState<AppRole | null>(null);
```

**Update fetchUserData (lines 57-78):**
```typescript
// Fetch ALL roles instead of limit(1)
const { data: rolesData, error: roleError } = await supabase
  .from('user_roles')
  .select('role')
  .eq('user_id', userId);

if (rolesData && rolesData.length > 0) {
  const userRoles = rolesData.map(r => r.role as AppRole);
  setRoles(userRoles);
  // Set primary role using priority order
  const primaryRole = getPrimaryRole(userRoles);
  setRole(primaryRole);
} else {
  setRoles(['hobby_player']);
  setRole('hobby_player');
}
```

**Add helper function:**
```typescript
const ROLE_PRIORITY: AppRole[] = [
  'admin', 'trainer', 'manager', 'instructor', 'bar_staff', 
  'part_time_staff', 'pro_player', 'hobby_player'
];

const getPrimaryRole = (userRoles: AppRole[]): AppRole => {
  for (const r of ROLE_PRIORITY) {
    if (userRoles.includes(r)) return r;
  }
  return 'hobby_player';
};

const hasAnyRole = (allowedRoles: string[]): boolean => {
  return roles.some(r => allowedRoles.includes(r));
};
```

**Update derived values (lines 169-172):**
```typescript
const isAdmin = roles.includes('admin');
const isTrainer = roles.includes('trainer');
const isStaff = roles.some(r => 
  ['part_time_staff', 'instructor', 'bar_staff', 'manager'].includes(r)
);
const isMember = roles.some(r => ['hobby_player', 'pro_player'].includes(r));
```

**Update context interface (lines 16-29):**
```typescript
interface AuthContextType {
  // ... existing
  role: AppRole | null;     // Primary role (backward compat)
  roles: AppRole[];         // NEW: all user roles
  hasAnyRole: (allowedRoles: string[]) => boolean;  // NEW
}
```

---

### Step 2: navigation.ts - Multi-Role Filtering

**Add new roles to ROLE_LABELS (lines 64-70):**
```typescript
export const ROLE_LABELS: Record<string, string> = {
  admin: 'Správce',
  trainer: 'Trenér',
  part_time_staff: 'Brigádník',
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  pro_player: 'Profi hráč',
  hobby_player: 'Hobby hráč',
};
```

**Expand NAV_ITEMS role arrays (lines 19-62):**
Add `'instructor', 'bar_staff', 'manager'` wherever `'part_time_staff'` exists.

**Add new filter function:**
```typescript
export const filterNavItemsByRoles = (
  items: NavItem[], 
  roles: string[]
): NavItem[] => {
  return items.filter(item => {
    if (roles.length === 0) {
      return DEFAULT_PATHS.includes(item.path);
    }
    return item.roles.some(allowedRole => roles.includes(allowedRole));
  });
};
```

---

### Step 3: Members.tsx - Multi-Checkbox Role UI

**Update data fetching (lines 37-59):**
```typescript
return profiles.map(profile => ({
  ...profile,
  roles: roles
    .filter(r => r.user_id === profile.user_id)
    .map(r => r.role),
}));
```

**Add new role labels and colors (lines 93-107):**
```typescript
const roleLabels: Record<string, string> = {
  admin: 'Správce',
  trainer: 'Trenér',
  part_time_staff: 'Brigádník',
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  pro_player: 'Profi hráč',
  hobby_player: 'Hobby hráč',
};

const roleColors: Record<string, string> = {
  admin: 'bg-red-500',
  trainer: 'bg-purple-500',
  part_time_staff: 'bg-blue-500',
  instructor: 'bg-teal-500',
  bar_staff: 'bg-amber-500',
  manager: 'bg-indigo-500',
  pro_player: 'bg-green-500',
  hobby_player: 'bg-gray-500',
};
```

**Replace single Select with multi-checkbox UI:**
```tsx
<div className="space-y-3">
  <p className="text-sm text-muted-foreground mb-2">
    Vyberte jednu nebo více rolí:
  </p>
  {Object.entries(roleLabels).map(([role, label]) => (
    <div key={role} className="flex items-center space-x-3">
      <Checkbox 
        id={`role-${role}`}
        checked={selectedRoles.includes(role)}
        onCheckedChange={(checked) => handleToggleRole(role, !!checked)}
        disabled={
          isUpdatingRoles || 
          (!checked && selectedRoles.length <= 1)
        }
      />
      <label htmlFor={`role-${role}`} className="flex items-center gap-2 cursor-pointer">
        <div className={`w-3 h-3 rounded-full ${roleColors[role]}`} />
        {label}
      </label>
    </div>
  ))}
</div>
```

**Toggle role handler:**
```typescript
const handleToggleRole = async (role: string, checked: boolean) => {
  if (!selectedMember) return;
  
  if (checked) {
    // INSERT new role
    await supabase.from('user_roles').insert({ 
      user_id: selectedMember.user_id, 
      role 
    });
  } else {
    // Prevent removing last role
    if (selectedRoles.length <= 1) {
      toast({ 
        title: 'Nelze odebrat', 
        description: 'Uživatel musí mít alespoň jednu roli.' 
      });
      return;
    }
    // DELETE role
    await supabase.from('user_roles')
      .delete()
      .eq('user_id', selectedMember.user_id)
      .eq('role', role);
  }
  queryClient.invalidateQueries({ queryKey: ['members'] });
};
```

**Display multiple badges in member list:**
```tsx
<div className="flex flex-wrap gap-1">
  {member.roles.map((r: string) => (
    <Badge key={r} className={`${roleColors[r]} text-white text-xs`}>
      {roleLabels[r]}
    </Badge>
  ))}
</div>
```

---

### Step 4: Layout Components Update

**Sidebar.tsx, MobileNav.tsx, MobileHeader.tsx:**
```typescript
// Change from:
const { role } = useAuth();
const filteredNavItems = filterNavItemsByRole(NAV_ITEMS, role);

// To:
const { roles } = useAuth();
const filteredNavItems = filterNavItemsByRoles(NAV_ITEMS, roles);
```

**MobileHeader.tsx - Display multiple roles:**
```tsx
<p className="text-xs text-muted-foreground">
  {roles.length > 0 
    ? roles.map(r => ROLE_LABELS[r]).join(', ')
    : 'Člen'}
</p>
```

---

### Step 5: useShifts.ts - Superfeed Logic

**Update availableStaff query (lines 11-35):**
Query for ALL staff roles, not just `part_time_staff`:

```typescript
const { data: staffRoles } = await supabase
  .from('user_roles')
  .select('user_id')
  .in('role', ['part_time_staff', 'instructor', 'bar_staff', 'manager']);
```

**Shift visibility (client-side filtering):**
Currently shifts are fetched for all staff, no `required_role` column exists, so the superfeed is already showing all shifts. The key change is that `isStaff` now correctly includes all staff roles.

---

### Step 6: Dashboard.tsx

**Update to use roles array:**
```typescript
const { roles } = useAuth();

// Display multiple role badges
<div className="flex flex-wrap gap-1">
  {roles.map(r => (
    <Badge key={r} variant="secondary">{roleLabels[r]}</Badge>
  ))}
</div>
```

---

### Step 7: validation.ts

**Update appRoleSchema (lines 302-308):**
```typescript
export const appRoleSchema = z.enum([
  'admin',
  'trainer',
  'part_time_staff',
  'instructor',
  'bar_staff',
  'manager',
  'pro_player',
  'hobby_player',
]);
```

**Update chatGroupSchema.authorized_roles (line 259):**
```typescript
authorized_roles: z.array(z.enum([
  'admin', 'trainer', 'part_time_staff', 'instructor', 
  'bar_staff', 'manager', 'pro_player', 'hobby_player'
])),
```

---

### New Role Colors

| Role | Czech Label | Color |
|------|-------------|-------|
| `instructor` | Instruktor | `bg-teal-500` |
| `bar_staff` | Obsluha baru | `bg-amber-500` |
| `manager` | Provozní hospoda | `bg-indigo-500` |

---

### Role Priority (for primary role display)

1. admin
2. trainer
3. manager
4. instructor
5. bar_staff
6. part_time_staff
7. pro_player
8. hobby_player

---

### Technical Notes

- **Backward compatibility**: `role` property remains as "primary role" for components not yet updated
- **RLS policies**: Current `has_role()` function in database checks if ANY matching row exists - works perfectly with multi-role
- **No database schema changes**: The `user_roles` table already supports multiple rows per user (id, user_id, role with unique constraint on user_id+role)
- **Checkbox minimum**: UI prevents unchecking the last role - users must always have at least one
- **Type safety**: Using `Record<string, string>` for labels/colors until Supabase types regenerate with new roles
