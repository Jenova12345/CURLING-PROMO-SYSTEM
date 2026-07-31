import { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { cn } from '@/lib/utils';
import { Menu, LogOut, User } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet';
import { Separator } from '@/components/ui/separator';
import { NAV_ITEMS, ROLE_LABELS, filterNavItemsByRoles } from '@/config/navigation';
import { BRAND } from '@/config/brand';

const MobileHeader = () => {
  const { profile, roles, signOut } = useAuth();
  const location = useLocation();
  const [isOpen, setIsOpen] = useState(false);

  const filteredNavItems = filterNavItemsByRoles(NAV_ITEMS, roles);

  // Display roles - join with comma if multiple
  const displayRoles = roles.length > 0 
    ? roles.map(r => ROLE_LABELS[r] || r).join(', ')
    : 'Člen';

  const handleNavClick = () => {
    setIsOpen(false);
  };

  return (
    <header className="sticky top-0 z-50 flex h-14 items-center justify-between border-b bg-card px-4 md:hidden safe-area-top">
      {/* Logo */}
      <Link to="/" className="flex items-center gap-2">
        <img src="/logo-placeholder.svg" alt={BRAND.name} className="h-8 w-auto" />
        <span className="font-bold">{BRAND.name}</span>
      </Link>

      {/* Menu Button */}
      <Sheet open={isOpen} onOpenChange={setIsOpen}>
        <SheetTrigger asChild>
          <Button variant="ghost" size="icon">
            <Menu className="h-5 w-5" />
          </Button>
        </SheetTrigger>
        <SheetContent side="right" className="w-[280px] p-0">
          <SheetHeader className="p-4 border-b pt-[calc(1rem+env(safe-area-inset-top,0))]">
            <SheetTitle className="flex items-center gap-2 text-left">
              <img src="/logo-placeholder.svg" alt={BRAND.name} className="h-10 w-auto" />
              <div>
                <div className="font-bold">{BRAND.name}</div>
                <div className="text-xs text-muted-foreground font-normal">{BRAND.tagline}</div>
              </div>
            </SheetTitle>
          </SheetHeader>

          {/* User Info */}
          <div className="p-4 bg-accent/50">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-full bg-primary text-primary-foreground">
                <User className="h-5 w-5" />
              </div>
              <div className="min-w-0 flex-1">
                <p className="font-medium truncate">{profile?.full_name || 'Uživatel'}</p>
                <p className="text-xs text-muted-foreground truncate">
                  {displayRoles}
                </p>
              </div>
            </div>
          </div>

          {/* Navigation */}
          <nav className="flex-1 p-4 space-y-1">
            {filteredNavItems.map((item) => {
              const Icon = item.icon;
              const isActive = location.pathname === item.path;
              
              return (
                <Link
                  key={item.path}
                  to={item.path}
                  onClick={handleNavClick}
                  className={cn(
                    'flex items-center gap-3 rounded-lg px-3 py-3 text-sm font-medium transition-colors',
                    isActive 
                      ? 'bg-primary text-primary-foreground' 
                      : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
                  )}
                >
                  <Icon className="h-5 w-5" />
                  {item.label}
                </Link>
              );
            })}
          </nav>

          <Separator />

          {/* Sign Out */}
          <div className="p-4">
            <Button
              variant="ghost"
              className="w-full justify-start text-muted-foreground"
              onClick={() => {
                signOut();
                setIsOpen(false);
              }}
            >
              <LogOut className="h-5 w-5 mr-3" />
              Odhlásit se
            </Button>
          </div>
        </SheetContent>
      </Sheet>
    </header>
  );
};

export default MobileHeader;
