"""PC uploader for the guild panel ("Hermandad") of El Especulador del WoW.

It reads <WoW>/_forever_/WTF/Account/<ACCOUNT>/SavedVariables/OroHermandad.lua for every account, keeps ONLY the
OroHermandadHist global (watched-item prices written by the Oro de Hermandad addon) and sends it as the upload JSON of
contract 3 to <panel>/api/guild/sync with the member's personal key (Authorization: Bearer gld_...).

Privacy and safety:
- The file is parsed locally by a literal-only reader (no Lua is ever executed) with size, depth and node limits.
  OroHermandadDB (guild roster, professions, recipes) and OroHermandadCharDB are skipped without being decoded or
  kept, and Auctionator.lua is never opened.
- The key is stored with Windows DPAPI (CryptProtectData), never as plain text, an argument or an environment
  variable. Without DPAPI (other systems) it is only kept in memory.
- HTTPS only, no redirects, bounded responses; a file is only sent again when its content changes (sha256).
"""
from __future__ import annotations

import sys

if sys.version_info < (3, 10):
    print("Necesitas Python 3.10 o superior. Descárgalo de https://www.python.org/downloads/ y vuelve a abrir HERMANDAD.cmd.")
    sys.exit(1)

import argparse
import base64
import contextlib
import ctypes
import getpass
import hashlib
import json
import math
import os
import re
import ssl
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, build_opener
from xml.sax.saxutils import escape as xml_text

import sincronizar as sync
from sincronizar import AuthenticationError, ReadPendingError, RetryableSyncError, SyncError

VERSION = "0.3.0"
SOURCE_NAME = "OroHermandad.lua"
ALLOWED = frozenset({SOURCE_NAME})
HIST_GLOBAL = "OroHermandadHist"
SCHEMA = 1

# Especular v1 (addon/OroHermandad/Spec.lua and src/especular.mjs): day 0, ranges and what the addon keeps.
DAY0 = 1577833200
PRICE_MAX = 1_000_000_000
QTY_MAX = 1_000_000
DAY_MAX = 99999
TIME_MAX = 9_999_999_999
KEEP_DAYS = 120
MAX_POINTS = 120
POINT_MERGE_SECONDS = 1800
POINT_SECONDS = 14 * 86400
RESEND_DAYS = 2              # an item the panel already has: its days from the newest accepted day minus 2 go again
CATEGORIES = ("metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco", "comida",
              "venda", "encantar", "elemental", "otro")

# Server limits (src/guild.mjs validateUpload).
ITEM_ID_MAX = 2**31 - 1
NAME_MAX = 100
MAX_MARKETS = 8
MAX_ITEMS = 300
MAX_DEPOSITS = MAX_ITEMS * 9
MAX_BODY_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
REQUEST_TIMEOUT = 30
POLL_SECONDS = 15
SETTLE_SECONDS = 3
MAX_ACCOUNTS = 50
PARSER_LIMITS = {"chars": 10 * 1024 * 1024, "depth": 30, "nodes": 500_000, "string_bytes": 1024 * 1024}

KEY_PATTERN = re.compile(r"gld_[A-Za-z0-9_-]{43}")
ADDON_PATTERN = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}")
MARKET_PATTERN = re.compile(r"([^|\x00-\x1f\x7f]+)-(?:Alliance|Horde)")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
TASK_NAME = "Oro de Hermandad - subidor de precios"
TASK_COMMAND_MAX = 261
LOCAL_TEST_ENV = "OROHERMANDAD_SOLO_PRUEBAS_HTTP_LOCAL"
USER_AGENT = "OroHermandadPC/" + VERSION


class LuaFormatError(SyncError):
    """OroHermandad.lua is not a literal-only SavedVariables file. The message never quotes its contents."""


class SchemaError(SyncError):
    """OroHermandadHist exists but is not schema 1."""


class RejectedUploadError(SyncError):
    """The panel refused this content (400, 413, 415): retrying the same bytes cannot help."""


class KeyStoreError(SyncError):
    """The stored key cannot be protected or recovered."""


# ---------------------------------------------------------------------------------------------------------------
# Output: the console, or a small log file when the startup task runs without a window.
# ---------------------------------------------------------------------------------------------------------------
class _Output:
    def __init__(self):
        self.file = None
        self.limit = 256 * 1024

    def say(self, message, stamp=True):
        line = (datetime.now().strftime("[%H:%M:%S] ") if stamp else "") + message
        if self.file is None:
            if sys.stdout is not None:
                print(line, flush=True)
            return
        try:
            if self.file.exists() and self.file.stat().st_size > self.limit:
                os.replace(self.file, self.file.with_name("registro.anterior.txt"))
            with self.file.open("a", encoding="utf-8") as stream:
                stream.write(datetime.now().strftime("%Y-%m-%d ") + line + "\n")
        except OSError:
            pass


_out = _Output()


def say(message, stamp=True):
    _out.say(message, stamp)


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


# ---------------------------------------------------------------------------------------------------------------
# Literal-only Lua reader (rules of src/auctioneer.mjs; base: the pricelab Auctionator reader)
# ---------------------------------------------------------------------------------------------------------------
_SPACE = re.compile(r"[ \t\r\n\v\f]*")
_LONG_OPEN = re.compile(r"\[(=*)\[")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUMBER = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)")
_NUMBER_TAIL = re.compile(r"[0-9A-Za-z_.]")
_NONFINITE = re.compile(r"(-?)(1\.#(?:INF|IND|QNAN|SNAN)0*|nan(?:\([0-9A-Za-z_]{0,16}\))?|inf(?:inity)?)(?![0-9A-Za-z_])",
                        re.IGNORECASE)
