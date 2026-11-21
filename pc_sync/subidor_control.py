"""Controller of the window «Oro de Hermandad · Subidor» (subidor.pyw): its states, texts and transitions, without Tk.

The window is a thin Tk view over this module and over the unchanged engine of hermandad.py:
- Session runs GuildUploader and hermandad.run() in a worker thread (stop and wake are threading.Events) and talks to
  the window only through a queue.Queue of plain messages, which the view polls every 200 ms (Tk is single-threaded):
  ("linea", text), ("enviando",), ("resultado", result, status), ("error", error, delay, status), ("aviso", marker
  status) and ("fin", code).
- Controller turns those messages into what the window shows: the status light and line, the detail line, the rows
  (panel, WoW folder, accounts, guild, marker), the version notice and the log.
- Setup holds the first run (and every «Cambiar»): the same checks as the command line (validate_panel_url,
  detect_wow_folders, validate_wow_folder, validate_key, seal_key).
- take_lock decides what to do when another uploader already runs for this Windows user (subidor.quien.json).
Nothing here imports tkinter, so the tests run everywhere; the Windows-only parts (DPAPI, winreg, PowerShell,
schtasks) are reached through hermandad.py and their injected seams.
"""
from __future__ import annotations

import collections
import contextlib
import ntpath
import os
import queue
import re
import threading
import time
from pathlib import Path

import hermandad as h

TITLE = "Oro de Hermandad · Subidor"
FOOTER = f"Versión {h.VERSION} · Basta con 1 o 2 personas de la hermandad."
LOG_LINES = 500
POLL_MS = 200

LIGHTS = {"verde": "#2e7d32", "gris": "#8a8a8a", "azul": "#1565c0", "ámbar": "#e09b00", "rojo": "#c62828"}
STATES = {
    "ok": ("verde", "Todo enviado"),
    "esperando": ("gris", "Esperando a WoW: guarda los precios al usar /reload o al salir del juego."),
    "enviando": ("azul", "Enviando…"),
    "red": ("ámbar", "Sin conexión con el panel. Se volverá a intentar a las {hora}."),
    "cuota": ("ámbar", "El panel pide esperar: siguiente intento a las {hora}."),
    "guardando": ("gris", "WoW está guardando el archivo; se leerá en cuanto termine."),
    "rechazado": ("ámbar", "{mensaje}"),
    "clave": ("rojo", "El panel ha rechazado tu clave. Pide una nueva a quien administra la hermandad."),
    "bloqueado": ("ámbar", "{mensaje}"),
    "detenido": ("rojo", "El subidor se ha parado por un error inesperado (está en el registro). Pulsa «Reintentar»."),
    "configurar": ("gris", "Falta configurar el subidor: sigue los pasos."),
}
BUTTONS = {"clave": "Cambiar clave", "bloqueado": "Reintentar", "detenido": "Reintentar"}

# Lock held at start (subidor.quien.json of the holder, and the hidden task of --instalar-inicio).
ALREADY_OPEN = "El subidor ya está abierto (mira la barra de tareas)."
MIGRATE = "He encontrado el subidor antiguo que arranca oculto con Windows. ¿Quitarlo y usar esta ventana?"
MIGRATED = "He quitado el subidor antiguo que arrancaba oculto con Windows: ahora sube esta ventana."
BLOCKED_CONSOLE = ("Ya hay otro subidor funcionando en este PC (una ventana de consola): ciérralo y vuelve a abrir "
                   "este.")
BLOCKED_HIDDEN = ("Ya hay otro subidor funcionando en este PC (el antiguo que arranca oculto con Windows): quítalo y "
                  "vuelve a abrir este.")
MIGRATED_AUTOSTART = "El subidor antiguo arrancaba con Windows. ¿Abrir esta ventana al iniciar Windows (minimizada)?"

# Two copies of the window (a new version extracted in another folder): config["subidor"] says which one is the newest.
OLD_COPY = ("Esta carpeta tiene la versión {esta} del subidor, pero en {carpeta} está la {otra}: cierra esta ventana y "
            "abre aquella. El inicio con Windows y el acceso directo del escritorio no se cambian a esta carpeta.")
