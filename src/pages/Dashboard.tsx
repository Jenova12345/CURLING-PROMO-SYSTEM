import { useAuth } from '@/contexts/AuthContext';
import { useEvents } from '@/hooks/useEvents';
import { useShifts } from '@/hooks/useShifts';
import { useNotifications } from '@/hooks/useNotifications';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Calendar, Clock, Bell, TrendingUp } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';

const Dashboard = () => {
  const { profile, role, isAdmin, isStaff } = useAuth();
  const { events } = useEvents();
  const { openShifts, myShifts, totalHoursWorked, totalEarnings } = useShifts();
  const { notifications, unreadCount } = useNotifications();

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
    free: 'bg-gray-500',
  };

  const eventTypeLabels: Record<string, string> = {
    commercial: 'Komerční',
    training: 'Trénink',
    maintenance: 'Údržba',
    free: 'Volný',
  };

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-3xl font-bold">
          Vítejte, {profile?.full_name || 'uživateli'}! 👋
        </h1>
        <p className="text-muted-foreground mt-1">
          Přehled vašeho účtu a nadcházejících událostí
        </p>
      </div>

      {/* Stats Grid */}
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Vaše role</CardTitle>
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

        {!isStaff && (
          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Oznámení</CardTitle>
              <Bell className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{unreadCount}</div>
              <p className="text-xs text-muted-foreground">
                nepřečtených
              </p>
            </CardContent>
          </Card>
        )}
      </div>

      {/* Content Grid */}
      <div className="grid gap-6 lg:grid-cols-2">
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

        {/* Recent Notifications */}
        <Card>
          <CardHeader>
            <CardTitle>Poslední oznámení</CardTitle>
            <CardDescription>Vaše nedávná upozornění</CardDescription>
          </CardHeader>
          <CardContent>
            {notifications.length === 0 ? (
              <p className="text-muted-foreground text-sm">Žádná oznámení</p>
            ) : (
              <div className="space-y-4">
                {notifications.slice(0, 5).map((notification) => (
                  <div key={notification.id} className="flex items-start gap-4">
                    <div className={`w-2 h-2 rounded-full mt-2 ${notification.read ? 'bg-muted' : 'bg-primary'}`} />
                    <div className="flex-1 min-w-0">
                      <p className="font-medium truncate">{notification.title}</p>
                      <p className="text-sm text-muted-foreground line-clamp-2">
                        {notification.message}
                      </p>
                      <p className="text-xs text-muted-foreground mt-1">
                        {format(new Date(notification.created_at), 'd. MMMM HH:mm', { locale: cs })}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

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
  );
};

export default Dashboard;