_DEC3 = re.compile(r"[0-9]{1,3}")
_STOP = {'"': re.compile(r'["\\\r\n]'), "'": re.compile(r"['\\\r\n]")}
_NEWLINES = re.compile(r"\r\n|\n\r|\r|\n")
_ESCAPES = {"a": 7, "b": 8, "f": 12, "n": 10, "r": 13, "t": 9, "v": 11, "\\": 92, '"': 34, "'": 39}
_KEYWORDS = frozenset(("and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
                       "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "goto"))
_STRING = object()   # a string of a skipped global: checked, never decoded
_TABLE = object()    # a table of a skipped global: checked, never built


def _lua_number(token):
    if len(token) > 64:
        raise ValueError("token")
    negative = token.startswith("-")
    body = token[1:] if negative else token
    if body[:2] in ("0x", "0X"):
        value = int(body[2:], 16)
    elif "." in body or "e" in body or "E" in body:
        value = float(body)
        if math.isfinite(value) and value.is_integer() and abs(value) <= 2**53:
            value = int(value)
    else:
        value = int(body)
    return -value if negative else value


class _LuaReader:
    """Reads `Name = literal` statements. Only the globals in `wanted` are built; the others are walked to find
    where they end (same syntax checks and limits) but their strings are never decoded and their tables never kept."""

    def __init__(self, text, limits=None):
        self.limits = dict(PARSER_LIMITS, **(limits or {}))
        if not isinstance(text, str):
            raise LuaFormatError(f"{SOURCE_NAME} no es texto.")
        if len(text) > self.limits["chars"]:
            raise LuaFormatError(f"{SOURCE_NAME} es demasiado grande.")
        self.text = text[1:] if text.startswith("\ufeff") else text
        self.pos = 0
        self.nodes = 0

    def fail(self, message):
        line = self.text.count("\n", 0, min(self.pos, len(self.text))) + 1
        raise LuaFormatError(f"{SOURCE_NAME} no se puede leer: {message} (línea {line}).")

    def skip(self):
        text = self.text
        while True:
            self.pos = _SPACE.match(text, self.pos).end()
            if not text.startswith("--", self.pos):
                return
            self.pos += 2
            opening = _LONG_OPEN.match(text, self.pos)
            if opening:
                closer = "]" + opening.group(1) + "]"
                end = text.find(closer, opening.end())
                if end < 0:
                    self.fail("hay un comentario sin cerrar")
                self.pos = end + len(closer)
            else:
                end = text.find("\n", self.pos)
                self.pos = len(text) if end < 0 else end + 1

    def expect(self, token):
        self.skip()
        if not self.text.startswith(token, self.pos):
            self.fail(f"se esperaba «{token}»")
        self.pos += len(token)

    def parse(self, wanted):
        found, names, text = {}, set(), self.text
        while True:
            self.skip()
            if self.pos >= len(text):
                return found
            match = _NAME.match(text, self.pos)
            if not match:
                self.fail("se esperaba el nombre de una variable guardada")
            name = match.group()
            if name in _KEYWORDS:
                self.fail("hay código Lua; solo se admiten datos guardados")
            if name in names:
                self.fail("una variable guardada aparece dos veces")
            names.add(name)
            self.pos = match.end()
            self.expect("=")
            keep = name in wanted
            value = self.value(0, keep)
            if keep:
                found[name] = value
            self.skip()
            if text.startswith(";", self.pos):
                self.pos += 1

    def value(self, depth, keep):
        self.skip()
        self.nodes += 1
        if self.nodes > self.limits["nodes"]:
            self.fail("tiene demasiados elementos")
        if depth > self.limits["depth"]:
            self.fail("la estructura es demasiado profunda")
        text, pos = self.text, self.pos
        if pos >= len(text):
            self.fail("falta un valor")
        char = text[pos]
        if char == "{":
            return self.table(depth + 1, keep)
        if char == '"' or char == "'":
            return self.quoted(keep)
        if char == "[":
            if _LONG_OPEN.match(text, pos):
                return self.long_string(keep)
            self.fail("hay un valor no válido")
        if char in "-1nNiI":
            special = _NONFINITE.match(text, pos)
            if special:
                self.pos = special.end()
                kind = special.group(2).lower()
                if "nan" in kind or "ind" in kind:
                    return math.nan
                return -math.inf if special.group(1) else math.inf
        if char in "-.0123456789":
            match = _NUMBER.match(text, pos)
            if not match or _NUMBER_TAIL.match(text, match.end()):
                self.fail("hay un número no válido")
            self.pos = match.end()
            try:
                return _lua_number(match.group())
            except ValueError:
                self.fail("hay un número demasiado largo")
        match = _NAME.match(text, pos)
        if match:
            word = match.group()
            if word in ("true", "false", "nil"):
                self.pos = match.end()
                return {"true": True, "false": False, "nil": None}[word]
        self.fail("solo se admiten datos (tablas, textos, números, true, false y nil); nunca se ejecuta código Lua")

    def key(self, key):
        if key is _STRING or isinstance(key, str) or type(key) is int:
            return key
        if type(key) is float and math.isfinite(key):
            return key
        self.fail("hay una clave de tabla no admitida")

    def table(self, depth, keep):
        text = self.text
        self.pos += 1
        result = {} if keep else _TABLE
        index = 1
        while True:
            self.skip()
            pos = self.pos
            if pos >= len(text):
                self.fail("falta «}» al final de una tabla")
            char = text[pos]
            if char == "}":
                self.pos += 1
                return result
            if char == "[" and not _LONG_OPEN.match(text, pos):
                self.pos += 1
                key = self.key(self.value(depth, keep))
                self.expect("]")
                self.expect("=")
                value = self.value(depth, keep)
            else:
                match = _NAME.match(text, pos)
                named = False
                if match:
                    self.pos = match.end()
                    self.skip()
                    if text.startswith("=", self.pos) and not text.startswith("==", self.pos):
                        if match.group() in _KEYWORDS:
                            self.fail("hay una palabra reservada de Lua usada como campo")
                        self.pos += 1
                        named = True
                    else:
                        self.pos = pos
                if named:
                    key = match.group()
                else:
                    key = index
                    index += 1
                value = self.value(depth, keep)
            if keep:
                if key in result:
                    self.fail("hay una clave repetida en una tabla")
                result[key] = value
            self.skip()
            if text.startswith("}", self.pos):
                self.pos += 1
                return result
            if text.startswith(",", self.pos) or text.startswith(";", self.pos):
                self.pos += 1
                continue
            self.fail("falta una coma entre los elementos de una tabla")

    def quoted(self, keep):
        text, limit = self.text, self.limits["string_bytes"]
        quote = text[self.pos]
        stop = _STOP[quote]
        pos = self.pos + 1
        parts, size = [], 0
        while True:
            match = stop.search(text, pos)
            if not match:
                self.pos = len(text)
                self.fail("hay un texto sin cerrar")
            start = match.start()
            if start > pos:
                if keep:
                    try:
                        chunk = text[pos:start].encode("utf-8")
                    except UnicodeEncodeError:
                        self.pos = pos
                        self.fail("hay un texto que no es UTF-8")
                    parts.append(chunk)
                    size += len(chunk)
                else:
                    size += start - pos
                if size > limit:
                    self.pos = start
                    self.fail("hay un texto demasiado largo")
            char = match.group()
            if char == quote:
                self.pos = start + 1
                if not keep:
                    return _STRING
                try:
                    return b"".join(parts).decode("utf-8")
                except UnicodeDecodeError:
                    self.fail("hay un texto con bytes que no son UTF-8")
            if char != "\\":
                self.pos = start
                self.fail("hay un salto de línea sin escapar dentro de un texto")
            pos = start + 1
            if pos >= len(text):
                self.pos = pos
                self.fail("hay un texto sin cerrar")
            escaped = text[pos]
            if escaped in _ESCAPES:
                byte = _ESCAPES[escaped]
                pos += 1
            elif "0" <= escaped <= "9":
                digits = _DEC3.match(text, pos)
                byte = int(digits.group())
                if byte > 255:
                    self.pos = pos
                    self.fail("hay un escape decimal fuera de rango")
                pos = digits.end()
            elif escaped in "\r\n":
                pos += 1
                if pos < len(text) and text[pos] in "\r\n" and text[pos] != escaped:
                    pos += 1
                byte = 10
            else:
                self.pos = pos
                self.fail("hay una secuencia de escape no admitida")
            size += 1
            if keep:
                parts.append(bytes((byte,)))
            if size > limit:
                self.pos = pos
                self.fail("hay un texto demasiado largo")

    def long_string(self, keep):
        text = self.text
        opening = _LONG_OPEN.match(text, self.pos)
        closer = "]" + opening.group(1) + "]"
        end = text.find(closer, opening.end())
        if end < 0:
            self.fail("hay un texto largo sin cerrar")
        value = text[opening.end():end]
        first = _NEWLINES.match(value)
        if first:
            value = value[first.end():]
        value = _NEWLINES.sub("\n", value)
        if len(value) > self.limits["string_bytes"] or (keep and len(value.encode("utf-8", "surrogatepass")) > self.limits["string_bytes"]):
            self.fail("hay un texto demasiado largo")
        self.pos = end + len(closer)
        return value if keep else _STRING


def read_globals(text, wanted, limits=None):
    """{name: value} for the wanted globals only. Tables become dicts with int, float or str keys."""
    return _LuaReader(text, limits).parse(frozenset(wanted))


def extract_hist(text, limits=None):
    """The OroHermandadHist table of an OroHermandad.lua text, or None when the file has none yet."""
    return read_globals(text, (HIST_GLOBAL,), limits).get(HIST_GLOBAL)


# ---------------------------------------------------------------------------------------------------------------
# OroHermandadHist strings (contract 2), decoded exactly like Spec.DecodeDays / DecodePoints / DecodeDeposits
# ---------------------------------------------------------------------------------------------------------------
_DIGITS = re.compile(r"[0-9]{1,12}")


def _is_int(value, low, high):
    return type(value) is int and low <= value <= high


def _parse_int(text, low, high):
    if text is None or not _DIGITS.fullmatch(text):
        return None
    value = int(text)
    return value if low <= value <= high else None


def _field(fields, index):
    return fields[index] if index < len(fields) else None


def merge_day(a, b):
    """Spec.MergeDay on tuples (d, lo, hi, last, qty, scans, src): an own record beats an import; otherwise
    lo = min, hi = max, qty = max, scans = max and last from the record with more scans (ties: the larger last)."""
    if a is None:
        return b
    if b is None:
        return a
    if a[0] != b[0]:
        return None
    if a[6] != b[6]:
        return a if a[6] == "o" else b
    newer = b if (b[5] > a[5] or (b[5] == a[5] and b[3] > a[3])) else a
    return (a[0], min(a[1], b[1]), max(a[2], b[2]), newer[3], max(a[4], b[4]), max(a[5], b[5]), a[6])


def decode_days(text):
    """'d,lo,hi,last,qty,scans,src;...' -> ascending [(d, lo, hi, last, qty, scans, src)], one per day, newest 120.
    Malformed records are skipped, as in the addon."""
    if not isinstance(text, str):
        return []
    by_day = {}
    for entry in text.split(";"):
        if not entry:
            continue
        fields = entry.split(",")
        record = (_parse_int(_field(fields, 0), 0, DAY_MAX), _parse_int(_field(fields, 1), 1, PRICE_MAX),
                  _parse_int(_field(fields, 2), 1, PRICE_MAX), _parse_int(_field(fields, 3), 1, PRICE_MAX),
                  _parse_int(_field(fields, 4), 0, QTY_MAX), _parse_int(_field(fields, 5), 0, QTY_MAX), _field(fields, 6))
        if None in record[:6] or record[1] > record[2] or record[6] not in ("o", "a"):
            continue
        by_day[record[0]] = merge_day(by_day.get(record[0]), record)
    return [by_day[d] for d in sorted(by_day)][-KEEP_DAYS:]


def decode_points(text):
    """'t,lo,qty,qty5;...' -> ascending [(t, lo, qty, qty5)]: points less than 30 min after the first of a group are
    merged into it (lo = min, qty = max, qty5 of the cheaper point, ties: the larger), newest 120."""
    if not isinstance(text, str):
        return []
    points = []
    for entry in text.split(";"):
        if not entry:
            continue
        fields = entry.split(",")
        point = (_parse_int(_field(fields, 0), 1, TIME_MAX), _parse_int(_field(fields, 1), 1, PRICE_MAX),
                 _parse_int(_field(fields, 2), 0, QTY_MAX), _parse_int(_field(fields, 3), 0, QTY_MAX))
        if None not in point:
            points.append(point)
    points.sort(key=lambda p: p[0])
    merged = []
    for t, lo, qty, qty5 in points:
        if merged and t - merged[-1][0] < POINT_MERGE_SECONDS:
            first = merged[-1]
            cheaper = qty5 if lo < first[1] else max(first[3], qty5) if lo == first[1] else first[3]
            merged[-1] = [first[0], min(first[1], lo), max(first[2], qty), cheaper]
        else:
            merged.append([t, lo, qty, qty5])
    return [tuple(p) for p in merged[-MAX_POINTS:]]


def decode_deposits(text):
    """'dur:copper,dur:copper' -> [(dur, copper)] by duration 1..9 (the last value of a duration wins)."""
    out = {}
    if not isinstance(text, str):
        return []
    for entry in text.split(","):
        if not entry or entry.count(":") != 1:
            continue
        dur, copper = entry.split(":")
        dur, copper = _parse_int(dur, 1, 9), _parse_int(copper, 0, PRICE_MAX)
        if dur is not None and copper is not None:
            out[dur] = copper
    return sorted(out.items())


def day_index(t):
    return (int(t) - DAY0) // 86400


def valid_market_key(key):
    """'<Realm>-Alliance' or '<Realm>-Horde', as the server checks it (realm of 1 to 64 UTF-16 units, no '|')."""
    if not isinstance(key, str):
        return False
    match = MARKET_PATTERN.fullmatch(key)
    return bool(match) and len(match.group(1).encode("utf-16-le")) // 2 <= 64


def clean_name(value):
    if not isinstance(value, str):
        return ""
    return CONTROL.sub("", value)[:NAME_MAX]


# ---------------------------------------------------------------------------------------------------------------
# OroHermandadHist -> upload JSON (contract 3)
# ---------------------------------------------------------------------------------------------------------------
def _progress(sent, key):
    """(day, t, items) of what the panel already accepted for one market of this account, or None (send it all)."""
    entry = sent.get(key) if isinstance(sent, dict) else None
    if not isinstance(entry, dict):
        return None
    day, t, items = entry.get("day"), entry.get("t"), entry.get("items")
    if not _is_int(day, 0, DAY_MAX) or not _is_int(t, 0, TIME_MAX) or not isinstance(items, list):
        return None
    return day, t, {i for i in items if _is_int(i, 1, ITEM_ID_MAX)}


def build_upload(hist, now, sent=None):
    """(upload, notes). upload follows contract 3; only the fields listed there are copied, so nothing else that
    might be inside the table can leave the PC. notes are short Spanish warnings about data that was left out.
    sent: {market: {"day", "t", "items"}} that the panel already accepted from this account (accepted_progress). An
    item it has only sends its days from that day minus RESEND_DAYS and its points newer than that time minus 30 min
    (a later scan can still merge into them); every other item goes complete. Each upload then writes a few hundred
    rows instead of the whole history again. A market with nothing new is left out."""
    if not isinstance(hist, dict):
        raise SchemaError(f"{HIST_GLOBAL} no tiene el formato esperado.")
    schema = hist.get("schema")
    if type(schema) is not int or schema != SCHEMA:
        shown = str(schema) if type(schema) is int else "desconocido"
        raise SchemaError(f"{HIST_GLOBAL} usa el formato {shown} y este subidor solo entiende el formato {SCHEMA}. "
                          "Descarga la última versión del subidor desde el panel de la hermandad.")
    addon = hist.get("addon")
    if not isinstance(addon, str) or not ADDON_PATTERN.fullmatch(addon):
        raise SchemaError(f"{HIST_GLOBAL} no indica una versión válida del addon Oro de Hermandad.")
    now = int(now)
    max_day, oldest_point, newest_point = day_index(now) + 1, max(DAY0, now - POINT_SECONDS), now + 86400
    notes, markets = [], []
    source = hist.get("markets") if isinstance(hist.get("markets"), dict) else {}
    for key, market in source.items():
        if not valid_market_key(key) or not isinstance(market, dict):
            notes.append("se ha saltado un mercado con un nombre no válido")
            continue
        raw_items = market.get("items") if isinstance(market.get("items"), dict) else {}
        progress = _progress(sent, key)
        known, items, bad = set(), [], 0
        for item_id, item in raw_items.items():
            if not _is_int(item_id, 1, ITEM_ID_MAX) or not isinstance(item, dict):
                bad += 1
                continue
            known.add(item_id)
            days = [list(r) for r in decode_days(item.get("d")) if r[0] <= max_day]
            points = [list(p) for p in decode_points(item.get("p")) if oldest_point <= p[0] <= newest_point]
            if progress and item_id in progress[2]:
                days = [r for r in days if r[0] >= progress[0] - RESEND_DAYS]
                points = [p for p in points if p[0] > progress[1] - POINT_MERGE_SECONDS]
            if not days and not points:
                continue
            category = item.get("c") if item.get("c") in CATEGORIES else "otro"
            vendor = item.get("v") if _is_int(item.get("v"), 0, PRICE_MAX) else 0
            items.append({"id": item_id, "name": clean_name(item.get("n")), "cat": category, "vendor": vendor,
                          "days": days, "points": points})
        if bad:
            notes.append(f"{key}: {plural(bad, 'objeto no válido se ha saltado', 'objetos no válidos se han saltado')}")
        if len(items) > MAX_ITEMS:
            recent = lambda i: (i["days"][-1][0] if i["days"] else -1, i["points"][-1][0] if i["points"] else -1)
            items.sort(key=lambda i: (recent(i), -i["id"]), reverse=True)
            dropped = items[MAX_ITEMS:]
            items = items[:MAX_ITEMS]
            known -= {i["id"] for i in dropped}
            notes.append(f"{key}: {plural(len(dropped), 'objeto no cabe', 'objetos no caben')} en un envío "
                         f"(máximo {MAX_ITEMS}); van los que tienen precios más recientes")
        items.sort(key=lambda i: i["id"])
        deposits = []
        raw_deposits = market.get("dep") if isinstance(market.get("dep"), dict) else {}
        for item_id, text in raw_deposits.items():
            if _is_int(item_id, 1, ITEM_ID_MAX) and item_id in known:
                deposits.extend([item_id, dur, copper] for dur, copper in decode_deposits(text))
        deposits.sort()
        deposits = deposits[:MAX_DEPOSITS]
        if not items and (not deposits or progress):
            continue
        cut = market.get("cut") if _is_int(market.get("cut"), 0, 9999) else None
        updated = market.get("updated") if _is_int(market.get("updated"), 0, TIME_MAX) else 0
        markets.append((updated, key, {"market": key, "cut": cut, "items": items, "deposits": deposits}))
    if len(markets) > MAX_MARKETS:
        markets.sort(key=lambda m: (m[0], m[1]), reverse=True)
        notes.append(f"solo se envían los {MAX_MARKETS} mercados usados más recientemente "
                     f"({plural(len(markets) - MAX_MARKETS, 'mercado se queda', 'mercados se quedan')} fuera)")
        markets = markets[:MAX_MARKETS]
    markets.sort(key=lambda m: m[1])
    return {"schema": SCHEMA, "addon": addon, "markets": [m[2] for m in markets]}, notes


def encode_json(data):
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def accepted_progress(sent, posted, result):
    """What to remember after the panel accepted posted (the upload as it was sent; result is the panel's answer):
    per market the newest day and scan time sent and the items stored. A market or an item that the panel skipped is
    left out, so it goes complete next time."""
    progress = {k: v for k, v in sent.items() if isinstance(k, str) and isinstance(v, dict)} if isinstance(sent, dict) else {}
    reports = result.get("markets") if isinstance(result.get("markets"), list) else []
    by_market = {r.get("market"): r for r in reports if isinstance(r, dict) and isinstance(r.get("market"), str)}
    for market in posted["markets"]:
        key, report = market["market"], by_market.get(market["market"], {})
        if report.get("skipped"):
            progress.pop(key, None)
            continue
        listed = report.get("skippedItems") if isinstance(report.get("skippedItems"), list) else []
        previous = _progress(progress, key) or (0, 0, set())
        day = max([previous[0]] + [r[0] for i in market["items"] for r in i["days"]])
        t = max([previous[1]] + [p[0] for i in market["items"] for p in i["points"]])
        items = (previous[2] | {i["id"] for i in market["items"]}) - {i for i in listed if _is_int(i, 1, ITEM_ID_MAX)}
        progress[key] = {"day": day, "t": t, "items": sorted(items)}
    return progress


def encode_payload(upload):
    """Compact UTF-8 JSON of at most 2 MiB. If it is larger, the scan points are left out first."""
    encode = encode_json
    payload = encode(upload)
    if len(payload) <= MAX_BODY_BYTES:
        return payload, []
    lighter = {**upload, "markets": [{**m, "items": [{**i, "points": []} for i in m["items"]]} for m in upload["markets"]]}
    payload = encode(lighter)
    if len(payload) > MAX_BODY_BYTES:
        raise SyncError("Los precios de esta cuenta ocupan más de 2 MiB incluso sin los puntos de escaneo. "
                        "No se ha enviado nada.")
    return payload, ["el envío pasaba de 2 MiB: esta vez van solo los días, sin los puntos de escaneo"]


def summary(upload):
    items = sum(len(m["items"]) for m in upload["markets"])
    return f"{plural(len(upload['markets']), 'mercado', 'mercados')}, {plural(items, 'objeto', 'objetos')}"


# ---------------------------------------------------------------------------------------------------------------
# Finding the files
# ---------------------------------------------------------------------------------------------------------------
@dataclass(frozen=True)
class Source:
    account: str
    path: Path


def _wtf_folder(folder):
    """The WTF folder of the Forever client the chosen folder points to, or None."""
    folder = Path(folder)
    if (folder / "_forever_" / "WTF").is_dir():
        return folder / "_forever_" / "WTF"
    if folder.name.lower() == "wtf" and folder.is_dir():
        return folder
    if folder.name.lower() == "account" and folder.parent.name.lower() == "wtf":
        return folder.parent
    if (folder / "WTF").is_dir():
        return folder / "WTF"
    if (folder / "_forever_").is_dir():
        return folder / "_forever_" / "WTF"
    return None


def find_sources(folder):
    """Every account's OroHermandad.lua under the chosen folder (the WoW folder, _forever_, WTF, Account or one
    account's SavedVariables). Per-character folders are never read: OroHermandadHist is account-wide."""
    folder = Path(folder)
    if folder.name.lower() == "savedvariables" or (folder / SOURCE_NAME).is_file():
        return [Source(folder.parent.name or folder.name, folder / SOURCE_NAME)]
    wtf = _wtf_folder(folder)
    accounts = wtf / "Account" if wtf else None
    if not accounts or not accounts.is_dir():
        return []
    try:
        names = sorted(entry.name for entry in os.scandir(accounts) if entry.is_dir() and entry.name.lower() != "savedvariables")
    except OSError:
        return []
    return [Source(name, accounts / name / "SavedVariables" / SOURCE_NAME) for name in names[:MAX_ACCOUNTS]]


def validate_wow_folder(value):
    if not isinstance(value, (str, Path)):
        raise SyncError("Indica la carpeta de World of Warcraft.")
    text = str(value).strip().strip('"').strip()
    if not text or text.startswith(("\\\\", "//")):
        raise SyncError("Elige una carpeta de este PC, no una ubicación de red.")
    try:
        folder = Path(text).expanduser().resolve()
        if not folder.is_dir():
            raise SyncError("No se encuentra esa carpeta.")
    except OSError:
        raise SyncError("No se puede abrir esa carpeta.") from None
    if not (folder.name.lower() == "savedvariables" or (folder / SOURCE_NAME).is_file() or _wtf_folder(folder)):
        raise SyncError("Ahí no está el cliente de WoW Forever. Elige la carpeta de World of Warcraft que contiene "
                        "_forever_ (o la carpeta _forever_ misma).")
    return folder


def _windows():
    return os.name == "nt"


def _fixed_drives():
    try:
        kernel32 = ctypes.windll.kernel32
        kernel32.SetErrorMode(0x0001 | 0x8000)  # no "insert a disk" dialogs while probing
        mask = kernel32.GetLogicalDrives()
        drives = [f"{chr(65 + i)}:\\" for i in range(26) if mask >> i & 1]
        return [d for d in drives if kernel32.GetDriveTypeW(d) == 3]
    except Exception:
        return ["C:\\"]


def detect_wow_folders(env=None):
    """Common places of a World of Warcraft install that holds the Forever client (_forever_)."""
    env = os.environ if env is None else env
    candidates = []
    if _windows():
        try:
            import winreg
            for root in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                         r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
                try:
                    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, root) as handle:
                        install = Path(str(winreg.QueryValueEx(handle, "InstallPath")[0]).rstrip("\\/"))
                    candidates += [install, install.parent]
                except OSError:
                    pass
        except ImportError:
            pass
        for name in ("ProgramFiles(x86)", "ProgramFiles", "ProgramW6432"):
            if env.get(name):
                candidates.append(Path(env[name]) / "World of Warcraft")
        if env.get("PUBLIC"):
            candidates.append(Path(env["PUBLIC"]) / "Games" / "World of Warcraft")
        for drive in _fixed_drives():
            for sub in ("World of Warcraft", r"Games\World of Warcraft", r"Juegos\World of Warcraft",
                        r"Battle.net\World of Warcraft", r"Blizzard\World of Warcraft",
                        r"Program Files (x86)\World of Warcraft", r"Program Files\World of Warcraft"):
                candidates.append(Path(drive) / sub)
    else:
        candidates += [Path("/Applications/World of Warcraft"), Path.home() / "Applications" / "World of Warcraft",
                       Path.home() / "Games" / "World of Warcraft"]
    found, seen = [], set()
    for candidate in candidates:
        try:
            if (candidate / "_forever_").is_dir():
                resolved = candidate.resolve()
                if str(resolved).lower() not in seen:
                    seen.add(str(resolved).lower())
                    found.append(resolved)
        except OSError:
            continue
    return found


# ---------------------------------------------------------------------------------------------------------------
# Panel address, member key and upload
# ---------------------------------------------------------------------------------------------------------------
def validate_panel_url(value, env=None):
    """The panel's HTTPS origin. The /hermandad page address is accepted too. http is only allowed for
    127.0.0.1 or localhost when OROHERMANDAD_SOLO_PRUEBAS_HTTP_LOCAL=1 (a local wrangler dev test)."""
    env = os.environ if env is None else env
    if isinstance(value, str):
        value = value.strip()
        try:
            parts = urlsplit(value)
            parts.port
        except ValueError:
            parts = None
        if parts and parts.path.rstrip("/") in ("/hermandad", "/hermandad.html") and not parts.query and not parts.fragment:
            value = urlunsplit((parts.scheme, parts.netloc, "", "", ""))
        if parts and parts.scheme.lower() == "http" and env.get(LOCAL_TEST_ENV) == "1":
            if (parts.hostname in ("127.0.0.1", "localhost") and parts.username is None and parts.password is None
                    and parts.path.rstrip("/") in ("", "/hermandad", "/hermandad.html") and not parts.query and not parts.fragment):
                return f"http://{parts.hostname}" + (f":{parts.port}" if parts.port else "")
            raise SyncError("El modo de pruebas sin HTTPS solo admite http://127.0.0.1 o http://localhost.")
    try:
        return sync.validate_url(value)
    except SyncError as error:
        raise SyncError(str(error).replace("de tu aplicación", "del panel").replace("de la aplicación", "del panel")) from None


def validate_key(value):
    if not isinstance(value, str) or not KEY_PATTERN.fullmatch(value.strip()):
        raise SyncError("La clave no tiene el formato de una clave de la hermandad (gld_ y 43 letras, números, - o _). "
                        "Cópiala de nuevo del mensaje en el que te la dieron.")
    return value.strip()


def _server_message(error, key):
    try:
        raw = error.read(MAX_RESPONSE_BYTES)
        data = json.loads(raw.decode("utf-8"))
        message = data.get("error") if isinstance(data, dict) else None
    except Exception:
        message = None
    if not isinstance(message, str):
        return ""
    message = CONTROL.sub(" ", message).strip()[:300]
    return message.replace(key, "[clave]") if key else message


def post_guild(url, key, payload, timeout=REQUEST_TIMEOUT):
    """One upload to <panel>/api/guild/sync. HTTPS only and no redirects, so the key cannot be sent elsewhere."""
    url, key = validate_panel_url(url), validate_key(key)
    request = Request(url + "/api/guild/sync", data=payload, method="POST",
                      headers={"Authorization": "Bearer " + key, "Content-Type": "application/json; charset=utf-8",
                               "Accept": "application/json", "User-Agent": USER_AGENT})
    opener = build_opener(sync._NoRedirect())
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as error:
        try:
            message = _server_message(error, key)
            retry_after = error.headers.get("Retry-After") if error.headers else None
        finally:
            error.close()
        said = f" El panel dice: «{message}»" if message else ""
        if error.code in (401, 403):
            raise AuthenticationError("El panel ha rechazado tu clave de la hermandad (incorrecta o revocada). Se detiene "
                                      "el subidor. Pide una clave nueva a quien administra la hermandad y abre "
                                      "HERMANDAD.cmd --reset para pegarla." + said) from None
        if error.code in (400, 413, 415, 422):
            raise RejectedUploadError(f"El panel no ha aceptado estos datos (HTTP {error.code}).{said}") from None
        if 300 <= error.code < 400:
            raise RetryableSyncError("La dirección del panel devuelve una redirección y no se sigue para no reenviar "
                                     "tu clave. Usa la dirección HTTPS final del panel (--reset para cambiarla).") from None
        if error.code == 429:
            wait = 900
            try:
                wait = int(retry_after)
            except (TypeError, ValueError):
                pass
            limited = RetryableSyncError(f"El panel pide esperar antes del siguiente envío (HTTP 429).{said}")
            limited.retry_after = max(60, min(3600, wait))
            raise limited from None
        if error.code == 503:
            raise RetryableSyncError("El panel todavía no tiene activada la hermandad (HTTP 503). Avisa a quien lo "
                                     "administra; se volverá a intentar." + said, 300) from None
        raise RetryableSyncError(f"El panel no ha podido guardar los datos (HTTP {error.code}). Se volverá a intentar.") from None
    except (URLError, TimeoutError, OSError, ssl.SSLError):
        raise RetryableSyncError("No se ha podido conectar con el panel. Tus archivos no se han tocado; se volverá "
                                 "a intentar.") from None
    if len(raw) > MAX_RESPONSE_BYTES:
        raise RetryableSyncError("El panel ha devuelto una respuesta demasiado grande.")
    try:
        result = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise RetryableSyncError("El panel no ha devuelto una confirmación válida.") from None
    if not isinstance(result, dict) or result.get("accepted") is not True:
        raise RetryableSyncError("El panel no ha confirmado el envío. Se volverá a intentar.")
    return result


# ---------------------------------------------------------------------------------------------------------------
# The uploader
# ---------------------------------------------------------------------------------------------------------------
@dataclass
class Event:
    source: Source
    kind: str          # uploaded, duplicate, rejected, invalid, empty, pending, unchanged
    message: str = ""
    result: dict | None = None
    upload: dict | None = None
    notes: tuple = ()


class GuildUploader:
    """state: {str(path): {"file": sha256, "payload": sha256, "at": unix, "markets": progress}} of accepted uploads;
    save() persists it. "payload" is the hash of the complete upload the file gives (unchanged content is never sent
    again), "markets" what the panel already has (accepted_progress), so only what is new is sent. Both are only
    recorded after the panel answers accepted: true; a rejected upload forgets "markets", so the next one is complete."""

    def __init__(self, url, key, folder, state=None, save=None, poster=post_guild, clock=time.time):
        self.url = validate_panel_url(url)
        self._key = validate_key(key)
        self.folder = Path(folder)
        self.state = {} if state is None else state
        self.save = save or (lambda: None)
        self.poster = poster
        self.clock = clock
        self.ignored = {}   # path -> sha256 of a file that was invalid, empty or rejected (until it changes)
        self.settled = {}   # path -> stat signature already handled in this run: not read again until it changes

    def remember(self, path, file_sha, payload_sha, now, markets=None):
        self.state[str(path)] = {"file": file_sha, "payload": payload_sha, "at": int(now)}
        if markets:
            self.state[str(path)]["markets"] = markets
        while len(self.state) > MAX_ACCOUNTS:
            self.state.pop(min(self.state, key=lambda k: self.state[k].get("at", 0)))
        try:
            self.save()
        except OSError:
            say("Aviso: no se ha podido guardar el registro de envíos; al reiniciar se enviará otra vez lo mismo.")

    def cycle(self):
        now = self.clock()
        events, present = [], 0
        for source in find_sources(self.folder):
            try:
                stat = source.path.stat()
            except OSError:
                continue
            if not source.path.is_file():
                continue
            present += 1
            try:
                events.append(self.check(source, stat, now))
            except (AuthenticationError, RetryableSyncError) as error:
                error.events = events
                raise
        return {"status": "missing" if present == 0 else "ok", "events": events}

    def check(self, source, stat, now):
        key, signature = str(source.path), (stat.st_size, stat.st_mtime_ns, stat.st_ino, stat.st_ctime_ns)
        if self.settled.get(key) == signature:
            return Event(source, "unchanged")
        # WoW writes the file at /reload or logout: wait until it has not changed for a few seconds.
        if 0 <= now - stat.st_mtime < SETTLE_SECONDS:
            return Event(source, "pending")
        try:
            observation = sync.stable_read(source.path, allowed=ALLOWED)
        except ReadPendingError:
            return Event(source, "pending")
        except SyncError as error:
            self.settled[key] = signature
            return Event(source, "invalid", str(error))
        event = self.handle(source, observation, now)
        self.settled[key] = signature
        return event

    def handle(self, source, observation, now):
        path, key = source.path, str(source.path)
        saved = self.state.get(key) or {}
        if observation.sha256 == saved.get("file") or observation.sha256 == self.ignored.get(key):
            return Event(source, "unchanged")
        try:
            hist = extract_hist(observation.text)
            if hist is None:
                self.ignored[key] = observation.sha256
                return Event(source, "empty", f"{SOURCE_NAME} todavía no tiene el historial de precios ({HIST_GLOBAL}). "
                             "Instala Oro de Hermandad 0.3.0 o posterior, entra en el juego y sal (o usa /reload).")
            complete, notes = build_upload(hist, now)
            if not complete["markets"]:
                self.ignored[key] = observation.sha256
                return Event(source, "empty", "todavía no hay precios para enviar. Abre la casa de subastas con "
                             "Auctionator, haz un escaneo y sal del juego (o usa /reload).")
            digest = hashlib.sha256(encode_json(complete)).hexdigest()
            sent = saved.get("markets")
            if digest == saved.get("payload"):
                self.remember(path, observation.sha256, digest, now, sent)
                return Event(source, "unchanged")
            upload, notes = build_upload(hist, now, sent) if sent else (complete, notes)
            if not upload["markets"]:                   # the panel already has everything new in the file
                self.remember(path, observation.sha256, digest, now, sent)
                return Event(source, "unchanged")
            payload, more = encode_payload(upload)
        except SyncError as error:
            self.ignored[key] = observation.sha256
            return Event(source, "invalid", str(error))
        try:
            result = self.poster(self.url, self._key, payload, timeout=REQUEST_TIMEOUT)
        except RejectedUploadError as error:
            self.ignored[key] = observation.sha256
            if sent:
                self.state[key] = {k: v for k, v in saved.items() if k != "markets"}
                with contextlib.suppress(OSError):
                    self.save()
            return Event(source, "rejected", str(error), upload=upload)
        if not isinstance(result, dict) or result.get("accepted") is not True:
            raise RetryableSyncError("El panel no ha confirmado el envío. Se volverá a intentar.")
        # A duplicate answer means the panel had this exact body already: what it has did not change.
        progress = sent if result.get("duplicate") is True else accepted_progress(sent, json.loads(payload), result)
        self.remember(path, observation.sha256, digest, now, progress)
        kind = "duplicate" if result.get("duplicate") is True else "uploaded"
        return Event(source, kind, result=result, upload=upload, notes=tuple(notes + more))


SKIPPED = {"LIMITE_DE_MERCADOS": "el panel ya tiene el máximo de mercados"}


def describe(event):
    who = f"Cuenta {event.source.account}"
    if event.kind == "uploaded":
        result = event.result or {}
        changes = result.get("rowsChanged")
        text = f"{who}: envío aceptado ({summary(event.upload)})"
        text += f": {plural(changes, 'cambio', 'cambios')}." if _is_int(changes, 0, 10**12) else "."
        left = result.get("uploadsLeft")
        if _is_int(left, 0, 10**6):
            text += " Te queda 1 envío hoy." if left == 1 else f" Te quedan {left} envíos hoy."
        lines = [text]
        for market in result.get("markets") if isinstance(result.get("markets"), list) else []:
            if not isinstance(market, dict):
                continue
            name = market.get("market") if isinstance(market.get("market"), str) else "?"
            skipped = market.get("skipped")
            if isinstance(skipped, str) and skipped:
                lines.append(f"{who}: el panel no ha guardado {name}: {SKIPPED.get(skipped, skipped)}.")
            items = market.get("skippedItems")
            if isinstance(items, list) and items:
                lines.append(f"{who}: en {name}, {plural(len(items), 'objeto no cabe', 'objetos no caben')} en el panel "
                             "(límite de objetos por mercado).")
        lines += [f"{who}: aviso: {note}." for note in event.notes]
        return lines
    if event.kind == "duplicate":
        return [f"{who}: el panel ya tenía estos datos; nada nuevo."]
    if event.kind == "rejected":
        return [f"{who}: {event.message} No se volverá a enviar hasta que el archivo cambie."]
    if event.kind in ("invalid", "empty"):
        return [f"{who}: {event.message}"]
    if event.kind == "pending":
        return [f"{who}: WoW está guardando {SOURCE_NAME}; se leerá en cuanto termine."]
    return []


def run(uploader, once=False, sleep=time.sleep):
    """Watch loop: checks every 15 s; on errors waits 60 s doubling up to 5 min (or what the panel asks).
    Returns 0 when stopped normally, 1 after an error in --once and 2 if the key was refused."""
    backoff, last_status, pending, problems, tries = 60, None, set(), False, 0
    while True:
        try:
            result = uploader.cycle()
        except AuthenticationError as error:
            for event in getattr(error, "events", []):
                for line in describe(event):
                    say(line)
            say(str(error))
            return 2
        except SyncError as error:
            for event in getattr(error, "events", []):
                for line in describe(event):
                    say(line)
            say(str(error))
            if once:
                return 1
            delay = max(backoff, getattr(error, "retry_after", 60))
            say(f"Nuevo intento dentro de {delay} segundos. Ctrl+C para cerrar.")
            sleep(delay)
            backoff, last_status = min(300, backoff * 2), None
            continue
        backoff = 60
        now_pending = set()
        for event in result["events"]:
            if event.kind == "pending":
                now_pending.add(str(event.source.path))
                if str(event.source.path) in pending:
                    continue
            problems = problems or event.kind in ("invalid", "rejected")
            for line in describe(event):
                say(line)
        pending = now_pending
        status = result["status"]
        quiet = all(e.kind == "unchanged" for e in result["events"])
        if status == "missing" and status != last_status:
            say(f"Esperando {SOURCE_NAME} en {uploader.folder}. Entra en el juego con Oro de Hermandad y usa /reload "
                "o sal del juego para que WoW lo guarde.")
        elif status == "ok" and quiet and last_status != "quiet":
            say("Sin cambios pendientes.")
        last_status = "quiet" if status == "ok" and quiet else status
        if once:
            if pending and tries < 10:
                tries += 1
                sleep(SETTLE_SECONDS)
                continue
            return 1 if problems else 0
        sleep(POLL_SECONDS)


# ---------------------------------------------------------------------------------------------------------------
# Key protection: Windows DPAPI (CryptProtectData through ctypes)
# ---------------------------------------------------------------------------------------------------------------
class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32), ("pbData", ctypes.POINTER(ctypes.c_char))]