LONG_COPY = ("La ruta de esta carpeta es demasiado larga para el inicio con Windows, y en {carpeta} está esta misma "
             "versión del subidor, que es la que se abre al iniciar Windows. El inicio con Windows y el acceso directo "
             "del escritorio no se cambian a esta carpeta.")
SHORTCUT_MOVED = "El acceso directo del escritorio abría otra carpeta: ahora abre esta."

# First run.
WELCOME = ("Bienvenido. Basta con que una o dos personas de la hermandad tengan el subidor abierto: el addon de los "
           "demás les pasa sus escaneos sin que se vea nada en el juego.")
ASK_URL = "Dirección del panel"
ASK_URL_HELP = "La que te dio quien administra la hermandad (empieza por https://)."
ASK_FOLDER = "Carpeta de World of Warcraft"
ASK_FOLDER_NONE = "No he encontrado World of Warcraft con el cliente Forever en las carpetas habituales."
CHOOSE_FOLDER = "Elegir otra carpeta…"
ASK_KEY = "Tu clave personal (empieza por gld_)"
PASTE = "Pegar"
KEY_SAFE = ("Se guarda cifrada con la protección de datos de Windows: solo tu usuario de Windows, en este PC, puede "
            "usarla.")
KEY_MEMORY = "En este sistema no hay protección de datos de Windows: la clave no se guarda y se pedirá cada vez."
READY = "Listo. Deja esta ventana abierta mientras juegas, o marca «Abrir el subidor al iniciar Windows»."
NEXT, START = "Siguiente", "Empezar"

# Main window.
UPLOAD_NOW = "Subir ahora"
UPLOAD_TIP = ("WoW solo escribe los precios en el archivo al usar /reload o al salir. Después de escanear, pulsa "
              "«Guardar y subir» en el addon o usa /reload, y el subidor los enviará en segundos.")
OPEN_PANEL, SHOW_LOG, MORE, CHANGE = "Abrir el panel", "Ver registro", "Más…", "Cambiar"
AUTOSTART = "Abrir el subidor al iniciar Windows (minimizado)"
SHORTCUT = "Crear acceso directo en el escritorio"
SHORTCUT_DONE = "Acceso directo creado en el escritorio: «Oro de Hermandad · Subidor»."
SHORTCUT_OFFER = "¿Crear un acceso directo en el escritorio para abrir el subidor sin «Abrir subidor.cmd»?"
CHANGE_KEY, REMOVE_MARKER, RESET = "Cambiar clave", "Quitar el aviso del addon", "Borrar mis datos de este PC"
RESET_CONFIRM = ("¿Borrar de este PC la dirección del panel, la carpeta, la clave cifrada, el registro de envíos y el "
                 "inicio con Windows? Después tendrás que configurarlo otra vez.")
RESET_DONE = "Datos del subidor borrados de este PC."
NEW_PANEL = "Panel nuevo: se le enviará todo otra vez."
LOG_TITLE = "Registro"
NEW_VERSION = ("Hay una versión nueva del subidor ({v}). Para actualizar: cierra el subidor, descarga «Subidor para "
               "Windows» en el panel (Descargas), desbloquea el zip y extrae su carpeta encima de la anterior "
               "(Reemplazar). Tu clave y tu configuración se conservan.")
