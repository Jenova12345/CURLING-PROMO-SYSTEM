import { useAuth } from '@/contexts/AuthContext';
import { useEvents } from '@/hooks/useEvents';
import { useShifts } from '@/hooks/useShifts';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Calendar, Clock, TrendingUp, Bell, MessageCircle } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Link } from 'react-router-dom';

const Dashboard = () => {
  const { profile, role, isAdmin, isStaff } = useAuth();
  const { events } = useEvents();
  const { openShifts, myShifts, totalHoursWorked, totalEarnings } = useShifts();

  const roleLabels: Record<string, string> = {
    admin: 'Správce',
    trainer: 'Trenér',
    part_time_staff: 'Brigádník',
    pro_player: 'Profi hráč',
    hobby_player: 'Hobby hráč',
  };

  const upcomingEvents = events
    .filter(e => new Date(e.start_time) > new Date())
    .slice(0, 5);

  const eventTypeColors: Record<string, string> = {
    commercial: 'bg-green-500',
    training: 'bg-blue-500',
    maintenance: 'bg-orange-500',
  };

  const eventTypeLabels: Record<string, string> = {
    commercial: 'Komerční',
    training: 'Trénink',
    maintenance: 'Údržba',
  };

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl md:text-3xl font-bold">
          Vítejte, {profile?.full_name || 'uživateli'}! 👋
        </h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Přehled vašeho účtu a nadcházejících událostí
        </p>
      </div>

      {/* Stats Grid */}
      <div className="grid gap-3 grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium whitespace-nowrap">Vaše role</CardTitle>
            <Badge variant="secondary">{role ? roleLabels[role] : 'Člen'}</Badge>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{profile?.full_name}</div>
            <p className="text-xs text-muted-foreground">
              Aktivní účet
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Nadcházející události</CardTitle>
            <Calendar className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{upcomingEvents.length}</div>
            <p className="text-xs text-muted-foreground">
              v kalendáři
            </p>
          </CardContent>
        </Card>

        {isStaff && (
          <>
            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Volné směny</CardTitle>
                <Clock className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{openShifts.length}</div>
                <p className="text-xs text-muted-foreground">
                  k dispozici
                </p>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Tento měsíc</CardTitle>
                <TrendingUp className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{totalHoursWorked} h</div>
                <p className="text-xs text-muted-foreground">
                  {totalEarnings.toLocaleString('cs-CZ')} Kč
                </p>
              </CardContent>
            </Card>
          </>
        )}
      </div>

      {/* Content Grid */}
      <div className="grid gap-4 md:gap-6 lg:grid-cols-2">
        {/* Announcements - for all users */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Bell className="h-5 w-5" />
              Oznámení
            </CardTitle>
            <CardDescription>Důležité informace z haly</CardDescription>
          </CardHeader>
          <CardContent>
            <p className="text-muted-foreground text-sm">
              Žádná nová oznámení
            </p>
          </CardContent>
        </Card>

        {/* Upcoming Events */}
        <Card>
          <CardHeader>
            <CardTitle>Nadcházející události</CardTitle>
            <CardDescription>Nejbližší akce v kalendáři</CardDescription>
          </CardHeader>
          <CardContent>
            {upcomingEvents.length === 0 ? (
              <p className="text-muted-foreground text-sm">Žádné nadcházející události</p>
            ) : (
              <div className="space-y-4">
                {upcomingEvents.map((event) => (
                  <div key={event.id} className="flex items-center gap-4">
                    <div className={`w-3 h-3 rounded-full ${eventTypeColors[event.event_type]}`} />
                    <div className="flex-1 min-w-0">
                      <p className="font-medium truncate">{event.title}</p>
                      <p className="text-sm text-muted-foreground">
                        {format(new Date(event.start_time), 'EEEE d. MMMM, HH:mm', { locale: cs })}
                      </p>
                    </div>
                    <Badge variant="outline">
                      {eventTypeLabels[event.event_type]}
                    </Badge>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        {/* WhatsApp Community Link - for non-staff members */}
        {!isStaff && !isAdmin && (
          <Card className="border-green-200 bg-green-50 dark:bg-green-950/20 lg:col-span-2">
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <MessageCircle className="h-8 w-8 text-green-600" />
                <div className="flex-1">
                  <p className="font-medium">Připojte se k naší komunitě</p>
                  <p className="text-sm text-muted-foreground">
                    Sledujte novinky a komunikujte s ostatními členy
                  </p>
                </div>
                <Button variant="outline" asChild>
                  <Link to="/communication">Zobrazit skupiny</Link>
                </Button>
              </div>
            </CardContent>
          </Card>
        )}

        {/* Staff Shifts Section */}
        {isStaff && myShifts.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle>Moje směny</CardTitle>
              <CardDescription>Přehled vašich přiřazených směn</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="space-y-4">
                {myShifts.slice(0, 5).map((shift) => (
                  <div key={shift.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/50">
                    <div>
                      <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                      <p className="text-sm text-muted-foreground">
                        {shift.event && format(new Date(shift.event.start_time), 'EEEE d. MMMM, HH:mm', { locale: cs })}
                      </p>
                    </div>
                    <Badge 
                      variant={shift.status === 'completed' ? 'default' : 'secondary'}
                    >
                      {shift.status === 'claimed' ? 'Přijato' : 
                       shift.status === 'completed' ? 'Dokončeno' : shift.status}
                    </Badge>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
};

export default Dashboard;
