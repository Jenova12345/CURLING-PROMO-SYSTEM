

## Aktualizace Komunikace - Role, Specifičtí uživatelé, RLS

Rozumím architektuře: nebudu měnit databázové schéma. Poskytuji:
1. SQL snippety (k manuálnímu spuštění) pro sloupec + RLS
2. Frontend kód

---

## Část 1: SQL snippety (spustíte manuálně v Supabase SQL Editoru)

### 1A. Přidat sloupec `visible_to_user_ids`

```sql
ALTER TABLE public.chat_groups 
ADD COLUMN visible_to_user_ids uuid[] DEFAULT NULL;
```

### 1B. Aktualizovat RLS SELECT politiku

Aktuální politika používá `get_user_role()`, která vrací jen primární roli. To je problém pro multi-role uživatele. Nová politika přidává podporu pro `visible_to_user_ids` a opravuje multi-role přístup:

```sql
DROP POLICY IF EXISTS "Users can view authorized groups" ON public.chat_groups;

CREATE POLICY "Users can view authorized groups" ON public.chat_groups
FOR SELECT USING (
  -- Admins see everything
  has_role(auth.uid(), 'admin'::app_role) 
  -- Public groups (empty roles array)
  OR (authorized_roles = '{}'::app_role[]) 
  -- User has one of the authorized roles (checks ALL user roles, not just primary)
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur 
    WHERE ur.user_id = auth.uid() 
    AND ur.role = ANY(authorized_roles)
  )
  -- User is in the visible_to_user_ids list
  OR (auth.uid() = ANY(visible_to_user_ids))
);
```

Tato nová politika:
- Opravuje multi-role problém (původní `get_user_role()` vrací jen 1 roli)
- Přidává podmínku pro `visible_to_user_ids`

---

## Část 2: Frontend změny

### Soubory k úpravě

| Soubor | Změny |
|--------|-------|
| `src/pages/Communication.tsx` | Aktualizovat `ALL_ROLES` (odebrat Brigádník, přidat 3 nové), přidat user search multi-select, aktualizovat form data a logiku |
| `src/hooks/useChatGroups.ts` | Přidat `visible_to_user_ids` do interface a mutací |
| `src/lib/validation.ts` | Přidat `visible_to_user_ids` do `chatGroupSchema` |

---

### 2.1 Communication.tsx - `ALL_ROLES` (řádky 36-42)

**Odebrat:** `part_time_staff` (Brigádník)
**Přidat:** `instructor`, `bar_staff`, `manager`

```typescript
const ALL_ROLES: { value: AppRole; label: string }[] = [
  { value: 'admin', label: 'Správce' },
  { value: 'trainer', label: 'Trenér' },
  { value: 'instructor', label: 'Instruktor' },
  { value: 'bar_staff', label: 'Obsluha baru' },
  { value: 'manager', label: 'Provozní hospoda' },
  { value: 'pro_player', label: 'Profi hráč' },
  { value: 'hobby_player', label: 'Hobby hráč' },
];
```

### 2.2 Communication.tsx - Form Data (řádky 75-91)

Přidat `visible_to_user_ids` do interface a default:

```typescript
interface ChatGroupFormData {
  name: string;
  description: string;
  whatsapp_url: string;
  icon_slug: string;
  authorized_roles: AppRole[];
  visible_to_user_ids: string[];
  isPublic: boolean;
}

const defaultFormData: ChatGroupFormData = {
  name: '',
  description: '',
  whatsapp_url: '',
  icon_slug: 'message-circle',
  authorized_roles: [],
  visible_to_user_ids: [],
  isPublic: false,
};
```

### 2.3 Communication.tsx - Fetch users + Search UI

Přidat nový `useQuery` pro seznam uživatelů (admins only, pro formulář):

```typescript
const { data: allUsers = [] } = useQuery({
  queryKey: ['all-users-for-groups'],
  queryFn: async () => {
    const { data, error } = await supabase
      .from('profiles')
      .select('user_id, full_name')
      .order('full_name');
    if (error) throw error;
    return data;
  },
  enabled: isAdmin,
});
```

