#!/bin/sh
# Comprueba el addon Oro de Hermandad con Lua 5.1 (la versión de WoW). Desde la raíz del repositorio:
#   sh test-lua/run.sh
set -e
ADDON=addon/OroHermandad

echo "Sintaxis..."
luac5.1 -p "$ADDON"/*.lua

echo "Globales que escribe el addon..."
unexpected=$(for f in "$ADDON"/*.lua; do luac5.1 -l -p "$f" | grep -o 'SETGLOBAL.*' | awk '{print $NF}'; done | sort -u |
  grep -v -x -e OroHermandadDB -e OroHermandadCharDB -e SLASH_OROHERMANDAD1 -e SLASH_OROHERMANDAD2 \
     -e OroHermandad_OnCompartmentClick -e OroHermandad_OnCompartmentEnter -e OroHermandad_OnCompartmentLeave || true)
if [ -n "$unexpected" ]; then echo "Globales no esperados: $unexpected"; exit 1; fi

echo "Archivos del TOC..."
grep '\.lua$' "$ADDON/OroHermandad.toc" | while read -r file; do test -f "$ADDON/$file" || { echo "Falta $file"; exit 1; }; done

for suite in engine scan guild load; do
  lua5.1 "test-lua/test_$suite.lua"
done
echo "Todo correcto."
