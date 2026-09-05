import { useState } from 'react';
import { ShieldCheck } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Switch } from '@/components/ui/switch';
import { Button } from '@/components/ui/button';
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
 * Seznam členů a pravomoci zástupce nad vlastním klubem:
 *   • udělit členovi „právo navíc" (smí si sám potvrdit svoji rezervaci),
 *   • jmenovat dalšího správce klubu (`jmenuj_spravce_klubu`, od 4. 9. 2026),
 *   • přijmout nového člena — ale jen SCHVÁLENÍM ŽÁDOSTI na stránce „Žádosti"
 *     (`approve_subject_request`); přímý zápis do `subject_reps` má v RLS
 *     `subject_reps_insert_admin`, tedy jen admin.
 *
 * ODEBRAT člena zástupce nemůže: `subject_reps_delete_admin` pouští jen
 * admina a žádná SECURITY DEFINER funkce na odebrání neexistuje (ověřeno
 * 5. 9. 2026). Původní znění téhle poznámky tvrdilo, že adminovi zůstává
 * i přidávání — to od zavedení schvalovací fronty neplatí.
 */
const MujKlub = () => {
  const { toast } = useToast();
  const { isRep, isAdmin } = useAuth();
  const { kluby, isLoading, error, nastavPravoNavic, jmenujSpravce, isBusy } = useMujKlub();

  // Potvrzovací krok „opravdu?" při UDĚLENÍ práva (R12).
  const [potvrzeni, setPotvrzeni] = useState<
    { subject_id: string; nazev: string; clen: ClenKlubu } | null
  >(null);

  // Jmenování správce se potvrzuje VŽDY: přes tuhle stránku ho nejde vzít zpět
  // (`jmenuj_spravce_klubu` povyšuje jen ze `member`, degradovat neumí) a nový
  // správce může jmenovat další. Odebrat ho umí jen správce haly.
  const [jmenovani, setJmenovani] = useState<
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
          Členové klubů, kterých jste správcem. Nové členy přijmete schválením jejich
          žádosti na stránce „Žádosti"; odebrat člena může jen správce haly.
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
                  <TableHead>Správa klubu</TableHead>
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
                    <TableCell>
                      {c.level === 'rep' ? (
                        <span className="text-muted-foreground text-sm">už je správce</span>
                      ) : (
                        <Button
                          variant="outline" size="sm" disabled={isBusy}
                          onClick={() => setJmenovani({ subject_id: klub.subject_id, nazev: klub.nazev, clen: c })}
                        >
                          Jmenovat správcem
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
                {klub.clenove.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={4} className="text-muted-foreground">
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

      <AlertDialog open={!!jmenovani} onOpenChange={(o) => !o && setJmenovani(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Jmenovat správcem klubu?</AlertDialogTitle>
            <AlertDialogDescription>
              {jmenovani && (
                <>
                  <strong>{jmenovani.clen.jmeno}</strong> bude správce klubu{' '}
                  <strong>{jmenovani.nazev}</strong> — bude schvalovat žádosti o členství,
                  potvrzovat rezervace klubu a <strong>jmenovat další správce</strong>.
                  <br /><br />
                  Na ceny, faktury ani na jiné kluby to nesahá. Odebrat správce klubu
                  ale přes tuhle stránku nejde — musel by o to požádat správce haly.
                </>
              )}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zrušit</AlertDialogCancel>
            <AlertDialogAction
              onClick={async () => {
                if (!jmenovani) return;
                const { subject_id, clen } = jmenovani;
                setJmenovani(null);
                try {
                  await jmenujSpravce({ subject_id, user_id: clen.user_id });
                  toast({
                    title: 'Správce jmenován',
                    description: `${clen.jmeno} je teď správce klubu.`,
                  });
                } catch (e) {
                  toast({
                    title: 'Nepovedlo se',
                    description: e instanceof Error ? e.message : 'Zkuste to prosím znovu.',
                    variant: 'destructive',
                  });
                }
              }}
            >
              Jmenovat správcem
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default MujKlub;
