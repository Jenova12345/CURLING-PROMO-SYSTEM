import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { cn } from '@/lib/utils';
import { 
  Calendar, 
  Clock, 
  Users, 
  LayoutDashboard,
  MessageCircle,
  Wallet
} from 'lucide-react';

const MobileNav = () => {
  const { role } = useAuth();
  const location = useLocation();

  const navItems = [
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
      path: '/communication', 
      label: 'Komunikace', 
      icon: MessageCircle,
      roles: ['admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player']
    },
    { 
      path: '/members', 
      label: 'Členové', 
      icon: Users,
      roles: ['admin']
    },
  ];

  const filteredNavItems = navItems.filter(item => 
    role && item.roles.includes(role)
  );

  // Show max 5 items on mobile bottom nav
  const mobileNavItems = filteredNavItems.slice(0, 5);

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-50 bg-card border-t md:hidden safe-area-bottom">
      <div className="flex items-center justify-around h-16">
        {mobileNavItems.map((item) => {
          const Icon = item.icon;
          const isActive = location.pathname === item.path;
          
          return (
            <Link
              key={item.path}
              to={item.path}
              className={cn(
                'flex flex-col items-center justify-center flex-1 h-full py-2 transition-colors',
                isActive 
                  ? 'text-primary' 
                  : 'text-muted-foreground'
              )}
            >
              <Icon className={cn("h-5 w-5", isActive && "text-primary")} />
              <span className={cn(
                "text-[10px] mt-1 font-medium",
                isActive && "text-primary"
              )}>
                {item.label}
              </span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
};

export default MobileNav;
