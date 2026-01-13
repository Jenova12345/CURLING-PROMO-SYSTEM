import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useShifts } from '@/hooks/useShifts';
import { usePayouts } from '@/hooks/usePayouts';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { Clock, CheckCircle, XCircle, TrendingUp, Calendar, UserCheck, AlertCircle, Wallet, DollarSign, History, Users, BarChart3, Download, UserPlus } from 'lucide-react';
import { format, startOfMonth, endOfMonth, subMonths, isWithinInterval } from 'date-fns';
import { cs } from 'date-fns/locale';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell } from 'recharts';
import { 
  completeShiftSchema, 
  payoutSchema, 
  assignShiftSchema, 
  shiftRequestSchema,
  safeValidate, 
  parseNumericInput, 
  sanitizeText,
  VALIDATION_LIMITS 
} from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';

const Shifts = () => {
  const { isAdmin, isStaff, user } = useAuth();
  const { 
    shifts, 
    openShifts,
    openShiftsByEvent,
    availableStaff,
    myShifts,
    myUnpaidShifts,
    pendingShifts,
    shiftsToComplete,
    staffUnpaidAmounts,
    adminStats,
    requestShift,
    approveShift,
    rejectShift,
    completeShift, 
    cancelRequest,
    cancelShift,
    assignShift,
    isRequesting,
    isApproving,
    isRejecting,
    isCompleting,
    isAssigning,
    totalHoursWorked,
    unpaidEarnings,
    isLoading 
  } = useShifts();
  const { payouts, myPayouts, createPayout, isCreatingPayout } = usePayouts();
  const { toast } = useToast();

  // Rate limiting hooks
  const shiftActionRateLimit = useRateLimit('shiftAction');
  const completeShiftRateLimit = useRateLimit('completeShift');
  const payoutRateLimit = useRateLimit('createPayout');
  const assignRateLimit = useRateLimit('assignShift');

  // Complete shift dialog (admin)
  const [completeDialogOpen, setCompleteDialogOpen] = useState(false);
  const [selectedShift, setSelectedShift] = useState<any>(null);
  const [hoursWorked, setHoursWorked] = useState('');
  const [hourlyRate, setHourlyRate] = useState('');
  const [notes, setNotes] = useState('');

  // Payout dialog (admin)
  const [payoutDialogOpen, setPayoutDialogOpen] = useState(false);
  const [selectedStaff, setSelectedStaff] = useState<{ staffId: string; staffName: string; amount: number } | null>(null);
  const [payoutNotes, setPayoutNotes] = useState('');

  // Assign shift dialog (admin)
  const [assignDialogOpen, setAssignDialogOpen] = useState(false);
  const [shiftToAssign, setShiftToAssign] = useState<any>(null);
  const [selectedStaffId, setSelectedStaffId] = useState<string>('');

  // Active tab state
  const defaultTab = isAdmin ? (pendingShifts.length > 0 ? 'pending' : shiftsToComplete.length > 0 ? 'complete' : 'all') : 'available';
  const [activeTab, setActiveTab] = useState<string>(defaultTab);

  const handleRequestShift = async (shiftId: string) => {
    // Rate limiting
    if (!shiftActionRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${shiftActionRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    // Validate shift ID
    const validation = safeValidate(shiftRequestSchema, { shiftId });
    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }

    try {
      await requestShift(validation.data.shiftId);
      toast({
        title: 'Přihláška odeslána!',
        description: 'Čeká na schválení adminem.',
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se přihlásit na směnu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const handleApproveShift = async (shiftId: string) => {
    try {
      await approveShift(shiftId);
      toast({
        title: 'Směna schválena!',
        description: 'Brigádník byl přiřazen na směnu.',
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se schválit směnu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const handleRejectShift = async (shiftId: string) => {
    try {
      await rejectShift(shiftId);
      toast({
        title: 'Přihláška odmítnuta',
        description: 'Směna je opět volná.',
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se odmítnout přihlášku.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const handleCancelRequest = async (shiftId: string) => {
    try {
      await cancelRequest(shiftId);
      toast({
        title: 'Přihláška zrušena',
        description: 'Směna je nyní opět volná.',
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se zrušit přihlášku.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const handleCancelShift = async (shiftId: string) => {
    try {
      await cancelShift(shiftId);
      toast({
        title: 'Směna zrušena',
        description: 'Směna je nyní opět volná.',
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se zrušit směnu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const openCompleteDialog = (shift: any) => {
    setSelectedShift(shift);
    // Pre-fill with event duration
    if (shift.event?.start_time && shift.event?.end_time) {
      const start = new Date(shift.event.start_time);
      const end = new Date(shift.event.end_time);
      const hours = (end.getTime() - start.getTime()) / (1000 * 60 * 60);
      setHoursWorked(hours.toFixed(1));
    }
    setHourlyRate(shift.hourly_rate?.toString() || '150');
    setNotes('');
    setCompleteDialogOpen(true);
  };

  const handleCompleteShift = async () => {
    if (!selectedShift) return;

    // Rate limiting
    if (!completeShiftRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${completeShiftRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    // Parse and validate input
    const parsedHours = parseNumericInput(hoursWorked, 0);
    const parsedRate = parseNumericInput(hourlyRate, 0);

    const validation = safeValidate(completeShiftSchema, {
      shiftId: selectedShift.id,
      hoursWorked: parsedHours,
      hourlyRate: parsedRate,
      notes: sanitizeText(notes) || undefined,
    });

    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }

    try {
      await completeShift({
        shiftId: validation.data.shiftId,
        hoursWorked: validation.data.hoursWorked,
        hourlyRate: validation.data.hourlyRate,
        notes: validation.data.notes,
      });
      toast({
        title: 'Směna dokončena',
        description: 'Hodiny a částka byly zaznamenány.',
      });
      setCompleteDialogOpen(false);
      setSelectedShift(null);
      setHoursWorked('');
      setHourlyRate('');
      setNotes('');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se dokončit směnu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const openPayoutDialog = (staff: { staffId: string; staffName: string; amount: number }) => {
    setSelectedStaff(staff);
    setPayoutNotes('');
    setPayoutDialogOpen(true);
  };

  const handlePayout = async () => {
    if (!selectedStaff) return;

    // Rate limiting
    if (!payoutRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${payoutRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    // Validate input
    const validation = safeValidate(payoutSchema, {
      userId: selectedStaff.staffId,
      amount: selectedStaff.amount,
      notes: sanitizeText(payoutNotes) || undefined,
    });

    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }

    try {
      await createPayout({
        userId: validation.data.userId,
        amount: validation.data.amount,
        notes: validation.data.notes,
      });
      toast({
        title: 'Výplata provedena!',
        description: `${selectedStaff.staffName} obdržel ${selectedStaff.amount.toLocaleString('cs-CZ')} Kč.`,
      });
      setPayoutDialogOpen(false);
      setSelectedStaff(null);
      setPayoutNotes('');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se provést výplatu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const openAssignDialog = (shift: any) => {
    setShiftToAssign(shift);
    setSelectedStaffId('');
    setAssignDialogOpen(true);
  };

  const handleAssignShift = async () => {
    if (!shiftToAssign) return;

    // Rate limiting
    if (!assignRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${assignRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    // Validate input
    const validation = safeValidate(assignShiftSchema, {
      shiftId: shiftToAssign.id,
      staffId: selectedStaffId,
    });

    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }

    try {
      await assignShift({ shiftId: validation.data.shiftId, staffId: validation.data.staffId });
      toast({
        title: 'Směna přiřazena!',
        description: 'Brigádník byl přiřazen na směnu.',
      });
      setAssignDialogOpen(false);
      setShiftToAssign(null);
      setSelectedStaffId('');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se přiřadit směnu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const statusLabels: Record<string, string> = {
    open: 'Volná',
    pending: 'Čeká na schválení',
    claimed: 'Schválená',
    completed: 'Dokončená',
    cancelled: 'Zrušená',
  };

  const statusColors: Record<string, string> = {
    open: 'bg-green-500',
    pending: 'bg-yellow-500',
    claimed: 'bg-blue-500',
    completed: 'bg-gray-500',
    cancelled: 'bg-red-500',
  };

  const getStaffName = (shift: any) => {
    return shift.claimed_profile?.full_name || 'Neznámý brigádník';
  };

  const calculateTotal = () => {
    const hours = parseFloat(hoursWorked) || 0;
    const rate = parseFloat(hourlyRate) || 0;
    return (hours * rate).toLocaleString('cs-CZ');
  };

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
      </div>
    );
  }

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl md:text-3xl font-bold">Správa směn</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          {isAdmin ? 'Přehled všech směn a brigádníků' : 'Volné směny a vaše přiřazení'}
        </p>
      </div>

      {/* Stats for Staff */}
      {isStaff && (
        <div className="grid gap-3 grid-cols-1 sm:grid-cols-3">
          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Volné směny</CardTitle>
              <Clock className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-green-600">{openShifts.length}</div>
              <p className="text-xs text-muted-foreground">k dispozici k přihlášení</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Odpracované hodiny</CardTitle>
              <TrendingUp className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{totalHoursWorked} h</div>
              <p className="text-xs text-muted-foreground">celkem dokončeno</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">K výplatě</CardTitle>
              <Wallet className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-green-600">{unpaidEarnings.toLocaleString('cs-CZ')} Kč</div>
              <p className="text-xs text-muted-foreground">{myUnpaidShifts.length} nevyplacených směn</p>
            </CardContent>
          </Card>
        </div>
      )}

      {/* Tabs */}
      <Tabs value={activeTab} onValueChange={setActiveTab} className="w-full">
        {/* Mobile: Select dropdown for tabs */}
        <div className="sm:hidden mb-4">
          <Select value={activeTab} onValueChange={setActiveTab}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder="Vyberte sekci" />
            </SelectTrigger>
            <SelectContent>
              {isStaff && <SelectItem value="available">Volné směny</SelectItem>}
              {isStaff && <SelectItem value="my">Moje směny</SelectItem>}
              {isStaff && <SelectItem value="payouts">Výplaty</SelectItem>}
              {isAdmin && <SelectItem value="pending">Čekající {pendingShifts.length > 0 && `(${pendingShifts.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="complete">K dokončení {shiftsToComplete.length > 0 && `(${shiftsToComplete.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="payouts">Výplaty {staffUnpaidAmounts.length > 0 && `(${staffUnpaidAmounts.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="open">Volné {openShifts.length > 0 && `(${openShifts.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="stats">Statistiky</SelectItem>}
              {isAdmin && <SelectItem value="all">Všechny směny</SelectItem>}
            </SelectContent>
          </Select>
        </div>

        {/* Desktop: Horizontal tabs */}
        <TabsList className="hidden sm:flex w-auto flex-wrap">
          {isStaff && <TabsTrigger value="available" className="text-sm">Volné směny</TabsTrigger>}
          {isStaff && <TabsTrigger value="my" className="text-sm">Moje směny</TabsTrigger>}
          {isStaff && <TabsTrigger value="payouts" className="text-sm">Výplaty</TabsTrigger>}
          {isAdmin && (
            <TabsTrigger value="pending" className="text-sm relative">
              Čekající
              {pendingShifts.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-yellow-500 rounded-full">
                  {pendingShifts.length}
                </span>
              )}
            </TabsTrigger>
          )}
          {isAdmin && (
            <TabsTrigger value="complete" className="text-sm relative">
              K dokončení
              {shiftsToComplete.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-orange-500 rounded-full">
                  {shiftsToComplete.length}
                </span>
              )}
            </TabsTrigger>
          )}
          {isAdmin && (
            <TabsTrigger value="payouts" className="text-sm relative">
              Výplaty
              {staffUnpaidAmounts.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-green-500 rounded-full">
                  {staffUnpaidAmounts.length}
                </span>
              )}
            </TabsTrigger>
          )}
          {isAdmin && <TabsTrigger value="open" className="text-sm relative">
              Volné
              {openShifts.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-green-500 rounded-full">
                  {openShifts.length}
                </span>
              )}
            </TabsTrigger>}
          {isAdmin && <TabsTrigger value="stats" className="text-sm">Statistiky</TabsTrigger>}
          {isAdmin && <TabsTrigger value="all" className="text-sm">Všechny směny</TabsTrigger>}
        </TabsList>

        {/* Available Shifts (Staff) - Grouped by Event */}
        {isStaff && (
          <TabsContent value="available" className="space-y-4">
            {openShiftsByEvent.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <Calendar className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Momentálně nejsou k dispozici žádné volné směny.</p>
                </CardContent>
              </Card>
            ) : (
              openShiftsByEvent.map((eventItem) => (
                <Card key={eventItem.eventId}>
                  <CardContent className="flex flex-col sm:flex-row sm:items-center justify-between p-4 md:p-6 gap-4">
                    <div className="flex items-start gap-3">
                      <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors.open}`} />
                      <div>
                        <p className="font-medium text-base md:text-lg">{eventItem.event?.title || 'Směna'}</p>
                        <p className="text-muted-foreground text-sm">
                          {eventItem.event && format(new Date(eventItem.event.start_time), 'EEE d. MMM yyyy', { locale: cs })}
                        </p>
                        <p className="text-xs md:text-sm text-muted-foreground">
                          {eventItem.event && `${format(new Date(eventItem.event.start_time), 'HH:mm')} - ${format(new Date(eventItem.event.end_time), 'HH:mm')}`}
                        </p>
                      </div>
                    </div>
                    <div className="flex items-center justify-between sm:justify-end gap-4 ml-6 sm:ml-0">
                      <div className="text-left sm:text-right">
                        <p className="text-xs text-muted-foreground">Sazba</p>
                        <p className="font-medium text-sm">{eventItem.hourlyRate} Kč/h</p>
                      </div>
                      <div className="text-left sm:text-right">
                        <p className="text-xs text-muted-foreground">Volná místa</p>
                        <p className="font-medium text-sm">{eventItem.openCount}/{eventItem.totalSlots}</p>
                      </div>
                      <Button 
                        onClick={() => handleRequestShift(eventItem.availableShiftIds[0])} 
                        disabled={isRequesting}
                        className="whitespace-nowrap"
                      >
                        {isRequesting ? 'Zpracování...' : 'Přihlásit se'}
                      </Button>
                    </div>
                  </CardContent>
                </Card>
              ))
            )}
          </TabsContent>
        )}

        {/* My Shifts (Staff) */}
        {isStaff && (
          <TabsContent value="my" className="space-y-4">
            {myShifts.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <Clock className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Nemáte žádné přiřazené směny.</p>
                </CardContent>
              </Card>
            ) : (
              myShifts.map((shift) => {
                const isPastEvent = shift.event?.end_time && new Date(shift.event.end_time) < new Date();
                const showWaitingBadge = shift.status === 'claimed' && isPastEvent;
                
                return (
                  <Card key={shift.id}>
                    <CardContent className="flex flex-col sm:flex-row sm:items-center justify-between p-4 md:p-6 gap-4">
                      <div className="flex items-start gap-3">
                        <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors[shift.status]}`} />
                        <div>
                          <p className="font-medium text-base md:text-lg">{shift.event?.title || 'Směna'}</p>
                          <p className="text-muted-foreground text-sm">
                            {shift.event && format(new Date(shift.event.start_time), 'EEE d. MMM yyyy', { locale: cs })}
                          </p>
                          <p className="text-xs md:text-sm text-muted-foreground">
                            {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                          </p>
                          {shift.status === 'completed' && shift.hours_worked && (
                            <div className="mt-1">
                              <p className="text-xs md:text-sm text-green-600">
                                Odpracováno: {shift.hours_worked} h ({(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč)
                              </p>
                              {shift.payout_id ? (
                                <Badge variant="outline" className="text-xs mt-1 border-green-500 text-green-600">
                                  <CheckCircle className="h-3 w-3 mr-1" />
                                  Vyplaceno
                                </Badge>
                              ) : (
                                <Badge variant="outline" className="text-xs mt-1 border-orange-500 text-orange-600">
                                  <Clock className="h-3 w-3 mr-1" />
                                  Čeká na výplatu
                                </Badge>
                              )}
                            </div>
                          )}
                        </div>
                      </div>
                      <div className="flex items-center gap-2 flex-wrap ml-6 sm:ml-0">
                        {showWaitingBadge ? (
                          <Badge variant="outline" className="border-orange-500 text-orange-600">
                            <Clock className="h-3 w-3 mr-1" />
                            Čeká na dokončení adminem
                          </Badge>
                        ) : (
                          <Badge 
                            variant={shift.status === 'completed' ? 'default' : shift.status === 'pending' ? 'outline' : 'secondary'}
                            className={shift.status === 'pending' ? 'border-yellow-500 text-yellow-600' : ''}
                          >
                            {statusLabels[shift.status]}
                          </Badge>
                        )}
                        {shift.status === 'pending' && (
                          <Button 
                            variant="outline" 
                            size="sm"
                            onClick={() => handleCancelRequest(shift.id)}
                            className="h-8"
                          >
                            <XCircle className="h-4 w-4 mr-1" />
                            <span className="hidden sm:inline">Zrušit přihlášku</span>
                          </Button>
                        )}
                        {shift.status === 'claimed' && !isPastEvent && (
                          <Button 
                            variant="outline" 
                            size="sm"
                            onClick={() => handleCancelShift(shift.id)}
                            className="h-8"
                          >
                            <XCircle className="h-4 w-4 mr-1" />
                            <span className="hidden sm:inline">Zrušit</span>
                          </Button>
                        )}
                      </div>
                    </CardContent>
                  </Card>
                );
              })
            )}
          </TabsContent>
        )}

        {/* Payouts (Staff) */}
        {isStaff && (
          <TabsContent value="payouts" className="space-y-4">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <History className="h-5 w-5" />
                  Historie výplat
                </CardTitle>
                <CardDescription>Přehled všech vašich výplat</CardDescription>
              </CardHeader>
              <CardContent>
                {myPayouts.length === 0 ? (
                  <div className="flex flex-col items-center justify-center py-8">
                    <Wallet className="h-12 w-12 text-muted-foreground mb-4" />
                    <p className="text-muted-foreground">Zatím nemáte žádné výplaty.</p>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {myPayouts.map((payout) => (
                      <div key={payout.id} className="flex items-center justify-between p-4 rounded-lg bg-accent/50">
                        <div>
                          <p className="font-medium">{payout.amount.toLocaleString('cs-CZ')} Kč</p>
                          <p className="text-sm text-muted-foreground">
                            {format(new Date(payout.paid_at), 'd. MMMM yyyy', { locale: cs })}
                          </p>
                          {payout.notes && (
                            <p className="text-xs text-muted-foreground mt-1">{payout.notes}</p>
                          )}
                        </div>
                        <Badge variant="outline" className="border-green-500 text-green-600">
                          <CheckCircle className="h-3 w-3 mr-1" />
                          Vyplaceno
                        </Badge>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>
          </TabsContent>
        )}

        {/* Pending Shifts (Admin) */}
        {isAdmin && (
          <TabsContent value="pending" className="space-y-4">
            {pendingShifts.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <UserCheck className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Žádné přihlášky čekající na schválení.</p>
                </CardContent>
              </Card>
            ) : (
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <AlertCircle className="h-5 w-5 text-yellow-500" />
                    Čekající přihlášky
                  </CardTitle>
                  <CardDescription>Brigádníci čekající na schválení směny</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {pendingShifts.map((shift) => (
                    <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-yellow-50 dark:bg-yellow-950/20 border border-yellow-200 dark:border-yellow-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className={`w-3 h-3 rounded-full mt-1.5 ${statusColors.pending}`} />
                        <div>
                          <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                          <p className="text-sm text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          <p className="text-sm font-medium text-yellow-700 dark:text-yellow-400 mt-1">
                            Brigádník: {getStaffName(shift)}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center gap-2 ml-7 sm:ml-0">
                        <Button 
                          variant="outline" 
                          size="sm"
                          onClick={() => handleRejectShift(shift.id)}
                          disabled={isRejecting}
                          className="text-red-600 border-red-300 hover:bg-red-50"
                        >
                          <XCircle className="h-4 w-4 mr-1" />
                          Odmítnout
                        </Button>
                        <Button 
                          size="sm"
                          onClick={() => handleApproveShift(shift.id)}
                          disabled={isApproving}
                          className="bg-green-600 hover:bg-green-700"
                        >
                          <CheckCircle className="h-4 w-4 mr-1" />
                          Schválit
                        </Button>
                      </div>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </TabsContent>
        )}

        {/* Shifts to Complete (Admin) */}
        {isAdmin && (
          <TabsContent value="complete" className="space-y-4">
            {shiftsToComplete.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <CheckCircle className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Žádné směny čekající na dokončení.</p>
                </CardContent>
              </Card>
            ) : (
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <Clock className="h-5 w-5 text-orange-500" />
                    Směny k dokončení
                  </CardTitle>
                  <CardDescription>Směny po skončení akce čekající na zadání hodin</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {shiftsToComplete.map((shift) => (
                    <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-orange-50 dark:bg-orange-950/20 border border-orange-200 dark:border-orange-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className={`w-3 h-3 rounded-full mt-1.5 bg-orange-500`} />
                        <div>
                          <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                          <p className="text-sm text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          <p className="text-sm font-medium text-orange-700 dark:text-orange-400 mt-1">
                            Brigádník: {getStaffName(shift)}
                          </p>
                          <p className="text-xs text-muted-foreground">
                            Sazba: {shift.hourly_rate} Kč/h
                          </p>
                        </div>
                      </div>
                      <Button 
                        size="sm"
                        onClick={() => openCompleteDialog(shift)}
                        className="ml-7 sm:ml-0"
                      >
                        <CheckCircle className="h-4 w-4 mr-1" />
                        Dokončit směnu
                      </Button>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </TabsContent>
        )}

        {/* Payouts (Admin) */}
        {isAdmin && (
          <TabsContent value="payouts" className="space-y-4">
            {/* Unpaid staff */}
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <DollarSign className="h-5 w-5 text-green-500" />
                  K vyplacení
                </CardTitle>
                <CardDescription>Brigádníci s nevyplacenými směnami</CardDescription>
              </CardHeader>
              <CardContent>
                {staffUnpaidAmounts.length === 0 ? (
                  <div className="flex flex-col items-center justify-center py-8">
                    <Wallet className="h-12 w-12 text-muted-foreground mb-4" />
                    <p className="text-muted-foreground">Všichni brigádníci jsou vyplaceni.</p>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {staffUnpaidAmounts.map((staff) => (
                      <div key={staff.staffId} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900 gap-4">
                        <div>
                          <p className="font-medium">{staff.staffName}</p>
                          <p className="text-sm text-muted-foreground">
                            {staff.shiftCount} dokončených směn
                          </p>
                          <p className="text-lg font-bold text-green-600 mt-1">
                            {staff.amount.toLocaleString('cs-CZ')} Kč
                          </p>
                        </div>
                        <Button 
                          onClick={() => openPayoutDialog(staff)}
                          className="bg-green-600 hover:bg-green-700"
                        >
                          <Wallet className="h-4 w-4 mr-1" />
                          Vyplatit
                        </Button>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>

            {/* Payout history */}
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <History className="h-5 w-5" />
                  Historie výplat
                </CardTitle>
                <CardDescription>Přehled všech provedených výplat</CardDescription>
              </CardHeader>
              <CardContent>
                {payouts.length === 0 ? (
                  <div className="flex flex-col items-center justify-center py-8">
                    <History className="h-12 w-12 text-muted-foreground mb-4" />
                    <p className="text-muted-foreground">Zatím nebyly provedeny žádné výplaty.</p>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {payouts.map((payout) => (
                      <div key={payout.id} className="flex items-center justify-between p-4 rounded-lg bg-accent/50">
                        <div>
                          <p className="font-medium">{(payout as any).profile?.full_name || 'Neznámý'}</p>
                          <p className="text-sm text-muted-foreground">
                            {format(new Date(payout.paid_at), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          {payout.notes && (
                            <p className="text-xs text-muted-foreground mt-1">{payout.notes}</p>
                          )}
                        </div>
                        <div className="text-right">
                          <p className="text-lg font-bold">{Number(payout.amount).toLocaleString('cs-CZ')} Kč</p>
                          <p className="text-xs text-muted-foreground">
                            vyplatil: {(payout as any).created_by_profile?.full_name || 'Systém'}
                          </p>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>
          </TabsContent>
        )}

        {/* Statistics (Admin) */}
        {isAdmin && (
          <TabsContent value="stats" className="space-y-6">
            {/* Overview Cards */}
            <div className="grid gap-4 grid-cols-2 lg:grid-cols-4">
              <Card>
                <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                  <CardTitle className="text-sm font-medium">Celkem vyplaceno</CardTitle>
                  <DollarSign className="h-4 w-4 text-muted-foreground" />
                </CardHeader>
                <CardContent>
                  <div className="text-2xl font-bold text-green-600">
                    {payouts.reduce((sum, p) => sum + Number(p.amount), 0).toLocaleString('cs-CZ')} Kč
                  </div>
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                  <CardTitle className="text-sm font-medium">Celkem odpracováno</CardTitle>
                  <Clock className="h-4 w-4 text-muted-foreground" />
                </CardHeader>
                <CardContent>
                  <div className="text-2xl font-bold">{adminStats.totalHoursAllStaff} h</div>
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                  <CardTitle className="text-sm font-medium">K vyplacení</CardTitle>
                  <Wallet className="h-4 w-4 text-muted-foreground" />
                </CardHeader>
                <CardContent>
                  <div className="text-2xl font-bold text-orange-600">
                    {adminStats.unpaidTotal.toLocaleString('cs-CZ')} Kč
                  </div>
                </CardContent>
              </Card>

              <Card>
                <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                  <CardTitle className="text-sm font-medium">Aktivní brigádníci</CardTitle>
                  <Users className="h-4 w-4 text-muted-foreground" />
                </CardHeader>
                <CardContent>
                  <div className="text-2xl font-bold">{adminStats.activeStaffCount}</div>
                  <p className="text-xs text-muted-foreground">{adminStats.completedShiftsCount} směn celkem</p>
                </CardContent>
              </Card>
            </div>

            {/* Charts */}
            <div className="grid gap-6 lg:grid-cols-2">
              {/* Hours by Staff */}
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <BarChart3 className="h-5 w-5" />
                    Odpracované hodiny
                  </CardTitle>
                  <CardDescription>Rozložení hodin mezi brigádníky</CardDescription>
                </CardHeader>
                <CardContent>
                  {adminStats.staffStats.length === 0 ? (
                    <p className="text-muted-foreground text-center py-8">Zatím nejsou žádná data.</p>
                  ) : (
                    <ResponsiveContainer width="100%" height={250}>
                      <BarChart data={adminStats.staffStats}>
                        <CartesianGrid strokeDasharray="3 3" />
                        <XAxis dataKey="staffName" tick={{ fontSize: 12 }} />
                        <YAxis tick={{ fontSize: 12 }} />
                        <Tooltip 
                          formatter={(value: number) => [`${value} h`, 'Hodiny']}
                          labelFormatter={(label) => label}
                        />
                        <Bar dataKey="hoursWorked" fill="hsl(var(--primary))" radius={[4, 4, 0, 0]} />
                      </BarChart>
                    </ResponsiveContainer>
                  )}
                </CardContent>
              </Card>

              {/* Earnings Distribution */}
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <TrendingUp className="h-5 w-5" />
                    Výdělky brigádníků
                  </CardTitle>
                  <CardDescription>Rozdělení celkových výdělků</CardDescription>
                </CardHeader>
                <CardContent>
                  {adminStats.staffStats.length === 0 ? (
                    <p className="text-muted-foreground text-center py-8">Zatím nejsou žádná data.</p>
                  ) : (
                    <ResponsiveContainer width="100%" height={250}>
                      <PieChart>
                        <Pie
                          data={adminStats.staffStats}
                          dataKey="totalEarnings"
                          nameKey="staffName"
                          cx="50%"
                          cy="50%"
                          outerRadius={80}
                          label={({ staffName, percent }) => `${staffName}: ${(percent * 100).toFixed(0)}%`}
                        >
                          {adminStats.staffStats.map((_, index) => (
                            <Cell 
                              key={`cell-${index}`} 
                              fill={[
                                'hsl(var(--primary))',
                                'hsl(var(--secondary))',
                                '#22c55e',
                                '#f59e0b',
                                '#ef4444',
                                '#8b5cf6',
                              ][index % 6]} 
                            />
                          ))}
                        </Pie>
                        <Tooltip formatter={(value: number) => `${value.toLocaleString('cs-CZ')} Kč`} />
                      </PieChart>
                    </ResponsiveContainer>
                  )}
                </CardContent>
              </Card>
            </div>

            {/* Staff Table */}
            <Card>
              <CardHeader className="flex flex-row items-center justify-between">
                <div>
                  <CardTitle>Přehled brigádníků</CardTitle>
                  <CardDescription>Detailní statistiky pro každého brigádníka</CardDescription>
                </div>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => {
                    const csv = [
                      ['Brigádník', 'Směn', 'Hodin', 'Celkem Kč', 'Vyplaceno Kč', 'K výplatě Kč'],
                      ...adminStats.staffStats.map(s => [
                        s.staffName,
                        s.shiftsCount,
                        s.hoursWorked,
                        s.totalEarnings,
                        s.paidAmount,
                        s.unpaidAmount,
                      ])
                    ].map(row => row.join(',')).join('\n');
                    
                    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
                    const link = document.createElement('a');
                    link.href = URL.createObjectURL(blob);
                    link.download = `brigádníci-statistiky-${format(new Date(), 'yyyy-MM-dd')}.csv`;
                    link.click();
                  }}
                >
                  <Download className="h-4 w-4 mr-1" />
                  Export CSV
                </Button>
              </CardHeader>
              <CardContent>
                {adminStats.staffStats.length === 0 ? (
                  <p className="text-muted-foreground text-center py-8">Zatím nejsou žádní brigádníci s dokončenými směnami.</p>
                ) : (
                  <div className="overflow-x-auto">
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Brigádník</TableHead>
                          <TableHead className="text-right">Směn</TableHead>
                          <TableHead className="text-right">Hodin</TableHead>
                          <TableHead className="text-right">Celkem</TableHead>
                          <TableHead className="text-right">Vyplaceno</TableHead>
                          <TableHead className="text-right">K výplatě</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {adminStats.staffStats.map((staff) => (
                          <TableRow key={staff.staffId}>
                            <TableCell className="font-medium">{staff.staffName}</TableCell>
                            <TableCell className="text-right">{staff.shiftsCount}</TableCell>
                            <TableCell className="text-right">{staff.hoursWorked} h</TableCell>
                            <TableCell className="text-right">{staff.totalEarnings.toLocaleString('cs-CZ')} Kč</TableCell>
                            <TableCell className="text-right text-green-600">{staff.paidAmount.toLocaleString('cs-CZ')} Kč</TableCell>
                            <TableCell className="text-right">
                              {staff.unpaidAmount > 0 ? (
                                <span className="text-orange-600 font-medium">{staff.unpaidAmount.toLocaleString('cs-CZ')} Kč</span>
                              ) : (
                                <span className="text-muted-foreground">0 Kč</span>
                              )}
                            </TableCell>
                          </TableRow>
                        ))}
                        <TableRow className="font-bold bg-accent/50">
                          <TableCell>Celkem</TableCell>
                          <TableCell className="text-right">{adminStats.completedShiftsCount}</TableCell>
                          <TableCell className="text-right">{adminStats.totalHoursAllStaff} h</TableCell>
                          <TableCell className="text-right">{adminStats.totalEarningsAllStaff.toLocaleString('cs-CZ')} Kč</TableCell>
                          <TableCell className="text-right text-green-600">
                            {payouts.reduce((sum, p) => sum + Number(p.amount), 0).toLocaleString('cs-CZ')} Kč
                          </TableCell>
                          <TableCell className="text-right text-orange-600">
                            {adminStats.unpaidTotal.toLocaleString('cs-CZ')} Kč
                          </TableCell>
                        </TableRow>
                      </TableBody>
                    </Table>
                  </div>
                )}
              </CardContent>
            </Card>
          </TabsContent>
        )}

        {/* Open Shifts - Admin can assign staff */}
        {isAdmin && (
          <TabsContent value="open" className="space-y-4">
            {openShifts.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <CheckCircle className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Všechny směny jsou obsazeny.</p>
                </CardContent>
              </Card>
            ) : (
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <UserPlus className="h-5 w-5 text-green-500" />
                    Volné směny k přiřazení
                  </CardTitle>
                  <CardDescription>Kliknutím na "Přiřadit" můžete ručně přiřadit brigádníka na směnu</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {openShifts.map((shift) => (
                    <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className="w-3 h-3 rounded-full mt-1.5 bg-green-500" />
                        <div>
                          <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                          <p className="text-sm text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'EEE d. MMMM yyyy', { locale: cs })}
                          </p>
                          <p className="text-xs text-muted-foreground">
                            {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                          </p>
                          <p className="text-xs text-muted-foreground mt-1">
                            Sazba: {shift.hourly_rate} Kč/h
                          </p>
                        </div>
                      </div>
                      <Button 
                        size="sm"
                        onClick={() => openAssignDialog(shift)}
                      >
                        <UserPlus className="h-4 w-4 mr-1" />
                        Přiřadit brigádníka
                      </Button>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </TabsContent>
        )}

        {/* All Shifts (Admin) */}
        {isAdmin && (
          <TabsContent value="all" className="space-y-4">
            <Card>
              <CardHeader>
                <CardTitle>Přehled všech směn</CardTitle>
                <CardDescription>Všechny směny seřazené podle data</CardDescription>
              </CardHeader>
              <CardContent>
                <div className="space-y-4">
                  {shifts.map((shift) => (
                    <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-accent/50 gap-2">
                      <div className="flex items-center gap-4">
                        <div className={`w-3 h-3 rounded-full ${statusColors[shift.status]}`} />
                        <div>
                          <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                          <p className="text-sm text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          {shift.claimed_by && (
                            <p className="text-sm text-muted-foreground">
                              Brigádník: {getStaffName(shift)}
                            </p>
                          )}
                        </div>
                      </div>
                      <div className="flex items-center gap-4 ml-7 sm:ml-0">
                        <Badge variant="outline">{statusLabels[shift.status]}</Badge>
                        {shift.hours_worked && (
                          <span className="text-sm">{shift.hours_worked} h • {(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč</span>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              </CardContent>
            </Card>
          </TabsContent>
        )}
      </Tabs>

      {/* Complete Shift Dialog (Admin) */}
      <Dialog open={completeDialogOpen} onOpenChange={setCompleteDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Dokončit směnu</DialogTitle>
            <DialogDescription>
              Zadejte skutečně odpracované hodiny a hodinovou sazbu.
            </DialogDescription>
          </DialogHeader>
          
          {selectedShift && (
            <div className="space-y-4">
              <div className="p-3 rounded-lg bg-accent/50">
                <p className="font-medium">{selectedShift.event?.title}</p>
                <p className="text-sm text-muted-foreground">
                  Brigádník: {getStaffName(selectedShift)}
                </p>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="hours">Počet hodin</Label>
                  <Input
                    id="hours"
                    type="number"
                    step="0.5"
                    min="0"
                    value={hoursWorked}
                    onChange={(e) => setHoursWorked(e.target.value)}
                    placeholder="Např. 4.5"
                  />
                </div>
                
                <div className="space-y-2">
                  <Label htmlFor="rate">Hodinová sazba (Kč)</Label>
                  <Input
                    id="rate"
                    type="number"
                    min="0"
                    value={hourlyRate}
                    onChange={(e) => setHourlyRate(e.target.value)}
                    placeholder="Např. 150"
                  />
                </div>
              </div>

              <div className="p-3 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900">
                <p className="text-sm text-muted-foreground">Výsledná částka</p>
                <p className="text-2xl font-bold text-green-600">{calculateTotal()} Kč</p>
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="notes">Poznámky (volitelné)</Label>
                <Textarea
                  id="notes"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  placeholder="Případné poznámky ke směně..."
                />
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setCompleteDialogOpen(false)}>
              Zrušit
            </Button>
            <Button onClick={handleCompleteShift} disabled={isCompleting}>
              {isCompleting ? 'Zpracování...' : 'Dokončit směnu'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Payout Dialog (Admin) */}
      <Dialog open={payoutDialogOpen} onOpenChange={setPayoutDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Vyplatit brigádníka</DialogTitle>
            <DialogDescription>
              Potvrďte výplatu pro brigádníka. Všechny jeho nevyplacené směny budou označeny jako vyplacené.
            </DialogDescription>
          </DialogHeader>
          
          {selectedStaff && (
            <div className="space-y-4">
              <div className="p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900">
                <p className="font-medium text-lg">{selectedStaff.staffName}</p>
                <p className="text-3xl font-bold text-green-600 mt-2">
                  {selectedStaff.amount.toLocaleString('cs-CZ')} Kč
                </p>
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="payoutNotes">Poznámka k výplatě (volitelné)</Label>
                <Textarea
                  id="payoutNotes"
                  value={payoutNotes}
                  onChange={(e) => setPayoutNotes(e.target.value)}
                  placeholder="Např. Výplata za leden 2026..."
                />
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setPayoutDialogOpen(false)}>
              Zrušit
            </Button>
            <Button 
              onClick={handlePayout} 
              disabled={isCreatingPayout}
              className="bg-green-600 hover:bg-green-700"
            >
              {isCreatingPayout ? 'Zpracování...' : 'Potvrdit výplatu'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Assign Shift Dialog (Admin) */}
      <Dialog open={assignDialogOpen} onOpenChange={setAssignDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Přiřadit brigádníka na směnu</DialogTitle>
            <DialogDescription>
              Vyberte brigádníka, kterého chcete přiřadit na tuto směnu. Směna bude rovnou schválena.
            </DialogDescription>
          </DialogHeader>
          
          {shiftToAssign && (
            <div className="space-y-4">
              <div className="p-4 rounded-lg bg-accent/50 border">
                <p className="font-medium text-lg">{shiftToAssign.event?.title || 'Směna'}</p>
                <p className="text-sm text-muted-foreground">
                  {shiftToAssign.event && format(new Date(shiftToAssign.event.start_time), 'EEEE d. MMMM yyyy', { locale: cs })}
                </p>
                <p className="text-sm text-muted-foreground">
                  {shiftToAssign.event && `${format(new Date(shiftToAssign.event.start_time), 'HH:mm')} - ${format(new Date(shiftToAssign.event.end_time), 'HH:mm')}`}
                </p>
                <p className="text-sm mt-2">Sazba: {shiftToAssign.hourly_rate} Kč/h</p>
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="staffSelect">Vyberte brigádníka</Label>
                <Select value={selectedStaffId} onValueChange={setSelectedStaffId}>
                  <SelectTrigger>
                    <SelectValue placeholder="Vyberte brigádníka..." />
                  </SelectTrigger>
                  <SelectContent>
                    {availableStaff.map((staff) => (
                      <SelectItem key={staff.userId} value={staff.userId}>
                        {staff.fullName}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {availableStaff.length === 0 && (
                  <p className="text-sm text-muted-foreground">Žádní brigádníci nejsou k dispozici.</p>
                )}
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setAssignDialogOpen(false)}>
              Zrušit
            </Button>
            <Button 
              onClick={handleAssignShift} 
              disabled={isAssigning || !selectedStaffId}
            >
              {isAssigning ? 'Zpracování...' : 'Přiřadit brigádníka'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Shifts;