@dataclass(frozen=True)
class _DpapiApi:
    protect: object
    unprotect: object
    local_free: object


def _windows_dpapi():
    crypt32, kernel32 = ctypes.WinDLL("crypt32", use_last_error=True), ctypes.WinDLL("kernel32", use_last_error=True)
    blob = ctypes.POINTER(DATA_BLOB)
    crypt32.CryptProtectData.argtypes = [blob, ctypes.c_wchar_p, blob, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, blob]
    crypt32.CryptProtectData.restype = ctypes.c_int
    crypt32.CryptUnprotectData.argtypes = [blob, ctypes.c_void_p, blob, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, blob]
    crypt32.CryptUnprotectData.restype = ctypes.c_int
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    return _DpapiApi(crypt32.CryptProtectData, crypt32.CryptUnprotectData, kernel32.LocalFree)


class DpapiProtector:
    """Encrypts the key for the current Windows user on this PC; another user or PC cannot decrypt it."""
    name = "dpapi"
    ENTROPY = b"OroHermandad/clave-gld/v1"
    UI_FORBIDDEN = 0x1

    def __init__(self, api=None):
        self.api = api

    def _call(self, function, data, describe_text):
        api = self.api = self.api or _windows_dpapi()
        source = ctypes.create_string_buffer(data, len(data))
        entropy = ctypes.create_string_buffer(self.ENTROPY, len(self.ENTROPY))
        blob_in = DATA_BLOB(len(data), ctypes.cast(source, ctypes.POINTER(ctypes.c_char)))
        blob_entropy = DATA_BLOB(len(self.ENTROPY), ctypes.cast(entropy, ctypes.POINTER(ctypes.c_char)))
        blob_out = DATA_BLOB()
        try:
            ok = getattr(api, function)(ctypes.pointer(blob_in), describe_text, ctypes.pointer(blob_entropy), None, None,
                                        self.UI_FORBIDDEN, ctypes.pointer(blob_out))
            if not ok or not blob_out.pbData:
                raise KeyStoreError("La protección de datos de Windows (DPAPI) no ha podido "
                                    + ("cifrar" if function == "protect" else "descifrar") + " la clave.")
            result = ctypes.string_at(blob_out.pbData, blob_out.cbData)
            ctypes.memset(blob_out.pbData, 0, blob_out.cbData)
            api.local_free(ctypes.cast(blob_out.pbData, ctypes.c_void_p))
            return result
        finally:
            ctypes.memset(source, 0, len(data))

    def protect(self, secret):
        return self._call("protect", secret, "Oro de Hermandad")

    def unprotect(self, blob):
        return self._call("unprotect", blob, None)