Přidat state pro vyhledávání uživatelů:

```typescript
const [userSearchQuery, setUserSearchQuery] = useState('');
```

Přidat do formuláře novou sekci "Konkrétní osoby" pod role checkboxy (po řádku 381):

```tsx
{/* Specific users selection */}
{!formData.isPublic && (
  <div className="space-y-2 mt-3">
    <Label>Konkrétní osoby (volitelné)</Label>
    <p className="text-xs text-muted-foreground">
      Vyberte uživatele, kteří uvidí skupinu bez ohledu na roli
    </p>
    <Input
      placeholder="Hledat podle jména..."
      value={userSearchQuery}
      onChange={(e) => setUserSearchQuery(e.target.value)}
      className="mb-2"
    />
    <div className="max-h-40 overflow-y-auto space-y-1 border rounded-md p-2">
      {allUsers
        .filter(u => u.full_name?.toLowerCase().includes(userSearchQuery.toLowerCase()))
        .map(u => (
          <div key={u.user_id} className="flex items-center space-x-2">
            <Checkbox
              id={`user-${u.user_id}`}
              checked={formData.visible_to_user_ids.includes(u.user_id)}
              onCheckedChange={(checked) => {
                setFormData(prev => ({
                  ...prev,
                  visible_to_user_ids: checked 
                    ? [...prev.visible_to_user_ids, u.user_id]
                    : prev.visible_to_user_ids.filter(id => id !== u.user_id),
                }));
              }}
            />
            <Label htmlFor={`user-${u.user_id}`} className="font-normal cursor-pointer text-sm">
              {u.full_name || 'Bez jména'}
            </Label>
          </div>
        ))}
    </div>
    {/* Show selected count */}
    {formData.visible_to_user_ids.length > 0 && (
      <p className="text-xs text-primary">
        Vybráno: {formData.visible_to_user_ids.length} uživatelů
      </p>
    )}
  </div>
)}
```

### 2.4 Communication.tsx - Aktualizovat `handleCreateOrUpdate`

Přidat `visible_to_user_ids` do payload (řádky 128-135):

```typescript
const payload = {
  name: sanitizeText(formData.name),
  description: sanitizeText(formData.description),
  whatsapp_url: formData.whatsapp_url.trim(),
  icon_slug: formData.icon_slug,
  authorized_roles: authorizedRoles,
  visible_to_user_ids: formData.visible_to_user_ids.length > 0 
    ? formData.visible_to_user_ids 
    : null,
};
```

### 2.5 Communication.tsx - Aktualizovat `handleEdit`

Přidat načtení `visible_to_user_ids` při editaci (řádky 178-191):

```typescript
const handleEdit = (group: typeof chatGroups[0]) => {
  const isPublic = group.authorized_roles.length === 0;
  setFormData({
    name: group.name,
    description: group.description || '',
    whatsapp_url: group.whatsapp_url,
    icon_slug: group.icon_slug || 'message-circle',
    authorized_roles: group.authorized_roles,
    visible_to_user_ids: (group as any).visible_to_user_ids || [],
    isPublic,
  });
  setEditingGroup(group.id);
  setValidationError(null);
  setIsDialogOpen(true);
};
```

### 2.6 Communication.tsx - Aktualizovat `isFormValid`

Rozšířit validaci na řádku 224:

```typescript
const isFormValid = formData.name.trim() && formData.whatsapp_url.trim() && 
  (formData.isPublic || formData.authorized_roles.length > 0 || formData.visible_to_user_ids.length > 0);
```

### 2.7 Communication.tsx - Aktualizovat validaci v `handleCreateOrUpdate`

Řádky 122-126 - Přidat podmínku pro visible_to_user_ids:

```typescript
if (!formData.isPublic && authorizedRoles.length === 0 && formData.visible_to_user_ids.length === 0) {
  setValidationError('Vyberte alespoň jednu roli, osobu, nebo označte skupinu jako veřejnou.');
  return;
}
```

