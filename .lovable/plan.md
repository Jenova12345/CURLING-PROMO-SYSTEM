

## Oprava zobrazení směn pro multi-role události

### Problém

Když má událost více směn s různými rolemi (např. 1x Instruktor, 1x Obsluha baru) a uživatel má obě role, vidí pouze první směnu. Druhá je skrytá, i když na ni má nárok.

### Příčina

V `Shifts.tsx` (řádky 578-619) se pro každou událost vykresluje pouze jedna karta s jedním tlačítkem "Přihlásit se", které odkazuje na `availableShiftIds[0]`. Badge se zobrazuje pouze z `availableShifts[0].required_role`.

```tsx
// Současný problematický kód (řádek 586-589)
{(eventItem as any).availableShifts?.[0]?.required_role && (
  <Badge>...</Badge>  // Pouze první role
)}

// Tlačítko (řádek 610)
onClick={() => handleRequestShift(eventItem.availableShiftIds[0])}  // Pouze první směna
```

### Řešení

Změnit UI tak, aby pro každou směnu v `availableShifts` vykreslila samostatný řádek s vlastním badge a tlačítkem.

---

### Změny v `src/pages/Shifts.tsx`

**Řádky 578-619** - Nahradit celý blok mapování událostí:

| Před | Po |
|------|-----|
| 1 karta = 1 událost | 1 karta = 1 událost, ALE s více řádky pro směny |
| 1 badge (první role) | Badge pro každou směnu |
| 1 tlačítko | Tlačítko pro každou směnu |

**Nový kód:**

```tsx
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
```

---

### Vizuální výsledek

**Před:**
```
┌─────────────────────────────────────────┐
│ ● Test Multi Role                       │
│   Pá 31. ledna 2025                     │
│   18:00 - 22:00                         │
│                                         │
│   Sazba: 150 Kč/h  Volná: 2/2  [Přihlásit se] │
└─────────────────────────────────────────┘
```

**Po:**
```
┌─────────────────────────────────────────┐
│ ● Test Multi Role                       │
│   Pá 31. ledna 2025                     │
│   18:00 - 22:00                         │
│                                         │
│   ┌─────────────────────────────────┐   │
│   │ [Instruktor]  150 Kč/h  [Přihlásit se] │   │
│   └─────────────────────────────────┘   │
│   ┌─────────────────────────────────┐   │
│   │ [Obsluha baru] 150 Kč/h [Přihlásit se] │   │
│   └─────────────────────────────────┘   │
│                                         │
│   Volná místa celkem: 2/2               │
└─────────────────────────────────────────┘
```

---

### Soubory k úpravě

| Soubor | Změna |
|--------|-------|
| `src/pages/Shifts.tsx` | Řádky 578-619 - Přepsat blok Available Shifts na iteraci přes jednotlivé směny |

### Důležité poznámky

- Žádné změny v `useShifts.ts` - data jsou již správně připravena v `availableShifts`
- Používám `(shift as any).required_role` pro TypeScript kompatibilitu
- Zachovávám stávající `handleRequestShift(shift.id)` logiku - jen předávám správné ID