CLOSE_WARNING = "Si cierras el subidor, los precios dejarán de subirse hasta que lo vuelvas a abrir."
CLOSE, MINIMIZE, CANCEL = "Cerrar", "Minimizar", "Cancelar"
WAIT_QUOTA = "El panel pide esperar: siguiente intento a las {hora}."
NOT_RUNNING = "El subidor no está subiendo ahora mismo."
ROWS = ("Panel", "Carpeta WoW", "Cuentas", "Hermandad", "Aviso addon")
MARKER_ROW = {
    "ok": "al día · el addon lo lee al entrar o con /reload",
    "refreshed": "al día · el addon lo lee al entrar o con /reload",
    "updated": "al día · el addon lo lee al entrar o con /reload",
    "later": "al día · el addon lo lee al entrar o con /reload",
    "created": "creado: sal del juego del todo y vuelve a entrar una vez (un /reload no basta)",
    "no-addon": "Oro de Hermandad no está instalado en esa carpeta de WoW",
    "unknown": "no encuentro la carpeta _forever_: escribe /oro subidor on en el juego",
    "denied": "no se ha podido escribir: escribe /oro subidor on en el juego",
    "error": "no se ha podido escribir: escribe /oro subidor on en el juego",
    "unsafe": "no se ha escrito (enlace fuera de AddOns): escribe /oro subidor on en el juego",
    "removed": "quitado: se vuelve a crear la próxima vez que abras el subidor",
}
MARKER_PENDING = "se comprueba al empezar"
_STAMP = re.compile(r"\[([0-9]{2}:[0-9]{2}):[0-9]{2}\] ")


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


def hhmm(t, local=time.localtime):
    """HH:MM of a unix time in this PC's time (only for display)."""
    return time.strftime("%H:%M", local(t))


def when(t, now, local=time.localtime):
    """«hoy a las 21:14», «ayer a las 21:14» or «el 18/11 a las 21:14»."""
    day, today = local(t), local(now)
    if (day.tm_year, day.tm_yday) == (today.tm_year, today.tm_yday):
        return f"hoy a las {hhmm(t, local)}"
    yesterday = local(now - 86400)
    if (day.tm_year, day.tm_yday) == (yesterday.tm_year, yesterday.tm_yday):
        return f"ayer a las {hhmm(t, local)}"
    return f"el {day.tm_mday:02d}/{day.tm_mon:02d} a las {hhmm(t, local)}"


def ago(t, now):
    """«hace 3 min», «hace 2 h», «hace 3 días» («hace menos de 1 min» under a minute)."""
    seconds = max(0, int(now - t))
    if seconds < 60:
        return "hace menos de 1 min"
    if seconds < 7200:
        return f"hace {seconds // 60} min"
    if seconds < 2 * 86400:
        return f"hace {seconds // 3600} h"
    return f"hace {seconds // 86400} días"


def clean_line(line, key=None):
    """A log line for the window: «[21:14:05] texto» -> «21:14 texto», and never a member key."""
    line = _STAMP.sub(lambda m: m.group(1) + " ", line, count=1) if line.startswith("[") else line
    if key:
        line = line.replace(key, "[clave]")
    return h.KEY_PATTERN.sub("[clave]", line)


def lock_decision(holder, task_installed):
    """What to do when subidor.lock is held: «abierto» (another window: say so and exit), «migrar» (the old hidden
    start with Windows: offer to remove it) or «bloqueado» (a console window, or nobody known: wait for it)."""
    modo = holder.get("modo") if isinstance(holder, dict) else None
    if modo == "ventana":
        return "abierto"
    if modo == "segundo-plano" or (holder is None and task_installed):
        return "migrar"
    return "bloqueado"


def take_lock(home, stack, ask, *, task_installed=h.startup_task_installed, remove_task=None, tries=20,
              pause=time.sleep):
    """Takes subidor.lock for the window (modo «ventana») and keeps it on stack (contextlib.ExitStack) until the
    window ends. Returns (outcome, text): («ok», "" or MIGRATED), («abierto», ALREADY_OPEN) or («bloqueado», text).
    ask(question) -> bool shows a yes/no question; remove_task() removes the hidden task (schtasks /End + /Delete)."""
    def attempt():
        trial = contextlib.ExitStack()
        if trial.enter_context(h.instance_lock(home, "ventana")):
            stack.enter_context(trial.pop_all())
            return True
        trial.close()
        return False

    if attempt():
        return "ok", ""
    holder = h.lock_holder(home)
    decision = lock_decision(holder, holder is None and task_installed())
    if decision == "abierto":
        return "abierto", ALREADY_OPEN
    if decision == "bloqueado":
        return "bloqueado", BLOCKED_CONSOLE
    if not ask(MIGRATE):
        return "bloqueado", BLOCKED_HIDDEN
    if remove_task is None:
        remove_task = lambda: h.uninstall_startup(end=True, hidden=True, quiet=True)
    with contextlib.suppress(h.SyncError, OSError):
        remove_task()
    for _ in range(tries):                 # the old copy needs a moment to end and free the lock
        if attempt():
            return "ok", MIGRATED
        pause(0.5)
    return "bloqueado", BLOCKED_HIDDEN


