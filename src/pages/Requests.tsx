import { useState } from 'react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { UserPlus, Check, X, AlertTriangle } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/components/ui/use-toast';
import { useSubjectRequests, type RepLevel, type SubjectRequest } from '@/hooks/useSubjectRequests';

const STAV: Record<string, { text: string; trida?: string }> = {
  ceka: { text: 'Čeká' },
  schvalena: { text: 'Schváleno', trida: 'border-emerald-300 bg-emerald-100 text-emerald-900 hover:bg-emerald-100' },
  zamitnuta: { text: 'Zamítnuto' },
};

const kdy = (d: string | null) => (d ? format(new Date(d), 'd. M. yyyy HH:mm', { locale: cs }) : '—');

const Requests = () => {
  const { isAdmin, isRep } = useAuth();
  const { toast } = useToast();
  const { requests, cekajici, isLoading, error, approve, reject, isBusy } = useSubjectRequests();
  // Úroveň se volí PRO KAŽDOU ŽÁDOST ZVLÁŠŤ, ne globálně: zástupce je výjimka,
  // a jedno společné rozbalovátko by svádělo k tomu udělat zástupce ze všech.
  const [uroven, setUroven] = useState<Record<string, RepLevel>>({});

  // Frontu vyřizuje i ZÁSTUPCE KLUBU (blok C, R5) — vidí v ní jen žádosti do
  // svých klubů, o což se stará politika na `subject_requests`, ne tahle
  // podmínka. Tady jde jen o to, komu se stránka vůbec ukáže.
  if (!isAdmin && !isRep) {
    return <div className="p-6 text-muted-foreground">Žádosti o přiřazení vyřizuje správce haly nebo zástupce klubu.</div>;
  }

  const schval = async (z: SubjectRequest) => {
    const level = uroven[z.id!] ?? 'member';
    if (level === 'rep' && !window.confirm(
      `Udělat ze žadatele „${z.zadatel}" ZÁSTUPCE klubu ${z.klub}?\n\n`
      + 'Zástupce potvrzuje rezervace ostatních členů klubu a rezervuje za celý klub.',
    )) return;

    try {
      await approve({ id: z.id!, level });
      toast({
        title: 'Přiřazeno',
        description: `${z.zadatel} → ${z.klub} (${level === 'rep' ? 'zástupce' : 'člen'}).`,
      });
    } catch (e) {
      toast({ title: 'Nepovedlo se', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const zamitni = async (z: SubjectRequest) => {
    const duvod = window.prompt(`Zamítnout žádost „${z.zadatel}" o klub ${z.klub}?\n\nDůvod (nepovinný):`);
    if (duvod === null) return;   // uživatel dal Storno
    try {
      await reject({ id: z.id!, duvod: duvod || undefined });
      toast({ title: 'Žádost zamítnuta' });
    } catch (e) {
      toast({ title: 'Nepovedlo se', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const vyrizene = requests.filter((r) => r.status !== 'ceka');

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div>
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
          <UserPlus className="h-6 w-6" /> Žádosti
        </h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Lidé, kteří si při registraci vybrali klub. Schválením vzniká členství —
          do té doby nemají k rezervacím klubu přístup.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            Čeká na vyřízení {cekajici.length > 0 && <Badge className="ml-2">{cekajici.length}</Badge>}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="text-muted-foreground">Načítám…</div>
          ) : error ? (
            <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
              <span>Žádosti se nepodařilo načíst: {error.message}</span>
            </div>
          ) : cekajici.length === 0 ? (
            <div className="text-muted-foreground text-sm">Žádná žádost nečeká.</div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Jméno</TableHead>
                  <TableHead>Klub</TableHead>
                  <TableHead>Podáno</TableHead>
                  <TableHead>Poznámka</TableHead>
                  <TableHead>Úroveň</TableHead>
                  <TableHead className="text-right">Akce</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {cekajici.map((z) => (
                  <TableRow key={z.id}>
                    <TableCell className="font-medium">{z.zadatel}</TableCell>
                    <TableCell>{z.klub}</TableCell>
                    <TableCell className="whitespace-nowrap">{kdy(z.created_at)}</TableCell>
                    <TableCell className="max-w-xs text-sm text-muted-foreground">{z.poznamka ?? '—'}</TableCell>
                    <TableCell>
                      <select
                        aria-label={`Úroveň pro ${z.zadatel}`}
                        className="h-9 rounded-md border border-input bg-background px-2 text-sm"
                        value={uroven[z.id!] ?? 'member'}
                        onChange={(e) => setUroven((u) => ({ ...u, [z.id!]: e.target.value as RepLevel }))}
                      >
                        <option value="member">člen</option>
                        {/* Zástupce smí jmenovat JEN admin (blok C) — zástupci se
                            ta volba ani nenabízí, aby nenarazil na chybu z databáze. */}
                        {isAdmin && <option value="rep">zástupce</option>}
                      </select>
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-1">
                        <Button size="sm" disabled={isBusy} onClick={() => schval(z)}>
                          <Check className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Schválit
                        </Button>
                        <Button size="sm" variant="outline" disabled={isBusy}
                                aria-label={`Zamítnout žádost ${z.zadatel}`}
                                onClick={() => zamitni(z)}>
                          <X className="h-3.5 w-3.5" aria-hidden="true" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {vyrizene.length > 0 && (
        <Card>
          <CardHeader><CardTitle className="text-base">Vyřízené</CardTitle></CardHeader>
          <CardContent>
            {/* Historie se nemaže: „kdo koho pustil do klubu" je přesně to, na co
                se za půl roku někdo ptá. */}
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Jméno</TableHead>
                  <TableHead>Klub</TableHead>
                  <TableHead>Stav</TableHead>
                  <TableHead>Úroveň</TableHead>
                  <TableHead>Vyřízeno</TableHead>
                  <TableHead>Důvod</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {vyrizene.map((z) => (
                  <TableRow key={z.id}>
                    <TableCell className="font-medium">{z.zadatel}</TableCell>
                    <TableCell>{z.klub}</TableCell>
                    <TableCell>
                      <Badge variant={z.status === 'zamitnuta' ? 'outline' : 'default'}
                             className={STAV[z.status ?? '']?.trida}>
                        {STAV[z.status ?? '']?.text ?? z.status}
                      </Badge>
                    </TableCell>
                    <TableCell>{z.uroven === 'rep' ? 'zástupce' : z.uroven === 'member' ? 'člen' : '—'}</TableCell>
                    <TableCell className="whitespace-nowrap">{kdy(z.decided_at)}</TableCell>
                    <TableCell className="text-sm text-muted-foreground">{z.decision_reason ?? '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </div>
  );
};

export default Requests;
