#!/usr/bin/env python3
"""
C3 — vyrobí z Noto Sans předsubsetovaný font jako TypeScriptový modul (base64).

PROČ VLASTNÍ FONT A NE STANDARDNÍ
`pdf-lib` má vestavěné fonty (Helvetica a spol.), jenže ty umí jen WinAnsi,
tedy Latin-1. Čeština je Latin-2: `ř š č ž ů ě ď ť ň` v Latin-1 NEJSOU. Doklad
by se vysázel s prázdnými místy nebo by render spadl — a je to doklad, který jde
ke klientovi. Vlastní font přes `@pdf-lib/fontkit` je tedy nutnost, ne vylepšení.

PROČ SUBSET
Plný Noto Sans má ~620 kB na řez. Edge funkce má krátký studený start a modul se
načítá při každém běhu, takže se font ořezává na znaky, které doklad opravdu
používá. Výsledek jsou desítky kB místo stovek.

PROČ BASE64 MODUL A NE SOUBOR
Edge funkce nemá spolehlivý přístup k souborovému systému vedle sebe. Font jako
TS modul se zabalí s kódem a je zaručeně po ruce; cenou je ~33 % nárůst velikosti
kvůli base64, což se u subsetu vejde.

Použití:
    python3 scripts/build-font-module.py <adresář-s-ttf> [výstup.ts]

Vstupní TTF se do repa NECOMMITUJÍ (jsou velké a jdou kdykoli stáhnout);
commituje se vygenerovaný modul a licence OFL, kterou font vyžaduje.
"""
import base64
import io
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

# ZNAKY, KTERÉ DOKLAD POUŽÍVÁ.
#
# Vyjmenované schválně, ne rozsahem: subset je bezpečnostní i vzhledová hranice.
# Když se na doklad dostane znak, který tu není, `pdf-lib` render SHODÍ — a to je
# lepší než tiše vytisknout prázdné místo tam, kde má být jméno odběratele.
# Kdo přidá do dokladu nový symbol, musí ho přidat i sem; render mu to připomene.
ZNAKY = (
    # základní latinka, číslice, interpunkce
    " !\"#$%&'()*+,-./0123456789:;<=>?@"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`"
    "abcdefghijklmnopqrstuvwxyz{|}~"
    # česká diakritika (velká i malá) — tohle je ten důvod, proč sem jdeme
    "ÁÄČĎÉĚÍĽĹŇÓÔÖŘŔŠŤÚŮÜÝŽ"
    "áäčďéěíľĺňóôöřŕšťúůüýž"
    # slovenština navíc (klienti mají i slovenské kluby)
    "ÀÂÃÈÊËÌÎÏÒÕÙÛàâãèêëìîïòõùû"
    # typografie a symboly, které layout používá
    "–—„“”‚‘’…•×÷°§±≤≥≈"
    "€£$¢©®™"
    # měna a zkratky
    "Kč"
    # zalomení nerozdělitelnou mezerou (v částkách: 22 600 Kč)
    " "
)


def subsetuj(cesta: Path) -> bytes:
    font = TTFont(str(cesta))
    nastaveni = subset.Options()
    # Layout tabulky (kerning, ligatury) se nechávají: bez nich vypadá text
    # rozsypaně, a u dokladu, který jde klientovi, na tom záleží.
    nastaveni.layout_features = ["*"]
    nastaveni.drop_tables += ["FFTM"]
    nastaveni.name_IDs = ["*"]        # jména musí zůstat kvůli licenci OFL
    nastaveni.notdef_outline = True   # ať je vidět, když znak chybí
    nastaveni.recalc_bounds = True
    subsetter = subset.Subsetter(options=nastaveni)
    subsetter.populate(text=ZNAKY)
    subsetter.subset(font)

    buf = io.BytesIO()
    font.save(buf)
    return buf.getvalue()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1

    zdroj = Path(sys.argv[1])
    vystup = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("supabase/functions/_shared/font-noto.ts")

    rezy = {"REGULAR": zdroj / "NotoSans-Regular.ttf", "BOLD": zdroj / "NotoSans-Bold.ttf"}
    for nazev, cesta in rezy.items():
        if not cesta.exists():
            print(f"CHYBA: chybí {cesta}", file=sys.stderr)
            return 1

    casti = []
    for nazev, cesta in rezy.items():
        data = subsetuj(cesta)
        b64 = base64.b64encode(data).decode("ascii")
        radky = "\n".join(b64[i:i + 100] for i in range(0, len(b64), 100))
        casti.append((nazev, len(data), radky))
        print(f"{cesta.name}: {cesta.stat().st_size // 1024} kB → {len(data) // 1024} kB "
              f"(base64 {len(b64) // 1024} kB)")

    hlavicka = f'''// GENEROVANÝ SOUBOR — needituj ho ručně.
// Vyrobil `scripts/build-font-module.py`; uprav seznam znaků tam a spusť ho znovu.
//
// Noto Sans, ořezaný na znaky, které doklad používá (čeština je Latin-2, kterou
// vestavěné fonty `pdf-lib` neumí — viz komentář v generátoru).
//
// Licence: SIL Open Font License 1.1, Copyright 2022 The Noto Project Authors.
// Plné znění je v `supabase/functions/_shared/OFL.txt` a MUSÍ zůstat u fontu.
//
// Když render spadne na chybějícím znaku, není to vada fontu — je to nový symbol
// v layoutu, který patří do seznamu v generátoru.

'''
    telo = "".join(
        f'export const NOTO_{nazev}_BASE64 =\n  "' + radky.replace("\n", '" +\n  "') + '";\n\n'
        f'/** Velikost subsetu {nazev.lower()}: {velikost // 1024} kB. */\n\n'
        for nazev, velikost, radky in casti
    )

    vystup.parent.mkdir(parents=True, exist_ok=True)
    vystup.write_text(hlavicka + telo, encoding="utf-8")
    print(f"Zapsáno: {vystup} ({vystup.stat().st_size // 1024} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
