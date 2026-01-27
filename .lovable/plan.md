

## PWA oprava pro iPhone - Finální implementace

### Aktuální stav

| Položka | Stav |
|---------|------|
| `viewport-fit=cover` | ✅ Řádek 5 |
| `apple-mobile-web-app-capable` | ✅ Řádek 13 |
| `apple-mobile-web-app-status-bar-style` | ✅ Řádek 14 |
| `apple-mobile-web-app-title` | ✅ Řádek 15 |
| `theme-color` | ✅ Řádek 12 |
| `.safe-area-bottom` utility | ✅ V index.css |
| Safe area na MobileNav | ✅ Aplikováno |
| **manifest.json** | ❌ Chybí |
| **Link na manifest** | ❌ Chybí |

### Implementace

#### Krok 1: Vytvořit `public/manifest.json`

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
    }
  ]
}
```

#### Krok 2: Přidat link do `index.html`

Přidat za řádek 33 (před OG tagy):

```html
<link rel="manifest" href="/manifest.json" />
```

### Výsledek

Po implementaci budou všechny interní odkazy (`/calendar`, `/profile`, `/shifts` atd.) zůstávat v standalone PWA aplikaci místo otevření v Safari.

### Soubory k úpravě

| Soubor | Akce |
|--------|------|
| `public/manifest.json` | Vytvořit |
| `index.html` | Přidat link na manifest |