class TestOnlyProtector:
    """SOLO PARA PRUEBAS: guarda la clave SIN CIFRAR. Nunca se elige solo; únicamente las pruebas lo pasan."""
    name = "solo-pruebas-sin-cifrar"
    MARK = b"SOLO-PRUEBAS-SIN-CIFRAR:"

    def protect(self, secret):
        return self.MARK + secret

    def unprotect(self, blob):
        if not blob.startswith(self.MARK):
            raise KeyStoreError("La clave guardada no es de este modo de pruebas.")
        return blob[len(self.MARK):]


def default_protector():
    """DPAPI on Windows. Elsewhere there is nothing equivalent in the standard library: the key stays in memory."""
    return DpapiProtector() if _windows() else None


def seal_key(key, protector):
    blob = protector.protect(key.encode("ascii"))
    if protector.unprotect(blob) != key.encode("ascii"):
        raise KeyStoreError("No se ha podido comprobar la clave cifrada.")
    return {"protection": protector.name, "data": base64.b64encode(blob).decode("ascii")}


def open_key(stored, protector):
    if not isinstance(stored, dict) or protector is None or stored.get("protection") != protector.name:
        return None
    try:
        return validate_key(protector.unprotect(base64.b64decode(str(stored.get("data")), validate=True)).decode("ascii"))
    except (KeyStoreError, SyncError, ValueError, UnicodeError):
        return None


