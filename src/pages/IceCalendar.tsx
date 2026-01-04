import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useEvents } from '@/hooks/useEvents';
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
import { Plus, ChevronLeft, ChevronRight, Trash2, Edit } from 'lucide-react';
import { format, startOfMonth, endOfMonth, eachDayOfInterval, isSameMonth, isSameDay, addMonths, subMonths } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Database } from '@/integrations/supabase/types';

type EventType = Database['public']['Enums']['event_type'];

const IceCalendar = () => {
  const { isAdmin } = useAuth();
  const { events, createEvent, deleteEvent, isCreating, isDeleting } = useEvents();
  const { toast } = useToast();
  
  const [currentMonth, setCurrentMonth] = useState(new Date());
  const [selectedDate, setSelectedDate] = useState<Date | null>(null);
  const [isCreateDialogOpen, setIsCreateDialogOpen] = useState(false);
  
  // Form state
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [eventType, setEventType] = useState<EventType>('free');
  const [startTime, setStartTime] = useState('09:00');
  const [endTime, setEndTime] = useState('11:00');
  const [requiredStaff, setRequiredStaff] = useState('0');

  const monthStart = startOfMonth(currentMonth);
  const monthEnd = endOfMonth(currentMonth);
  const daysInMonth = eachDayOfInterval({ start: monthStart, end: monthEnd });

  const eventTypeColors: Record<EventType, string> = {
    commercial: 'bg-green-500 text-white',
    training: 'bg-blue-500 text-white',
    maintenance: 'bg-orange-500 text-white',
    free: 'bg-gray-300 text-gray-700',
  };

  const eventTypeLabels: Record<EventType, string> = {
    commercial: 'Komerční akce',
    training: 'Trénink',
    maintenance: 'Údržba ledu',
    free: 'Volný termín',
  };

  const getEventsForDay = (day: Date) => {
    return events.filter(event => isSameDay(new Date(event.start_time), day));
  };

  const handleCreateEvent = async () => {
    if (!selectedDate || !title) {
      toast({
        title: 'Chyba',
        description: 'Vyplňte prosím název události',
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

    try {
      await createEvent({
        title,
        description: description || undefined,
        event_type: eventType,
        start_time: startDateTime.toISOString(),
        end_time: endDateTime.toISOString(),
        required_staff: eventType === 'commercial' ? parseInt(requiredStaff) : 0,
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

  const resetForm = () => {
    setTitle('');
    setDescription('');
    setEventType('free');
    setStartTime('09:00');
    setEndTime('11:00');
    setRequiredStaff('0');
    setSelectedDate(null);
  };

  const dayNames = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold">Kalendář ledu</h1>
          <p className="text-muted-foreground mt-1">
            Přehled obsazenosti a dostupnosti ledové plochy
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
            <DialogContent className="max-w-md">
              <DialogHeader>
                <DialogTitle>Vytvořit novou událost</DialogTitle>
                <DialogDescription>
                  Přidejte novou událost do kalendáře ledové plochy.
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
                  <Label htmlFor="title">Název události</Label>
                  <Input
                    id="title"
                    value={title}
                    onChange={(e) => setTitle(e.target.value)}
                    placeholder="Např. Firemní teambuilding"
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
                      <SelectItem value="free">Volný termín</SelectItem>
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
                  />
                </div>
              </div>

              <DialogFooter>
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
      <div className="flex flex-wrap gap-4">
        {(Object.keys(eventTypeLabels) as EventType[]).map((type) => (
          <div key={type} className="flex items-center gap-2">
            <div className={`w-4 h-4 rounded ${eventTypeColors[type]}`} />
            <span className="text-sm">{eventTypeLabels[type]}</span>
          </div>
        ))}
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
        <CardContent className="p-4">
          {/* Day headers */}
          <div className="grid grid-cols-7 gap-1 mb-2">
            {dayNames.map((day) => (
              <div key={day} className="text-center text-sm font-medium text-muted-foreground py-2">
                {day}
              </div>
            ))}
          </div>

          {/* Days grid */}
          <div className="grid grid-cols-7 gap-1">
            {/* Empty cells for days before month start */}
            {Array.from({ length: (monthStart.getDay() + 6) % 7 }).map((_, i) => (
              <div key={`empty-${i}`} className="min-h-[100px] bg-muted/30 rounded-lg" />
            ))}

            {/* Actual days */}
            {daysInMonth.map((day) => {
              const dayEvents = getEventsForDay(day);
              const isToday = isSameDay(day, new Date());

              return (
                <div
                  key={day.toISOString()}
                  className={`min-h-[100px] border rounded-lg p-2 ${
                    isToday ? 'border-primary bg-primary/5' : 'border-border'
                  }`}
                >
                  <div className={`text-sm font-medium mb-1 ${isToday ? 'text-primary' : ''}`}>
                    {format(day, 'd')}
                  </div>
                  <div className="space-y-1">
                    {dayEvents.map((event) => (
                      <div
                        key={event.id}
                        className={`text-xs p-1 rounded truncate ${eventTypeColors[event.event_type]}`}
                        title={`${event.title} - ${format(new Date(event.start_time), 'HH:mm')} - ${format(new Date(event.end_time), 'HH:mm')}`}
                      >
                        {format(new Date(event.start_time), 'HH:mm')} {event.title}
                      </div>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>
        </CardContent>
      </Card>

      {/* Upcoming Events List */}
      <Card>
        <CardHeader>
          <CardTitle>Nadcházející události</CardTitle>
          <CardDescription>Seznam všech plánovaných akcí</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="space-y-4">
            {events
              .filter(e => new Date(e.start_time) >= new Date())
              .slice(0, 10)
              .map((event) => (
                <div key={event.id} className="flex items-center justify-between p-4 rounded-lg bg-accent/50">
                  <div className="flex items-center gap-4">
                    <div className={`w-4 h-4 rounded ${eventTypeColors[event.event_type]}`} />
                    <div>
                      <p className="font-medium">{event.title}</p>
                      <p className="text-sm text-muted-foreground">
                        {format(new Date(event.start_time), 'EEEE d. MMMM yyyy, HH:mm', { locale: cs })} - {format(new Date(event.end_time), 'HH:mm')}
                      </p>
                      {event.description && (
                        <p className="text-sm text-muted-foreground mt-1">{event.description}</p>
                      )}
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant="outline">{eventTypeLabels[event.event_type]}</Badge>
                    {event.required_staff && event.required_staff > 0 && (
                      <Badge variant="secondary">{event.required_staff} brigádníků</Badge>
                    )}
                    {isAdmin && (
                      <Button
                        variant="ghost"
                        size="icon"
                        onClick={() => handleDeleteEvent(event.id)}
                        disabled={isDeleting}
                      >
                        <Trash2 className="h-4 w-4 text-destructive" />
                      </Button>
                    )}
                  </div>
                </div>
              ))}
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default IceCalendar;
