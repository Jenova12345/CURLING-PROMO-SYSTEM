

## Oprava PWA problémů na iPhone

### Problém 1: Header schovaný za status barem

**Příčina:** MobileHeader používá `sticky top-0`, ale nerespektuje horní safe area (notch/status bar).

**Řešení:** Přidat `safe-area-top` třídu a upravit padding headeru.

#### Změny v `MobileHeader.tsx`

```tsx
// Řádek 24 - změnit z:
<header className="sticky top-0 z-50 flex h-14 items-center justify-between border-b bg-card px-4 md:hidden">

// Na:
<header className="sticky top-0 z-50 flex h-14 items-center justify-between border-b bg-card px-4 md:hidden safe-area-top">
```

Tím header získá `padding-top: env(safe-area-inset-top)` a posune se pod status bar.

---

### Problém 2: Ikona na Home Screen

**Příčina:** 
- `manifest.json` obsahuje pouze 48x48 favicon
- Chybí `apple-touch-icon` meta tag v HTML
- iOS ignoruje manifest ikony a vyžaduje specifický `<link rel="apple-touch-icon">`

**Řešení:** Použít existující logo z externího úložiště (již používané pro OG image).

#### Změny v `index.html`

Přidat za řádek 15 (za `apple-mobile-web-app-title`):

```html
<link rel="apple-touch-icon" href="https://storage.googleapis.com/gpt-engineer-file-uploads/Eqox9k4DCTMG4PRyQMupWtPtBF33/uploads/1768338334316-CP - Mlade kameny logo kulate.png">
```

#### Změny v `manifest.json`

Přidat větší ikonu pro Android/Chrome PWA:

```json
{
  "name": "Mladé kameny",
  "short_name": "MK",
  "description": "Interní systém pro správu curlingové haly",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#1e293b",
  "theme_color": "#1e293b",
  "orientation": "portrait-primary",
  "icons": [
    {
      "src": "/favicon.ico",
      "sizes": "48x48",
      "type": "image/x-icon"
    },
    {
      "src": "https://storage.googleapis.com/gpt-engineer-file-uploads/Eqox9k4DCTMG4PRyQMupWtPtBF33/uploads/1768338334316-CP - Mlade kameny logo kulate.png",
      "sizes": "192x192",
      "type": "image/png"
    },
    {
      "src": "https://storage.googleapis.com/gpt-engineer-file-uploads/Eqox9k4DCTMG4PRyQMupWtPtBF33/uploads/1768338334316-CP - Mlade kameny logo kulate.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any maskable"
    }
  ]
}
```

---

### Shrnutí změn

| Soubor | Změna |
|--------|-------|
| `MobileHeader.tsx` | Přidat `safe-area-top` třídu |
| `index.html` | Přidat `<link rel="apple-touch-icon">` |
| `manifest.json` | Přidat větší ikony (192x192, 512x512) |

### Po nasazení

Pro zobrazení nové ikony na iPhone:
1. Smazat existující ikonu z Home Screen
2. Znovu přidat aplikaci na Home Screen přes Safari (Share → Add to Home Screen)
3. iOS cachuje ikony agresivně, takže restart Safari může pomoci

