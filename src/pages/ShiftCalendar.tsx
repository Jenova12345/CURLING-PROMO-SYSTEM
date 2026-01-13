import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useShifts } from '@/hooks/useShifts';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useToast } from '@/hooks/use-toast';
import { ChevronLeft, ChevronRight, Clock, User, Calendar } from 'lucide-react';
import { format, startOfMonth, endOfMonth, eachDayOfInterval, isSameDay, addMonths, subMonths } from 'date-fns';
import { cs } from 'date-fns/locale';

const ShiftCalendar = () => {
  const { isAdmin, isStaff, user } = useAuth();
  const { shifts, openShiftsByEvent, requestShift, isRequesting } = useShifts();
  const { toast } = useToast();

  const [currentMonth, setCurrentMonth] = useState(new Date());
  const [selectedDate, setSelectedDate] = useState<Date | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);

  const monthStart = startOfMonth(currentMonth);
  const monthEnd = endOfMonth(currentMonth);
  const daysInMonth = eachDayOfInterval({ start: monthStart, end: monthEnd });

  const statusColors: Record<string, string> = {
    open: 'bg-green-500',
    pending: 'bg-yellow-500',
    claimed: 'bg-blue-500',
    completed: 'bg-gray-500',
  };

  const statusLabels: Record<string, string> = {
    open: 'Volná',
    pending: 'Čeká na schválení',
    claimed: 'Přiřazená',
    completed: 'Dokončená',
  };

  const getShiftsForDay = (day: Date) => {
    return shifts.filter(shift => {
      if (!shift.event?.start_time) return false;
      return isSameDay(new Date(shift.event.start_time), day);
    });
  };

  // Get event IDs where the user already has a pending, claimed or completed shift
  const myEventIds = new Set(
    shifts
      .filter(s => s.claimed_by === user?.id && (s.status === 'pending' || s.status === 'claimed' || s.status === 'completed'))
      .map(s => s.event_id)
  );

  // Group shifts by event for display - for staff, group open shifts into one entry per event
  const getVisibleShiftsForDay = (day: Date) => {
    const dayShifts = getShiftsForDay(day);
    
    if (isAdmin) {
      return dayShifts;
    }
    
    // Staff: show their own shifts + one entry per event with open slots
    const myShiftsForDay = dayShifts.filter(s => s.claimed_by === user?.id);
    
    // Group open shifts by event
    const openShiftsByEventForDay = Object.values(
      dayShifts
        .filter(s => s.status === 'open' && !myEventIds.has(s.event_id))
        .reduce((acc, shift) => {
          const eventId = shift.event_id;
          if (!acc[eventId]) {
            const totalSlots = dayShifts.filter(s => s.event_id === eventId).length;
            acc[eventId] = {
              ...shift,
              _isGrouped: true,
              _openCount: 0,
              _totalSlots: totalSlots,
              _availableShiftIds: [] as string[],
            };
          }
          acc[eventId]._openCount += 1;
          acc[eventId]._availableShiftIds.push(shift.id);
          return acc;
        }, {} as Record<string, any>)
    );
    
    return [...myShiftsForDay, ...openShiftsByEventForDay];
  };

  const handleDayClick = (day: Date) => {
    const dayShifts = getVisibleShiftsForDay(day);
    if (dayShifts.length > 0) {
      setSelectedDate(day);
      setDialogOpen(true);
    }
  };

  const handleRequestShift = async (shiftId: string) => {
    try {
      await requestShift(shiftId);
      toast({
        title: 'Přihláška odeslána!',
        description: 'Čeká na schválení adminem.',
      });
      setDialogOpen(false);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se přihlásit na směnu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const selectedDayShifts = selectedDate ? getVisibleShiftsForDay(selectedDate) : [];

  const dayNames = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];

  const canRequestShift = (shift: any) => {
    // For grouped shifts, check if it's an open grouped entry
    if (shift._isGrouped) return true;
    return shift.status === 'open' && !myEventIds.has(shift.event_id);
  };

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl md:text-3xl font-bold">Kalendář směn</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          {isAdmin ? 'Přehled všech směn na kalendáři' : 'Volné směny a vaše přiřazení'}
        </p>
      </div>

      {/* Legend */}
      <div className="flex flex-wrap gap-3 md:gap-4">
        <div className="flex items-center gap-1.5">
          <div className="w-3 h-3 rounded-full bg-green-500" />
          <span className="text-xs md:text-sm">Volná</span>
        </div>
        <div className="flex items-center gap-1.5">
          <div className="w-3 h-3 rounded-full bg-yellow-500" />
          <span className="text-xs md:text-sm">Čekající</span>
        </div>
        <div className="flex items-center gap-1.5">
          <div className="w-3 h-3 rounded-full bg-blue-500" />
          <span className="text-xs md:text-sm">Přiřazená</span>
        </div>
        <div className="flex items-center gap-1.5">
          <div className="w-3 h-3 rounded-full bg-gray-500" />
          <span className="text-xs md:text-sm">Dokončená</span>
        </div>
      </div>

      {/* Calendar Navigation */}
      <div className="flex items-center justify-between">
        <Button variant="outline" onClick={() => setCurrentMonth(subMonths(currentMonth, 1))}>
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <h2 className="text-xl font-semibold">
          {format(currentMonth, 'LLLL yyyy', { locale: cs })}
        </h2>
        <Button variant="outline" onClick={() => setCurrentMonth(addMonths(currentMonth, 1))}>
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>

      {/* Calendar Grid */}
      <Card>
        <CardContent className="p-2 md:p-4">
          {/* Day headers */}
          <div className="grid grid-cols-7 gap-0.5 md:gap-1 mb-2">
            {dayNames.map((day) => (
              <div key={day} className="text-center text-[10px] md:text-sm font-medium text-muted-foreground py-1 md:py-2">
                {day}
              </div>
            ))}
          </div>

          {/* Days grid */}
          <div className="grid grid-cols-7 gap-0.5 md:gap-1">
            {/* Empty cells for days before month start */}
            {Array.from({ length: (monthStart.getDay() + 6) % 7 }).map((_, i) => (
              <div key={`empty-${i}`} className="min-h-[60px] md:min-h-[80px] bg-muted/30 rounded" />
            ))}

            {/* Actual days */}
            {daysInMonth.map((day) => {
              const dayShifts = getVisibleShiftsForDay(day);
              const isToday = isSameDay(day, new Date());
              const hasShifts = dayShifts.length > 0;

              // Count by status
              const statusCounts = dayShifts.reduce((acc, s) => {
                acc[s.status] = (acc[s.status] || 0) + 1;
                return acc;
              }, {} as Record<string, number>);

              return (
                <div
                  key={day.toISOString()}
                  onClick={() => handleDayClick(day)}
                  className={`min-h-[60px] md:min-h-[80px] border rounded p-1 md:p-2 transition-colors ${
                    isToday ? 'border-primary bg-primary/5' : 'border-border'
                  } ${hasShifts ? 'cursor-pointer hover:bg-accent/50' : ''}`}
                >
                  <div className={`text-[10px] md:text-sm font-medium mb-1 ${isToday ? 'text-primary' : ''}`}>
                    {format(day, 'd')}
                  </div>
                  
                  {/* Shift indicators */}
                  <div className="flex flex-wrap gap-0.5">
                    {statusCounts.open && (
                      <div className="flex items-center gap-0.5">
                        {Array.from({ length: Math.min(statusCounts.open, 3) }).map((_, i) => (
                          <div key={`open-${i}`} className="w-2 h-2 rounded-full bg-green-500" />
                        ))}
                        {statusCounts.open > 3 && (
                          <span className="text-[8px] text-muted-foreground">+{statusCounts.open - 3}</span>
                        )}
                      </div>
                    )}
                    {statusCounts.pending && (
                      <div className="flex items-center gap-0.5">
                        {Array.from({ length: Math.min(statusCounts.pending, 2) }).map((_, i) => (
                          <div key={`pending-${i}`} className="w-2 h-2 rounded-full bg-yellow-500" />
                        ))}
                      </div>
                    )}
                    {statusCounts.claimed && (
                      <div className="flex items-center gap-0.5">
                        {Array.from({ length: Math.min(statusCounts.claimed, 2) }).map((_, i) => (
                          <div key={`claimed-${i}`} className="w-2 h-2 rounded-full bg-blue-500" />
                        ))}
                      </div>
                    )}
                    {statusCounts.completed && (
                      <div className="flex items-center gap-0.5">
                        {Array.from({ length: Math.min(statusCounts.completed, 2) }).map((_, i) => (
                          <div key={`completed-${i}`} className="w-2 h-2 rounded-full bg-gray-500" />
                        ))}
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </CardContent>
      </Card>

      {/* Day Detail Dialog */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Calendar className="h-5 w-5" />
              {selectedDate && format(selectedDate, 'EEEE d. MMMM yyyy', { locale: cs })}
            </DialogTitle>
          </DialogHeader>

          <div className="space-y-3 max-h-[60vh] overflow-y-auto">
            {selectedDayShifts.map((shift) => {
              const isGrouped = shift._isGrouped;
              const shiftIdToRequest = isGrouped ? shift._availableShiftIds[0] : shift.id;
              
              return (
                <div 
                  key={isGrouped ? `grouped-${shift.event_id}` : shift.id} 
                  className="p-4 rounded-lg border bg-card"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="flex items-start gap-3">
                      <div className={`w-3 h-3 rounded-full mt-1.5 flex-shrink-0 ${statusColors[shift.status]}`} />
                      <div>
                        <p className="font-medium">{shift.event?.title || 'Směna'}</p>
                        <p className="text-sm text-muted-foreground">
                          {shift.event && `${format(new Date(shift.event.start_time), 'HH:mm')} - ${format(new Date(shift.event.end_time), 'HH:mm')}`}
                        </p>
                        <div className="flex items-center gap-2 mt-2">
                          <Badge variant="outline" className="text-xs">
                            {isGrouped ? 'Volná' : statusLabels[shift.status]}
                          </Badge>
                          <span className="text-xs text-muted-foreground">
                            {shift.hourly_rate} Kč/h
                          </span>
                          {isGrouped && (
                            <span className="text-xs font-medium text-green-600">
                              Volná místa: {shift._openCount}/{shift._totalSlots}
                            </span>
                          )}
                        </div>
                        {!isGrouped && shift.claimed_by && shift.claimed_profile && (
                          <div className="flex items-center gap-1 mt-2 text-sm text-muted-foreground">
                            <User className="h-3 w-3" />
                            {shift.claimed_profile.full_name}
                          </div>
                        )}
                      </div>
                    </div>

                    {isStaff && canRequestShift(shift) && (
                      <Button 
                        size="sm"
                        onClick={() => handleRequestShift(shiftIdToRequest)}
                        disabled={isRequesting}
                      >
                        {isRequesting ? 'Zpracování...' : 'Přihlásit se'}
                      </Button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default ShiftCalendar;
