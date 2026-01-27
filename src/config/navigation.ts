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
