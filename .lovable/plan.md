

## Nová stránka: Nápověda a Tutoriály

Vytvoření kompletní stránky s nápovědou pro členy týmu i správce, s navigací a routingem.

---

### Přehled změn

| Soubor | Akce | Popis |
|--------|------|-------|
| `src/pages/Help.tsx` | **Nový** | Hlavní stránka s Tabs + Accordion |
| `src/config/navigation.ts` | Upravit | Přidat "Nápověda" s ikonou HelpCircle |
| `src/App.tsx` | Upravit | Přidat route `/help` |

---

### 1. `src/config/navigation.ts`

Přidat import `HelpCircle` z lucide-react a novou položku do `NAV_ITEMS` (před "Můj profil"):

```typescript
{ 
  path: '/help', 
  label: 'Nápověda', 
  icon: HelpCircle,
  roles: ['admin', 'trainer', 'part_time_staff', 'instructor', 
          'bar_staff', 'manager', 'pro_player', 'hobby_player']
},
```

Taktéž přidat `/help` do `DEFAULT_PATHS`, aby byla dostupná i bez role.

---

### 2. `src/App.tsx`

Přidat import a route uvnitř `<AppLayout>`:

```typescript
import Help from "./pages/Help";
// ...
<Route path="/help" element={<Help />} />
```

---

### 3. `src/pages/Help.tsx` (nový soubor)

Stránka bude používat existující Shadcn komponenty: `Tabs`, `TabsList`, `TabsTrigger`, `TabsContent`, `Accordion`, `AccordionItem`, `AccordionTrigger`, `AccordionContent` a `Card`.

**Struktura:**

```
Nápověda a Tutoriály (nadpis)
┌─────────────────────────────────────────┐
│ [Pro členy týmu]  [Pro správce]         │  <-- Tabs
├─────────────────────────────────────────┤
│                                         │
│  ▸ Jak si zapíšu směnu?                 │  <-- Accordion
│  ▸ Co znamenají barevné štítky u směn?  │
│  ▸ Jak se dostanu do WhatsApp skupiny?  │
│  ▸ Můžu zrušit směnu?                  │
│                                         │
└─────────────────────────────────────────┘
```

**Obsah Tab 1 - "Pro členy týmu"** (default):
- 4 otázky/odpovědi v Accordion formátu dle zadání (směny, štítky, WhatsApp, zrušení)

**Obsah Tab 2 - "Pro správce"**:
- 4 otázky/odpovědi v Accordion formátu dle zadání (akce s rolemi, schvalování, WhatsApp skupiny, správa členů)

**Design:**
- Responzivní layout (padding pro mobile i desktop)
- Styl odpovědí: srozumitelný text s vizuálními cues (popis cesty v aplikaci)
- Konzistentní se zbytkem aplikace (Card wrapper, muted-foreground pro popisy)

---

### Technické detaily

- Stránka je čistě statická (žádné API volání, žádný stav)
- Přístupná všem přihlášeným uživatelům (všechny role)
- Na mobilu se "Nápověda" zobrazí v navigaci podle `filterNavItemsByRoles` (MobileNav zobrazuje prvních 5 položek, Help bude 8. položka - nebude v bottom nav, ale bude v sidebaru a dostupná přes URL)