# ---------------------------------------------------------------------------------------------------------------
# Settings in %LOCALAPPDATA%\OroHermandad\config.json
# ---------------------------------------------------------------------------------------------------------------
def config_dir(env=None):
    env = os.environ if env is None else env
    if _windows():
        base = env.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    else:
        base = env.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "OroHermandad"


def load_config(directory):
    path = Path(directory) / "config.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, UnicodeError):
        say("La configuración guardada no se puede leer; se pedirán los datos de nuevo.")
        return {}
    if not isinstance(data, dict) or data.get("schema") != 1:
        return {}
    if not isinstance(data.get("sources"), dict):
        data["sources"] = {}
    return data


def save_config(directory, data):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "config.json.tmp"
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    if not _windows():
        os.chmod(temporary, 0o600)
    os.replace(temporary, directory / "config.json")


@contextlib.contextmanager
def instance_lock(directory):
    """Only one uploader per Windows user (the startup task and a double click would otherwise both upload)."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    stream = open(directory / "subidor.lock", "a+")
    locked = False
    try:
        try:
            if _windows():
                import msvcrt
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except ImportError:
            locked = True
        except OSError:
            locked = False
        yield locked
    finally:
        if locked:
            with contextlib.suppress(Exception):
                if _windows():
                    import msvcrt
                    stream.seek(0)
                    msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        stream.close()


def _ask_until_valid(ask, prompt, check, attempts=5):
    for _ in range(attempts):
        try:
            return check(ask(prompt))
        except SyncError as error:
            say(str(error), stamp=False)
    raise SyncError("Demasiados intentos. Vuelve a abrir HERMANDAD.cmd cuando tengas los datos a mano.")


def ask_folder(ask, detect):
    found = detect()
    if found:
        say("He encontrado World of Warcraft con el cliente Forever en:", stamp=False)
        for number, folder in enumerate(found, 1):
            say(f"  {number}) {folder}", stamp=False)
        prompt = "Pulsa Intro para usar la 1, escribe otro número o pega otra carpeta: "
    else:
        say("No he encontrado World of Warcraft en las carpetas habituales.", stamp=False)
        prompt = "Pega la carpeta de World of Warcraft (la que contiene _forever_): "

    def check(answer):
        answer = (answer or "").strip()
        if found and (answer == "" or answer.isdigit()):
            index = int(answer or "1") - 1
            if not 0 <= index < len(found):
                raise SyncError("Ese número no está en la lista.")
            return validate_wow_folder(found[index])
        return validate_wow_folder(answer)
    return _ask_until_valid(ask, prompt, check)


def ensure_settings(config, protector, interactive, ask=input, ask_secret=getpass.getpass, detect=detect_wow_folders):
    """(url, folder, key). Asks only for what is missing or no longer valid, then stores url and folder in the
    config and the key sealed with DPAPI. Without a protector the key is only kept in memory."""
    url = folder = key = None
    with contextlib.suppress(SyncError):
        url = validate_panel_url(config.get("url"))
    with contextlib.suppress(SyncError):
        folder = validate_wow_folder(config.get("wow"))
    key = open_key(config.get("key"), protector)
    if config.get("key") and key is None and protector is not None:
        say("No se ha podido descifrar la clave guardada (quizá es de otro usuario de Windows o de otro PC).", stamp=False)
    if url and folder and key:
        return url, folder, key
    if not interactive:
        raise SyncError("Falta la configuración del subidor o ya no es válida. Abre HERMANDAD.cmd una vez para "
                        "guardar la dirección del panel, la carpeta de WoW y tu clave.")
    if not config.get("url"):
        say("Primera vez: necesito tres datos. Se guardan en este PC y no se vuelven a pedir.", stamp=False)
    if not url:
        url = _ask_until_valid(ask, "Dirección HTTPS del panel de la hermandad (te la da quien la administra): ",
                               validate_panel_url)
    if not folder:
        folder = ask_folder(ask, detect)
        if not any(source.path.is_file() for source in find_sources(folder)):
            say(f"Todavía no hay ningún {SOURCE_NAME} ahí. Se creará cuando juegues con Oro de Hermandad 0.3.0 y "
                "salgas del juego (o uses /reload).", stamp=False)
    if not key:
        key = _ask_until_valid(ask_secret, "Pega tu clave personal de la hermandad (gld_..., no se verá al pegarla): ",
                               validate_key)
    config.update({"schema": 1, "url": url, "wow": str(folder)})
    config.setdefault("sources", {})
    if protector is not None:
        config["key"] = seal_key(key, protector)
        say("Clave guardada cifrada con la protección de datos de Windows: solo tu usuario de Windows, en este PC, "
            "puede usarla.", stamp=False)
    else:
        config.pop("key", None)
        say("En este sistema no hay protección de datos de Windows: la clave no se guarda y se pedirá cada vez.",
            stamp=False)
    return url, folder, key


# ---------------------------------------------------------------------------------------------------------------
# Optional start with Windows (Task Scheduler, opt-in)
# ---------------------------------------------------------------------------------------------------------------
def startup_parts(executable=None, script=None):
    """(program, arguments) of the start with Windows: pythonw.exe when it exists next to python.exe (no window)."""
    executable = Path(executable or sys.executable)
    windowless = executable.with_name("pythonw.exe")
    if windowless.is_file():
        executable = windowless
    script = Path(script or __file__).resolve()
    arguments = f'"{script}" --segundo-plano'
    if len(f'"{executable}" {arguments}') > TASK_COMMAND_MAX:
        raise SyncError("La ruta de la carpeta del subidor es demasiado larga para el Programador de tareas. Mueve la "
                        "carpeta a una ruta más corta (por ejemplo C:\\OroHermandad) y vuelve a intentarlo.")
    return executable, arguments


def startup_task_xml(executable, arguments, user=None, folder=None):
    """Task Scheduler definition of the start with Windows. A task made with plain schtasks switches would keep the
    Windows defaults: it would not start on battery power, would stop when the laptop is unplugged and would be killed
    after 72 hours, all without a window to say so. Those settings only exist in a task XML, so they are written here:
    start one minute after this user logs on, only while that user is logged on, with the lowest rights, never stopped
    by battery or a time limit, and never twice at once."""
    user_id = f"\n      <UserId>{xml_text(user)}</UserId>" if user else ""
    folder_line = f"\n      <WorkingDirectory>{xml_text(str(folder))}</WorkingDirectory>" if folder else ""
    return f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Oro de Hermandad: sube los precios de la hermandad al panel sin abrir ventanas.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>{user_id}
      <Delay>PT1M</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">{user_id}
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"{xml_text(str(executable))}"</Command>
      <Arguments>{xml_text(arguments)}</Arguments>{folder_line}
    </Exec>
  </Actions>
</Task>
"""


