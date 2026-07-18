import { Link } from 'react-router-dom';
import { CalendarCheck, LogIn } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

// Minimalistický veřejný vstup do systému (odkaz z webu i odjinud).
const Portal = () => (
  <div className="min-h-screen flex items-center justify-center bg-muted/30 p-4">
    <Card className="w-full max-w-md text-center">
      <CardContent className="pt-8 pb-8 space-y-5">
        <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-primary text-primary-foreground">
          <CalendarCheck className="h-7 w-7" />
        </div>
        <div>
          <h1 className="text-2xl font-bold">Mladé kameny — rezervační systém</h1>
          <p className="text-muted-foreground mt-2 text-sm">
            Rezervace ledu, komerční akce a směny na jednom místě. Pro vstup se přihlas.
          </p>
        </div>
        <div className="flex flex-col gap-2">
          <Button asChild className="w-full">
            <Link to="/calendar"><CalendarCheck className="h-4 w-4 mr-2" /> Vstoupit do kalendáře</Link>
          </Button>
          <Button asChild variant="outline" className="w-full">
            <Link to="/auth"><LogIn className="h-4 w-4 mr-2" /> Přihlásit se</Link>
          </Button>
        </div>
        <p className="text-xs text-muted-foreground">Přístup jen pro přihlášené (kluby, brigádníci, správce).</p>
      </CardContent>
    </Card>
  </div>
);

export default Portal;
