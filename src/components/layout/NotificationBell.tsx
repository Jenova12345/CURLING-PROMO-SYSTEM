import { useNavigate } from 'react-router-dom';
import { formatDistanceToNow } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Bell, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { cn } from '@/lib/utils';
import { useNotifications, type Notification } from '@/hooks/useNotifications';

// Upozornění v aplikaci: zrušená akce (přebití komerční akcí), rezervace čekající
// na potvrzení zástupcem, potvrzení rezervace, přesun či zrušení rezervace.
// E-maily jsou zatím vypnuté.
export function NotificationBell({ className }: { className?: string }) {
  const navigate = useNavigate();
  const { notifications, unreadCount, markRead, markAllRead, dismiss, dismissAllRead } =
    useNotifications();

  const readCount = notifications.length - unreadCount;

  const open = async (n: Notification) => {
    if (!n.read_at) await markRead([n.id]).catch(() => undefined);
    if (n.link) navigate(n.link);
  };

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="icon" className={cn('relative', className)} aria-label="Upozornění">
          <Bell className="h-5 w-5" />
          {unreadCount > 0 && (
            <span className="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-bold text-destructive-foreground">
              {unreadCount > 9 ? '9+' : unreadCount}
            </span>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-80 p-0">
        <div className="flex items-center justify-between gap-2 border-b p-3">
          <span className="text-sm font-medium">
            Upozornění
            {notifications.length > 0 && (
              <span className="ml-1 font-normal text-muted-foreground">({notifications.length})</span>
            )}
          </span>
          <div className="flex shrink-0 items-center gap-3">
            {unreadCount > 0 && (
              <Button variant="link" size="sm" className="h-auto p-0 text-xs" onClick={() => markAllRead()}>
                Označit přečtené
              </Button>
            )}
            {readCount > 0 && (
              <Button variant="link" size="sm" className="h-auto p-0 text-xs" onClick={() => dismissAllRead()}>
                Uklidit přečtené
              </Button>
            )}
          </div>
        </div>

        {/*
          ROLOVÁNÍ SCHVÁLNĚ BEZ `ScrollArea`.
          Radixový `ScrollArea` má na kořeni `overflow-hidden` a uvnitř viewport
          s `h-full`. S `max-h-80` na kořeni tedy `h-full` nemá vůči čemu
          dopočítat výšku, přetečení nevznikne a obsah se jen OŘÍZNE — přesně
          Jakubův symptom „mám 9 upozornění, vidím 4 a nedá se posunout".
          Obyčejný `overflow-y-auto` na seznamu roluje a při jednom upozornění
          nedělá z panelu prázdných 320 px.
        */}
        <div className="max-h-80 overflow-y-auto overscroll-contain">
          {notifications.length === 0 ? (
            <p className="p-4 text-sm text-muted-foreground">Zatím žádná upozornění.</p>
          ) : (
            <ul className="divide-y">
              {notifications.map((n) => (
                <li key={n.id} className={cn('relative group', !n.read_at && 'bg-primary/5')}>
                  <button
                    type="button"
                    onClick={() => open(n)}
                    className="w-full py-2 pl-3 pr-9 text-left hover:bg-accent"
                  >
                    <div className="flex items-start gap-2">
                      {!n.read_at && <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-primary" />}
                      <div className={cn('min-w-0', n.read_at && 'pl-4')}>
                        <p className="text-sm font-medium">{n.title}</p>
                        {n.body && <p className="text-xs text-muted-foreground">{n.body}</p>}
                        <p className="mt-0.5 text-[11px] text-muted-foreground">
                          {formatDistanceToNow(new Date(n.created_at), { addSuffix: true, locale: cs })}
                        </p>
                      </div>
                    </div>
                  </button>
                  {/* Odklidit jednotlivé upozornění — typicky to ke zrušené rezervaci,
                      které jsem si přečetl a dál ho ve schránce nechci. */}
                  <button
                    type="button"
                    aria-label={`Odklidit upozornění: ${n.title}`}
                    title="Odklidit"
                    onClick={() => dismiss([n.id]).catch(() => undefined)}
                    className="absolute right-1 top-1.5 rounded p-1 text-muted-foreground opacity-60 hover:bg-accent hover:text-foreground hover:opacity-100 focus-visible:opacity-100"
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </PopoverContent>
    </Popover>
  );
}
