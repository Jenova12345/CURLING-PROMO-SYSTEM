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
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold">Oznámení</h1>
          <p className="text-muted-foreground mt-1">
            {unreadCount > 0 
              ? `Máte ${unreadCount} nepřečtených oznámení` 
              : 'Všechna oznámení přečtena'}
          </p>
        </div>
        
        {unreadCount > 0 && (
          <Button variant="outline" onClick={() => markAllAsRead()}>
            <CheckCheck className="h-4 w-4 mr-2" />
            Označit vše jako přečtené
          </Button>
        )}
      </div>

      {/* Notifications List */}
      <Card>
        <CardHeader>
          <CardTitle>Všechna oznámení</CardTitle>
          <CardDescription>Vaše upozornění a zprávy</CardDescription>
        </CardHeader>
        <CardContent>
          {notifications.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12">
              <Bell className="h-12 w-12 text-muted-foreground mb-4" />
              <p className="text-muted-foreground">Nemáte žádná oznámení</p>
            </div>
          ) : (
            <div className="space-y-4">
              {notifications.map((notification) => (
                <div
                  key={notification.id}
                  className={`flex items-start gap-4 p-4 rounded-lg transition-colors ${
                    notification.read ? 'bg-muted/30' : 'bg-primary/5 border-l-4 border-primary'
                  }`}
                >
                  <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${
                    notification.read ? 'bg-muted-foreground/30' : 'bg-primary'
                  }`} />
                  
                  <div className="flex-1 min-w-0">
                    <div className="flex items-start justify-between gap-4">
                      <div>
                        <p className="font-medium">{notification.title}</p>
                        <p className="text-sm text-muted-foreground mt-1">
                          {notification.message}
                        </p>
                        <p className="text-xs text-muted-foreground mt-2">
                          {format(new Date(notification.created_at), 'EEEE d. MMMM yyyy, HH:mm', { locale: cs })}
                        </p>
                      </div>
                      
                      <div className="flex items-center gap-2 flex-shrink-0">
                        {notification.type && (
                          <Badge variant="outline" className="capitalize">
                            {notification.type === 'shift' ? 'Směna' : notification.type}
                          </Badge>
                        )}
                        
                        {!notification.read && (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => markAsRead(notification.id)}
                          >
                            <Check className="h-4 w-4" />
                          </Button>
                        )}
                      </div>
                    </div>
                    
                    {notification.link && (
                      <Link 
                        to={notification.link}
                        className="text-sm text-primary hover:underline mt-2 inline-block"
                      >
                        Zobrazit detail →
                      </Link>
                    )}
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
