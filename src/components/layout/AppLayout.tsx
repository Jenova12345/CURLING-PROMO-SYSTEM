import { Navigate, Outlet } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import Sidebar from './Sidebar';
import MobileHeader from './MobileHeader';
import MobileNav from './MobileNav';

const AppLayout = () => {
  const { user, loading, cekaNaSchvaleni, profilNedostupny, profile, signOut } = useAuth();

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

  // PROFIL SE NENAČETL — nevíme, jestli účet dovnitř smí.
  //
  // Zastavuje se to ze stejného důvodu jako čekající účet: bez profilu by
  // uživatel prošel do aplikace, ve které mu RLS nic nevydá, a koukal by na
  // prázdný kalendář a prázdné menu. Z takové obrazovky nepozná, jestli se
  // něco pokazilo, nebo jestli je jen prázdno — a to je přesně ten stav,
  // kterému se tenhle blok vyhýbá.
  if (profilNedostupny) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background p-6">
        <div className="w-full max-w-md space-y-4 rounded-lg border bg-card p-6 text-card-foreground shadow-sm">
          <h1 className="text-xl font-semibold">Profil se nepodařilo načíst</h1>
          <p className="text-sm text-muted-foreground">
            Přihlášení proběhlo, ale nepodařilo se načíst tvůj profil — nejspíš
            výpadek spojení. Zkus obnovit stránku; když to potrvá, ozvi se
            správci haly.
          </p>
          <div className="flex gap-2">
            <Button onClick={() => window.location.reload()}>Zkusit znovu</Button>
            <Button variant="outline" onClick={() => signOut()}>Odhlásit se</Button>
          </div>
        </div>
      </div>
    );
  }

  // ÚČET, KTERÝ JEŠTĚ NIKDO NEPUSTIL DOVNITŘ (blok C).
  //
  // Zastavuje se to tady, v jednom místě nad všemi stránkami — ne v každé
  // stránce zvlášť. Databáze by mu stejně nic nevydala (RLS), jenže to by
  // znamenalo prázdný kalendář a prázdné menu, tedy obrazovku, ze které
  // uživatel nepozná, jestli se něco pokazilo, nebo se jen čeká.
  if (cekaNaSchvaleni) {
    const zamitnut = profile?.stav === 'zamitnut';
    const zavreny = profile?.stav === 'deaktivovan';
    return (
      <div className="flex min-h-screen items-center justify-center bg-background p-6">
        <div className="w-full max-w-md space-y-4 rounded-lg border bg-card p-6 text-card-foreground shadow-sm">
          <h1 className="text-xl font-semibold">
            {zamitnut ? 'Žádost byla zamítnuta'
              : zavreny ? 'Účet je zablokovaný'
              : 'Čeká se na potvrzení'}
          </h1>
          <p className="text-sm text-muted-foreground">
            {zamitnut
              ? 'Přiřazení ke klubu neprošlo. Ozvi se správci haly nebo zástupci svého klubu — žádost jde podat znovu.'
              : zavreny
              ? 'Přístup byl pozastaven. Obnovit ho může správce haly.'
              : 'Registrace proběhla. Teď musí tvoje přiřazení ke klubu schválit správce haly nebo zástupce klubu — do té doby se do systému nedostaneš.'}
          </p>
          <p className="text-sm text-muted-foreground">
            Jakmile to někdo odklikne, stačí se znovu přihlásit.
          </p>
          <Button variant="outline" onClick={() => signOut()}>Odhlásit se</Button>
        </div>
      </div>
    );
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