def _schtasks(arguments, runner):
    return runner(["schtasks", *arguments], capture_output=True, stdin=subprocess.DEVNULL, timeout=60,
                  encoding="oem" if _windows() else None, errors="replace")


def install_startup(runner=subprocess.run, env=None, executable=None, script=None, home=None):
    env = os.environ if env is None else env
    if not _windows():
        raise SyncError("El inicio con Windows solo existe en Windows.")
    program, arguments = startup_parts(executable, script)
    user = env.get("USERNAME")
    if user and env.get("USERDOMAIN"):
        user = f"{env['USERDOMAIN']}\\{user}"
    definition = startup_task_xml(program, arguments, user, Path(script or __file__).resolve().parent)
    # schtasks reads the definition from a file; it holds paths only (never the key) and is deleted right after.
    handle, name = tempfile.mkstemp(prefix="OroHermandad-tarea-", suffix=".xml")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(definition.encode("utf-16"))
        result = _schtasks(["/Create", "/TN", TASK_NAME, "/XML", name, "/F"], runner)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(name)
    if result.returncode != 0:
        raise SyncError(f"Windows no ha dejado crear la tarea de inicio (código {result.returncode}). Las tareas que "
                        "arrancan al iniciar sesión a veces piden permisos de administrador: abre «Símbolo del sistema» "
                        "como administrador, ve a esta carpeta y ejecuta  py -3 hermandad.py --instalar-inicio  "
                        "(o sigue abriendo HERMANDAD.cmd a mano).")
    log_file = Path(home or config_dir(env)) / "registro.txt"
    say(f"Listo: el subidor arrancará sin ventana un minuto después de cada inicio de sesión en Windows, también con "
        f"el portátil sin enchufar y sin límite de tiempo (tarea «{TASK_NAME}»). Lo que haga queda en {log_file}. "
        "Para quitarlo: HERMANDAD.cmd --quitar-inicio", stamp=False)


