import { Navigate, Outlet } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import Sidebar from './Sidebar';
import MobileHeader from './MobileHeader';
import MobileNav from './MobileNav';

const AppLayout = () => {
  const { user, loading } = useAuth();

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
      </div>
    );
  }

  if (!user) {
    return <Navigate to="/auth" replace />;
  }

  return (
    <div className="min-h-screen bg-background">
      {/* Desktop Sidebar - completely hidden on mobile */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden md:block">
        <Sidebar />
      </aside>
      
      {/* Mobile Header - only visible on mobile */}
      <MobileHeader />
      
      {/* Main Content - full width on mobile, offset on desktop */}
      <main className="min-h-screen overflow-auto pb-20 md:pb-0 md:ml-64">
        <Outlet />
      </main>
      
      {/* Mobile Bottom Navigation - only visible on mobile */}
      <MobileNav />
    </div>
  );
};

export default AppLayout;