def claim_copy(config, script, folder, version=None, exists=os.path.isfile, autostart=None, command=None):
    """Whether this copy of the window may point the start with Windows and the desktop shortcut at its folder. script
    and folder: this copy's subidor.pyw and folder (hermandad.launch_parts). config["subidor"] = {"programa",
    "carpeta", "version"} remembers the newest copy opened (config.json is shared by every copy).
    (True, moved, ""): this copy is recorded in config; moved says that another folder was recorded: the folder was
    moved, or a newer or the same version was extracted elsewhere (with none recorded, False).
    (False, False, text): another folder that still has its subidor.pyw holds a newer version. This is then the old
    copy (opened from its old folder or an old shortcut) and must not take them back; config stays as it was. The same
    when that folder holds this same version and the start with Windows opens it (autostart: the Run value now) while
    this copy's Run value (command) would be longer than Windows runs: the start with Windows that works stays, and
    the shortcut is not moved to the folder that the window told the user to leave for a shorter one."""
    version = version or h.VERSION
    known = config.get("subidor") if isinstance(config.get("subidor"), dict) else {}
    other, theirs, mine = known.get("programa"), h.dotted_version(known.get("version")), h.dotted_version(version)
    other = other if isinstance(other, str) and other else None
    same = other is not None and ntpath.normcase(other) == ntpath.normcase(script)
    if other is not None and not same and theirs and mine and theirs >= mine and exists(other):
        place = known.get("carpeta") if isinstance(known.get("carpeta"), str) else ntpath.dirname(other)
        if theirs > mine:
            return False, False, OLD_COPY.format(esta=version, otra=known["version"], carpeta=place)
        opens = h.autostart_script(autostart)
        if (command is not None and not h.run_command_fits(command) and opens and h.run_command_fits(autostart)
                and ntpath.normcase(opens) == ntpath.normcase(other)):
            return False, False, LONG_COPY.format(carpeta=place)
    config["subidor"] = {"programa": script, "carpeta": folder, "version": version}
    return True, other is not None and not same, ""


def older_copy(known, version=None):
    """(subidor.pyw,) of the copy recorded in known (config["subidor"] before claim_copy) when it holds an older
    version than this one, otherwise (): hermandad.repair_autostart then removes a Run value that opens it."""
    known = known if isinstance(known, dict) else {}
    other, theirs = known.get("programa"), h.dotted_version(known.get("version"))
    mine = h.dotted_version(version or h.VERSION)
    return (other,) if isinstance(other, str) and other and theirs and mine and theirs < mine else ()


def scan_accounts(folder):
    """(accounts with OroHermandad.lua, newest time WoW saved one of them, or None) under the WoW folder."""
    count, newest = 0, None
    for source in h.find_sources(folder) if folder else ():
        try:
            stat = source.path.stat()
        except OSError:
            continue
        if source.path.is_file():
            count += 1
            newest = stat.st_mtime if newest is None else max(newest, stat.st_mtime)
    return count, newest


def folder_summary(folder):
    """«Cuentas encontradas: 2 · Oro de Hermandad instalado: sí» of a WoW folder."""
    accounts = len(h.find_sources(folder))
    forever = h.forever_folder(folder)
    installed = forever is not None and (Path(forever) / "Interface" / "AddOns" / "OroHermandad" / "OroHermandad.toc").is_file()
    return f"Cuentas encontradas: {accounts} · Oro de Hermandad instalado: {'sí' if installed else 'no'}"


