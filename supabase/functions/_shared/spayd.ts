// SPAYD pro Edge funkce — přeposílá TÝŽ modul, který používá tisk z obrazovky.
//
// Vlastní kopie by byla lákavá (Deno chce přípony, frontend má aliasy), ale QR
// platba je jediné místo na dokladu, které zákazník nečte — jen naskenuje
// a potvrdí. Dvě kopie by se časem rozešly a nikdo by si toho nevšiml, dokud by
// peníze neodešly jinam. Aliasy řeší import mapa v `supabase/functions/deno.json`.
export { buildSpayd, spaydText, type SpaydPlatba } from '@/lib/spayd';
