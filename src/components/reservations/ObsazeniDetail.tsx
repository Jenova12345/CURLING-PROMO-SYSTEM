import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { useToast } from '@/components/ui/use-toast';
import { useShifts } from '@/hooks/useShifts';
import { useShiftApplications } from '@/hooks/useShiftApplications';

const ROLE_LABELS: Record<string, string> = {
  instructor: 'Instruktor', bar_staff: 'Obsluha baru', manager: 'Provozní hospoda',
};

// Detail obsazení komerční akce: kdo se přihlásil / je potvrzený, po rolích.
// Reuse stávajícího toku shift_applications (přihláška → schválení). Admin potvrzuje.
export function ObsazeniDetail({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const { shifts } = useShifts();
  const { applicationsByShift, approveApplication, isApproving } = useShiftApplications();

  const eventShifts = (shifts as Array<Record<string, unknown>>).filter((s) => s.event_id === eventId);
  if (eventShifts.length === 0) return null;

  const approve = async (appId: string) => {
    try {
      await approveApplication(appId);
      toast({ title: 'Přihláška potvrzena' });
    } catch (e) {
      toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Nepodařilo se potvrdit.', variant: 'destructive' });
    }
  };

  return (
    <div className="mt-2 space-y-2 border-t pt-2">
      <div className="text-xs font-medium">Obsazení směn</div>
      {eventShifts.map((sh) => {
        const id = sh.id as string;
        const role = sh.required_role as string | null;
        const status = sh.status as string;
        const claimedName = (sh.claimed_profile as { full_name?: string } | null)?.full_name;
        const apps = (applicationsByShift[id] ?? []).filter((a) => a.status === 'pending');
        return (
          <div key={id} className="rounded border p-1.5 text-xs">
            <div className="font-medium">{(role && ROLE_LABELS[role]) || role || 'Směna'}</div>
            {status === 'claimed' || status === 'completed' ? (
              <div className="text-green-700">Potvrzen: {claimedName ?? '—'}</div>
            ) : status === 'cancelled' ? (
              <div className="text-muted-foreground">Zrušeno</div>
            ) : apps.length ? (
              apps.map((a) => (
                <div key={a.id} className="flex items-center justify-between gap-2">
                  <span>{a.applicant_name} <span className="text-muted-foreground">(čeká)</span></span>
                  <Button size="sm" variant="outline" className="h-6 px-2" disabled={isApproving} onClick={() => approve(a.id)}>Potvrdit</Button>
                </div>
              ))
            ) : (
              <div className="text-muted-foreground">Zatím bez přihlášek</div>
            )}
          </div>
        );
      })}
      <Link to="/shifts" className="text-xs text-primary underline">Správa směn →</Link>
    </div>
  );
}
