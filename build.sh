#!/usr/bin/env bash
# build.sh — compile amalgame-bridge (Linux natif, ou Windows en croisé).
#
#   ./build.sh                 binaire Linux  → build/bridge
#   ./build.sh --windows       binaire Windows via x86_64-w64-mingw32-gcc → build/bridge.exe
#   ./build.sh -g              build de débogage (-O0 -g)
#
# Variables : AMC (binaire amc), AMALGAME_SERVICE (dépôt amalgame-service),
#             AMALGAME_RUNTIME (runtime/ d'amc), CC (compilateur C).
set -euo pipefail
cd "$(dirname "$0")"

TARGET=linux
OPT="-O2"
for a in "$@"; do
    case "$a" in
        --windows) TARGET=windows ;;
        -g)        OPT="-O0 -g" ;;
        *) echo "option inconnue : $a" >&2; exit 2 ;;
    esac
done

AMC="${AMC:-$(command -v amc || true)}"
[ -x "$AMC" ] || { echo "amc introuvable (définir AMC=...)" >&2; exit 2; }
AMC_HOME="$(cd "$(dirname "$(readlink -f "$AMC")")/.." && pwd)"
RUNTIME="${AMALGAME_RUNTIME:-$AMC_HOME/share/amalgame/runtime}"
[ -f "$RUNTIME/_runtime.h" ] || { echo "runtime amc introuvable : $RUNTIME" >&2; exit 2; }

# Façade amalgame-service vendorisée (vendor/amalgame-service) ; surcharge possible.
SVC="${AMALGAME_SERVICE:-vendor/amalgame-service}"
[ -f "$SVC/facade.am" ] || { echo "amalgame-service introuvable : $SVC" >&2; exit 2; }

if [ "$TARGET" = windows ]; then
    CC="${CC:-x86_64-w64-mingw32-gcc}"
    OUT=build/bridge.exe
    LIBS="-lgc -lws2_32 -liphlpapi -ladvapi32"
    LIBAMALGAME="${LIBAMALGAME_WIN:-}"   # libamalgame.a compilée pour MinGW, si nécessaire
else
    CC="${CC:-gcc}"
    OUT=build/bridge
    LIBS="-lgc -lm -lpthread -ldl"
    LIBAMALGAME="$AMC_HOME/share/amalgame/lib/libamalgame.a"
fi

OBJ="build/obj-$TARGET"
mkdir -p "$OBJ"
LW=vendor/lwip/src
CFLAGS_LW="$OPT -Wall -Wno-address -Isrc/native -I$LW/include"

# ── lwIP + glue ───────────────────────────────────────
LWIP_SRCS="$(ls $LW/core/*.c $LW/core/ipv4/*.c) $LW/netif/ethernet.c src/native/bridge_lwip.c"
OBJS=""
for f in $LWIP_SRCS; do
    o="$OBJ/$(basename "$f" .c).o"
    if [ ! -f "$o" ] || [ "$f" -nt "$o" ] || [ src/native/lwipopts.h -nt "$o" ]; then
        $CC $CFLAGS_LW -c "$f" -o "$o"
    fi
    OBJS="$OBJS $o"
done

# ── Sources Amalgame (sys.am en premier : ordre des #include Windows) ──
AM_SRCS="src/sys.am src/bytes.am src/link.am src/net.am src/hostsock.am src/socks.am src/config.am $SVC/facade.am src/main.am"
"$AMC" --quiet -o build/bridge $AM_SRCS

# ── Édition de liens ──────────────────────────────────
$CC $OPT -w -Isrc/native -I$LW/include -I"$RUNTIME" build/bridge.c $OBJS $LIBAMALGAME $LIBS -o "$OUT"
echo "OK : $OUT"