# ---------------------------------------------------------------------------------------------------------------
# First run and «Cambiar»
# ---------------------------------------------------------------------------------------------------------------
class Setup:
    """The three steps of the first run (or one of them, for «Cambiar»). Each check_* returns an error text or ""."""

    def __init__(self, config, protector, detect=h.detect_wow_folders, steps=("url", "folder", "key")):
        self.config, self.protector, self.detect = config, protector, detect
        self.steps = tuple(steps)
        self.url = self.folder = self.key = None
        with contextlib.suppress(h.SyncError):
            self.url = h.validate_panel_url(config.get("url"))
        self.stored_url = self.url               # another panel needs everything again (finish)
        with contextlib.suppress(h.SyncError):
            self.folder = h.validate_wow_folder(config.get("wow"))
        self.key = h.open_key(config.get("key"), protector)
        self.found = None

    def folders(self):
        """The detected WoW installs that hold the Forever client (asked once)."""
        if self.found is None:
            try:
                self.found = list(self.detect())
            except Exception:
                self.found = []
        return self.found

    def check_url(self, text):
        try:
            self.url = h.validate_panel_url(text)
        except h.SyncError as error:
            return str(error)
        return ""

    def check_folder(self, text):
        try:
            self.folder = h.validate_wow_folder(text)
        except h.SyncError as error:
            return str(error)
        return ""

    def check_key(self, text):
        try:
            self.key = h.validate_key(text)
        except h.SyncError as error:
            return str(error)
        return ""

    def key_text(self):
        return KEY_SAFE if self.protector is not None else KEY_MEMORY

    def finish(self):
        """Stores the address and folder in the config and the key sealed with DPAPI (without DPAPI: in memory only).
        Returns (url, folder, key); raises SyncError when something is still missing."""
        if not (self.url and self.folder and self.key):
            raise h.SyncError("Falta algún dato: la dirección del panel, la carpeta de WoW o tu clave.")
        if self.url != self.stored_url:
            # What was sent («sources») and the status («estado») belong to the old panel: the new one gets it all.
            self.config["sources"] = {}
            self.config.pop("estado", None)
            if self.stored_url is not None:
                h.say(NEW_PANEL)
        self.config.update({"schema": 1, "url": self.url, "wow": str(self.folder)})
        self.config.setdefault("sources", {})
        if self.protector is not None:
            self.config["key"] = h.seal_key(self.key, self.protector)
        else:
            self.config.pop("key", None)
        return self.url, self.folder, self.key


def needed_steps(config, protector):
    """The first-run steps still missing for this config (none: the uploader can start)."""
    setup = Setup(config, protector, detect=lambda: [])
    return tuple(step for step, value in (("url", setup.url), ("folder", setup.folder), ("key", setup.key)) if not value)


# ---------------------------------------------------------------------------------------------------------------
# The uploader in the worker thread
# ---------------------------------------------------------------------------------------------------------------
class Session:
    """GuildUploader + hermandad.run() for the window. Only the worker thread writes config.json while it runs (the
    window waits for it to end before changing anything). Messages go to `messages` (a queue.Queue)."""

    def __init__(self, url, key, folder, config, home, messages, *, poster=h.post_guild, fishing_poster=h.post_fishing,
                 clock=time.time, save=None, marker=h.ensure_marker):
        self.config, self.home, self.messages, self.clock, self.folder = config, Path(home), messages, clock, folder
        self.stop, self.wake = threading.Event(), threading.Event()
        self.marker_removed = threading.Event()
        self.status = h.UploaderStatus(config.get("estado"))
        self.save = save or (lambda: h.save_config(self.home, self.config))
        self.poster, self.fishing_poster, self.ensure_marker = poster, fishing_poster, marker
        self.uploader = h.GuildUploader(url, key, folder, state=config.setdefault("sources", {}), save=self.save,
                                        poster=self._post, fishing_poster=self._post_fishing, clock=clock)
        self.thread = None

    def snapshot(self):
        return {name: getattr(self.status, name) for name in h.UploaderStatus.FIELDS}

    def _post(self, *args, **kwargs):
        self.messages.put(("enviando",))
        return self.poster(*args, **kwargs)

    def _post_fishing(self, *args, **kwargs):
        self.messages.put(("enviando",))
        return self.fishing_poster(*args, **kwargs)

    def _keep(self, changed):
        if changed:
            self.config["estado"] = self.status.to_config()
            try:
                self.save()
            except OSError:
                h.say("Aviso: no se ha podido guardar el estado del subidor.")

    def marker(self):
        if self.marker_removed.is_set():
            return "removed"
        status = self.ensure_marker(self.folder, self.status.marker_state(), now=self.clock())
        self.messages.put(("aviso", status))
        return status

    def on_result(self, result):
        self._keep(self.status.record_result(result, self.clock()))
        self.messages.put(("resultado", result, self.snapshot()))

    def on_error(self, error, delay):
        self._keep(self.status.record_error(error, self.clock()))
        self.messages.put(("error", error, delay, self.snapshot()))

    def main(self):
        """The worker thread: runs until stopped (0), the key is refused (2) or something unexpected happens (1)."""
        try:
            code = h.run(self.uploader, marker=self.marker, stop=self.stop, wake=self.wake, on_result=self.on_result,
                         on_error=self.on_error)
        except Exception as error:
            h.say(f"Error inesperado ({type(error).__name__}). El subidor se ha parado.")
            code = 1
        self.messages.put(("fin", code))
        return code

    def start(self):
        self.thread = threading.Thread(target=self.main, name="subidor", daemon=True)
        self.thread.start()
        return self.thread

    def alive(self):
        return self.thread is not None and self.thread.is_alive()

    def request_stop(self):
        self.stop.set()
        self.wake.set()

    def upload_now(self):
        self.wake.set()


