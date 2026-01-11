import { useNotifications } from '@/hooks/useNotifications';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Bell, Check, CheckCheck } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Link } from 'react-router-dom';

const Notifications = () => {
  const { notifications, isLoading, unreadCount, markAsRead, markAllAsRead } = useNotifications();

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
      </div>
    );
  }

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold">Oznámení</h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">
            {unreadCount > 0 
              ? `Máte ${unreadCount} nepřečtených oznámení` 
              : 'Všechna oznámení přečtena'}
          </p>
        </div>
        
        {unreadCount > 0 && (
          <Button variant="outline" onClick={() => markAllAsRead()} className="w-full sm:w-auto">
            <CheckCheck className="h-4 w-4 mr-2" />
            <span className="hidden sm:inline">Označit vše jako přečtené</span>
            <span className="sm:hidden">Přečíst vše</span>
          </Button>
        )}
      </div>

      {/* Notifications List */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-lg md:text-xl">Všechna oznámení</CardTitle>
          <CardDescription>Vaše upozornění a zprávy</CardDescription>
        </CardHeader>
        <CardContent>
          {notifications.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12">
              <Bell className="h-12 w-12 text-muted-foreground mb-4" />
              <p className="text-muted-foreground">Nemáte žádná oznámení</p>
            </div>
          ) : (
            <div className="space-y-3">
              {notifications.map((notification) => (
                <div
                  key={notification.id}
                  className={`p-3 md:p-4 rounded-lg transition-colors ${
                    notification.read ? 'bg-muted/30' : 'bg-primary/5 border-l-4 border-primary'
                  }`}
                >
                  <div className="flex items-start gap-3">
                    <div className={`w-2.5 h-2.5 rounded-full mt-1.5 flex-shrink-0 ${
                      notification.read ? 'bg-muted-foreground/30' : 'bg-primary'
                    }`} />
                    
                    <div className="flex-1 min-w-0">
                      <div className="flex flex-col sm:flex-row sm:items-start justify-between gap-2">
                        <div className="flex-1 min-w-0">
                          <p className="font-medium text-sm md:text-base">{notification.title}</p>
                          <p className="text-xs md:text-sm text-muted-foreground mt-1">
                            {notification.message}
                          </p>
                          <p className="text-[10px] md:text-xs text-muted-foreground mt-2">
                            {format(new Date(notification.created_at), 'EEE d. MMM, HH:mm', { locale: cs })}
                          </p>
                        </div>
                        
                        <div className="flex items-center gap-2 flex-shrink-0">
                          {notification.type && (
                            <Badge variant="outline" className="capitalize text-xs">
                              {notification.type === 'shift' ? 'Směna' : notification.type}
                            </Badge>
                          )}
                          
                          {!notification.read && (
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => markAsRead(notification.id)}
                              className="h-8 w-8 p-0"
                            >
                              <Check className="h-4 w-4" />
                            </Button>
                          )}
                        </div>
                      </div>
                      
                      {notification.link && (
                        <Link 
                          to={notification.link}
                          className="text-xs md:text-sm text-primary hover:underline mt-2 inline-block"
                        >
                          Zobrazit detail →
                        </Link>
                      )}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
};

export default Notifications;
