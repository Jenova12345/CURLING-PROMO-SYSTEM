import {
  Calendar,
  CalendarCheck,
  Clock,
  Users, 
  LayoutDashboard, 
  MessageCircle, 
  Wallet,
  User,
  HelpCircle,
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
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
  {
    path: '/calendar',
    label: 'Kalendář',
    icon: Calendar,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
  },
  {
    path: '/reservations',
    label: 'Rezervace',
    icon: CalendarCheck,
    roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 'bar_staff', 'manager', 'pro_player', 'hobby_player']
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
  hobby_player: 'Hobby hráč',
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
  roles: string[]
): NavItem[] => {
  return items.filter(item => {
    if (roles.length === 0) {
      return DEFAULT_PATHS.includes(item.path);
    }
    return item.roles.some(allowedRole => roles.includes(allowedRole));
  });
};
