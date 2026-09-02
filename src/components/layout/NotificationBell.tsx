import { useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { formatDistanceToNow } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Bell, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { useToast } from '@/hooks/use-toast';
import { cn } from '@/lib/utils';
import { useNotifications, type Notification } from '@/hooks/useNotifications';

// Upozornění v aplikaci: zrušená akce (přebití komerční akcí), rezervace čekající
// na potvrzení zástupcem, potvrzení rezervace, přesun či zrušení rezervace.
// E-maily jsou zatím vypnuté.
export function NotificationBell({ className }: { className?: string }) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const { notifications, unreadCount, markRead, markAllRead, dismiss, dismissAllRead } =
    useNotifications();
  const seznamRef = useRef<HTMLDivElement>(null);
  const [hlaseni, setHlaseni] = useState('');

  const readCount = notifications.length - unreadCount;

  // KAŽDÁ AKCE MUSÍ BÝT SLYŠET, KDYŽ SELŽE.
  //
  // Původně tu visely holé `markAllRead()` a `dismissAllRead()` — plovoucí
  // promise bez `catch`. Mutace v hooku navíc nemají `onError`, takže ty
  // pečlivě napsané hlášky („Nepodařilo se…") nikdo nikdy neuviděl. Kdyby
  // zápis odmítla RLS nebo síť, tlačítko by se tvářilo, že nic nedělá — což
  // je PŘESNĚ ten symptom, kvůli kterému tahle oprava vznikla, jen s jinou
  // příčinou.
  const provest = async (akce: () => Promise<unknown>, popisChyby: string) => {
    try {
      await akce();
      return true;
    } catch (e) {
      toast({
        title: popisChyby,
        description: e instanceof Error ? e.message : undefined,
        variant: 'destructive',
      });
      return false;
    }
  };

  const open = async (n: Notification) => {
    if (!n.read_at) await provest(() => markRead([n.id]), 'Nepodařilo se označit jako přečtené');
    if (n.link) navigate(n.link);
  };

  const odklidit = async (n: Notification) => {
    if (!(await provest(() => dismiss([n.id]), 'Nepodařilo se upozornění odklidit'))) return;
    // FOKUS NESMÍ SPADNOUT NA <body>.
    //
    // Odklizená položka se odmountuje i s právě fokusovaným křížkem. Kdo jde
    // panelem z klávesnice, byl by tím vystrčený ven a další Tab by pokračoval
    // od začátku dokumentu. Vracíme fokus na seznam; čtečce to zároveň
    // oznámíme, protože zmizení řádku sama o sobě žádná událost není.
    seznamRef.current?.focus();
    setHlaseni(`Upozornění odklizeno: ${n.title}`);
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
              <Button
                variant="link" size="sm" className="h-auto p-0 text-xs"
                onClick={() => void provest(markAllRead, 'Nepodařilo se označit upozornění jako přečtená')}
              >
                Označit přečtené
              </Button>
            )}
            {readCount > 0 && (
              <Button
                variant="link" size="sm" className="h-auto p-0 text-xs"
                onClick={() => void provest(dismissAllRead, 'Nepodařilo se odklidit přečtená upozornění')}
              >
                Uklidit přečtené
              </Button>
            )}
          </div>
        </div>

        {/*
          ROLOVÁNÍ SCHVÁLNĚ BEZ `ScrollArea`.
          Radixový `ScrollArea` má na kořeni `overflow-hidden` a uvnitř viewport
          s `h-full`. Kořen s `max-h-80` má ale `height: auto`, a `height: 100%`
          se proti takovému rodiči rezolvuje taky na `auto` — viewport naroste
          na celou výšku obsahu, přetečení uvnitř nikdy nevznikne a `overflow-
          hidden` obsah jen OŘÍZNE. Přesně Jakubův symptom „mám 9 upozornění,
          vidím 4 a nedá se posunout". Obyčejný `overflow-y-auto` roluje
          a při jednom upozornění nedělá z panelu prázdných 320 px.
          `overscroll-contain` drží scroll uvnitř panelu.
        */}
        <div
          ref={seznamRef}
          tabIndex={-1}
          className="max-h-80 overflow-y-auto overscroll-contain outline-none"
        >
          {notifications.length === 0 ? (
            <p className="p-4 text-sm text-muted-foreground">Zatím žádná upozornění.</p>
          ) : (
            <ul className="divide-y">
              {notifications.map((n) => (
                <li key={n.id} className={cn('relative', !n.read_at && 'bg-primary/5')}>
                  <button
                    type="button"
                    onClick={() => void open(n)}
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
                  {/* Křížek je SOUROZENEC hlavního tlačítka, ne potomek — tlačítko
                      v tlačítku je neplatné HTML a klik by probublal do `open`.
                      Místo mu drží `pr-9` na hlavním tlačítku. */}
                  <button
                    type="button"
                    aria-label={`Odklidit upozornění: ${n.title}`}
                    title="Odklidit"
                    onClick={() => void odklidit(n)}
                    className="absolute right-1 top-1.5 rounded p-1 text-muted-foreground opacity-60 hover:bg-accent hover:text-foreground hover:opacity-100 focus-visible:opacity-100"
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        <span aria-live="polite" className="sr-only">{hlaseni}</span>
      </PopoverContent>
    </Popover>
  );
}
