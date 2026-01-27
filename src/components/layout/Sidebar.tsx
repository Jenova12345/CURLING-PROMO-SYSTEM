import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { cn } from '@/lib/utils';
import { LogOut, User } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Separator } from '@/components/ui/separator';
import logo from '@/assets/logo.png';
import { NAV_ITEMS, ROLE_LABELS, filterNavItemsByRoles } from '@/config/navigation';

const Sidebar = () => {
  const { profile, roles, signOut } = useAuth();
  const location = useLocation();

  const filteredNavItems = filterNavItemsByRoles(NAV_ITEMS, roles);

  // Display roles - join with comma if multiple
  const displayRoles = roles.length > 0 
    ? roles.map(r => ROLE_LABELS[r] || r).join(', ')
    : 'Člen';

  return (
    <aside className="flex h-screen w-64 flex-col border-r bg-card">
      {/* Logo */}
      <div className="flex h-16 items-center gap-3 px-6 border-b">
        <img src={logo} alt="Mladé Kameny" className="h-10 w-auto" />
        <div>
          <h1 className="font-bold text-lg leading-none">Mladé kameny</h1>
          <p className="text-xs text-muted-foreground">Curlingová hala</p>
        </div>
      </div>

      {/* Navigation */}
      <nav className="flex-1 space-y-1 p-4">
        {filteredNavItems.map((item) => {
          const Icon = item.icon;
          const isActive = location.pathname === item.path;
          
          return (
            <Link
              key={item.path}
              to={item.path}
              className={cn(
                'flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors',
                isActive 
                  ? 'bg-primary text-primary-foreground' 
                  : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
              )}
            >
              <Icon className="h-4 w-4" />
              {item.label}
            </Link>
          );
        })}
      </nav>

      <Separator />

      {/* User Profile */}
      <div className="p-4">
        <div className="flex items-center gap-3 rounded-lg bg-accent/50 p-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-full bg-primary text-primary-foreground">
            <User className="h-5 w-5" />
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-sm font-medium truncate">
              {profile?.full_name || 'Uživatel'}
            </p>
            <p className="text-xs text-muted-foreground truncate">
              {displayRoles}
            </p>
          </div>
        </div>
        <Button
          variant="ghost"
          className="w-full mt-2 justify-start text-muted-foreground"
          onClick={signOut}
        >
          <LogOut className="h-4 w-4 mr-2" />
          Odhlásit se
        </Button>
      </div>
    </aside>
  );
};

export default Sidebar;
