

## Refaktoring navigace - Single Source of Truth

### Aktuální stav

Navigační logika je duplikována ve **3 souborech**:

| Soubor | Účel | Problémy |
|--------|------|----------|
| `Sidebar.tsx` | Desktop sidebar | 7 položek, obsahuje `/profile` |
| `MobileNav.tsx` | Mobilní bottom bar | 6 položek, chybí `/profile` |
| `MobileHeader.tsx` | Mobilní slide menu | 5 položek, chybí `/profile` a `/payouts` |

### Plán implementace

#### Krok 1: Vytvořit konfigurační soubor

Nový soubor `src/config/navigation.ts`:

```typescript
import { 
  Calendar, 
  Clock, 
  Users, 
  LayoutDashboard, 
  MessageCircle, 
  Wallet,
  User,
  LucideIcon
} from 'lucide-react';

export interface NavItem {
  path: string;
  label: string;
  icon: LucideIcon;
  roles: string[];
}

export const NAV_ITEMS: NavItem[] = [
  { 
    path: '/', 
    label: 'Přehled', 
    icon: LayoutDashboard,
    roles: ['admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player']
  },
  { 
    path: '/calendar', 
    label: 'Kalendář', 
    icon: Calendar,
    roles: ['admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player']
  },
  { 
    path: '/shifts', 
    label: 'Směny', 
    icon: Clock,
    roles: ['admin', 'part_time_staff']
  },
  { 
    path: '/payouts', 
    label: 'Výplaty', 
    icon: Wallet,
    roles: ['admin']
  },
  { 
    path: '/members', 
    label: 'Členové', 
    icon: Users,
    roles: ['admin']
  },
  { 
    path: '/communication', 
    label: 'Komunikace', 
    icon: MessageCircle,
    roles: ['admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player']
  },
  { 
    path: '/profile', 
    label: 'Můj profil', 
    icon: User,
    roles: ['admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player']
  },
];

export const ROLE_LABELS: Record<string, string> = {
  admin: 'Správce',
  trainer: 'Trenér',
  part_time_staff: 'Brigádník',
  pro_player: 'Profi hráč',
  hobby_player: 'Hobby hráč',
};

export const DEFAULT_PATHS = ['/', '/calendar', '/profile', '/communication'];

// Helper funkce pro filtrování navigace podle role
export const filterNavItemsByRole = (
  items: NavItem[], 
  role: string | null
): NavItem[] => {
  return items.filter(item => {
    if (!role) {
      return DEFAULT_PATHS.includes(item.path);
    }
    return item.roles.includes(role);
  });
};
```

#### Krok 2: Aktualizovat Sidebar.tsx

Změny:
- Odstranit hardcoded `navItems`, `roleLabels`, `defaultPaths`
- Importovat `NAV_ITEMS`, `ROLE_LABELS`, `filterNavItemsByRole` z `@/config/navigation`
- Odstranit nepoužívané Lucide importy (kromě `LogOut` a `User` pro ikony)
- Zachovat UI strukturu beze změn

```typescript
import { NAV_ITEMS, ROLE_LABELS, filterNavItemsByRole } from '@/config/navigation';
// ... rest of imports (remove icon imports except LogOut, User)

const Sidebar = () => {
  // ...
  const filteredNavItems = filterNavItemsByRole(NAV_ITEMS, role);
  // ... UI zůstane stejné
};
```

#### Krok 3: Aktualizovat MobileNav.tsx

Změny:
- Odstranit hardcoded `navItems`, `defaultPaths`
- Importovat `NAV_ITEMS`, `filterNavItemsByRole` z `@/config/navigation`
- Odstranit všechny Lucide importy (ikony přijdou z konfigurace)
- Zachovat `.slice(0, 5)` pro omezení na 5 položek

```typescript
import { NAV_ITEMS, filterNavItemsByRole } from '@/config/navigation';
// ... rest of imports (no Lucide icons needed)

const MobileNav = () => {
  // ...
  const filteredNavItems = filterNavItemsByRole(NAV_ITEMS, role);
  const mobileNavItems = filteredNavItems.slice(0, 5);
  // ... UI zůstane stejné
};
```

#### Krok 4: Aktualizovat MobileHeader.tsx

Změny:
- Odstranit hardcoded `navItems`, `roleLabels`
- Importovat `NAV_ITEMS`, `ROLE_LABELS`, `filterNavItemsByRole` z `@/config/navigation`
- Zachovat pouze `Menu`, `LogOut`, `User` z Lucide (pro specifické ikony v UI)
- Použít helper funkci pro filtrování

```typescript
import { NAV_ITEMS, ROLE_LABELS, filterNavItemsByRole } from '@/config/navigation';
import { Menu, LogOut, User } from 'lucide-react';
// ... rest of imports

const MobileHeader = () => {
  // ...
  const filteredNavItems = filterNavItemsByRole(NAV_ITEMS, role);
  // ... UI zůstane stejné
};
```

### Výhody refaktoringu

| Aspekt | Před | Po |
|--------|------|-----|
| Definice položek | 3x duplikováno | 1x centrálně |
| Role labels | 2x duplikováno | 1x centrálně |
| Přidání nové položky | 3 soubory upravit | 1 soubor upravit |
| Konzistence | Nekonzistentní pořadí | Jednotné pořadí |
| Údržba | Náchylné k chybám | Jednoduchá správa |

### Technické detaily

- **TypeScript interface** `NavItem` zajistí typovou bezpečnost
- **Helper funkce** `filterNavItemsByRole` eliminuje duplicitní logiku filtrování
- **LucideIcon type** umožňuje správné typování ikon v konfiguraci

