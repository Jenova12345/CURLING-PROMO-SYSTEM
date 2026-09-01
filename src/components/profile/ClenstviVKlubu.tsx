import { useEffect, useState } from 'react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Users, Clock, CheckCircle2, XCircle } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/components/ui/use-toast';
import { useSubjectRequests } from '@/hooks/useSubjectRequests';

/**
 * Členství v klubu na profilu — a hlavně cesta, jak o něj požádat dodatečně.
 *
 * Klub se vybírá při registraci, jenže je nepovinný: hobby hráč se přihlásí bez
 * něj a do klubu se přidá až později. Bez tohohle by neměl kudy — RPC pro podání
 * žádosti existovalo, ale nevolala ho žádná stránka, takže „doplním si klub
 * potom" byla slepá cesta.
 *
 * Členství se tu NEPŘIDĚLUJE, jen se o něj žádá. Schvaluje admin ve frontě
 * „Žádosti" a spolu se schválením přiděluje úroveň (člen / zástupce).
 */
const ClenstviVKlubu = () => {
  const { user } = useAuth();
  const { toast } = useToast();
  const { requests, request, isBusy } = useSubjectRequests();

  const [kluby, setKluby] = useState<{ id: string; name: string }[]>([]);
  const [klub, setKlub] = useState('');
  const [poznamka, setPoznamka] = useState('');
  const [clenstvi, setClenstvi] = useState<{ nazev: string; uroven: string }[]>([]);

  useEffect(() => {
    let zivy = true;
    supabase.from('clubs_public').select('id, name').order('name').then(({ data }) => {
      if (zivy && data) setKluby(data as { id: string; name: string }[]);
    });
    return () => { zivy = false; };
  }, []);

  // Vlastní členství. Čte se přes `subject_reps` + `clubs_public`, protože na
  // `subjects` běžný člen nedosáhne (jsou tam IČO, adresy a sazby).
  useEffect(() => {
    if (!user) return;
    let zivy = true;
    (async () => {
      const { data: reps } = await supabase.from('subject_reps')
        .select('subject_id, level').eq('user_id', user.id);
      if (!zivy || !reps?.length) { setClenstvi([]); return; }
      const { data: nazvy } = await supabase.from('clubs_public')
        .select('id, name').in('id', reps.map((r) => r.subject_id));
      if (!zivy) return;
      setClenstvi(reps.map((r) => ({
        nazev: nazvy?.find((n) => n.id === r.subject_id)?.name ?? '(klub už neexistuje)',
        uroven: r.level === 'rep' ? 'správce klubu' : 'člen',
      })));
    })();
    return () => { zivy = false; };
  }, [user, requests]);

  const cekajici = requests.find((r) => r.status === 'ceka');
  // Jen poslední vyřízená: historie rozhodnutí patří adminovi, ne žadateli.
  const posledniVyrizena = requests
    .filter((r) => r.status !== 'ceka')
    .sort((a, b) => (b.decided_at ?? '').localeCompare(a.decided_at ?? ''))[0];

  const posli = async () => {
    if (!klub) return;
    try {
      await request({ subjectId: klub, poznamka: poznamka.trim() || undefined });
      setKlub(''); setPoznamka('');
      toast({
        title: 'Žádost odeslána',
        description: 'Správce haly ji vyřídí. Do té doby k rezervacím klubu přístup nemáš.',
      });
    } catch (e) {
      // Hlášky z RPC jsou české a konkrétní („Jedna žádost už čeká na vyřízení.“),
      // tak se ukazují tak, jak přišly.
      toast({ title: 'Žádost se nepodařilo podat', description: (e as Error).message, variant: 'destructive' });
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <Users className="h-4 w-4" aria-hidden="true" /> Členství v klubu
        </CardTitle>
        <CardDescription>
          Členství potvrzuje správce haly. Do té doby vidíš halu jako host.
        </CardDescription>
      </CardHeader>

      <CardContent className="space-y-4">
        {clenstvi.length > 0 && (
          <div className="space-y-2">
            {clenstvi.map((c) => (
              <div key={c.nazev} className="flex items-center gap-2 text-sm">
                <CheckCircle2 className="h-4 w-4 text-emerald-600" aria-hidden="true" />
                <span className="font-medium">{c.nazev}</span>
                <Badge variant="secondary">{c.uroven}</Badge>
              </div>
            ))}
          </div>
        )}

        {cekajici ? (
          // Čekající žádost NENÍ formulář: databáze pustí jen jednu, takže druhé
          // odeslání by skončilo chybou. Místo toho se ukáže, na čem se čeká.
          <div className="flex items-start gap-2 rounded-md border bg-muted/40 p-3 text-sm">
            <Clock className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <div>
              <div>Žádost o klub <strong>{cekajici.klub}</strong> čeká na vyřízení.</div>
              <div className="text-muted-foreground text-xs mt-0.5">
                Podáno {cekajici.created_at
                  ? format(new Date(cekajici.created_at), 'd. M. yyyy', { locale: cs })
                  : '—'}. Další žádost jde podat, až tuhle správce vyřídí.
              </div>
            </div>
          </div>
        ) : (
          <>
            {posledniVyrizena?.status === 'zamitnuta' && (
              <div className="flex items-start gap-2 rounded-md border p-3 text-sm">
                <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                <div>
                  <div>Předchozí žádost o {posledniVyrizena.klub} byla zamítnuta.</div>
                  {posledniVyrizena.decision_reason && (
                    <div className="text-muted-foreground text-xs mt-0.5">
                      Důvod: {posledniVyrizena.decision_reason}
                    </div>
                  )}
                </div>
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="klub-vyber">
                {clenstvi.length > 0 ? 'Požádat o další klub' : 'Vybrat klub'}
              </Label>
              <select
                id="klub-vyber"
                className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={klub}
                onChange={(e) => setKlub(e.target.value)}
              >
                <option value="">— vyber klub —</option>
                {kluby
                  .filter((k) => !clenstvi.some((c) => c.nazev === k.name))
                  .map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
              </select>
            </div>

            <div className="space-y-2">
              <Label htmlFor="klub-poznamka">Poznámka pro správce (nepovinná)</Label>
              <Input
                id="klub-poznamka"
                value={poznamka}
                maxLength={500}
                placeholder="Např. chodím na úterní tréninky"
                onChange={(e) => setPoznamka(e.target.value)}
              />
            </div>

            <Button disabled={!klub || isBusy} onClick={posli}>
              Požádat o členství
            </Button>
          </>
        )}
      </CardContent>
    </Card>
  );
};

export default ClenstviVKlubu;
