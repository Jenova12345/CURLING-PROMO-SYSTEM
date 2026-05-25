import { useState, useEffect } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useShifts } from '@/hooks/useShifts';
import { useShiftApplications } from '@/hooks/useShiftApplications';
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
import { Switch } from '@/components/ui/switch';
import { useToast } from '@/hooks/use-toast';
import { Clock, CheckCircle, XCircle, Calendar, UserCheck, AlertCircle, History, UserPlus, TrendingUp, DollarSign, Wallet } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { 
  completeShiftSchema, 
  assignShiftSchema, 
  shiftRequestSchema,
  safeValidate, 
  parseNumericInput, 
  sanitizeText,
  VALIDATION_LIMITS 
} from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';

// Staff role labels and colors for badges
const staffRoleLabels: Record<string, string> = {
  instructor: 'Instruktor',
  bar_staff: 'Obsluha baru',
  manager: 'Provozní hospoda',
  part_time_staff: 'Brigádník',
};

const staffRoleColors: Record<string, string> = {
  instructor: 'bg-teal-500',
  bar_staff: 'bg-amber-500',
  manager: 'bg-indigo-500',
  part_time_staff: 'bg-blue-500',
};

const Shifts = () => {
  const { isAdmin, isStaff, user } = useAuth();
  const { 
    shifts, 
    openShifts,
    openShiftsByEvent,
    availableStaff,
    myShifts,
    myPendingShifts,
    myConfirmedShifts,
    myCompletedShifts,
    myUnpaidShifts,
    pendingShifts,
    shiftsToComplete,
    eventsToComplete,
    upcomingShiftsByEvent,
    historyShifts,
    requestShift,
    approveShift,
    rejectShift,
    completeShift,
    completeShiftsIndividually,
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
  const { myPayouts } = usePayouts();
  const {
    myApplications,
    applicationsByShift,
    pendingApplications,
    applyToShift,
    cancelMyApplication,
    approveApplication,
    rejectApplication,
    revokeApproval,
    isApplying,
    isApproving: isApprovingApp,
    isRejecting: isRejectingApp,
    isRevoking,
  } = useShiftApplications();
  const { toast } = useToast();

  // Rate limiting hooks
  const shiftActionRateLimit = useRateLimit('shiftAction');
  const completeShiftRateLimit = useRateLimit('completeShift');
  const assignRateLimit = useRateLimit('assignShift');

  // Complete event dialog (admin) - individual staff data
  interface StaffCompletionData {
    shiftId: string;
    staffName: string;
    hours: string;
    rate: string;
    manualAmount: string;
    useManualAmount: boolean;
  }
  const [completeDialogOpen, setCompleteDialogOpen] = useState(false);
  const [selectedEvent, setSelectedEvent] = useState<any>(null);
  const [staffCompletionData, setStaffCompletionData] = useState<StaffCompletionData[]>([]);
  const [notes, setNotes] = useState('');


  // Assign shift dialog (admin)
  const [assignDialogOpen, setAssignDialogOpen] = useState(false);
  const [shiftToAssign, setShiftToAssign] = useState<any>(null);
  const [selectedStaffId, setSelectedStaffId] = useState<string>('');


  // Active tab state - initialize as empty and set properly after auth loads
  const [activeTab, setActiveTab] = useState<string>('');

  // Set default tab based on role - runs when isAdmin/isStaff/data changes
  useEffect(() => {
    if (isLoading) return;
    
    // Only set default tab if not already set
    if (!activeTab) {
      if (isAdmin) {
        if (pendingShifts.length > 0) {
          setActiveTab('pending');
        } else if (eventsToComplete.length > 0) {
          setActiveTab('complete');
        } else {
          setActiveTab('upcoming');
        }
      } else if (isStaff) {
        setActiveTab('available');
      }
    }
  }, [isAdmin, isStaff, isLoading, pendingShifts.length, eventsToComplete.length, activeTab]);


  const handleRequestShift = async (shiftId: string) => {
    if (!shiftActionRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${shiftActionRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }
    const validation = safeValidate(shiftRequestSchema, { shiftId });
    if (!validation.success) {
      toast({ title: 'Chyba validace', description: validation.error, variant: 'destructive' });
      return;
    }
    try {
      await applyToShift(validation.data.shiftId);
      toast({ title: 'Přihláška odeslána!', description: 'Čeká na schválení adminem.' });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se přihlásit.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
    }
  };

  const handleCancelApplication = async (appId: string) => {
    try {
      await cancelMyApplication(appId);
      toast({ title: 'Přihláška zrušena' });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se zrušit přihlášku.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
    }
  };

  const handleApproveApplication = async (appId: string) => {
    try {
      await approveApplication(appId);
      toast({ title: 'Přihláška schválena', description: 'Brigádník byl přiřazen na směnu.' });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se schválit přihlášku.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
    }
  };

  const handleRejectApplication = async (appId: string) => {
    try {
      await rejectApplication(appId);
      toast({ title: 'Přihláška zamítnuta' });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se zamítnout přihlášku.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
    }
  };

  const handleRevokeApproval = async (shiftId: string) => {
    const app = applicationsByShift[shiftId]?.find((a) => a.status === 'approved');
    if (!app) {
      toast({ title: 'Chyba', description: 'Schválená přihláška nenalezena.', variant: 'destructive' });
      return;
    }
    try {
      await revokeApproval(app.id);
      toast({ title: 'Brigádník odebrán', description: 'Směna je opět volná.' });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se odebrat brigádníka.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
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

  const openCompleteDialog = (eventItem: any) => {
    setSelectedEvent(eventItem);
    
    // Calculate default hours from event duration
    let defaultHours = '';
    if (eventItem.event?.start_time && eventItem.event?.end_time) {
      const start = new Date(eventItem.event.start_time);
      const end = new Date(eventItem.event.end_time);
      const hours = (end.getTime() - start.getTime()) / (1000 * 60 * 60);
      defaultHours = hours.toFixed(1);
    }
    
    // Initialize data for each staff member
    const initialData: StaffCompletionData[] = eventItem.shifts.map((shift: any) => ({
      shiftId: shift.id,
      staffName: shift.claimed_profile?.full_name || 'Neznámý',
      hours: defaultHours,
      rate: shift.hourly_rate?.toString() || '150',
      manualAmount: '',
      useManualAmount: false,
    }));
    
    setStaffCompletionData(initialData);
    setNotes('');
    setCompleteDialogOpen(true);
  };

  const handleCompleteEvent = async () => {
    if (!selectedEvent || staffCompletionData.length === 0) return;

    // Rate limiting
    if (!completeShiftRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${completeShiftRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    // Validate all inputs and prepare data
    const shiftsToSubmit = staffCompletionData.map(staff => {
      const hours = parseNumericInput(staff.hours, 0);
      const rate = parseNumericInput(staff.rate, 0);
      const manualAmount = parseNumericInput(staff.manualAmount, 0);
      
      return {
        shiftId: staff.shiftId,
        hoursWorked: hours,
        hourlyRate: rate,
        manualAmount: staff.useManualAmount ? manualAmount : undefined,
      };
    });
    
    // Validate - each must have valid values
    const invalid = shiftsToSubmit.some(s => {
      if (s.hoursWorked <= 0) return true;
      if (s.manualAmount !== undefined) {
        return s.manualAmount <= 0;
      }
      return s.hourlyRate <= 0;
    });

    if (invalid) {
      toast({
        title: 'Chyba validace',
        description: 'Zkontrolujte hodnoty pro všechny brigádníky. Hodiny a částky musí být větší než 0.',
        variant: 'destructive',
      });
      return;
    }

    try {
      await completeShiftsIndividually({
        shiftsData: shiftsToSubmit,
        notes: sanitizeText(notes) || undefined,
      });
      toast({
        title: 'Akce dokončena',
        description: `Všechny směny (${selectedEvent.shifts.length} brigádníků) byly dokončeny.`,
      });
      setCompleteDialogOpen(false);
      setSelectedEvent(null);
      setStaffCompletionData([]);
      setNotes('');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se dokončit akci.';
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

  // Update individual staff completion data
  const updateStaffData = (shiftId: string, field: keyof StaffCompletionData, value: string | boolean) => {
    setStaffCompletionData(prev => 
      prev.map(staff => 
        staff.shiftId === shiftId 
          ? { ...staff, [field]: value }
          : staff
      )
    );
  };

  // Calculate total for all staff
  const calculateTotalAmount = () => {
    return staffCompletionData.reduce((sum, staff) => {
      const hours = parseFloat(staff.hours) || 0;
      const rate = parseFloat(staff.rate) || 0;
      const manualAmount = parseFloat(staff.manualAmount) || 0;
      return sum + (staff.useManualAmount ? manualAmount : hours * rate);
    }, 0);
  };

  // Calculate individual staff amount
  const calculateStaffAmount = (staff: StaffCompletionData) => {
    const hours = parseFloat(staff.hours) || 0;
    const rate = parseFloat(staff.rate) || 0;
    const manualAmount = parseFloat(staff.manualAmount) || 0;
    return staff.useManualAmount ? manualAmount : hours * rate;
  };

  // Set same values for all staff
  const setAllStaffValues = (field: 'hours' | 'rate', value: string) => {
    setStaffCompletionData(prev => prev.map(staff => ({ ...staff, [field]: value })));
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
              {isStaff && <SelectItem value="completed">Dokončené směny</SelectItem>}
              {isStaff && <SelectItem value="payouts">Výplaty</SelectItem>}
              {isAdmin && <SelectItem value="pending">Brigádníci k potvrzení {pendingShifts.length > 0 && `(${pendingShifts.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="complete">Akce k dokončení {eventsToComplete.length > 0 && `(${eventsToComplete.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="open">Směny kde chybí brigádníci {openShifts.length > 0 && `(${openShifts.length})`}</SelectItem>}
              {isAdmin && <SelectItem value="upcoming">Hotové nadcházející akce</SelectItem>}
              {isAdmin && <SelectItem value="history">Historie směn</SelectItem>}
            </SelectContent>
          </Select>
        </div>

        {/* Desktop: Horizontal tabs */}
        <TabsList className="hidden sm:flex w-auto flex-wrap">
          {isStaff && <TabsTrigger value="available" className="text-sm">Volné směny</TabsTrigger>}
          {isStaff && <TabsTrigger value="my" className="text-sm">Moje směny</TabsTrigger>}
          {isStaff && (
            <TabsTrigger value="completed" className="text-sm relative">
              Dokončené směny
              {myCompletedShifts.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-green-500 rounded-full">
                  {myCompletedShifts.length}
                </span>
              )}
            </TabsTrigger>
          )}
          {isStaff && <TabsTrigger value="payouts" className="text-sm">Výplaty</TabsTrigger>}
          {isAdmin && (
            <TabsTrigger value="pending" className="text-sm relative">
              Brigádníci k potvrzení
              {pendingShifts.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-yellow-500 rounded-full">
                  {pendingShifts.length}
                </span>
              )}
            </TabsTrigger>
          )}
          {isAdmin && (
            <TabsTrigger value="complete" className="text-sm relative">
              Akce k dokončení
              {eventsToComplete.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-orange-500 rounded-full">
                  {eventsToComplete.length}
                </span>
              )}
            </TabsTrigger>
          )}
          {isAdmin && <TabsTrigger value="open" className="text-sm relative">
              Směny kde chybí brigádníci
              {openShifts.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-green-500 rounded-full">
                  {openShifts.length}
                </span>
              )}
            </TabsTrigger>}
          {isAdmin && <TabsTrigger value="upcoming" className="text-sm">Hotové nadcházející akce</TabsTrigger>}
          {isAdmin && <TabsTrigger value="history" className="text-sm">Historie směn</TabsTrigger>}
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
                  <CardContent className="p-4 md:p-6 space-y-4">
                    {/* Event header - shared info */}
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
                    
                    {/* Individual shifts - one row per available shift */}
                    <div className="space-y-3 ml-6">
                      {(eventItem as any).availableShifts.map((shift: any) => (
                        <div 
                          key={shift.id} 
                          className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-3 bg-muted/50 rounded-lg"
                        >
                          <div className="flex items-center gap-2">
                            {shift.required_role && (
                              <Badge className={`${staffRoleColors[shift.required_role] || 'bg-gray-500'} text-white text-xs`}>
                                {staffRoleLabels[shift.required_role] || shift.required_role}
                              </Badge>
                            )}
                            <span className="text-sm text-muted-foreground">
                              {eventItem.hourlyRate} Kč/h
                            </span>
                          </div>
                          <Button 
                            onClick={() => handleRequestShift(shift.id)} 
                            disabled={isRequesting}
                            size="sm"
                            className="whitespace-nowrap"
                          >
                            {isRequesting ? 'Zpracování...' : 'Přihlásit se'}
                          </Button>
                        </div>
                      ))}
                    </div>
                    
                    {/* Summary footer */}
                    <div className="text-xs text-muted-foreground ml-6">
                      Volná místa celkem: {eventItem.openCount}/{eventItem.totalSlots}
                    </div>
                  </CardContent>
                </Card>
              ))
            )}
          </TabsContent>
        )}

        {/* My Shifts (Staff) - Split into Pending and Confirmed */}
        {isStaff && (
          <TabsContent value="my" className="space-y-6">
            {myShifts.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <Clock className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Nemáte žádné přiřazené směny.</p>
                </CardContent>
              </Card>
            ) : (
              <>
                {/* Pending Shifts Section */}
                <Card className="border-yellow-200 dark:border-yellow-900">
                  <CardHeader className="pb-3">
                    <CardTitle className="flex items-center gap-2 text-lg">
                      <AlertCircle className="h-5 w-5 text-yellow-500" />
                      Čeká na potvrzení
                      {myPendingShifts.length > 0 && (
                        <Badge variant="outline" className="ml-2 border-yellow-500 text-yellow-600">
                          {myPendingShifts.length}
                        </Badge>
                      )}
                    </CardTitle>
                    <CardDescription>Směny čekající na schválení adminem</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    {myPendingShifts.length === 0 ? (
                      <p className="text-sm text-muted-foreground py-4 text-center">
                        Žádné směny nečekají na potvrzení
                      </p>
                    ) : (
                      myPendingShifts.map((shift) => (
                        <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-yellow-50 dark:bg-yellow-950/20 border border-yellow-200 dark:border-yellow-900 gap-4">
                          <div className="flex items-start gap-3">
                            <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors.pending}`} />
                            <div>
                              <div className="flex items-center gap-2 flex-wrap">
                                <p className="font-medium text-base">{shift.event?.title || 'Směna'}</p>
                                {(shift as any).required_role && (
                                  <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
                                    {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
                                  </Badge>
                                )}
                              </div>
                              <p className="text-muted-foreground text-sm">
                                {shift.event && format(new Date(shift.event.start_time), 'EEE d. MMM yyyy', { locale: cs })}
                              </p>
                              <p className="text-xs text-muted-foreground">
                                {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                              </p>
                            </div>
                          </div>
                          <div className="flex items-center gap-2 ml-6 sm:ml-0">
                            <Badge variant="outline" className="border-yellow-500 text-yellow-600">
                              <Clock className="h-3 w-3 mr-1" />
                              Čeká na schválení
                            </Badge>
                            <Button 
                              variant="outline" 
                              size="sm"
                              onClick={() => handleCancelRequest(shift.id)}
                              className="h-8"
                            >
                              <XCircle className="h-4 w-4 mr-1" />
                              <span className="hidden sm:inline">Zrušit přihlášku</span>
                            </Button>
                          </div>
                        </div>
                      ))
                    )}
                  </CardContent>
                </Card>

                {/* Confirmed Shifts Section */}
                <Card className="border-blue-200 dark:border-blue-900">
                  <CardHeader className="pb-3">
                    <CardTitle className="flex items-center gap-2 text-lg">
                      <CheckCircle className="h-5 w-5 text-blue-500" />
                      Potvrzené
                      {myConfirmedShifts.length > 0 && (
                        <Badge variant="outline" className="ml-2 border-blue-500 text-blue-600">
                          {myConfirmedShifts.length}
                        </Badge>
                      )}
                    </CardTitle>
                    <CardDescription>Nadcházející schválené směny</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    {myConfirmedShifts.length === 0 ? (
                      <p className="text-sm text-muted-foreground py-4 text-center">
                        Zatím nemáte žádné potvrzené směny
                      </p>
                    ) : (
                      myConfirmedShifts.map((shift) => {
                        const isPastEvent = shift.event?.end_time && new Date(shift.event.end_time) < new Date();
                        const showWaitingBadge = isPastEvent;
                        
                        return (
                          <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-blue-50 dark:bg-blue-950/20 border border-blue-200 dark:border-blue-900 gap-4">
                            <div className="flex items-start gap-3">
                              <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors.claimed}`} />
                              <div>
                                <div className="flex items-center gap-2 flex-wrap">
                                  <p className="font-medium text-base">{shift.event?.title || 'Směna'}</p>
                                  {(shift as any).required_role && (
                                    <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
                                      {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
                                    </Badge>
                                  )}
                                </div>
                                <p className="text-muted-foreground text-sm">
                                  {shift.event && format(new Date(shift.event.start_time), 'EEE d. MMM yyyy', { locale: cs })}
                                </p>
                                <p className="text-xs text-muted-foreground">
                                  {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                                </p>
                              </div>
                            </div>
                            <div className="flex items-center gap-2 flex-wrap ml-6 sm:ml-0">
                              {showWaitingBadge ? (
                                <Badge variant="outline" className="border-orange-500 text-orange-600">
                                  <Clock className="h-3 w-3 mr-1" />
                                  Čeká na dokončení adminem
                                </Badge>
                              ) : (
                                <Badge variant="secondary">
                                  {statusLabels[shift.status]}
                                </Badge>
                              )}
                              {!isPastEvent && (
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
                          </div>
                        );
                      })
                    )}
                  </CardContent>
                </Card>
              </>
            )}
          </TabsContent>
        )}

        {/* Completed Shifts (Staff) */}
        {isStaff && (
          <TabsContent value="completed" className="space-y-4">
            <Card className="border-green-200 dark:border-green-900">
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <CheckCircle className="h-5 w-5 text-green-500" />
                  Dokončené směny
                  {myCompletedShifts.length > 0 && (
                    <Badge variant="outline" className="ml-2 border-green-500 text-green-600">
                      {myCompletedShifts.length}
                    </Badge>
                  )}
                </CardTitle>
                <CardDescription>Odpracované směny a přehled výdělků</CardDescription>
              </CardHeader>
              <CardContent>
                {myCompletedShifts.length === 0 ? (
                  <div className="flex flex-col items-center justify-center py-8">
                    <CheckCircle className="h-12 w-12 text-muted-foreground mb-4" />
                    <p className="text-muted-foreground">Zatím nemáte žádné dokončené směny.</p>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {myCompletedShifts.map((shift) => (
                      <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900 gap-4">
                        <div className="flex items-start gap-3">
                          <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors.completed}`} />
                          <div>
                            <p className="font-medium text-base">{shift.event?.title || 'Směna'}</p>
                            <p className="text-muted-foreground text-sm">
                              {shift.event && format(new Date(shift.event.start_time), 'EEE d. MMM yyyy', { locale: cs })}
                            </p>
                            <p className="text-xs text-muted-foreground">
                              {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                            </p>
                            {shift.hours_worked && (
                              <div className="mt-2">
                                <p className="text-sm font-medium text-green-600">
                                  Odpracováno: {shift.hours_worked} h • {(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč
                                </p>
                              </div>
                            )}
                          </div>
                        </div>
                        <div className="flex items-center gap-2 ml-6 sm:ml-0">
                          {shift.payout_id ? (
                            <Badge variant="outline" className="border-green-500 text-green-600">
                              <CheckCircle className="h-3 w-3 mr-1" />
                              Vyplaceno
                            </Badge>
                          ) : (
                            <Badge variant="outline" className="border-orange-500 text-orange-600">
                              <Clock className="h-3 w-3 mr-1" />
                              Čeká na výplatu
                            </Badge>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>
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
                    Brigádníci k potvrzení
                  </CardTitle>
                  <CardDescription>Brigádníci čekající na schválení směny</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {pendingShifts.map((shift) => (
                    <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-yellow-50 dark:bg-yellow-950/20 border border-yellow-200 dark:border-yellow-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className={`w-3 h-3 rounded-full mt-1.5 ${statusColors.pending}`} />
                        <div>
                          <div className="flex items-center gap-2 flex-wrap">
                            <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                            {(shift as any).required_role && (
                              <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
                                {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
                              </Badge>
                            )}
                          </div>
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

        {/* Events to Complete (Admin) */}
        {isAdmin && (
          <TabsContent value="complete" className="space-y-4">
            {eventsToComplete.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <CheckCircle className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Žádné akce čekající na dokončení.</p>
                </CardContent>
              </Card>
            ) : (
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <Clock className="h-5 w-5 text-orange-500" />
                    Akce k dokončení
                  </CardTitle>
                  <CardDescription>Akce po skončení čekající na zadání hodin pro všechny brigádníky</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {eventsToComplete.map((eventItem) => (
                    <div key={eventItem.eventId} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-orange-50 dark:bg-orange-950/20 border border-orange-200 dark:border-orange-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className={`w-3 h-3 rounded-full mt-1.5 bg-orange-500`} />
                        <div>
                          <p className="font-medium">{eventItem.event?.title || 'Akce'}</p>
                          <p className="text-sm text-muted-foreground">
                            {eventItem.event && format(new Date(eventItem.event.start_time), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          <p className="text-sm font-medium text-orange-700 dark:text-orange-400 mt-1">
                            Brigádníci ({eventItem.shifts.length}): {eventItem.staffNames.join(', ')}
                          </p>
                          <p className="text-xs text-muted-foreground">
                            Sazba: {eventItem.hourlyRate} Kč/h
                          </p>
                        </div>
                      </div>
                      <Button 
                        size="sm"
                        onClick={() => openCompleteDialog(eventItem)}
                        className="ml-7 sm:ml-0"
                      >
                        <CheckCircle className="h-4 w-4 mr-1" />
                        Dokončit akci ({eventItem.shifts.length})
                      </Button>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </TabsContent>
        )}

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
                    Směny kde chybí brigádníci
                  </CardTitle>
                  <CardDescription>Kliknutím na "Přiřadit" můžete ručně přiřadit brigádníka na směnu</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {openShifts.map((shift) => (
                    <div key={shift.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className="w-3 h-3 rounded-full mt-1.5 bg-green-500" />
                        <div>
                          <div className="flex items-center gap-2 flex-wrap">
                            <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                            {(shift as any).required_role && (
                              <Badge className={`${staffRoleColors[(shift as any).required_role] || 'bg-gray-500'} text-white text-xs`}>
                                {staffRoleLabels[(shift as any).required_role] || (shift as any).required_role}
                              </Badge>
                            )}
                          </div>
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
                        Přiřadit {staffRoleLabels[(shift as any).required_role] || 'brigádníka'}
                      </Button>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </TabsContent>
        )}

        {/* Upcoming Shifts (Admin) - Future events with staff */}
        {isAdmin && (
          <TabsContent value="upcoming" className="space-y-4">
            {upcomingShiftsByEvent.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <Calendar className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Žádné nadcházející akce s brigádníky.</p>
                </CardContent>
              </Card>
            ) : (
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <Calendar className="h-5 w-5 text-blue-500" />
                    Hotové nadcházející akce
                  </CardTitle>
                  <CardDescription>Budoucí akce s potvrzenými brigádníky</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {upcomingShiftsByEvent.map((eventItem) => (
                    <div key={eventItem.eventId} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-blue-50 dark:bg-blue-950/20 border border-blue-200 dark:border-blue-900 gap-4">
                      <div className="flex items-start gap-4">
                        <div className="w-3 h-3 rounded-full mt-1.5 bg-blue-500" />
                        <div>
                          <p className="font-medium">{eventItem.event?.title || 'Akce'}</p>
                          <p className="text-sm text-muted-foreground">
                            {eventItem.event && format(new Date(eventItem.event.start_time), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          <p className="text-sm font-medium text-blue-700 dark:text-blue-400 mt-1">
                            Brigádníci ({eventItem.shifts.length}): {eventItem.staffNames.join(', ')}
                          </p>
                        </div>
                      </div>
                      <Badge variant="outline" className="border-blue-500 text-blue-600">
                        <CheckCircle className="h-3 w-3 mr-1" />
                        Připraveno
                      </Badge>
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
          </TabsContent>
        )}

        {/* History Shifts (Admin) - Last 2 months */}
        {isAdmin && (
          <TabsContent value="history" className="space-y-4">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <History className="h-5 w-5" />
                  Historie dokončených směn
                </CardTitle>
                <CardDescription>Poslední 2 měsíce</CardDescription>
              </CardHeader>
              <CardContent>
                {historyShifts.length === 0 ? (
                  <div className="flex flex-col items-center justify-center py-8">
                    <History className="h-12 w-12 text-muted-foreground mb-4" />
                    <p className="text-muted-foreground">Žádné dokončené směny v posledních 2 měsících.</p>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {historyShifts.map((shift) => (
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
                          {shift.payout_id ? (
                            <Badge variant="outline" className="border-green-500 text-green-600">
                              <CheckCircle className="h-3 w-3 mr-1" />
                              Vyplaceno
                            </Badge>
                          ) : (
                            <Badge variant="outline" className="border-orange-500 text-orange-600">
                              <Clock className="h-3 w-3 mr-1" />
                              K výplatě
                            </Badge>
                          )}
                          {shift.hours_worked && (
                            <span className="text-sm">{shift.hours_worked} h • {(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč</span>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>
          </TabsContent>
        )}
      </Tabs>

      {/* Complete Event Dialog (Admin) - Individual staff values */}
      <Dialog open={completeDialogOpen} onOpenChange={setCompleteDialogOpen}>
        <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Dokončit akci</DialogTitle>
            <DialogDescription>
              Zadejte hodiny a sazbu pro každého brigádníka zvlášť, nebo použijte ruční odměnu.
            </DialogDescription>
          </DialogHeader>
          
          {selectedEvent && (
            <div className="space-y-4">
              <div className="p-3 rounded-lg bg-accent/50">
                <p className="font-medium">{selectedEvent.event?.title}</p>
                <p className="text-sm text-muted-foreground">
                  {selectedEvent.event && format(new Date(selectedEvent.event.start_time), 'EEEE d. MMMM yyyy', { locale: cs })}
                  {selectedEvent.event && ` • ${format(new Date(selectedEvent.event.start_time), 'HH:mm')} - ${format(new Date(selectedEvent.event.end_time), 'HH:mm')}`}
                </p>
              </div>

              {/* Bulk set for all */}
              {staffCompletionData.length > 1 && (
                <div className="p-3 rounded-lg border border-dashed bg-muted/30 space-y-2">
                  <p className="text-sm font-medium text-muted-foreground">Nastavit všem stejně:</p>
                  <div className="flex gap-2 flex-wrap">
                    <div className="flex items-center gap-2">
                      <Label className="text-xs whitespace-nowrap">Hodiny:</Label>
                      <Input
                        type="number"
                        step="0.5"
                        min="0"
                        className="w-20 h-8 text-sm"
                        placeholder="h"
                        onChange={(e) => setAllStaffValues('hours', e.target.value)}
                      />
                    </div>
                    <div className="flex items-center gap-2">
                      <Label className="text-xs whitespace-nowrap">Sazba:</Label>
                      <Input
                        type="number"
                        min="0"
                        className="w-20 h-8 text-sm"
                        placeholder="Kč/h"
                        onChange={(e) => setAllStaffValues('rate', e.target.value)}
                      />
                    </div>
                  </div>
                </div>
              )}

              {/* Individual staff entries */}
              <div className="space-y-3">
                {staffCompletionData.map((staff, index) => (
                  <div 
                    key={staff.shiftId} 
                    className={`p-4 rounded-lg border ${staff.useManualAmount ? 'border-orange-300 bg-orange-50/50 dark:border-orange-800 dark:bg-orange-950/20' : 'bg-accent/30'}`}
                  >
                    <div className="flex items-center justify-between mb-3">
                      <span className="font-medium">{index + 1}. {staff.staffName}</span>
                      <span className="font-bold text-lg">
                        {calculateStaffAmount(staff).toLocaleString('cs-CZ')} Kč
                      </span>
                    </div>
                    
                    <div className="grid grid-cols-2 gap-3 mb-3">
                      <div className="space-y-1">
                        <Label className="text-xs">Hodiny</Label>
                        <Input
                          type="number"
                          step="0.5"
                          min="0"
                          value={staff.hours}
                          onChange={(e) => updateStaffData(staff.shiftId, 'hours', e.target.value)}
                          placeholder="Např. 4.5"
                          className="h-9"
                        />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs">Sazba (Kč/h)</Label>
                        <Input
                          type="number"
                          min="0"
                          value={staff.rate}
                          onChange={(e) => updateStaffData(staff.shiftId, 'rate', e.target.value)}
                          placeholder="Např. 150"
                          className="h-9"
                          disabled={staff.useManualAmount}
                        />
                      </div>
                    </div>

                    <div className="flex items-center justify-between pt-2 border-t border-dashed">
                      <label 
                        htmlFor={`manual-${staff.shiftId}`} 
                        className={`flex items-center gap-2 px-3 py-1.5 rounded-md cursor-pointer transition-colors ${
                          staff.useManualAmount 
                            ? 'bg-orange-100 dark:bg-orange-900/30 text-orange-700 dark:text-orange-300' 
                            : 'bg-muted hover:bg-accent'
                        }`}
                      >
                        <Switch
                          id={`manual-${staff.shiftId}`}
                          checked={staff.useManualAmount}
                          onCheckedChange={(checked) => updateStaffData(staff.shiftId, 'useManualAmount', checked)}
                        />
                        <DollarSign className="h-4 w-4" />
                        <span className="text-sm font-medium">Ruční odměna</span>
                      </label>
                      
                      {staff.useManualAmount && (
                        <div className="flex items-center gap-2">
                          <Input
                            type="number"
                            min="0"
                            value={staff.manualAmount}
                            onChange={(e) => updateStaffData(staff.shiftId, 'manualAmount', e.target.value)}
                            placeholder="Zadejte částku"
                            className="w-32 h-9 font-medium"
                          />
                          <span className="text-sm font-medium">Kč</span>
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </div>

              {/* Total summary */}
              <div className="p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm text-muted-foreground">Celkem za {staffCompletionData.length} brigádníků</p>
                    <p className="text-2xl font-bold text-green-600">
                      {calculateTotalAmount().toLocaleString('cs-CZ')} Kč
                    </p>
                  </div>
                  <div className="text-right text-sm text-muted-foreground">
                    {staffCompletionData.filter(s => s.useManualAmount).length > 0 && (
                      <p className="text-orange-600">
                        {staffCompletionData.filter(s => s.useManualAmount).length}× ruční odměna
                      </p>
                    )}
                  </div>
                </div>
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="notes">Poznámky (volitelné)</Label>
                <Textarea
                  id="notes"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  placeholder="Případné poznámky k akci..."
                />
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setCompleteDialogOpen(false)}>
              Zrušit
            </Button>
            <Button onClick={handleCompleteEvent} disabled={isCompleting}>
              {isCompleting ? 'Zpracování...' : `Dokončit akci (${staffCompletionData.length} brigádníků)`}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

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
                <div className="flex items-center gap-2 flex-wrap">
                  <p className="font-medium text-lg">{shiftToAssign.event?.title || 'Směna'}</p>
                  {(shiftToAssign as any).required_role && (
                    <Badge className={`${staffRoleColors[(shiftToAssign as any).required_role] || 'bg-gray-500'} text-white`}>
                      {staffRoleLabels[(shiftToAssign as any).required_role] || (shiftToAssign as any).required_role}
                    </Badge>
                  )}
                </div>
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
              {isAssigning ? 'Zpracování...' : `Přiřadit ${staffRoleLabels[(shiftToAssign as any)?.required_role] || 'brigádníka'}`}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

    </div>
  );
};

export default Shifts;
