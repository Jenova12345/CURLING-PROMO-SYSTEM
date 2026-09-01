import { useState } from 'react';
import { ShieldCheck } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Switch } from '@/components/ui/switch';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/components/ui/use-toast';
import { useAuth } from '@/contexts/AuthContext';
import { useMujKlub, type ClenKlubu } from '@/hooks/useMujKlub';

/**
 * „Můj klub" — pro ZÁSTUPCE klubu.
 *
 * Čistě čtecí seznam členů plus jediná pravomoc: udělit členovi „právo navíc"
 * (smí si sám potvrdit svoji rezervaci). Přidávat a odebírat členy zůstává
 * adminovi — rozhodnutí PM P3 z 31. 8. 2026, dokud se nedořeší politika
 * odchodu z klubu.
 */
const MujKlub = () => {
  const { toast } = useToast();
  const { isRep, isAdmin } = useAuth();
  const { kluby, isLoading, error, nastavPravoNavic, isBusy } = useMujKlub();

  // Potvrzovací krok „opravdu?" při UDĚLENÍ práva (R12).
  const [potvrzeni, setPotvrzeni] = useState<
    { subject_id: string; nazev: string; clen: ClenKlubu } | null
  >(null);

  if (!isRep && !isAdmin) {
    return <div className="p-6 text-muted-foreground">Tuhle stránku vidí správce klubu.</div>;
  }

  const prepni = async (subject_id: string, nazev: string, clen: ClenKlubu) => {
    // ODEBRÁNÍ práva se nepotvrzuje. Ubrat oprávnění je bezpečný směr a ptát se
    // na něj lidi jen učí odklikávat dialogy bez čtení. Potvrzuje se udělení.
    if (clen.muze_potvrzovat) {
      await proved(subject_id, clen, false);
      return;
    }
    setPotvrzeni({ subject_id, nazev, clen });
  };

  const proved = async (subject_id: string, clen: ClenKlubu, hodnota: boolean) => {
    try {
      await nastavPravoNavic({ subject_id, user_id: clen.user_id, hodnota });
      toast({
        title: hodnota ? 'Právo uděleno' : 'Právo odebráno',
        description: hodnota
          ? `${clen.jmeno} si teď může sám potvrdit svoji rezervaci.`
          : `${clen.jmeno} už si rezervaci sám nepotvrdí.`,
      });
    } catch (e) {
      toast({
        title: 'Nepovedlo se',
        description: e instanceof Error ? e.message : 'Zkuste to prosím znovu.',
        variant: 'destructive',
      });
    }
  };

  return (
    <div className="p-4 md:p-6 space-y-6">
      <div>
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
          <ShieldCheck className="h-7 w-7" /> Můj klub
        </h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Členové klubů, kterých jste správcem. Přidávat a odebírat členy může správce haly.
        </p>
      </div>

      {isLoading && <div className="text-muted-foreground">Načítám…</div>}
      {error && (
        <div className="text-destructive">
          Seznam se nepodařilo načíst. Zkuste stránku znovu načíst.
        </div>
      )}

      {!isLoading && !error && kluby.length === 0 && (
        <Card>
          <CardContent className="py-6 text-muted-foreground">
            Nejste správcem žádného klubu. Správce klubu jmenuje správce haly.
          </CardContent>
        </Card>
      )}

      {kluby.map((klub) => (
        <Card key={klub.subject_id}>
          <CardHeader>
            <CardTitle>{klub.nazev}</CardTitle>
            <CardDescription>
              „Smí si potvrdit rezervaci" znamená, že si člen sám potvrdí <strong>svoji</strong> rezervaci
              před akcí. Potvrzení akce po skončení, které spouští fakturaci a výplaty, zůstává
              vám a správci haly.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Jméno</TableHead>
                  <TableHead>Role v klubu</TableHead>
                  <TableHead>Smí si potvrdit rezervaci</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {klub.clenove.map((c) => (
                  <TableRow key={c.user_id}>
                    <TableCell className="font-medium">{c.jmeno}</TableCell>
                    <TableCell>{c.level === 'rep' ? 'Správce klubu' : 'Člen'}</TableCell>
                    <TableCell>
                      {c.level === 'rep' ? (
                        // Zástupce potvrzuje z titulu své úrovně, právo navíc
                        // by u něj nic neznamenalo — RPC ho ani nenastaví.
                        <span className="text-muted-foreground text-sm">z titulu správce klubu</span>
                      ) : (
                        <Switch
                          checked={c.muze_potvrzovat}
                          disabled={isBusy}
                          aria-label={`Právo potvrzovat rezervace pro ${c.jmeno}`}
                          onCheckedChange={() => prepni(klub.subject_id, klub.nazev, c)}
                        />
                      )}
                    </TableCell>
                  </TableRow>
                ))}
                {klub.clenove.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={3} className="text-muted-foreground">
                      Klub zatím nemá členy.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      ))}

      <AlertDialog open={!!potvrzeni} onOpenChange={(o) => !o && setPotvrzeni(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Dát právo potvrzovat rezervace?</AlertDialogTitle>
            <AlertDialogDescription>
              {potvrzeni && (
                <>
                  <strong>{potvrzeni.clen.jmeno}</strong> si pak sám potvrdí svoje rezervace
                  v klubu <strong>{potvrzeni.nazev}</strong> — bez čekání na vás.
                  <br /><br />
                  Cizí rezervace tím potvrzovat nezačne a na fakturaci ani výplaty právo nesahá.
                </>
              )}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zrušit</AlertDialogCancel>
            <AlertDialogAction
              onClick={async () => {
                if (!potvrzeni) return;
                const { subject_id, clen } = potvrzeni;
                setPotvrzeni(null);
                await proved(subject_id, clen, true);
              }}
            >
              Udělit právo
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default MujKlub;
