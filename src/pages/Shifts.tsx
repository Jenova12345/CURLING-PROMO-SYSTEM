import { useState, useEffect } from 'react';
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
import { Switch } from '@/components/ui/switch';
import { useToast } from '@/hooks/use-toast';
import { Clock, CheckCircle, XCircle, TrendingUp, Calendar, UserCheck, AlertCircle, Wallet, DollarSign, History, Users, BarChart3, Download, UserPlus, Landmark, Copy } from 'lucide-react';
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
    eventsToComplete,
    staffUnpaidAmounts,
    adminStats,
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
  const { payouts, myPayouts, createPayout, isCreatingPayout } = usePayouts();
  const { toast } = useToast();

  // Rate limiting hooks
  const shiftActionRateLimit = useRateLimit('shiftAction');
  const completeShiftRateLimit = useRateLimit('completeShift');
  const payoutRateLimit = useRateLimit('createPayout');
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

  // Payout dialog (admin)
  const [payoutDialogOpen, setPayoutDialogOpen] = useState(false);
  const [selectedStaff, setSelectedStaff] = useState<{ staffId: string; staffName: string; amount: number; bankAccount: string | null } | null>(null);
  const [payoutNotes, setPayoutNotes] = useState('');

  // Assign shift dialog (admin)
  const [assignDialogOpen, setAssignDialogOpen] = useState(false);
  const [shiftToAssign, setShiftToAssign] = useState<any>(null);
  const [selectedStaffId, setSelectedStaffId] = useState<string>('');

  // Staff payout history dialog (admin)
  const [staffHistoryDialogOpen, setStaffHistoryDialogOpen] = useState(false);
  const [selectedStaffHistory, setSelectedStaffHistory] = useState<{ staffId: string; staffName: string } | null>(null);

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
          setActiveTab('all');
        }
      } else if (isStaff) {
        setActiveTab('available');
      }
    }
  }, [isAdmin, isStaff, isLoading, pendingShifts.length, eventsToComplete.length, activeTab]);

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

  const openPayoutDialog = (staff: { staffId: string; staffName: string; amount: number; bankAccount: string | null }) => {
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

  // Get payouts for a specific staff member
  const getStaffPayouts = (staffId: string) => {
    return payouts.filter(p => p.user_id === staffId);
  };

  // Get completed shifts for a specific staff member
  const getStaffCompletedShifts = (staffId: string) => {
    return shifts.filter(s => s.claimed_by === staffId && s.status === 'completed');
  };

  const openStaffHistoryDialog = (staffId: string, staffName: string) => {
    setSelectedStaffHistory({ staffId, staffName });
    setStaffHistoryDialogOpen(true);
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
              {isAdmin && <SelectItem value="complete">K dokončení {eventsToComplete.length > 0 && `(${eventsToComplete.length})`}</SelectItem>}
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
              {eventsToComplete.length > 0 && (
                <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-orange-500 rounded-full">
                  {eventsToComplete.length}
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
                          <TableHead className="text-right">Akce</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {adminStats.staffStats.map((staff) => (
                          <TableRow 
                            key={staff.staffId}
                            className="cursor-pointer hover:bg-accent/70"
                            onClick={() => openStaffHistoryDialog(staff.staffId, staff.staffName)}
                          >
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
                            <TableCell className="text-right">
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={(e) => {
                                  e.stopPropagation();
                                  openStaffHistoryDialog(staff.staffId, staff.staffName);
                                }}
                              >
                                <History className="h-4 w-4" />
                              </Button>
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
                          <TableCell></TableCell>
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

              {/* Bank account section */}
              <div className="space-y-2">
                <Label className="flex items-center gap-2">
                  <Landmark className="h-4 w-4" />
                  Číslo účtu
                </Label>
                {selectedStaff.bankAccount ? (
                  <div className="flex items-center gap-2 p-3 rounded-lg bg-accent/50 border">
                    <span className="font-mono text-base flex-1">{selectedStaff.bankAccount}</span>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-8 w-8"
                      onClick={() => {
                        navigator.clipboard.writeText(selectedStaff.bankAccount!);
                        toast({
                          title: 'Zkopírováno',
                          description: 'Číslo účtu bylo zkopírováno do schránky.',
                        });
                      }}
                    >
                      <Copy className="h-4 w-4" />
                    </Button>
                  </div>
                ) : (
                  <div className="p-3 rounded-lg bg-orange-50 dark:bg-orange-950/20 border border-orange-200 dark:border-orange-900 flex items-center gap-2">
                    <AlertCircle className="h-4 w-4 text-orange-600" />
                    <span className="text-sm text-orange-700 dark:text-orange-400">
                      Brigádník nemá vyplněné číslo účtu!
                    </span>
                  </div>
                )}
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

      {/* Staff Payout History Dialog (Admin) */}
      <Dialog open={staffHistoryDialogOpen} onOpenChange={setStaffHistoryDialogOpen}>
        <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <History className="h-5 w-5" />
              Historie výplat - {selectedStaffHistory?.staffName}
            </DialogTitle>
            <DialogDescription>
              Detailní přehled všech výplat a dokončených směn brigádníka
            </DialogDescription>
          </DialogHeader>

          {selectedStaffHistory && (
            <div className="space-y-6">
              {/* Payout summary */}
              <div className="grid grid-cols-2 gap-4">
                <div className="p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900">
                  <p className="text-sm text-muted-foreground">Celkem vyplaceno</p>
                  <p className="text-2xl font-bold text-green-600">
                    {getStaffPayouts(selectedStaffHistory.staffId)
                      .reduce((sum, p) => sum + Number(p.amount), 0)
                      .toLocaleString('cs-CZ')} Kč
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {getStaffPayouts(selectedStaffHistory.staffId).length} výplat
                  </p>
                </div>
                <div className="p-4 rounded-lg bg-accent/50 border">
                  <p className="text-sm text-muted-foreground">Dokončené směny</p>
                  <p className="text-2xl font-bold">
                    {getStaffCompletedShifts(selectedStaffHistory.staffId).length}
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {getStaffCompletedShifts(selectedStaffHistory.staffId)
                      .reduce((sum, s) => sum + (Number(s.hours_worked) || 0), 0)
                      .toFixed(1)} h odpracováno
                  </p>
                </div>
              </div>

              {/* Payouts list */}
              <div>
                <h4 className="font-medium mb-3 flex items-center gap-2">
                  <Wallet className="h-4 w-4" />
                  Výplaty
                </h4>
                {getStaffPayouts(selectedStaffHistory.staffId).length === 0 ? (
                  <p className="text-muted-foreground text-sm py-4 text-center">Zatím žádné výplaty.</p>
                ) : (
                  <div className="space-y-2">
                    {getStaffPayouts(selectedStaffHistory.staffId).map((payout) => (
                      <div key={payout.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/50">
                        <div>
                          <p className="font-medium">{Number(payout.amount).toLocaleString('cs-CZ')} Kč</p>
                          <p className="text-xs text-muted-foreground">
                            {format(new Date(payout.paid_at), 'd. MMMM yyyy, HH:mm', { locale: cs })}
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
              </div>

              {/* Completed shifts list */}
              <div>
                <h4 className="font-medium mb-3 flex items-center gap-2">
                  <Clock className="h-4 w-4" />
                  Dokončené směny
                </h4>
                {getStaffCompletedShifts(selectedStaffHistory.staffId).length === 0 ? (
                  <p className="text-muted-foreground text-sm py-4 text-center">Zatím žádné dokončené směny.</p>
                ) : (
                  <div className="space-y-2 max-h-60 overflow-y-auto">
                    {getStaffCompletedShifts(selectedStaffHistory.staffId).map((shift) => (
                      <div key={shift.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/30 border">
                        <div>
                          <p className="font-medium text-sm">{shift.event?.title || 'Směna'}</p>
                          <p className="text-xs text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'd. MMM yyyy', { locale: cs })}
                          </p>
                        </div>
                        <div className="text-right">
                          <p className="font-medium text-sm">
                            {(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč
                          </p>
                          <p className="text-xs text-muted-foreground">
                            {shift.hours_worked} h × {shift.hourly_rate} Kč
                          </p>
                          {shift.payout_id ? (
                            <Badge variant="outline" className="text-[10px] mt-1 border-green-500 text-green-600">
                              Vyplaceno
                            </Badge>
                          ) : (
                            <Badge variant="outline" className="text-[10px] mt-1 border-orange-500 text-orange-600">
                              Čeká
                            </Badge>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setStaffHistoryDialogOpen(false)}>
              Zavřít
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Shifts;
