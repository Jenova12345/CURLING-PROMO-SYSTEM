# Deployment Guide - Mladé Kameny

Tento dokument popisuje postup pro nasazení aplikace na vlastní infrastrukturu (Supabase + libovolný hosting).

## Architektura

```
┌─────────────────────────┐     ┌─────────────────────────┐
│   Frontend Hosting      │────▶│   Supabase              │
│   (Vercel/Netlify/...)  │     │   (vlastní projekt)     │
│   React + Vite          │     │   - PostgreSQL DB       │
│                         │     │   - Auth                │
└─────────────────────────┘     └─────────────────────────┘
```

---

## Krok 1: Vytvoření Supabase projektu

1. Jdi na [supabase.com](https://supabase.com) a přihlas se / vytvoř účet
2. Klikni **"New Project"** a vyber organizaci
3. Vyplň:
   - **Project name:** `mlad-kameny` (nebo podobné)
   - **Database password:** zapamatuj si ho!
   - **Region:** `Frankfurt (eu-central-1)` - nejbližší pro CZ
4. Počkej cca 2 minuty na vytvoření projektu

---

## Krok 2: Spuštění databázového schématu

1. V Supabase dashboard jdi do **SQL Editor**
2. Zkopíruj celý obsah souboru `MIGRATION_SCRIPT.sql`
3. Vlož a spusť - vytvoří všechny tabulky, funkce, triggery, RLS politiky a views

---

## Krok 3: Konfigurace Authentication

### 3a. URL Configuration
V **Authentication → URL Configuration**:

| Nastavení | Hodnota |
|-----------|---------|
| Site URL | `https://tvoje-domena.cz` |
| Redirect URLs | `https://tvoje-domena.cz/` |
| | `https://tvoje-domena.cz/update-password` |
| | `http://localhost:8080/` (pro vývoj) |
| | `http://localhost:8080/update-password` |

### 3b. Security Settings (doporučeno)
V **Authentication → Settings**:
- **Enable email confirmations:** ON (pro produkci)
- **Leaked Password Protection:** ON

---

## Krok 4: Získání API credentials

V **Settings → API** zkopíruj:
- **Project URL** → `VITE_SUPABASE_URL`
- **anon public key** → `VITE_SUPABASE_PUBLISHABLE_KEY`
- **Project ID** (část URL) → `VITE_SUPABASE_PROJECT_ID`

---

## Krok 5: Příprava kódu

### 5a. Environment variables
1. Zkopíruj `.env.example` jako `.env`
2. Vyplň hodnoty z kroku 4

### 5b. Odstranění Lovable závislostí

**V `package.json`** odstraň z devDependencies:
```json
"lovable-tagger": "^1.1.13",
```

**V `vite.config.ts`** odstraň:
```typescript
// ODSTRANIT tento import:
import { componentTagger } from "lovable-tagger";

// ZMĚNIT plugins na:
plugins: [react()],
// místo: plugins: [react(), mode === 'development' && componentTagger()].filter(Boolean),
```

### 5c. Nahrání na GitHub
```bash
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/tvuj-username/mlad-kameny.git
git push -u origin main
```

---

## Krok 6: Frontend Deployment

### Vercel
1. Jdi na [vercel.com](https://vercel.com)
2. Propoj GitHub repozitář
3. **Framework Preset:** Vite
4. **Build Command:** `npm run build`
5. **Output Directory:** `dist`
6. **Environment Variables:** přidej všechny z `.env`

### Netlify
1. Jdi na [netlify.com](https://netlify.com)
2. Propoj GitHub repozitář
3. **Build Command:** `npm run build`
4. **Publish Directory:** `dist`
5. **Environment Variables:** přidej všechny z `.env`

### Cloudflare Pages
1. Jdi na [pages.cloudflare.com](https://pages.cloudflare.com)
2. Propoj GitHub repozitář
3. **Framework preset:** Vite
4. **Build Command:** `npm run build`
5. **Build output directory:** `dist`
6. **Environment Variables:** přidej všechny z `.env`

---

## Krok 7: Aktualizace Supabase URLs

Po získání produkční URL aktualizuj v Supabase:

1. **Authentication → URL Configuration**
2. Změň **Site URL** na produkční doménu
3. Přidej produkční URL do **Redirect URLs**

---

## Krok 8: Vytvoření admin účtu

1. Registruj se na produkční aplikaci
2. Potvrď email (klikni na odkaz v emailu)
3. V Supabase **SQL Editor** spusť:

```sql
UPDATE public.user_roles 
SET role = 'admin' 
WHERE user_id = (SELECT id FROM auth.users WHERE email = 'tvuj@email.cz');
```

---

## Krok 9: (Volitelné) Vlastní doména

### V hosting službě
1. Přidej vlastní doménu v nastavení projektu
2. Nastav DNS záznamy podle instrukcí

### V Supabase
1. Aktualizuj Site URL na novou doménu
2. Aktualizuj Redirect URLs

---

## Rychlé příkazy pro správu rolí

```sql
-- Nastavit jako admina
UPDATE public.user_roles SET role = 'admin' 
WHERE user_id = (SELECT id FROM auth.users WHERE email = 'admin@email.cz');

-- Nastavit jako brigádníka
UPDATE public.user_roles SET role = 'part_time_staff' 
WHERE user_id = (SELECT id FROM auth.users WHERE email = 'brigadnik@email.cz');

-- Nastavit jako trenéra
UPDATE public.user_roles SET role = 'trainer' 
WHERE user_id = (SELECT id FROM auth.users WHERE email = 'trener@email.cz');
```

---

## Checklist

- [ ] Vytvořen Supabase projekt
- [ ] Spuštěn MIGRATION_SCRIPT.sql
- [ ] Nastaveny Auth URL redirects
- [ ] Kód nahrán na GitHub
- [ ] Odstraněn lovable-tagger z kódu
- [ ] Frontend projekt vytvořen (Vercel/Netlify/...)
- [ ] Environment variables nastaveny
- [ ] Site URL aktualizován v Supabase
- [ ] Admin účet vytvořen a ověřen

---

## Soubory potřebné pro deployment

```
├── src/                          # Frontend kód
├── public/                       # Statické soubory
├── MIGRATION_SCRIPT.sql          # Databázové schéma
├── package.json                  # (upravit - odstranit lovable-tagger)
├── vite.config.ts                # (upravit - odstranit componentTagger)
├── tailwind.config.ts
├── postcss.config.js
├── tsconfig.json
├── tsconfig.app.json
├── tsconfig.node.json
├── eslint.config.js
├── index.html
├── components.json
└── .env.example
```

---

## Podpora

Pokud narazíš na problémy:
1. Zkontroluj browser console pro frontend chyby
2. Zkontroluj Supabase Logs pro backend chyby
3. Ověř, že environment variables jsou správně nastavené
