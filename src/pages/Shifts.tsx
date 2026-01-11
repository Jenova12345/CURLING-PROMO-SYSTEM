import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useShifts } from '@/hooks/useShifts';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { Clock, CheckCircle, XCircle, TrendingUp, Calendar } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';

const Shifts = () => {
  const { isAdmin, isStaff, user } = useAuth();
  const { 
    shifts, 
    openShifts, 
    myShifts, 
    claimShift, 
    completeShift, 
    cancelShift,
    isClaiming,
    totalHoursWorked,
    totalEarnings,
    isLoading 
  } = useShifts();
  const { toast } = useToast();

  const [completeDialogOpen, setCompleteDialogOpen] = useState(false);
  const [selectedShiftId, setSelectedShiftId] = useState<string | null>(null);
  const [hoursWorked, setHoursWorked] = useState('');
  const [notes, setNotes] = useState('');

  const handleClaimShift = async (shiftId: string) => {
    try {
      await claimShift(shiftId);
      toast({
        title: 'Směna přijata!',
        description: 'Úspěšně jste si vzali tuto směnu.',
      });
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Směna již byla obsazena někým jiným.',
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
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se zrušit směnu.',
        variant: 'destructive',
      });
    }
  };

  const openCompleteDialog = (shiftId: string) => {
    setSelectedShiftId(shiftId);
    setCompleteDialogOpen(true);
  };

  const handleCompleteShift = async () => {
    if (!selectedShiftId || !hoursWorked) {
      toast({
        title: 'Chyba',
        description: 'Vyplňte počet odpracovaných hodin.',
        variant: 'destructive',
      });
      return;
    }

    try {
      await completeShift({
        shiftId: selectedShiftId,
        hoursWorked: parseFloat(hoursWorked),
        notes: notes || undefined,
      });
      toast({
        title: 'Směna dokončena',
        description: 'Hodiny byly zaznamenány.',
      });
      setCompleteDialogOpen(false);
      setHoursWorked('');
      setNotes('');
      setSelectedShiftId(null);
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se dokončit směnu.',
        variant: 'destructive',
      });
    }
  };

  const statusLabels: Record<string, string> = {
    open: 'Volná',
    claimed: 'Obsazená',
    completed: 'Dokončená',
    cancelled: 'Zrušená',
  };

  const statusColors: Record<string, string> = {
    open: 'bg-green-500',
    claimed: 'bg-blue-500',
    completed: 'bg-gray-500',
    cancelled: 'bg-red-500',
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
              <p className="text-xs text-muted-foreground">k dispozici k převzetí</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Odpracované hodiny</CardTitle>
              <TrendingUp className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{totalHoursWorked} h</div>
              <p className="text-xs text-muted-foreground">tento měsíc</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">K výplatě</CardTitle>
              <CheckCircle className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{totalEarnings.toLocaleString('cs-CZ')} Kč</div>
              <p className="text-xs text-muted-foreground">tento měsíc</p>
            </CardContent>
          </Card>
        </div>
      )}

      {/* Tabs */}
      <Tabs defaultValue={isStaff ? 'available' : 'all'} className="w-full">
        <TabsList className="w-full sm:w-auto grid grid-cols-2 sm:flex">
          {isStaff && <TabsTrigger value="available" className="text-xs sm:text-sm">Volné směny</TabsTrigger>}
          {isStaff && <TabsTrigger value="my" className="text-xs sm:text-sm">Moje směny</TabsTrigger>}
          {isAdmin && <TabsTrigger value="all" className="text-xs sm:text-sm">Všechny směny</TabsTrigger>}
        </TabsList>

        {/* Available Shifts */}
        {isStaff && (
          <TabsContent value="available" className="space-y-4">
            {openShifts.length === 0 ? (
              <Card>
                <CardContent className="flex flex-col items-center justify-center py-12">
                  <Calendar className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Momentálně nejsou k dispozici žádné volné směny.</p>
                </CardContent>
              </Card>
            ) : (
              openShifts.map((shift) => (
                <Card key={shift.id}>
                  <CardContent className="flex flex-col sm:flex-row sm:items-center justify-between p-4 md:p-6 gap-4">
                    <div className="flex items-start gap-3">
                      <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors.open}`} />
                      <div>
                        <p className="font-medium text-base md:text-lg">{shift.event?.title || 'Směna'}</p>
                        <p className="text-muted-foreground text-sm">
                          {shift.event && format(new Date(shift.event.start_time), 'EEE d. MMM yyyy', { locale: cs })}
                        </p>
                        <p className="text-xs md:text-sm text-muted-foreground">
                          {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                        </p>
                      </div>
                    </div>
                    <div className="flex items-center justify-between sm:justify-end gap-4 ml-6 sm:ml-0">
                      <div className="text-left sm:text-right">
                        <p className="text-xs text-muted-foreground">Sazba</p>
                        <p className="font-medium text-sm">{shift.hourly_rate} Kč/h</p>
                      </div>
                      <Button 
                        onClick={() => handleClaimShift(shift.id)} 
                        disabled={isClaiming}
                        className="whitespace-nowrap"
                      >
                        {isClaiming ? 'Zpracování...' : 'Vzít směnu'}
                      </Button>
                    </div>
                  </CardContent>
                </Card>
              ))
            )}
          </TabsContent>
        )}

        {/* My Shifts */}
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
              myShifts.map((shift) => (
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
                          <p className="text-xs md:text-sm text-green-600 mt-1">
                            Odpracováno: {shift.hours_worked} h ({(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč)
                          </p>
                        )}
                      </div>
                    </div>
                    <div className="flex items-center gap-2 flex-wrap ml-6 sm:ml-0">
                      <Badge variant={shift.status === 'completed' ? 'default' : 'secondary'}>
                        {statusLabels[shift.status]}
                      </Badge>
                      {shift.status === 'claimed' && (
                        <>
                          <Button 
                            variant="outline" 
                            size="sm"
                            onClick={() => handleCancelShift(shift.id)}
                            className="h-8"
                          >
                            <XCircle className="h-4 w-4 mr-1" />
                            <span className="hidden sm:inline">Zrušit</span>
                          </Button>
                          <Button 
                            size="sm"
                            onClick={() => openCompleteDialog(shift.id)}
                            className="h-8"
                          >
                            <CheckCircle className="h-4 w-4 mr-1" />
                            <span className="hidden sm:inline">Dokončit</span>
                          </Button>
                        </>
                      )}
                    </div>
                  </CardContent>
                </Card>
              ))
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
                    <div key={shift.id} className="flex items-center justify-between p-4 rounded-lg bg-accent/50">
                      <div className="flex items-center gap-4">
                        <div className={`w-3 h-3 rounded-full ${statusColors[shift.status]}`} />
                        <div>
                          <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                          <p className="text-sm text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center gap-4">
                        <Badge variant="outline">{statusLabels[shift.status]}</Badge>
                        {shift.hours_worked && (
                          <span className="text-sm">{shift.hours_worked} h</span>
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

      {/* Complete Shift Dialog */}
      <Dialog open={completeDialogOpen} onOpenChange={setCompleteDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Dokončit směnu</DialogTitle>
            <DialogDescription>
              Zadejte počet skutečně odpracovaných hodin.
            </DialogDescription>
          </DialogHeader>
          
          <div className="space-y-4">
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
              <Label htmlFor="notes">Poznámky (volitelné)</Label>
              <Textarea
                id="notes"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Případné poznámky ke směně..."
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setCompleteDialogOpen(false)}>
              Zrušit
            </Button>
            <Button onClick={handleCompleteShift}>
              Dokončit směnu
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Shifts;
