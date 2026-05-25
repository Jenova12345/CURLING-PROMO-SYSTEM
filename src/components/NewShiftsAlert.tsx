import { useEffect, useMemo, useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useShifts } from '@/hooks/useShifts';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Bell, X } from 'lucide-react';
import { Link } from 'react-router-dom';

const STAFF_ROLES = ['part_time_staff', 'instructor', 'bar_staff', 'manager'];

export const NewShiftsAlert = () => {
  const { user, roles, isStaff } = useAuth();
  const { openShifts } = useShifts();

  const relevantOpenShifts = useMemo(() => {
    const now = Date.now();
    return openShifts
      .filter((s: any) => {
        if (!s.event?.start_time) return false;
        if (new Date(s.event.start_time).getTime() <= now) return false;
        const req = s.required_role;
        if (!req) return true;
        return roles.includes(req);
      })
      .map((s: any) => s.id)
      .sort();
  }, [openShifts, roles]);

  const currentHash = useMemo(
    () => relevantOpenShifts.join(','),
    [relevantOpenShifts]
  );

  const storageKey = user ? `newShiftsSeenHash:${user.id}` : '';
  const [dismissed, setDismissed] = useState(true);

  useEffect(() => {
    if (!storageKey) return;
    const seen = localStorage.getItem(storageKey) || '';
    setDismissed(seen === currentHash || relevantOpenShifts.length === 0);
  }, [storageKey, currentHash, relevantOpenShifts.length]);

  if (!isStaff || dismissed || relevantOpenShifts.length === 0) return null;

  const handleDismiss = () => {
    if (storageKey) localStorage.setItem(storageKey, currentHash);
    setDismissed(true);
  };

  return (
    <Alert className="border-primary/40 bg-primary/5">
      <Bell className="h-4 w-4" />
      <AlertTitle>Jsou vypsány nové směny!</AlertTitle>
      <AlertDescription className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <span>🔔 Podívejte se do nabídky a přihlaste se.</span>
        <div className="flex gap-2">
          <Button asChild size="sm">
            <Link to="/shifts">Zobrazit směny</Link>
          </Button>
          <Button size="sm" variant="ghost" onClick={handleDismiss}>
            <X className="h-4 w-4" />
          </Button>
        </div>
      </AlertDescription>
    </Alert>
  );
};

export default NewShiftsAlert;