def uninstall_startup(runner=subprocess.run):
    if not _windows():
        raise SyncError("El inicio con Windows solo existe en Windows.")
    result = _schtasks(["/Delete", "/TN", TASK_NAME, "/F"], runner)
    if result.returncode != 0:
        say("No había ninguna tarea de inicio del subidor (o ya se había quitado).", stamp=False)
    else:
        say("Quitado: el subidor ya no arrancará con Windows.", stamp=False)


# ---------------------------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------------------------
_DEFAULT = object()


def main(argv=None, *, protector=_DEFAULT, home=None, ask=input, ask_secret=getpass.getpass, detect=detect_wow_folders,
         poster=post_guild, runner=subprocess.run, sleep=time.sleep, clock=time.time):
    parser = argparse.ArgumentParser(prog="hermandad.py",
                                     description="Sube los precios de Oro de Hermandad al panel de la hermandad.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--once", action="store_true", help="hace una comprobación (y un envío si hay cambios) y termina")
    group.add_argument("--instalar-inicio", action="store_true", help="arranca el subidor sin ventana al iniciar sesión en Windows")
    group.add_argument("--quitar-inicio", action="store_true", help="quita el arranque con Windows")
    group.add_argument("--reset", action="store_true", help="borra la dirección, la carpeta y la clave guardadas")
    group.add_argument("--segundo-plano", action="store_true", help="lo usa la tarea de inicio: sin ventana ni preguntas")
    args = parser.parse_args(argv)
    home = Path(home) if home else config_dir()
    if protector is _DEFAULT:
        protector = default_protector()
    if args.segundo_plano:
        home.mkdir(parents=True, exist_ok=True)
        _out.file = home / "registro.txt"
    try:
        if not args.segundo_plano:
            say("Oro de Hermandad · subidor de precios para el panel de la hermandad", stamp=False)
            say(f"Solo envía {HIST_GLOBAL}: precios de los objetos vigilados (nombre, precio de mercader, categoría y "
                "depósitos) por reino y facción. Nunca envía personajes, la hermandad, profesiones, oro ni nada de "
                "Auctionator. No modifica WoW.", stamp=False)
        if args.reset:
            with contextlib.suppress(FileNotFoundError):
                (home / "config.json").unlink()
            say("Se ha borrado la configuración guardada (dirección, carpeta, clave cifrada y registro de envíos). "
                "La próxima vez se pedirá todo de nuevo. Si activaste el inicio con Windows y ya no lo quieres, usa "
                "--quitar-inicio.", stamp=False)
            return 0
        if args.quitar_inicio:
            uninstall_startup(runner)
            return 0
        if args.instalar_inicio and not _windows():
            raise SyncError("El inicio con Windows solo existe en Windows.")
        # The lock comes first: a running uploader owns config.json (its upload hashes) until it stops.
        with contextlib.nullcontext(True) if args.instalar_inicio else instance_lock(home) as locked:
            if not locked:
                say("Ya hay otro subidor de la hermandad funcionando en este PC (quizá el que arranca con Windows). "
                    "No hace falta abrir otro.")
                return 1
            config = load_config(home)
            before = json.dumps(config, sort_keys=True)
            url, folder, key = ensure_settings(config, protector, interactive=not args.segundo_plano, ask=ask,
                                               ask_secret=ask_secret, detect=detect)
            if json.dumps(config, sort_keys=True) != before:
                save_config(home, config)
            if args.instalar_inicio:
                if protector is None:
                    raise SyncError("Sin la protección de datos de Windows no se puede guardar la clave para el inicio "
                                    "automático.")
                install_startup(runner, home=home)
                return 0
            uploader = GuildUploader(url, key, folder, state=config["sources"], save=lambda: save_config(home, config),
                                     poster=poster, clock=clock)
            if args.segundo_plano:
                say(f"Subidor {VERSION} iniciado sin ventana. Vigilando {folder}.")
            elif not args.once:
                say(f"Vigilando {folder}. Mantén esta ventana abierta mientras juegas: WoW guarda {SOURCE_NAME} al usar "
                    "/reload o al salir. Ctrl+C para cerrar.", stamp=False)
            return run(uploader, once=args.once, sleep=sleep)
    except (SyncError, EOFError) as error:
        say(str(error) if isinstance(error, SyncError) else "Entrada cancelada. No se ha guardado nada nuevo.")
        return 1
    except KeyboardInterrupt:
        say("\nSubidor detenido.", stamp=False)
        return 0
    except Exception as error:
        if not args.segundo_plano:
            raise
        say(f"Error inesperado ({type(error).__name__}). El subidor se detiene.")
        return 1
    finally:
        _out.file = None


if __name__ == "__main__":
    sys.exit(main())
