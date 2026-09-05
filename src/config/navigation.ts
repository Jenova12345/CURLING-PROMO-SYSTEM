import {
  Calendar,
  Clock,
  Users, 
  LayoutDashboard, 
  MessageCircle, 
  Wallet,
  Coins,
  FileText,
  UserPlus,
  Building2,
  ShieldCheck,
  Settings,
  User,
  HelpCircle,
  LucideIcon
} from 'lucide-react';

export interface NavItem {
  path: string;
  label: string;
  icon: LucideIcon;
  roles: string[];
  /**
   * Položka jen pro ZÁSTUPCE KLUBU.
   *
   * „Zástupce" není role v `app_role` — je to vztah ke klubu
   * (`subject_reps.level = 'rep'`, rozhodnutí PM R2). Filtr podle rolí ho tedy
   * nepozná a musí se předat zvlášť.
   */
  vyzadujeZastupce?: boolean;
  /**
   * Položka navíc PRO ZÁSTUPCE KLUBU — vidí ji, kdo splní `roles`, a k tomu
   * každý zástupce klubu bez ohledu na roli.
   *
   * Opak `vyzadujeZastupce`, který naopak přístup zužuje. Vzniklo kvůli
   * „Žádostem": schvalovat členy svého klubu smí zástupce už v databázi
   * (`approve_subject_request`, brána R5), ale do menu se nedostal, protože
   * filtr uměl jen `app_role` — a „zástupce" žádná role není.
   */
  iProZastupce?: boolean;
}

export const NAV_ITEMS: NavItem[] = [
  { 
    path: '/', 
    label: 'Přehled', 
    icon: LayoutDashboard,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
  {
    path: '/calendar',
    label: 'Kalendář',
    icon: Calendar,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
  {
    path: '/muj-klub',
    label: 'Můj klub',
    icon: ShieldCheck,
    // Role tu nejsou omezující — rozhoduje `vyzadujeZastupce`. Členem klubu
    // může být kdokoli, ale tuhle stránku vidí jen jeho zástupce.
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player'],
    vyzadujeZastupce: true,
  },
  {
    path: '/shifts',
    label: 'Směny', 
    icon: Clock,
    roles: ['admin', 'part_time_staff', 'instructor', 'bar_staff', 'manager']
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
    path: '/requests',
    label: 'Žádosti',
    icon: UserPlus,
    roles: ['admin'],
    // Zástupce klubu schvaluje žádosti do SVÉHO klubu (databáze mu to dovolí
    // už dnes). Zúžení na vlastní kluby řeší stránka, ne tenhle filtr.
    iProZastupce: true,
  },
  {
    path: '/subjects',
    label: 'Subjekty',
    icon: Building2,
    roles: ['admin']
  },
  {
    path: '/dues',
    label: 'Přehled fakturace',
    icon: Coins,
    roles: ['admin']
  },
  {
    path: '/invoices',
    label: 'Faktury',
    icon: FileText,
    roles: ['admin']
  },
  {
    path: '/settings',
    label: 'Nastavení',
    icon: Settings,
    roles: ['admin']
  },
  {
    path: '/communication',
    label: 'Komunikace', 
    icon: MessageCircle,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
  { 
    path: '/help', 
    label: 'Nápověda', 
    icon: HelpCircle,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
  { 
    path: '/profile', 
    label: 'Můj profil', 
    icon: User,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
];

export const ROLE_LABELS: Record<string, string> = {
  admin: 'Správce',
  trainer: 'Trenér',
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  pro_player: 'Profi hráč',
  // R3: v databázi zůstává `hobby_player`, mění se JEN popisek v UI.
  hobby_player: 'Hráč klubu',
};

export const DEFAULT_PATHS = ['/', '/calendar', '/profile', '/communication', '/help'];

// Legacy function for backward compatibility
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

// New multi-role filter function
export const filterNavItemsByRoles = (
  items: NavItem[], 
  roles: string[],
  jeZastupce = false,
): NavItem[] => {
  return items.filter(item => {
    // Položky pro zástupce klubu se řídí vztahem ke klubu, ne rolí.
    if (item.vyzadujeZastupce && !jeZastupce) return false;
    // …a naopak: zástupce se k položce dostane i bez odpovídající role.
    // Schválně PŘED kontrolou prázdných rolí — účet bez role, který je
    // zástupcem klubu, by jinak vypadl na `DEFAULT_PATHS`.
    if (item.iProZastupce && jeZastupce) return true;
    if (roles.length === 0) {
      return DEFAULT_PATHS.includes(item.path);
    }
    return item.roles.some(allowedRole => roles.includes(allowedRole));
  });
};