### 2.8 Communication.tsx - Aktualizovat `handlePublicToggle`

Řádky 207-215 - Resetovat i visible_to_user_ids:

```typescript
const handlePublicToggle = (checked: boolean) => {
  setFormData(prev => ({
    ...prev,
    isPublic: checked,
    authorized_roles: checked ? [] : prev.authorized_roles,
    visible_to_user_ids: checked ? [] : prev.visible_to_user_ids,
  }));
  setValidationError(null);
};
```

### 2.9 Communication.tsx - Aktualizovat `handleCloseDialog`

Řádek 220 - Resetovat userSearchQuery:

```typescript
const handleCloseDialog = () => {
  setIsDialogOpen(false);
  setEditingGroup(null);
  setFormData(defaultFormData);
  setValidationError(null);
  setUserSearchQuery('');
};
```

---

### 2.10 useChatGroups.ts - Přidat `visible_to_user_ids`

**Interface (řádek 9-19):**
```typescript
interface ChatGroup {
  id: string;
  name: string;
  description: string | null;
  whatsapp_url: string;
  icon: string | null;
  icon_slug: string | null;
  authorized_roles: AppRole[];
  visible_to_user_ids: string[] | null;
  created_at: string;
  updated_at: string;
}
```

**CreateChatGroupInput (řádky 21-28):**
```typescript
interface CreateChatGroupInput {
  name: string;
  description?: string;
  whatsapp_url: string;
  icon?: string;
  icon_slug?: string;
  authorized_roles: AppRole[];
  visible_to_user_ids?: string[] | null;
}
```

**createGroup mutationFn (řádky 53-65) - přidat pole:**
```typescript
const { data, error } = await supabase
  .from('chat_groups')
  .insert({
    name: input.name,
    description: input.description || null,
    whatsapp_url: input.whatsapp_url,
    icon: input.icon || null,
    icon_slug: input.icon_slug || 'message-circle',
    authorized_roles: input.authorized_roles,
    visible_to_user_ids: input.visible_to_user_ids || null,
  } as any)
  .select()
  .single();
```

**updateGroup mutationFn (řádky 81-88) - cast `as any`:**
```typescript
const { data, error } = await supabase
  .from('chat_groups')
  .update(updates as any)
  .eq('id', id)
  .select()
  .single();
```

---

### 2.11 validation.ts - Aktualizovat `chatGroupSchema` (řádky 254-263)

Přidat `visible_to_user_ids`:

```typescript
export const chatGroupSchema = z.object({
  name: titleSchema,
  description: descriptionSchema,
  whatsapp_url: whatsappUrlSchema,
  icon_slug: z.string().max(50).optional(),
  authorized_roles: z.array(z.enum([
    'admin', 'trainer', 'part_time_staff', 'instructor', 
    'bar_staff', 'manager', 'pro_player', 'hobby_player'
  ])),
  visible_to_user_ids: z.array(z.string().uuid()).nullable().optional(),
});
```

---

## Výsledek po implementaci

| Oblast | Pred | Po |
|--------|------|-----|
| **Role checkboxy** | admin, trener, brigadnik, profi, hobby | admin, trener, instruktor, obsluha baru, provozni hospoda, profi, hobby |
| **Specifické osoby** | Neexistuje | Multi-select se search |
| **Validace** | Role NEBO Public | Role NEBO Public NEBO osoby |
| **RLS** | `get_user_role()` (1 role) | `EXISTS` (multi-role) + `visible_to_user_ids` |
| **Data hook** | Bez `visible_to_user_ids` | S `visible_to_user_ids` |

## TypeScript Note

Používám `as any` cast pro `visible_to_user_ids` v Supabase operacích, protože auto-generované typy neobsahují nový sloupec.

## Pořadí kroků

1. Spustit SQL snippet 1A (sloupec) v Supabase
2. Spustit SQL snippet 1B (RLS) v Supabase
3. Implementovat frontend změny (soubory 2.1-2.11)
4. Otestovat: vytvořit skupinu s rolemi + konkrétními osobami

