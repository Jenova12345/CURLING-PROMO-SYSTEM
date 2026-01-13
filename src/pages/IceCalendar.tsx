import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useEvents } from '@/hooks/useEvents';
import { useShifts } from '@/hooks/useShifts';
import { useIsMobile } from '@/hooks/use-mobile';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { Calendar } from '@/components/ui/calendar';
import { useToast } from '@/hooks/use-toast';
import { Plus, ChevronLeft, ChevronRight, Trash2, User, Clock, Pencil } from 'lucide-react';
import { format, startOfMonth, endOfMonth, eachDayOfInterval, isSameDay, addMonths, subMonths, startOfWeek, addDays, addWeeks, subWeeks } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Database } from '@/integrations/supabase/types';
import { eventSchema, safeValidate, VALIDATION_LIMITS, sanitizeText } from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';

type EventType = Database['public']['Enums']['event_type'];
type ViewMode = 'week' | 'month';
type Event = Database['public']['Tables']['events']['Row'];

const IceCalendar = () => {
  const { isAdmin, isStaff, user } = useAuth();
  const { events, createEvent, updateEvent, deleteEvent, isCreating, isUpdating, isDeleting } = useEvents();
  const { shifts, requestShift, isRequesting } = useShifts();
  const { toast } = useToast();
  const { retryAfter, checkLimit } = useRateLimit('createEvent');
  const isMobile = useIsMobile();
  
  const [currentMonth, setCurrentMonth] = useState(new Date());
  const [selectedDate, setSelectedDate] = useState<Date | null>(null);
  const [isCreateDialogOpen, setIsCreateDialogOpen] = useState(false);
  const [isEditDialogOpen, setIsEditDialogOpen] = useState(false);
  const [editingEvent, setEditingEvent] = useState<Event | null>(null);
  const [isDayDetailOpen, setIsDayDetailOpen] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>('week');
  const [weekStart, setWeekStart] = useState(() => 
    startOfWeek(new Date(), { weekStartsOn: 1 })
  );
  
  // Form state
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [eventType, setEventType] = useState<EventType>('commercial');
  const [startTime, setStartTime] = useState('09:00');
  const [endTime, setEndTime] = useState('11:00');
  const [requiredStaff, setRequiredStaff] = useState('0');

  const monthStart = startOfMonth(currentMonth);
  const monthEnd = endOfMonth(currentMonth);
  const daysInMonth = eachDayOfInterval({ start: monthStart, end: monthEnd });

  // Week days calculation
  const getWeekDays = () => {
    return eachDayOfInterval({
      start: weekStart,
      end: addDays(weekStart, 6)
    });
  };

  const weekDays = getWeekDays();
  const displayDays = isMobile && viewMode === 'week' ? weekDays : daysInMonth;

  // Navigation handlers
  const handlePrevNav = () => {
    if (isMobile && viewMode === 'week') {
      setWeekStart(subWeeks(weekStart, 1));
    } else {
      setCurrentMonth(subMonths(currentMonth, 1));
    }
  };

  const handleNextNav = () => {
    if (isMobile && viewMode === 'week') {
      setWeekStart(addWeeks(weekStart, 1));
    } else {
      setCurrentMonth(addMonths(currentMonth, 1));
    }
  };

  const handleGoToToday = () => {
    const today = new Date();
    setWeekStart(startOfWeek(today, { weekStartsOn: 1 }));
    setCurrentMonth(today);
  };

  // Format header based on view mode
  const getCalendarHeader = () => {
    if (isMobile && viewMode === 'week') {
      const endDate = addDays(weekStart, 6);
      return `${format(weekStart, 'd.', { locale: cs })} - ${format(endDate, 'd. MMMM yyyy', { locale: cs })}`;
    }
    return format(currentMonth, 'LLLL yyyy', { locale: cs });
  };

  const eventTypeColors: Record<string, string> = {
    commercial: 'bg-green-500 text-white',
    training: 'bg-blue-500 text-white',
    maintenance: 'bg-orange-500 text-white',
  };

  const eventTypeLabels: Record<string, string> = {
    commercial: 'Komerční akce',
    training: 'Trénink',
    maintenance: 'Údržba ledu',
  };

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

  const getEventsForDay = (day: Date) => {
    return events.filter(event => isSameDay(new Date(event.start_time), day));
  };

  // Get shift fill stats for an event
  const getEventShiftStats = (eventId: string) => {
    const eventShifts = shifts.filter(s => s.event_id === eventId);
    const total = eventShifts.length;
    const filled = eventShifts.filter(s => s.status === 'claimed' || s.status === 'pending' || s.status === 'completed').length;
    return { filled, total };
  };

  // Get shifts for a specific day
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

  const handleCreateEvent = async () => {
    // Rate limiting check
    if (!checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    if (!selectedDate) {
      toast({
        title: 'Chyba',
        description: 'Vyberte prosím datum události',
        variant: 'destructive',
      });
      return;
    }

    const startDateTime = new Date(selectedDate);
    const [startHours, startMinutes] = startTime.split(':');
    startDateTime.setHours(parseInt(startHours), parseInt(startMinutes));

    const endDateTime = new Date(selectedDate);
    const [endHours, endMinutes] = endTime.split(':');
    endDateTime.setHours(parseInt(endHours), parseInt(endMinutes));

    // Validate input using schema
    const validation = safeValidate(eventSchema, {
      title: sanitizeText(title),
      description: sanitizeText(description) || undefined,
      event_type: eventType,
      start_time: startDateTime.toISOString(),
      end_time: endDateTime.toISOString(),
      required_staff: eventType === 'commercial' ? parseInt(requiredStaff) || 0 : 0,
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
      await createEvent({
        title: validation.data.title,
        description: validation.data.description,
        event_type: validation.data.event_type,
        start_time: validation.data.start_time,
        end_time: validation.data.end_time,
        required_staff: validation.data.required_staff,
      });

      toast({
        title: 'Událost vytvořena',
        description: eventType === 'commercial' && parseInt(requiredStaff) > 0
          ? `Brigádníci byli upozorněni na ${requiredStaff} volných směn.`
          : 'Událost byla úspěšně přidána do kalendáře.',
      });

      setIsCreateDialogOpen(false);
      resetForm();
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se vytvořit událost',
        variant: 'destructive',
      });
    }
  };

  const handleDeleteEvent = async (eventId: string) => {
    try {
      await deleteEvent(eventId);
      toast({
        title: 'Událost smazána',
        description: 'Událost byla úspěšně odstraněna.',
      });
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se smazat událost',
        variant: 'destructive',
      });
    }
  };

  const handleRequestShift = async (shiftId: string) => {
    try {
      await requestShift(shiftId);
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

  const handleDayClick = (day: Date) => {
    const dayEvents = getEventsForDay(day);
    const dayShifts = (isAdmin || isStaff) ? getVisibleShiftsForDay(day) : [];
    
    if (dayEvents.length > 0 || dayShifts.length > 0) {
      setSelectedDate(day);
      setIsDayDetailOpen(true);
    }
  };

  const canRequestShift = (shift: any) => {
    // For grouped shifts, check if it's an open grouped entry
    if (shift._isGrouped) return true;
    return shift.status === 'open' && !myEventIds.has(shift.event_id);
  };

  const resetForm = () => {
    setTitle('');
    setDescription('');
    setEventType('commercial');
    setStartTime('09:00');
    setEndTime('11:00');
    setRequiredStaff('0');
    setSelectedDate(null);
    setEditingEvent(null);
  };

  // Open edit dialog with pre-filled data
  const handleOpenEditDialog = (event: Event) => {
    setEditingEvent(event);
    setTitle(event.title);
    setDescription(event.description || '');
    setEventType(event.event_type);
    setStartTime(format(new Date(event.start_time), 'HH:mm'));
    setEndTime(format(new Date(event.end_time), 'HH:mm'));
    setRequiredStaff(event.required_staff?.toString() || '0');
    setSelectedDate(new Date(event.start_time));
    setIsEditDialogOpen(true);
  };

  // Update event handler
  const handleUpdateEvent = async () => {
    if (!editingEvent || !selectedDate) return;

    const startDateTime = new Date(selectedDate);
    const [startHours, startMinutes] = startTime.split(':');
    startDateTime.setHours(parseInt(startHours), parseInt(startMinutes));

    const endDateTime = new Date(selectedDate);
    const [endHours, endMinutes] = endTime.split(':');
    endDateTime.setHours(parseInt(endHours), parseInt(endMinutes));

    const validation = safeValidate(eventSchema, {
      title: sanitizeText(title),
      description: sanitizeText(description) || undefined,
      event_type: eventType,
      start_time: startDateTime.toISOString(),
      end_time: endDateTime.toISOString(),
      required_staff: eventType === 'commercial' ? parseInt(requiredStaff) || 0 : 0,
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
      await updateEvent({
        id: editingEvent.id,
        title: validation.data.title,
        description: validation.data.description,
        event_type: validation.data.event_type,
        start_time: validation.data.start_time,
        end_time: validation.data.end_time,
        required_staff: validation.data.required_staff,
      });

      toast({
        title: 'Událost aktualizována',
        description: 'Změny byly úspěšně uloženy.',
      });

      setIsEditDialogOpen(false);
      resetForm();
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se aktualizovat událost',
        variant: 'destructive',
      });
    }
  };


  const dayNames = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];

  const selectedDayEvents = selectedDate ? getEventsForDay(selectedDate) : [];
  const selectedDayShifts = selectedDate && (isAdmin || isStaff) ? getVisibleShiftsForDay(selectedDate) : [];

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold">Kalendář</h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">
            Přehled obsazenosti ledové plochy{(isAdmin || isStaff) && ' a směn'}
          </p>
        </div>
        
        {isAdmin && (
          <Dialog open={isCreateDialogOpen} onOpenChange={setIsCreateDialogOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4 mr-2" />
                Nová událost
              </Button>
            </DialogTrigger>
            <DialogContent className="max-w-md max-h-[90vh] flex flex-col">
              <DialogHeader className="flex-shrink-0">
                <DialogTitle>Vytvořit novou událost</DialogTitle>
                <DialogDescription>
                  Přidejte novou událost do kalendáře ledové plochy.
                </DialogDescription>
              </DialogHeader>
              
              <div className="space-y-4 overflow-y-auto flex-1 pr-2">
                <div>
                  <Label>Vyberte datum</Label>
                  <Calendar
                    mode="single"
                    selected={selectedDate || undefined}
                    onSelect={(date) => setSelectedDate(date || null)}
                    className="rounded-md border mt-2"
                    locale={cs}
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor="title">Název události</Label>
                  <Input
                    id="title"
                    value={title}
                    onChange={(e) => setTitle(e.target.value)}
                    placeholder="Např. Firemní teambuilding"
                    maxLength={VALIDATION_LIMITS.TITLE_MAX}
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor="type">Typ události</Label>
                  <Select value={eventType} onValueChange={(v) => setEventType(v as EventType)}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="commercial">Komerční akce</SelectItem>
                      <SelectItem value="training">Trénink</SelectItem>
                      <SelectItem value="maintenance">Údržba ledu</SelectItem>
                    </SelectContent>
                  </Select>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="start">Začátek</Label>
                    <Input
                      id="start"
                      type="time"
                      value={startTime}
                      onChange={(e) => setStartTime(e.target.value)}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="end">Konec</Label>
                    <Input
                      id="end"
                      type="time"
                      value={endTime}
                      onChange={(e) => setEndTime(e.target.value)}
                    />
                  </div>
                </div>

                {eventType === 'commercial' && (
                  <div className="space-y-2">
                    <Label htmlFor="staff">Počet potřebných brigádníků</Label>
                    <Input
                      id="staff"
                      type="number"
                      min="0"
                      max={VALIDATION_LIMITS.STAFF_COUNT_MAX}
                      value={requiredStaff}
                      onChange={(e) => setRequiredStaff(e.target.value)}
                    />
                    <p className="text-xs text-muted-foreground">
                      Brigádníci budou automaticky upozorněni na volné směny.
                    </p>
                  </div>
                )}

                <div className="space-y-2">
                  <Label htmlFor="description">Popis (volitelné)</Label>
                  <Textarea
                    id="description"
                    value={description}
                    onChange={(e) => setDescription(e.target.value)}
                    placeholder="Další informace o události..."
                    maxLength={VALIDATION_LIMITS.DESCRIPTION_MAX}
                  />
                </div>
              </div>

              <DialogFooter className="flex-shrink-0">
                <Button variant="outline" onClick={() => setIsCreateDialogOpen(false)}>
                  Zrušit
                </Button>
                <Button onClick={handleCreateEvent} disabled={isCreating}>
                  {isCreating ? 'Vytváření...' : 'Vytvořit'}
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
      </div>

      {/* Legend */}
      <Card className="bg-muted/30">
        <CardContent className="p-3 md:p-4">
          <div className="space-y-3">
            {/* Event types legend */}
            <div>
              <p className="text-xs font-semibold text-foreground mb-2">Události</p>
              <div className="grid grid-cols-2 gap-x-4 gap-y-2 md:flex md:flex-wrap md:gap-4">
                {(Object.keys(eventTypeLabels) as EventType[]).map((type) => (
                  <div key={type} className="flex items-center gap-2">
                    <div className={`w-3.5 h-3.5 rounded-sm flex-shrink-0 ${eventTypeColors[type]}`} />
                    <span className="text-sm">{eventTypeLabels[type]}</span>
                  </div>
                ))}
              </div>
            </div>
            
            {/* Shift status legend - only for staff/admin */}
            {(isAdmin || isStaff) && (
              <>
                <div className="border-t border-border" />
                <div>
                  <p className="text-xs font-semibold text-foreground mb-2">Směny</p>
                  <div className="grid grid-cols-2 gap-x-4 gap-y-2 md:flex md:flex-wrap md:gap-4">
                    <div className="flex items-center gap-2">
                      <div className="w-3 h-3 rounded-full bg-green-500 flex-shrink-0" />
                      <span className="text-sm">Volná</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <div className="w-3 h-3 rounded-full bg-yellow-500 flex-shrink-0" />
                      <span className="text-sm">Čekající</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <div className="w-3 h-3 rounded-full bg-blue-500 flex-shrink-0" />
                      <span className="text-sm">Přiřazená</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <div className="w-3 h-3 rounded-full bg-gray-500 flex-shrink-0" />
                      <span className="text-sm">Dokončená</span>
                    </div>
                  </div>
                </div>
              </>
            )}
          </div>
        </CardContent>
      </Card>

      {/* View Mode Toggle - Mobile only */}
      {isMobile && (
        <div className="flex items-center justify-center gap-2">
          <Button 
            variant={viewMode === 'week' ? 'default' : 'outline'} 
            size="sm"
            onClick={() => setViewMode('week')}
          >
            Týden
          </Button>
          <Button 
            variant={viewMode === 'month' ? 'default' : 'outline'} 
            size="sm"
            onClick={() => setViewMode('month')}
          >
            Měsíc
          </Button>
        </div>
      )}

      {/* Calendar Navigation */}
      <div className="flex items-center justify-between gap-2">
        <Button variant="outline" size="icon" onClick={handlePrevNav}>
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <div className="flex items-center gap-2">
          <h2 className="text-lg md:text-xl font-semibold text-center">
            {getCalendarHeader()}
          </h2>
          {isMobile && viewMode === 'week' && (
            <Button variant="ghost" size="sm" onClick={handleGoToToday} className="text-xs">
              Dnes
            </Button>
          )}
        </div>
        <Button variant="outline" size="icon" onClick={handleNextNav}>
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>

      {/* Calendar Grid */}
      <Card>
        <CardContent className="p-2 md:p-4">
          {/* Vertical list for mobile week view */}
          {isMobile && viewMode === 'week' ? (
            <div className="space-y-2">
              {displayDays.map((day) => {
                const dayEvents = getEventsForDay(day);
                const dayShifts = (isAdmin || isStaff) ? getVisibleShiftsForDay(day) : [];
                const isToday = isSameDay(day, new Date());
                const hasContent = dayEvents.length > 0 || dayShifts.length > 0;

                return (
                  <div
                    key={day.toISOString()}
                    onClick={() => handleDayClick(day)}
                    className={`rounded-lg border transition-colors ${
                      isToday 
                        ? 'border-primary bg-primary/5 ring-1 ring-primary/20' 
                        : 'border-border'
                    } ${hasContent ? 'cursor-pointer hover:bg-accent/50' : ''}`}
                  >
                    {/* Day header */}
                    <div className={`flex items-center justify-between px-3 py-2 ${
                      hasContent ? 'border-b border-border/50' : ''
                    }`}>
                      <div className="flex items-center gap-2">
                        <span className={`font-semibold text-sm ${isToday ? 'text-primary' : ''}`}>
                          {format(day, 'EEEE', { locale: cs })}
                        </span>
                        <span className={`text-sm ${isToday ? 'text-primary' : 'text-muted-foreground'}`}>
                          {format(day, 'd. MMMM', { locale: cs })}
                        </span>
                      </div>
                      {isToday && (
                        <Badge variant="default" className="text-xs">Dnes</Badge>
                      )}
                    </div>

                    {/* Events and shifts */}
                    {hasContent ? (
                      <div className="p-2 space-y-1.5">
                        {dayEvents.map((event) => {
                          const stats = event.event_type === 'commercial' ? getEventShiftStats(event.id) : null;
                          return (
                            <div
                              key={event.id}
                              className={`flex items-center gap-2 p-2 rounded ${eventTypeColors[event.event_type]}`}
                            >
                              <Clock className="h-3.5 w-3.5 flex-shrink-0 opacity-80" />
                              <span className="text-xs font-medium">
                                {format(new Date(event.start_time), 'HH:mm')}-{format(new Date(event.end_time), 'HH:mm')}
                              </span>
                              <span className="text-sm font-medium truncate flex-1">
                                {event.title}
                              </span>
                              {(isAdmin || isStaff) && stats && stats.total > 0 && (
                                <span className={`px-1.5 py-0.5 rounded text-xs font-medium flex-shrink-0 ${
                                  stats.filled === stats.total 
                                    ? 'bg-white/30 text-white' 
                                    : 'bg-white/80 text-green-700'
                                }`}>
                                  {stats.filled}/{stats.total}
                                </span>
                              )}
                            </div>
                          );
                        })}

                        {/* Shift indicators for staff/admin */}
                        {(isAdmin || isStaff) && dayShifts.length > 0 && (
                          <div className="flex flex-wrap gap-1 pt-1">
                            {dayShifts.map((shift, index) => (
                              <div 
                                key={shift._isGrouped ? `grouped-${shift.event_id}` : shift.id}
                                className="flex items-center gap-1.5 px-2 py-1 rounded-full bg-muted/50 text-xs"
                              >
                                <div className={`w-2 h-2 rounded-full ${statusColors[shift.status]}`} />
                                <span className="text-muted-foreground">
                                  {shift._isGrouped ? `${shift._openCount} volných` : statusLabels[shift.status]}
                                </span>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    ) : (
                      <div className="px-3 py-1.5 text-xs text-muted-foreground">
                        Žádné události
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          ) : (
            <>
              {/* Day headers - only for grid view */}
              <div className="grid grid-cols-7 gap-0.5 md:gap-1 mb-2">
                {dayNames.map((day) => (
                  <div key={day} className="text-center text-[10px] md:text-sm font-medium text-muted-foreground py-1 md:py-2">
                    {day}
                  </div>
                ))}
              </div>

              {/* Days grid */}
              <div className="grid grid-cols-7 gap-0.5 md:gap-1">
                {/* Empty cells for days before start */}
                {Array.from({ length: (monthStart.getDay() + 6) % 7 }).map((_, i) => (
                  <div key={`empty-${i}`} className="min-h-[60px] md:min-h-[100px] bg-muted/30 rounded" />
                ))}

                {/* Actual days */}
                {displayDays.map((day) => {
                  const dayEvents = getEventsForDay(day);
                  const dayShifts = (isAdmin || isStaff) ? getVisibleShiftsForDay(day) : [];
                  const isToday = isSameDay(day, new Date());
                  const hasContent = dayEvents.length > 0 || dayShifts.length > 0;

                  // Count shifts by status
                  const statusCounts = dayShifts.reduce((acc, s) => {
                    acc[s.status] = (acc[s.status] || 0) + 1;
                    return acc;
                  }, {} as Record<string, number>);

                  return (
                    <div
                      key={day.toISOString()}
                      onClick={() => handleDayClick(day)}
                      className={`min-h-[60px] md:min-h-[100px] border rounded p-1 md:p-2 transition-colors ${
                        isToday ? 'border-primary bg-primary/5' : 'border-border'
                      } ${hasContent ? 'cursor-pointer hover:bg-accent/50' : ''}`}
                    >
                      <div className={`text-[10px] md:text-sm font-medium mb-0.5 md:mb-1 ${isToday ? 'text-primary' : ''}`}>
                        {format(day, 'd')}
                      </div>
                      
                      {/* Events */}
                      <div className="space-y-0.5">
                        {dayEvents.slice(0, 2).map((event) => {
                          const stats = event.event_type === 'commercial' ? getEventShiftStats(event.id) : null;
                          return (
                            <div
                              key={event.id}
                              className={`text-[8px] md:text-xs p-0.5 md:p-1 rounded truncate ${eventTypeColors[event.event_type]}`}
                              title={`${event.title} - ${format(new Date(event.start_time), 'HH:mm')} - ${format(new Date(event.end_time), 'HH:mm')}${stats ? ` (${stats.filled}/${stats.total} obsazeno)` : ''}`}
                            >
                              <span className="hidden md:inline">{format(new Date(event.start_time), 'HH:mm')} </span>
                              {event.title}
                              {(isAdmin || isStaff) && stats && stats.total > 0 && (
                                <span className={`ml-1 px-1 rounded text-[7px] md:text-[10px] font-medium ${
                                  stats.filled === stats.total 
                                    ? 'bg-white/30 text-white' 
                                    : 'bg-white/80 text-green-700'
                                }`}>
                                  {stats.filled}/{stats.total}
                                </span>
                              )}
                            </div>
                          );
                        })}
                        {dayEvents.length > 2 && (
                          <div className="text-[8px] md:text-xs text-muted-foreground">
                            +{dayEvents.length - 2} dalších
                          </div>
                        )}
                      </div>

                      {/* Shift indicators for staff/admin */}
                      {(isAdmin || isStaff) && dayShifts.length > 0 && (
                        <div className="flex flex-wrap gap-0.5 mt-1">
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
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </>
          )}
        </CardContent>
      </Card>

      {/* Day Detail Dialog */}
      <Dialog open={isDayDetailOpen} onOpenChange={setIsDayDetailOpen}>
        <DialogContent className="max-w-md max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {selectedDate && format(selectedDate, 'EEEE d. MMMM yyyy', { locale: cs })}
            </DialogTitle>
          </DialogHeader>

          <div className="space-y-4">
            {/* Events with nested shifts */}
            {selectedDayEvents.length > 0 ? (
              <div className="space-y-3">
                {selectedDayEvents.map((event) => {
                  // Filter shifts for this specific event
                  const eventShifts = selectedDayShifts.filter(shift => shift.event_id === event.id);
                  
                  // Define border color based on event type
                  const borderColors: Record<string, string> = {
                    commercial: 'border-l-green-500',
                    training: 'border-l-blue-500',
                    maintenance: 'border-l-orange-500',
                  };
                  
                  return (
                    <div 
                      key={event.id} 
                      className={`border-l-4 rounded-lg overflow-hidden bg-card border ${borderColors[event.event_type]}`}
                    >
                      {/* Event header */}
                      <div className="p-3 bg-accent/30">
                        <div className="flex items-start justify-between gap-3">
                          <div className="flex items-start gap-3">
                            <div className={`w-3 h-3 rounded mt-1 flex-shrink-0 ${eventTypeColors[event.event_type]}`} />
                            <div className="min-w-0">
                              <p className="font-medium text-sm">{event.title}</p>
                              <p className="text-xs text-muted-foreground">
                                {format(new Date(event.start_time), 'HH:mm')} - {format(new Date(event.end_time), 'HH:mm')}
                              </p>
                              {event.description && (
                                <p className="text-xs text-muted-foreground mt-1">{event.description}</p>
                              )}
                            </div>
                          </div>
                          <div className="flex items-center gap-2 flex-shrink-0">
                            <Badge variant="outline" className="text-xs whitespace-nowrap">{eventTypeLabels[event.event_type]}</Badge>
                            {isAdmin && (
                              <div className="flex items-center gap-1">
                                <Button
                                  variant="ghost"
                                  size="icon"
                                  className="h-7 w-7"
                                  onClick={() => {
                                    setIsDayDetailOpen(false);
                                    handleOpenEditDialog(event);
                                  }}
                                >
                                  <Pencil className="h-3 w-3" />
                                </Button>
                                <Button
                                  variant="ghost"
                                  size="icon"
                                  className="h-7 w-7"
                                  onClick={() => handleDeleteEvent(event.id)}
                                  disabled={isDeleting}
                                >
                                  <Trash2 className="h-3 w-3 text-destructive" />
                                </Button>
                              </div>
                            )}
                          </div>
                        </div>
                      </div>

                      {/* Nested shifts for this event */}
                      {(isAdmin || isStaff) && eventShifts.length > 0 && (
                        <div className="border-t bg-background p-3 space-y-2">
                          <p className="text-xs font-medium text-muted-foreground">
                            Směny ({eventShifts.length})
                          </p>
                          {eventShifts.map((shift) => {
                            const isGrouped = shift._isGrouped;
                            const shiftIdToRequest = isGrouped ? shift._availableShiftIds[0] : shift.id;
                            
                            return (
                              <div 
                                key={isGrouped ? `grouped-${shift.event_id}` : shift.id} 
                                className="p-2 rounded-md bg-muted/50 flex items-start justify-between gap-3"
                              >
                                <div className="flex items-start gap-2">
                                  <div className={`w-2.5 h-2.5 rounded-full mt-1 flex-shrink-0 ${statusColors[shift.status]}`} />
                                  <div>
                                    <div className="flex items-center gap-2 flex-wrap">
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
                                      <div className="flex items-center gap-1 mt-1 text-xs text-muted-foreground">
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
                                    {isRequesting ? 'Zpracování...' : 'Přihlásit'}
                                  </Button>
                                )}
                              </div>
                            );
                          })}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">Žádné události v tento den.</p>
            )}
          </div>
        </DialogContent>
      </Dialog>

      {/* Upcoming Events List */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-lg md:text-xl">Nadcházející události</CardTitle>
          <CardDescription>Seznam všech plánovaných akcí</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="space-y-3">
            {events
              .filter(e => new Date(e.start_time) >= new Date())
              .slice(0, 10)
              .map((event) => (
                <div key={event.id} className="flex flex-col sm:flex-row sm:items-center justify-between p-3 md:p-4 rounded-lg bg-accent/50 gap-3">
                  <div className="flex items-start gap-3">
                    <div className={`w-3 h-3 md:w-4 md:h-4 rounded mt-1.5 flex-shrink-0 ${eventTypeColors[event.event_type]}`} />
                    <div className="min-w-0">
                      <p className="font-medium text-sm md:text-base">{event.title}</p>
                      <p className="text-xs md:text-sm text-muted-foreground">
                        {format(new Date(event.start_time), 'EEE d. MMM, HH:mm', { locale: cs })} - {format(new Date(event.end_time), 'HH:mm')}
                      </p>
                      {event.description && (
                        <p className="text-xs md:text-sm text-muted-foreground mt-1 line-clamp-2">{event.description}</p>
                      )}
                    </div>
                  </div>
                  <div className="flex items-center gap-2 flex-wrap ml-6 sm:ml-0">
                    <Badge variant="outline" className="text-xs">{eventTypeLabels[event.event_type]}</Badge>
                    {event.event_type === 'commercial' && event.required_staff && event.required_staff > 0 && (
                      <Badge variant="secondary" className="text-xs">{event.required_staff} brig.</Badge>
                    )}
                    {isAdmin && (
                      <div className="flex items-center gap-1">
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8"
                          onClick={() => handleOpenEditDialog(event)}
                        >
                          <Pencil className="h-4 w-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8"
                          onClick={() => handleDeleteEvent(event.id)}
                          disabled={isDeleting}
                        >
                          <Trash2 className="h-4 w-4 text-destructive" />
                        </Button>
                      </div>
                    )}
                  </div>
                </div>
              ))}
          </div>
        </CardContent>
      </Card>

      {/* Edit Event Dialog */}
      <Dialog open={isEditDialogOpen} onOpenChange={(open) => {
        setIsEditDialogOpen(open);
        if (!open) resetForm();
      }}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Upravit událost</DialogTitle>
            <DialogDescription>
              Upravte detaily události.
            </DialogDescription>
          </DialogHeader>
          
          <div className="space-y-4">
            <div>
              <Label>Vyberte datum</Label>
              <Calendar
                mode="single"
                selected={selectedDate || undefined}
                onSelect={(date) => setSelectedDate(date || null)}
                className="rounded-md border mt-2"
                locale={cs}
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="edit-title">Název události</Label>
              <Input
                id="edit-title"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="Např. Firemní teambuilding"
                maxLength={VALIDATION_LIMITS.TITLE_MAX}
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="edit-type">Typ události</Label>
              <Select value={eventType} onValueChange={(v) => setEventType(v as EventType)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="commercial">Komerční akce</SelectItem>
                  <SelectItem value="training">Trénink</SelectItem>
                  <SelectItem value="maintenance">Údržba ledu</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="edit-start">Začátek</Label>
                <Input
                  id="edit-start"
                  type="time"
                  value={startTime}
                  onChange={(e) => setStartTime(e.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit-end">Konec</Label>
                <Input
                  id="edit-end"
                  type="time"
                  value={endTime}
                  onChange={(e) => setEndTime(e.target.value)}
                />
              </div>
            </div>

            {eventType === 'commercial' && (
              <div className="space-y-2">
                <Label htmlFor="edit-staff">Počet potřebných brigádníků</Label>
                <Input
                  id="edit-staff"
                  type="number"
                  min="0"
                  max={VALIDATION_LIMITS.STAFF_COUNT_MAX}
                  value={requiredStaff}
                  onChange={(e) => setRequiredStaff(e.target.value)}
                />
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="edit-description">Popis (volitelné)</Label>
              <Textarea
                id="edit-description"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Další informace o události..."
                maxLength={VALIDATION_LIMITS.DESCRIPTION_MAX}
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setIsEditDialogOpen(false)}>
              Zrušit
            </Button>
            <Button onClick={handleUpdateEvent} disabled={isUpdating}>
              {isUpdating ? 'Ukládání...' : 'Uložit změny'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default IceCalendar;