# ---------------------------------------------------------------------------------------------------------------
# What the window shows
# ---------------------------------------------------------------------------------------------------------------
class Controller:
    """The window's model. handle(message) applies one message of the Session's queue; the other methods return
    the texts the view shows. clock and local are injected for the tests."""

    def __init__(self, clock=time.time, local=time.localtime):
        self.clock, self.local = clock, local
        self.state, self.message, self.retry_at = "esperando", "", None
        self.status = {}
        self.changes = None
        self.versions = {}          # account -> addon version of its last OroHermandadHist
        self.marker = None
        self.accounts = (0, None)   # scan_accounts of the WoW folder
        self.url = self.folder = None
        self.running = False
        self.key = None             # only to keep it out of the log, never shown
        self.log = collections.deque(maxlen=LOG_LINES)
        self.new_lines = []

    # -- messages ------------------------------------------------------------------------------------------------
    def handle(self, message):
        kind = message[0]
        if kind == "linea":
            self.add_line(message[1])
        elif kind == "enviando":
            if self.state not in ("clave", "bloqueado"):
                self.state = "enviando"
        elif kind == "resultado":
            self._result(message[1], message[2])
        elif kind == "error":
            self._error(message[1], message[2], message[3])
        elif kind == "aviso":
            self.marker = message[1]
        elif kind == "fin":
            self.running = False
            if message[1] == 1 and self.state not in ("clave", "bloqueado"):
                self.state = "detenido"

    def add_line(self, line):
        text = clean_line(str(line), self.key)
        self.log.append(text)
        self.new_lines.append(text)

    def take_lines(self):
        lines, self.new_lines = self.new_lines, []
        return lines

    def started(self, url, folder, key=None, status=None):
        self.url, self.folder, self.key, self.running = url, folder, key, True
        self.state, self.message, self.retry_at = "esperando", "", None
        if status:
            self.status = dict(status)
        if self.status.get("aceptado") and self.status.get("ultimo") == "ok":
            self.state = "ok"

    def blocked(self, text):
        self.state, self.message, self.running = "bloqueado", text, False

    def configuring(self):
        self.state, self.running = "configurar", False

    def _result(self, result, status):
        self.status = dict(status or {})
        self.retry_at = None
        events = result.get("events", []) if isinstance(result, dict) else []
        prices = [e for e in events if e.source.path.name == h.SOURCE_NAME]
        for event in prices:
            if event.addon:
                self.versions[event.source.account] = event.addon
        sent = [e for e in prices if e.kind in ("uploaded", "duplicate")]
        bad = [e for e in prices if e.kind in ("rejected", "invalid")]
        for event in sent:
            changes = (event.result or {}).get("rowsChanged") if event.kind == "uploaded" else 0
            if h._is_int(changes, 0, 10**12):
                self.changes = changes
        if any(e.kind == "pending" for e in events):
            self.state = "guardando"
        elif bad:
            self.state, self.message = "rechazado", h.describe(bad[0])[0]
        elif sent:
            self.state = "ok"
        elif isinstance(result, dict) and result.get("status") == "missing":
            self.state = "esperando"
        elif self.state != "rechazado":
            self.state = "ok" if self.status.get("aceptado") and self.status.get("ultimo") == "ok" else "esperando"

    def _error(self, error, delay, status):
        self.status = dict(status or {})
        self.state = h.error_estado(error)
        self.retry_at = None if delay is None else self.clock() + delay
        if self.state == "clave":
            self.running = False

    # -- actions -------------------------------------------------------------------------------------------------
    def upload_now(self):
        """«Subir ahora»: True when the worker should be woken. Not while the panel asked to wait (HTTP 429): that
        wait is kept, and the log says until when."""
        if not self.running:
            self.add_line(NOT_RUNNING)
            return False
        if self.state == "cuota":
            self.add_line(WAIT_QUOTA.format(hora=hhmm(self.retry_at, self.local) if self.retry_at else "--:--"))
            return False
        return True

    # -- texts ---------------------------------------------------------------------------------------------------
    def status_line(self):
        """(light colour name, text) of the status line."""
        light, text = STATES[self.state]
        hora = hhmm(self.retry_at, self.local) if self.retry_at else "--:--"
        return light, text.format(hora=hora, mensaje=self.message)

    def action(self):
        """The button next to the status line («Cambiar clave», «Reintentar»), or None."""
        return BUTTONS.get(self.state)

    def detail_line(self):
        now = self.clock()
        accepted = self.status.get("aceptado")
        if not accepted:
            return "" if self.state in ("bloqueado", "configurar") else "Todavía no hay ningún envío aceptado desde este PC."
        text = f"Último envío aceptado: {when(accepted, now, self.local)} ({ago(accepted, now)})"
        if self.changes is not None:
            text += f" · {plural(self.changes, 'cambio', 'cambios')}"
        text += "."
        left, day = self.status.get("quedan"), self.status.get("dia")
        if left is not None and day == h.day_index(now):
            text += " Te queda 1 envío hoy." if left == 1 else f" Te quedan {left} envíos hoy."
        return text

    def version_notice(self):
        latest = self.status.get("nueva")
        return NEW_VERSION.format(v=latest) if latest else ""

    def accounts_text(self):
        count, newest = self.accounts
        if not count:
            return "ninguna todavía: entra en el juego con Oro de Hermandad y sal (o usa /reload)"
        text = f"{count} con Oro de Hermandad"
        if newest is not None:
            text += f" · WoW guardó {ago(newest, self.clock())}"
        for account, version in sorted(self.versions.items()):
            if h.addon_notice(account, version):
                text += f" · {account} tiene el addon {version}: actualízalo para que el panel reciba las ventas"
        return text

    def guild_text(self):
        uploaders, feeders = self.status.get("suben"), self.status.get("aportan")
        if feeders is None:
            return "el panel lo dirá tras el próximo envío"
        if uploaders is None:
            return f"{plural(feeders, 'persona aporta', 'personas aportan')} precios (14 días)"
        return (f"{plural(uploaders, 'persona sube', 'personas suben')} y {feeders} "
                f"{'aporta' if feeders == 1 else 'aportan'} precios (14 días)")

    def marker_text(self):
        return MARKER_ROW.get(self.marker, MARKER_PENDING)

    def rows(self):
        """[(label, text)] of the five rows, in order."""
        return list(zip(ROWS, (self.url or "—", str(self.folder) if self.folder else "—", self.accounts_text(),
                               self.guild_text(), self.marker_text())))


def drain(messages, controller, limit=200):
    """Applies up to limit pending messages (the view calls it every POLL_MS). Returns how many."""
    done = 0
    while done < limit:
        try:
            message = messages.get_nowait()
        except queue.Empty:
            break
        controller.handle(message)
        done += 1
    return done
