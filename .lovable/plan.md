
## Implementace oprav PWA layoutu pro iPhone

### Změna 1: MobileHeader.tsx - Sheet safe area

**Soubor:** `src/components/layout/MobileHeader.tsx`

**Řádek 45** - změnit z:
```tsx
<SheetHeader className="p-4 border-b">
```

Na:
```tsx
<SheetHeader className="p-4 border-b pt-[calc(1rem+env(safe-area-inset-top,0))]">
```

**Účel:** Obsah side menu (logo, X tlačítko) se posune pod status bar/notch. Nemodifikujeme sdílenou sheet.tsx komponentu.

---

### Změna 2: MobileNav.tsx - Bottom navigation pozadí

**Soubor:** `src/components/layout/MobileNav.tsx`

**Řádek 14** - změnit z:
```tsx
<nav className="fixed bottom-0 left-0 right-0 z-50 bg-card border-t md:hidden safe-area-bottom">
```

Na:
```tsx
<nav className="fixed bottom-0 left-0 right-0 z-50 bg-card border-t md:hidden pb-[env(safe-area-inset-bottom,0)]">
```

**Účel:** Pozadí `bg-card` se rozšíří do celého safe area prostoru (vyplní mezeru mezi navigací a spodním okrajem obrazovky), zatímco ikony zůstanou v h-16 oblasti nad home indicatorem.

---

### Shrnutí

| Soubor | Změna | Výsledek |
|--------|-------|----------|
| `MobileHeader.tsx` | Přidat `pt-[calc(1rem+env(safe-area-inset-top,0))]` na SheetHeader | Menu obsah pod notchem |
| `MobileNav.tsx` | Změnit `safe-area-bottom` na `pb-[env(safe-area-inset-bottom,0)]` | Plné pozadí do spodního okraje |

### Technické poznámky

- Tailwind JIT zpracuje `env()` funkce v arbitrary values
- Nepotřebujeme měnit sdílené UI komponenty
- Řešení je specifické pro PWA kontext v MobileHeader a MobileNav
