"""Tests of the window «Oro de Hermandad · Subidor»: the controller (subidor_control.py) without Tk, the uploader in
its worker thread, the lock owner, the first run, the start with Windows and the desktop shortcut through injected
fakes (no Windows, registry, PowerShell or network needed), and the Tk view (subidor.pyw), which is skipped unless a
Tk window can really be created here (Windows, or a display on Linux)."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import queue
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import hermandad as h
import subidor_control as c
from test_hermandad import KEY, NOW, URL, sample_hist, saved_variables, write

HERE = Path(__file__).resolve().parent
V06 = HERE / "fixtures" / "v06"
SYNC = json.loads((V06 / "sync-response-v060.json").read_text(encoding="utf-8"))
def SPAIN(t):
    """The window shows the PC's time: the tests pin it to a PC in Spain in November (CET, UTC+1)."""
    return time.gmtime(t + 3600)


def tk_available():
    """True on Windows, or when a Tk root can really be created (tkinter present and a display)."""
    try:
        import tkinter
    except ImportError:
        return False
    if os.name == "nt":
        return True
    try:
        root = tkinter.Tk()
    except tkinter.TclError:
        return False
    root.destroy()
    return True


TK = tk_available()


def event(kind, account="JUSEP", result=None, name=h.SOURCE_NAME, addon=None, message=""):
    return h.Event(h.Source(account, Path("WoW") / account / name), kind, message=message, result=result,
                   upload={"markets": []}, addon=addon)


def accepted(rows=412, left=21, day=None, **extra):
    return {"accepted": True, "duplicate": False, "rowsChanged": rows, "uploadsLeft": left,
            "day": h.day_index(NOW) if day is None else day, **extra}


class Quiet(unittest.TestCase):
    def setUp(self):
        self.lines = []
        previous = h.set_output_sink(self.lines.append)
        self.addCleanup(h.set_output_sink, previous)
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.tmp = Path(folder.name)
        h.set_log_file(self.tmp / "registro.txt")
        self.addCleanup(h.set_log_file, None)


# -----------------------------------------------------------------------------------------------------------
# The controller: every state of the status line
# -----------------------------------------------------------------------------------------------------------
class ControllerTests(unittest.TestCase):
    def controller(self, now=NOW):
        controller = c.Controller(clock=lambda: now, local=SPAIN)
        controller.started(URL, Path("C:/WoW"), KEY)
        return controller

    def status(self, **values):
        return {"aceptado": 0, "ultimo": None, "suben": None, "aportan": None, "nueva": None, "quedan": None,
                "dia": None, **values}

    def test_ok_after_an_accepted_upload_with_the_detail_line(self):
        controller = self.controller(NOW + 180)
        controller.handle(("enviando",))
        self.assertEqual(controller.status_line(), ("azul", "Enviando…"))
        controller.handle(("resultado", {"status": "ok", "events": [event("uploaded", result=accepted())]},
                           self.status(aceptado=NOW, ultimo="ok", quedan=21, dia=h.day_index(NOW))))
        self.assertEqual(controller.status_line(), ("verde", "Todo enviado"))
        self.assertEqual(controller.detail_line(),
                         "Último envío aceptado: hoy a las 12:00 (hace 3 min) · 412 cambios. Te quedan 21 envíos hoy.")
        controller.handle(("resultado", {"status": "ok", "events": [event("unchanged")]},
                           self.status(aceptado=NOW, ultimo="ok", quedan=1, dia=h.day_index(NOW))))
        self.assertEqual(controller.state, "ok")
        self.assertTrue(controller.detail_line().endswith("· 412 cambios. Te queda 1 envío hoy."))
        later = c.Controller(clock=lambda: NOW + 86400, local=SPAIN)
        later.status = self.status(aceptado=NOW, quedan=21, dia=h.day_index(NOW))
        self.assertEqual(later.detail_line(), "Último envío aceptado: ayer a las 12:00 (hace 24 h).",
                         "uploads left of another day are not shown")
        later.clock = lambda: NOW + 5 * 86400
        self.assertEqual(later.detail_line(), "Último envío aceptado: el 09/11 a las 12:00 (hace 5 días).")

    def test_waiting_saving_and_nothing_sent_yet(self):
        controller = self.controller()
        self.assertEqual(controller.status_line(),
                         ("gris", "Esperando a WoW: guarda los precios al usar /reload o al salir del juego."))
        self.assertEqual(controller.detail_line(), "Todavía no hay ningún envío aceptado desde este PC.")
        controller.handle(("resultado", {"status": "missing", "events": []}, self.status()))
        self.assertEqual(controller.state, "esperando")
        controller.handle(("resultado", {"status": "ok", "events": [event("pending")]}, self.status()))
        self.assertEqual(controller.status_line(), ("gris", "WoW está guardando el archivo; se leerá en cuanto termine."))
        controller.handle(("resultado", {"status": "ok", "events": [event("unchanged"), event("empty")]}, self.status()))
        self.assertEqual(controller.state, "esperando")

    def test_network_quota_rejected_and_refused_key(self):
        controller = self.controller()
        controller.handle(("error", h.RetryableSyncError("sin red"), 120, self.status(ultimo="red")))
        self.assertEqual(controller.status_line(),
                         ("ámbar", "Sin conexión con el panel. Se volverá a intentar a las 12:02."))
        limited = h.RetryableSyncError("429")
        limited.cuota = True
        controller.handle(("error", limited, 900, self.status(ultimo="cuota")))
        self.assertEqual(controller.status_line(), ("ámbar", "El panel pide esperar: siguiente intento a las 12:15."))
        refused = event("rejected", message="El panel no ha aceptado estos datos (HTTP 400).")
        controller.handle(("resultado", {"status": "ok", "events": [refused]}, self.status(ultimo="rechazado")))
        self.assertEqual(controller.status_line(), ("ámbar", h.describe(refused)[0]))
        controller.handle(("resultado", {"status": "ok", "events": [event("unchanged")]}, self.status()))
        self.assertEqual(controller.state, "rechazado", "it stays until something is accepted")
        broken = event("invalid", message="OroHermandad.lua no se puede leer: falta un valor (línea 3).")
        controller.handle(("resultado", {"status": "ok", "events": [broken]}, self.status()))
        self.assertEqual(controller.status_line()[1], "Cuenta JUSEP: OroHermandad.lua no se puede leer: falta un valor (línea 3).")
        controller.handle(("resultado", {"status": "ok", "events": [event("uploaded", result=accepted())]},
                           self.status(aceptado=NOW, ultimo="ok")))
        self.assertEqual(controller.state, "ok")
        controller.handle(("error", h.AuthenticationError("clave"), None, self.status(aceptado=NOW, ultimo="clave")))
        self.assertEqual(controller.status_line(), ("rojo", "El panel ha rechazado tu clave. Pide una nueva a quien "
                                                            "administra la hermandad."))
        self.assertEqual(controller.action(), "Cambiar clave")
        controller.handle(("fin", 2))
        self.assertEqual((controller.state, controller.running), ("clave", False))

    def test_fishing_events_never_change_the_price_state(self):
        controller = self.controller()
        controller.handle(("resultado", {"status": "ok", "events": [event("rejected", name=h.FISHING_NAME),
                                                                     event("fishing", name=h.FISHING_NAME)]}, {}))
        self.assertEqual(controller.state, "esperando")

    def test_blocked_stopped_and_setup_states(self):
        controller = self.controller()
        controller.blocked(c.BLOCKED_CONSOLE)
        self.assertEqual(controller.status_line(), ("ámbar", "Ya hay otro subidor funcionando en este PC (una ventana de "
                                                             "consola): ciérralo y vuelve a abrir este."))
        self.assertEqual((controller.action(), controller.detail_line()), ("Reintentar", ""))
        other = self.controller()
        other.handle(("fin", 1))
        self.assertEqual((other.status_line()[0], other.action()), ("rojo", "Reintentar"))
        other.configuring()
        self.assertEqual(other.status_line(), ("gris", "Falta configurar el subidor: sigue los pasos."))
        self.assertEqual(set(c.STATES) >= {"ok", "esperando", "enviando", "red", "cuota", "guardando", "rechazado",
                                           "clave", "bloqueado"}, True)
        for light, _ in c.STATES.values():
            self.assertIn(light, c.LIGHTS)

    def test_upload_now_wakes_except_while_the_panel_asks_to_wait(self):
        controller = self.controller()
        self.assertTrue(controller.upload_now())
        limited = h.RetryableSyncError("429")
        limited.cuota = True
        controller.handle(("error", limited, 900, {}))
        self.assertFalse(controller.upload_now())
        self.assertEqual(controller.take_lines()[-1], "El panel pide esperar: siguiente intento a las 12:15.")
        controller.handle(("error", h.RetryableSyncError("sin red"), 60, {}))
        self.assertTrue(controller.upload_now(), "a network wait can be cut short")
        controller.handle(("error", h.AuthenticationError("clave"), None, {}))
        self.assertFalse(controller.upload_now())
        self.assertEqual(controller.take_lines()[-1], c.NOT_RUNNING)

    def test_rows_guild_counts_marker_and_notices(self):
        controller = self.controller(NOW + 300)
        controller.accounts = (2, NOW)
        controller.handle(("resultado", {"status": "ok", "events": [event("uploaded", result=accepted(), addon="0.5.1"),
                                                                     event("unchanged", account="OTRA", addon="0.6.0")]},
                           {"aceptado": NOW, "ultimo": "ok", "suben": 2, "aportan": 7, "nueva": "0.6.1"}))
        controller.handle(("aviso", "refreshed"))
        rows = dict(controller.rows())
        self.assertEqual(list(dict(controller.rows())), list(c.ROWS))
        self.assertEqual(rows["Panel"], URL)
        self.assertEqual(rows["Cuentas"], "2 con Oro de Hermandad · WoW guardó hace 5 min · JUSEP tiene el addon "
                                          "0.5.1: actualízalo para que el panel reciba las ventas")
        self.assertEqual(rows["Hermandad"], "2 personas suben y 7 aportan precios (14 días)")
        self.assertEqual(rows["Aviso addon"], "al día · el addon lo lee al entrar o con /reload")
        self.assertEqual(controller.version_notice(),
                         "Hay una versión nueva del subidor (0.6.1). Para actualizar: cierra el subidor, descarga "
                         "«Subidor para Windows» en el panel (Descargas), desbloquea el zip y extrae su carpeta encima "
                         "de la anterior (Reemplazar). Tu clave y tu configuración se conservan.")
        controller.status = {"suben": 1, "aportan": 1}
        self.assertEqual(controller.guild_text(), "1 persona sube y 1 aporta precios (14 días)")
        controller.status = {"aportan": 3}
        self.assertEqual(controller.guild_text(), "3 personas aportan precios (14 días)")
        controller.status = {}
        self.assertEqual((controller.guild_text(), controller.version_notice()), ("el panel lo dirá tras el próximo envío", ""))
        controller.accounts = (0, None)
        self.assertIn("ninguna todavía", controller.accounts_text())
        for status in ("created", "no-addon", "denied", "unsafe", "unknown", "removed", None):
            controller.marker = status
            self.assertTrue(controller.marker_text(), status)
        controller.marker = "created"
        self.assertIn("un /reload no basta", controller.marker_text())
        self.assertEqual(c.FOOTER, "Versión 0.6.0 · Basta con 1 o 2 personas de la hermandad.")

    def test_log_lines_are_short_and_never_hold_the_key(self):
        controller = self.controller()
        controller.handle(("linea", "[21:14:05] Cuenta JUSEP: envío aceptado (1 mercado, 2 objetos): 412 cambios."))
        controller.handle(("linea", f"algo raro con {KEY} dentro"))
        controller.handle(("linea", "gld_" + "x" * 43))
        self.assertEqual(controller.take_lines(), ["21:14 Cuenta JUSEP: envío aceptado (1 mercado, 2 objetos): 412 cambios.",
                                                   "algo raro con [clave] dentro", "[clave]"])
        self.assertEqual(controller.take_lines(), [])
        for _ in range(c.LOG_LINES + 10):
            controller.handle(("linea", "x"))
        self.assertEqual(len(controller.log), c.LOG_LINES)

    def test_drain_applies_the_queue_in_order(self):
        messages, controller = queue.Queue(), self.controller()
        for item in (("enviando",), ("aviso", "ok"), ("linea", "uno")):
            messages.put(item)
        self.assertEqual(c.drain(messages, controller), 3)
        self.assertEqual((controller.state, controller.marker, list(controller.log)), ("enviando", "ok", ["uno"]))
        self.assertEqual(c.drain(messages, controller), 0)

    def test_window_texts(self):
        self.assertEqual(c.TITLE, "Oro de Hermandad · Subidor")
        self.assertEqual(c.CLOSE_WARNING, "Si cierras el subidor, los precios dejarán de subirse hasta que lo vuelvas a abrir.")
        self.assertEqual(c.UPLOAD_TIP, "WoW solo escribe los precios en el archivo al usar /reload o al salir. Después "
                                       "de escanear, pulsa «Guardar y subir» en el addon o usa /reload, y el subidor los "
                                       "enviará en segundos.")
        self.assertEqual(c.AUTOSTART, "Abrir el subidor al iniciar Windows (minimizado)")
        self.assertEqual(c.SHORTCUT, "Crear acceso directo en el escritorio")
        self.assertEqual(c.MIGRATE, "He encontrado el subidor antiguo que arranca oculto con Windows. ¿Quitarlo y usar "
                                    "esta ventana?")
        self.assertEqual(c.ALREADY_OPEN, "El subidor ya está abierto (mira la barra de tareas).")
        for text in (c.WELCOME, c.READY, c.KEY_SAFE, c.NEW_VERSION, c.CLOSE_WARNING, c.UPLOAD_TIP):
            self.assertNotIn("Auctionator", text)


# -----------------------------------------------------------------------------------------------------------
# Lock held at start
# -----------------------------------------------------------------------------------------------------------
class LockTests(Quiet):
    def test_decision_by_holder_and_hidden_task(self):
        for holder, task, expected in (({"modo": "ventana"}, True, "abierto"), ({"modo": "segundo-plano"}, False, "migrar"),
                                       (None, True, "migrar"), (None, False, "bloqueado"),
                                       ({"modo": "consola"}, True, "bloqueado")):
            self.assertEqual(c.lock_decision(holder, task), expected, (holder, task))

    def hold(self, modo):
        """Another uploader holding the lock (same process: flock is per open file)."""
        stack = contextlib.ExitStack()
        self.assertTrue(stack.enter_context(h.instance_lock(self.tmp, modo)))
        return stack

    def ask(self, answer):
        asked = []

        def ask(question):
            asked.append(question)
            return answer
        return ask, asked

    def test_free_lock_and_another_window(self):
        with contextlib.ExitStack() as stack:
            self.assertEqual(c.take_lock(self.tmp, stack, None, task_installed=None), ("ok", ""))
            self.assertEqual(h.lock_holder(self.tmp)["modo"], "ventana")
            with contextlib.ExitStack() as second:
                ask, asked = self.ask(True)
                self.assertEqual(c.take_lock(self.tmp, second, ask, task_installed=lambda: True),
                                 ("abierto", "El subidor ya está abierto (mira la barra de tareas)."))
                self.assertEqual(asked, [])
        self.assertIsNone(h.lock_holder(self.tmp), "released with the window")

    def test_a_console_blocks_and_nothing_is_asked(self):
        holder = self.hold("consola")
        ask, asked = self.ask(True)
        with contextlib.ExitStack() as stack:
            self.assertEqual(c.take_lock(self.tmp, stack, ask, task_installed=lambda: True), ("bloqueado", c.BLOCKED_CONSOLE))
        self.assertEqual(asked, [])
        holder.close()

    def test_the_old_hidden_start_is_offered_and_removed(self):
        for holder_mode, task in (("segundo-plano", False), (None, True)):
            with self.subTest(holder=holder_mode):
                holder = self.hold("segundo-plano")
                if holder_mode is None:
                    (self.tmp / h.LOCK_HOLDER).unlink()        # a 0.5.0 copy writes no holder file
                removed = []
                ask, asked = self.ask(True)
                with contextlib.ExitStack() as stack:
                    outcome = c.take_lock(self.tmp, stack, ask, task_installed=lambda: task,
                                          remove_task=lambda: removed.append(1) or holder.close(), pause=lambda s: None)
                    self.assertEqual(outcome, ("ok", c.MIGRATED))
                    self.assertEqual((asked, removed), ([c.MIGRATE], [1]))
                    self.assertEqual(h.lock_holder(self.tmp)["modo"], "ventana")

    def test_declined_or_still_running_stays_blocked(self):
        holder = self.hold("segundo-plano")
        ask, _ = self.ask(False)
        with contextlib.ExitStack() as stack:
            self.assertEqual(c.take_lock(self.tmp, stack, ask, task_installed=lambda: True), ("bloqueado", c.BLOCKED_HIDDEN))
        ask, _ = self.ask(True)
        pauses = []
        with contextlib.ExitStack() as stack:
            self.assertEqual(c.take_lock(self.tmp, stack, ask, task_installed=lambda: True, remove_task=lambda: None,
                                         tries=3, pause=pauses.append), ("bloqueado", c.BLOCKED_HIDDEN))
        self.assertEqual(pauses, [0.5, 0.5, 0.5])
        holder.close()


# -----------------------------------------------------------------------------------------------------------
# The uploader in its worker thread (real threads, files and events; fake panel)
# -----------------------------------------------------------------------------------------------------------
class SessionTests(Quiet):
    def setUp(self):
        super().setUp()
        self.wow = self.tmp / "World of Warcraft"
        self.file = self.wow / "_forever_" / "WTF" / "Account" / "JUSEP" / "SavedVariables" / "OroHermandad.lua"
        self.hist = sample_hist()
        self.hist["addon"] = "0.5.1"
        write(self.file, saved_variables(self.hist))
        addons = self.wow / "_forever_" / "Interface" / "AddOns"
        (addons / "OroHermandad").mkdir(parents=True)
        (addons / "OroHermandad" / "OroHermandad.toc").write_bytes(b"## Interface: 16001\n")
        self.marker = addons / h.MARKER_FOLDER / h.MARKER_LUA
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.config = {"schema": 1, "url": URL, "wow": str(self.wow), "sources": {},
                       "key": h.seal_key(KEY, h.TestOnlyProtector())}
        self.messages = queue.Queue()
        self.posts = []
        self.answers = []

    def poster(self, url, key, payload, timeout):
        self.posts.append(payload)
        answer = self.answers.pop(0) if self.answers else accepted(**{"estado": SYNC["accepted"]["estado"]})
        if isinstance(answer, Exception):
            raise answer
        return answer

    def session(self):
        session = c.Session(URL, KEY, self.wow, self.config, self.home, self.messages, poster=self.poster,
                            fishing_poster=self.poster, clock=lambda: NOW)
        self.addCleanup(self.finish, session)
        return session

    def finish(self, session):
        session.request_stop()
        if session.thread is not None:
            session.thread.join(10)

    def wait_for(self, kind, timeout=10):
        """Every message until one of kind arrives (fails after timeout seconds)."""
        seen, deadline = [], time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=0.05)
            except queue.Empty:
                continue
            seen.append(message)
            if message[0] == kind:
                return seen
        self.fail(f"no llegó «{kind}»: {[m[0] for m in seen]}")

    def test_uploads_tells_the_window_and_writes_the_status_and_marker_v2(self):
        session = self.session()
        controller = c.Controller(clock=lambda: NOW, local=SPAIN)
        controller.started(URL, self.wow, KEY, session.snapshot())
        session.start()
        messages = self.wait_for("resultado")
        for message in messages:
            controller.handle(message)
        self.assertEqual([m[0] for m in messages if m[0] != "linea"], ["enviando", "resultado"])
        self.assertEqual(controller.state, "ok")
        self.assertEqual(controller.status["aportan"], 7)
        controller.accounts = c.scan_accounts(self.wow)               # the view does it every 5 s
        self.assertEqual(controller.accounts_text(), "1 con Oro de Hermandad · WoW guardó hace 1 min · JUSEP tiene el "
                                                     "addon 0.5.1: actualízalo para que el panel reciba las ventas")
        for message in self.wait_for("aviso"):
            controller.handle(message)
        self.assertEqual(controller.marker, "created")
        self.assertEqual(self.marker.read_bytes(), h.marker_lua(
            {"escrito": NOW, "version": "0.6.0", "envio": {"t": NOW, "estado": "ok"}, "suben": 2, "aportan": 7,
             "quedan": 21, "dia": h.day_index(NOW)}))
        saved = json.loads((self.home / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["estado"]["ultimo"], "ok")
        self.assertIn(str(self.file), saved["sources"])
        self.assertTrue(any("La cuenta JUSEP tiene el addon 0.5.1" in line for line in self.lines))
        self.assertFalse(any(KEY in line for line in self.lines))
        self.assertNotIn(KEY, (self.home / "config.json").read_text(encoding="utf-8"))
        self.assertNotIn(KEY, (self.tmp / "registro.txt").read_text(encoding="utf-8"))
        session.request_stop()
        self.assertEqual(self.wait_for("fin")[-1], ("fin", 0))
        session.thread.join(5)
        self.assertFalse(session.alive())

    def test_upload_now_wakes_the_wait(self):
        session = self.session()
        session.start()
        self.wait_for("resultado")
        self.hist["markets"]["Mirage Raceway-Alliance"]["items"][2589]["p"] += f";{NOW - 60},81,300,30"
        write(self.file, saved_variables(self.hist), age=30)
        started = time.monotonic()
        session.upload_now()
        self.wait_for("resultado", timeout=5)
        self.assertLess(time.monotonic() - started, h.POLL_SECONDS - 5, "woken, not after the 15 s poll")
        self.assertEqual(len(self.posts), 2)

    def test_a_refused_key_stops_until_a_new_key(self):
        self.answers = [h.AuthenticationError("El panel ha rechazado tu clave de la hermandad.")]
        session = self.session()
        controller = c.Controller(clock=lambda: NOW, local=SPAIN)
        controller.started(URL, self.wow, KEY)
        session.start()
        for message in self.wait_for("fin"):
            controller.handle(message)
        self.assertEqual((controller.state, controller.running, controller.action()), ("clave", False, "Cambiar clave"))
        self.assertEqual(json.loads((self.home / "config.json").read_text(encoding="utf-8"))["estado"]["ultimo"], "clave")
        self.assertIn(b'estado = "clave"', self.marker.read_bytes())
        self.assertFalse(controller.upload_now())
        session.thread.join(5)
        second = self.session()                                    # «Cambiar clave»: a new session with the new key
        controller.started(URL, self.wow, KEY, second.snapshot())
        second.start()
        for message in self.wait_for("resultado"):
            controller.handle(message)
        self.assertEqual(controller.state, "ok")

    def test_network_errors_are_retried_and_the_quota_wait_is_kept(self):
        limited = h.RetryableSyncError("El panel pide esperar antes del siguiente envío (HTTP 429).")
        limited.retry_after, limited.cuota = 900, True
        self.answers = [limited]
        session = self.session()
        controller = c.Controller(clock=lambda: NOW, local=SPAIN)
        controller.started(URL, self.wow, KEY)
        session.start()
        for message in self.wait_for("error"):
            controller.handle(message)
        self.assertEqual(controller.status_line(), ("ámbar", "El panel pide esperar: siguiente intento a las 12:15."))
        self.assertFalse(controller.upload_now())
        session.upload_now()                                          # even a wake does not cut the panel's wait
        time.sleep(0.3)
        self.assertEqual(len(self.posts), 1)

    def test_the_marker_is_not_written_again_after_the_user_removed_it(self):
        session = self.session()
        session.marker_removed.set()
        session.start()
        self.wait_for("resultado")
        self.assertFalse(self.marker.exists())
        self.assertEqual(session.marker(), "removed")

    def test_an_unexpected_error_ends_with_1(self):
        session = self.session()
        session.uploader.cycle = lambda: 1 / 0
        session.start()
        self.assertEqual(self.wait_for("fin")[-1], ("fin", 1))
        self.assertTrue(any("Error inesperado (ZeroDivisionError)" in line for line in self.lines))


# -----------------------------------------------------------------------------------------------------------
# First run
# -----------------------------------------------------------------------------------------------------------
class SetupTests(Quiet):
    def wow(self):
        root = self.tmp / "World of Warcraft"
        (root / "_forever_" / "WTF" / "Account" / "JUSEP" / "SavedVariables").mkdir(parents=True)
        (root / "_forever_" / "WTF" / "Account" / "OTRA").mkdir(parents=True)
        return root

    def test_validation_errors_and_a_complete_first_run(self):
        config = {}
        setup = c.Setup(config, h.TestOnlyProtector(), detect=lambda: [self.tmp / "nada"])
        self.assertEqual(setup.steps, ("url", "folder", "key"))
        self.assertIn("HTTPS", setup.check_url("http://panel.example.com"))
        self.assertEqual(setup.check_url(URL + "/hermandad"), "")
        self.assertEqual(setup.url, URL)
        self.assertEqual(setup.check_folder(str(self.tmp / "no-existe")), "No se encuentra esa carpeta.")
        self.assertIn("_forever_", setup.check_folder(str(self.tmp)))
        self.assertEqual(setup.check_folder("\\\\servidor\\juegos"), "Elige una carpeta de este PC, no una ubicación de red.")
        root = self.wow()
        self.assertEqual(setup.check_folder(str(root)), "")
        self.assertEqual(c.folder_summary(root), "Cuentas encontradas: 2 · Oro de Hermandad instalado: no")
        (root / "_forever_" / "Interface" / "AddOns" / "OroHermandad").mkdir(parents=True)
        (root / "_forever_" / "Interface" / "AddOns" / "OroHermandad" / "OroHermandad.toc").write_text("x")
        self.assertEqual(c.folder_summary(root), "Cuentas encontradas: 2 · Oro de Hermandad instalado: sí")
        wrong = "gld_corta-" + KEY[-6:]
        problem = setup.check_key(wrong)
        self.assertIn("gld_ y 43", problem)
        self.assertNotIn(wrong, problem)
        with self.assertRaises(h.SyncError):
            setup.finish()
        self.assertEqual(setup.check_key("  " + KEY + "\n"), "")
        self.assertEqual(setup.key_text(), c.KEY_SAFE)
        self.assertEqual(setup.finish(), (URL, root.resolve(), KEY))
        self.assertEqual((config["schema"], config["url"], config["wow"], config["sources"]), (1, URL, str(root.resolve()), {}))
        self.assertEqual(h.open_key(config["key"], h.TestOnlyProtector()), KEY)
        self.assertEqual(c.needed_steps(config, h.TestOnlyProtector()), ())
        self.assertEqual(c.needed_steps(config, None), ("key",), "without DPAPI the key is asked at every start")
        self.assertEqual(c.needed_steps({}, None), ("url", "folder", "key"))
        self.assertEqual(setup.folders(), [self.tmp / "nada"])

    def test_change_one_step_and_no_dpapi(self):
        config = {"schema": 1, "url": URL, "wow": str(self.wow()), "sources": {"x": {}}}
        setup = c.Setup(config, None, steps=("key",))
        self.assertEqual(setup.key_text(), c.KEY_MEMORY)
        self.assertEqual(setup.check_key(KEY), "")
        self.assertEqual(setup.finish()[2], KEY)
        self.assertNotIn("key", config)
        self.assertEqual(config["sources"], {"x": {}}, "the upload record is kept")
        broken = c.Setup({}, None, detect=lambda: 1 / 0)
        self.assertEqual(broken.folders(), [])

    def test_accounts_row_counts_saved_files(self):
        root = self.wow()
        self.assertEqual(c.scan_accounts(root), (0, None))
        path = root / "_forever_" / "WTF" / "Account" / "JUSEP" / "SavedVariables" / "OroHermandad.lua"
        write(path, "OroHermandadHist = {}", age=300)
        self.assertEqual(c.scan_accounts(root), (1, NOW - 300))
        self.assertEqual(c.scan_accounts(None), (0, None))


# -----------------------------------------------------------------------------------------------------------
# Start with Windows (Run key), desktop shortcut and the old hidden task, through injected fakes
# -----------------------------------------------------------------------------------------------------------
IÑAKI = "C:\\Users\\Iñaki\\Documents\\OroHermandad Subidor"


class FakeWinreg:
    """The part of winreg that RunKey uses, over a dict; records every call."""
    HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE, REG_SZ, REG_EXPAND_SZ, REG_DWORD = "HKCU", 1, 2, 1, 2, 4

    def __init__(self, values=None):
        self.values, self.calls = dict(values or {}), []

    @contextlib.contextmanager
    def OpenKey(self, root, path, reserved, access):
        self.calls.append(("OpenKey", root, path, access))
        yield path

    @contextlib.contextmanager
    def CreateKeyEx(self, root, path, reserved, access):
        self.calls.append(("CreateKeyEx", root, path, access))
        yield path

    def QueryValueEx(self, key, name):
        if name not in self.values:
            raise FileNotFoundError(name)
        return self.values[name]

    def SetValueEx(self, key, name, reserved, kind, value):
        self.calls.append(("SetValueEx", name, kind, value))
        self.values[name] = (value, kind)

    def DeleteValue(self, key, name):
        if name not in self.values:
            raise FileNotFoundError(name)
        del self.values[name]


class StartWithWindowsTests(Quiet):
    def test_command_quoting_with_spaces_and_accents(self):
        packaged = {IÑAKI + "\\runtime\\pythonw.exe"}
        self.assertEqual(h.autostart_command(IÑAKI + "\\app", exists=packaged.__contains__),
                         f'"{IÑAKI}\\runtime\\pythonw.exe" -E -s "{IÑAKI}\\app\\subidor.pyw" --minimizado')
        self.assertEqual(h.launch_parts(IÑAKI + "\\app\\", exists=packaged.__contains__),
                         (IÑAKI + "\\runtime\\pythonw.exe", IÑAKI + "\\app\\subidor.pyw", IÑAKI))
        source = "C:\\Users\\Iñaki\\el especulador\\pc_sync"
        python = "C:\\Program Files\\Python313\\python.exe"
        self.assertEqual(h.autostart_command(source, python, exists={"C:\\Program Files\\Python313\\pythonw.exe"}.__contains__),
                         f'"C:\\Program Files\\Python313\\pythonw.exe" -E -s "{source}\\subidor.pyw" --minimizado')
        self.assertEqual(h.autostart_command(source, python, exists=lambda path: False),
                         f'"{python}" -E -s "{source}\\subidor.pyw" --minimizado')
        self.assertNotIn(" -I ", h.autostart_command(source, python, exists=lambda path: False))

    def test_run_key_through_winreg(self):
        api = FakeWinreg()
        registry = h.RunKey(api)
        self.assertFalse(h.autostart_installed(registry))
        h.install_autostart(registry, command='"C:\\x\\pythonw.exe" -E -s "C:\\x\\subidor.pyw" --minimizado')
        self.assertIn(("CreateKeyEx", "HKCU", "Software\\Microsoft\\Windows\\CurrentVersion\\Run", api.KEY_SET_VALUE),
                      api.calls)
        self.assertIn(("SetValueEx", "OroHermandadSubidor", api.REG_SZ,
                       '"C:\\x\\pythonw.exe" -E -s "C:\\x\\subidor.pyw" --minimizado'), api.calls)
        self.assertTrue(h.autostart_installed(registry))
        h.uninstall_autostart(registry)
        h.uninstall_autostart(registry)                                 # already gone: fine
        self.assertFalse(h.autostart_installed(registry))
        api.values["OroHermandadSubidor"] = (5, api.REG_DWORD)
        self.assertIsNone(registry.get("OroHermandadSubidor"), "only text values count")

    def test_a_run_value_of_another_folder_is_rewritten_at_start_and_logged(self):
        wanted = f'"{IÑAKI}\\runtime\\pythonw.exe" -E -s "{IÑAKI}\\app\\subidor.pyw" --minimizado'
        api = FakeWinreg({"OroHermandadSubidor": ('"D:\\viejo\\runtime\\pythonw.exe" -E -s "D:\\viejo\\app\\subidor.pyw" '
                                                  '--minimizado', 1)})
        self.assertTrue(h.repair_autostart(h.RunKey(api), wanted))
        self.assertEqual(api.values["OroHermandadSubidor"], (wanted, 1))
        self.assertEqual(self.lines[-1][-len(h.AUTOSTART_MOVED):], "El inicio con Windows apuntaba a otra carpeta: ahora "
                                                                    "abre esta.")
        self.assertFalse(h.repair_autostart(h.RunKey(api), wanted), "already right")
        self.assertFalse(h.repair_autostart(h.RunKey(FakeWinreg()), wanted), "never turned on by itself")
        self.assertEqual(len(self.lines), 1)

    def test_registry_errors_become_spanish_messages(self):
        class Broken(FakeWinreg):
            def SetValueEx(self, *args):
                raise PermissionError("denegado")
        with self.assertRaises(h.SyncError) as raised:
            h.install_autostart(h.RunKey(Broken()), command="x")
        self.assertEqual(str(raised.exception), "Windows no ha dejado activar el inicio con Windows.")
        self.assertFalse(h.repair_autostart(h.RunKey(Broken({"OroHermandadSubidor": ("otro", 1)})), "x"))
        if os.name != "nt":
            with self.assertRaises(h.SyncError):
                h.install_autostart(command="x")
            self.assertFalse(h.autostart_installed())

    def runner(self, code=0):
        calls = []

        def run(args, **kwargs):
            calls.append((args, kwargs))
            return SimpleNamespace(returncode=code, stdout="", stderr="")
        return run, calls

    def test_the_shortcut_gets_the_paths_only_through_its_environment(self):
        run, calls = self.runner()
        packaged = {IÑAKI + "\\runtime\\pythonw.exe"}
        with patch.object(h, "_windows", return_value=True):
            self.assertTrue(h.create_shortcut(IÑAKI + "\\app", runner=run, env={"SystemRoot": "C:\\Windows", "PATH": "x"},
                                              exists=packaged.__contains__))
        args, kwargs = calls[0]
        self.assertEqual(args[:4], ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile",
                                    "-NonInteractive", "-Command"])
        self.assertEqual(kwargs["creationflags"], h.CREATE_NO_WINDOW)
        self.assertEqual(kwargs["creationflags"], 0x08000000)
        self.assertIs(kwargs["stdin"], h.subprocess.DEVNULL)
        script = args[4]
        for secret in (IÑAKI, "runtime", "pythonw", "subidor.pyw", ".lnk"):
            self.assertNotIn(secret, script, "nothing is interpolated into the command")
        environment = kwargs["env"]
        self.assertEqual(environment["OROHERMANDAD_ACCESO"], "Oro de Hermandad · Subidor.lnk")
        self.assertEqual(environment["OROHERMANDAD_PROGRAMA"], IÑAKI + "\\runtime\\pythonw.exe")
        self.assertEqual(environment["OROHERMANDAD_ARGUMENTOS"], f'-E -s "{IÑAKI}\\app\\subidor.pyw"')
        self.assertEqual(environment["OROHERMANDAD_CARPETA"], IÑAKI)
        self.assertEqual(environment["PATH"], "x")
        self.assertIn("GetFolderPath('Desktop')", script)
        failing, _ = self.runner(1)
        with patch.object(h, "_windows", return_value=True), self.assertRaises(h.SyncError) as raised:
            h.create_shortcut(IÑAKI + "\\app", runner=failing, env={}, exists=packaged.__contains__)
        self.assertEqual(str(raised.exception), "No se pudo crear el acceso directo: abre «Abrir subidor.cmd».")

        def missing(args, **kwargs):
            raise FileNotFoundError("powershell")
        with patch.object(h, "_windows", return_value=True), self.assertRaises(h.SyncError):
            h.create_shortcut(IÑAKI + "\\app", runner=missing, env={}, exists=packaged.__contains__)
        with patch.object(h, "_windows", return_value=False), self.assertRaises(h.SyncError):
            h.create_shortcut(runner=run)

    def test_the_hidden_task_is_found_and_removed_without_flashing_a_console(self):
        run, calls = self.runner()
        with patch.object(h, "_windows", return_value=True):
            self.assertTrue(h.startup_task_installed(run))
            self.assertTrue(h.uninstall_startup(run, end=True, hidden=True, quiet=True))
        self.assertEqual([args for args, _ in calls], [["schtasks", "/Query", "/TN", h.TASK_NAME],
                                                       ["schtasks", "/End", "/TN", h.TASK_NAME],
                                                       ["schtasks", "/Delete", "/TN", h.TASK_NAME, "/F"]])
        self.assertTrue(all(kwargs["creationflags"] == h.CREATE_NO_WINDOW for _, kwargs in calls))
        self.assertEqual(self.lines, [], "quiet: the window logs its own line")
        missing, _ = self.runner(1)
        with patch.object(h, "_windows", return_value=True):
            self.assertFalse(h.startup_task_installed(missing))

            def broken(args, **kwargs):
                raise OSError("sin schtasks")
            self.assertFalse(h.startup_task_installed(broken))
        cli, cli_calls = self.runner()
        with patch.object(h, "_windows", return_value=True):
            h.uninstall_startup(cli)                                   # the command line keeps its behaviour
        self.assertEqual([args for args, _ in cli_calls], [["schtasks", "/Delete", "/TN", h.TASK_NAME, "/F"]])
        self.assertNotIn("creationflags", cli_calls[0][1])
        self.assertIn("Quitado: el subidor ya no arrancará con Windows.", self.lines[-1])
        with patch.object(h, "_windows", return_value=False):
            self.assertFalse(h.startup_task_installed(run))


# -----------------------------------------------------------------------------------------------------------
# Packaging pieces that the Windows build relies on
# -----------------------------------------------------------------------------------------------------------
class PackagingTests(unittest.TestCase):
    def test_the_window_files_and_the_engine_version(self):
        source = (HERE / "subidor.pyw").read_text(encoding="utf-8")
        for needle in ("import hermandad as h", "import subidor_control as c", "root.after(c.POLL_MS, self.poll)",
                       "--minimizado", "--comprobar", "queue.Queue()"):
            self.assertIn(needle, source)
        self.assertEqual(c.POLL_MS, 200)
        control = (HERE / "subidor_control.py").read_text(encoding="utf-8")
        self.assertNotIn("tkinter", control.split('"""', 2)[2], "the controller never imports Tk")
        self.assertEqual(h.VERSION, "0.6.0")

    def test_readme_puts_the_window_first(self):
        text = (HERE / "LEEME.md").read_text(encoding="utf-8")
        guild = text.split("## Panel de la hermandad")[1]
        steps = ["1. Clic derecho en el zip → Propiedades → marca «Desbloquear» → Aceptar.",
                 "2. Extrae la carpeta donde quieras (por ejemplo en Documentos).",
                 "3. Abre «Abrir subidor.cmd»; la primera vez te ofrece un acceso directo en el escritorio."]
        self.assertLess(guild.index("Subidor para Windows"), guild.index("HERMANDAD.cmd"))
        self.assertEqual([guild.index(step) for step in steps], sorted(guild.index(step) for step in steps))
        for needle in ("Cierra el subidor, desbloquea el zip nuevo y extrae su carpeta encima de la anterior (Reemplazar). "
                       "Tu clave y tu configuración se conservan.", "solo si sabes lo que haces",
                       "WoW solo escribe el archivo al usar `/reload` o al salir", "Riesgo de baneo: **muy bajo**",
                       "nadie puede prometer «está permitido»", "**Quien tiene el subidor actualiza primero el addon y el subidor**",
                       "Oro de Hermandad · Subidor", "Guardar y subir", "`sold`"):
            self.assertIn(needle, guild)
        self.assertNotIn("Auctionator y haz un escaneo completo", text)

    def test_workflow_contract_c10(self):
        text = (HERE.parent / ".github" / "workflows" / "subidor-windows.yml").read_text(encoding="utf-8")
        for needle in ("  workflow_call:\n    outputs:\n      version:\n", "value: ${{ jobs.windows.outputs.version }}",
                       "permissions:\n  contents: read\n", "runs-on: windows-2025", "runs-on: ubuntu-24.04",
                       "persist-credentials: false", "python-version: '3.13.17'", "git config --global core.autocrlf false",
                       'python -m unittest discover -s pc_sync -p "test_*.py"',
                       'python -B pc_sync/empaquetar_windows.py --salida "$RUNNER_TEMP/Subidor_Windows.zip"',
                       "name: Subidor_Windows\n", "path: ${{ runner.temp }}/Subidor_Windows.zip", "retention-days: 30",
                       'echo "version=$version" >> "$GITHUB_OUTPUT"'):
            self.assertIn(needle, text)
        for forbidden in ("contents: write", "gh release", "inputs:", "secrets.", "archive: false"):
            self.assertNotIn(forbidden, text)
        self.assertEqual(text.count("workflow_call:"), 1)

    def test_the_console_download_is_unchanged(self):
        script = (HERE.parent / "scripts" / "prepare-downloads.mjs").read_text(encoding="utf-8")
        line = next(line for line in script.splitlines() if "Sincronizador_PC.zip" in line)
        self.assertIn('["sincronizar.py","SINCRONIZAR.cmd","LEEME.md","hermandad.py","HERMANDAD.cmd"]', line)

    def test_the_tk_skip_rule(self):
        import builtins
        real_import = builtins.__import__

        def no_tk(name, *args, **kwargs):
            if name == "tkinter":
                raise ImportError("no tkinter")
            return real_import(name, *args, **kwargs)
        with patch.object(builtins, "__import__", no_tk):
            self.assertFalse(tk_available())
        fake = SimpleNamespace(TclError=RuntimeError, Tk=lambda: (_ for _ in ()).throw(RuntimeError("no display")))
        with patch.dict("sys.modules", {"tkinter": fake}), patch.object(os, "name", "posix"):
            self.assertFalse(tk_available())


# -----------------------------------------------------------------------------------------------------------
# empaquetar_windows.py: the portable folder and its reproducible zip (a fake runtime here; the real one in CI)
# -----------------------------------------------------------------------------------------------------------
import empaquetar_windows as e  # noqa: E402

RUNTIME_FILES = {
    "python.exe": "exe", "pythonw.exe": "exe", "python313.dll": "dll", "LICENSE.txt": "licencia",
    "DLLs/_tkinter.pyd": "pyd", "DLLs/tcl86t.dll": "dll", "Lib/os.py": "os", "Lib/tkinter/__init__.py": "tk",
    "Lib/__pycache__/os.cpython-313.pyc": "pyc", "Lib/tkinter/__pycache__/x.pyc": "pyc", "Lib/stray.pyc": "pyc",
    "Lib/test/test_os.py": "x", "Lib/idlelib/idle.py": "x", "Lib/turtledemo/demo.py": "x",
    "Lib/ensurepip/_bundled/pip.whl": "x", "Lib/site-packages/pip/__init__.py": "x", "Lib/site-packages/README.txt": "x",
    "Scripts/pip.exe": "x", "include/Python.h": "x", "libs/python313.lib": "x", "Doc/python.chm": "x",
    "Tools/scripts/x.py": "x", "tcl/tcl8.6/license.terms": "tcl", "tcl/tk8.6/license.terms": "tk",
    "Lib/testing_helpers.py": "kept: only the Lib/test folder goes",
}


class PackagerTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.tmp = Path(folder.name)
        self.runtime = self.tmp / "Python313"
        for name, text in RUNTIME_FILES.items():
            (self.runtime / name).parent.mkdir(parents=True, exist_ok=True)
            (self.runtime / name).write_text(text, encoding="utf-8")

    def test_the_folder_layout_trimmed_runtime_and_app_files(self):
        files = e.entries(self.runtime)
        root = "OroHermandad Subidor/"
        self.assertEqual(sorted(n for n in files if not n.startswith(root + "runtime/")),
                         [root + "Abrir subidor.cmd", root + "LEEME.txt", root + "app/hermandad.py",
                          root + "app/sincronizar.py", root + "app/subidor.pyw", root + "app/subidor_control.py"])
        runtime = sorted(n[len(root + "runtime/"):] for n in files if n.startswith(root + "runtime/"))
        self.assertEqual(runtime, ["DLLs/_tkinter.pyd", "DLLs/tcl86t.dll", "LICENSE.txt", "Lib/os.py",
                                   "Lib/testing_helpers.py", "Lib/tkinter/__init__.py", "python.exe", "python313.dll",
                                   "pythonw.exe", "tcl/tcl8.6/license.terms", "tcl/tk8.6/license.terms"])
        self.assertEqual(files[root + "app/hermandad.py"], (HERE / "hermandad.py").read_bytes())
        self.assertNotIn(root + "app/empaquetar_windows.py", files)
        with self.assertRaises(e.BuildError):
            e.entries(self.tmp)

    def test_launcher_and_readme(self):
        files = e.entries(self.runtime)
        launcher = files["OroHermandad Subidor/Abrir subidor.cmd"]
        text = launcher.decode("ascii")
        self.assertEqual(text.count("\r\n"), text.count("\n"), "CRLF only")
        self.assertTrue(text.startswith("@echo off\r\n"))
        self.assertIn('if exist "%~dp0runtime\\pythonw.exe" goto abrir', text)
        self.assertIn("echo Extrae primero la carpeta del zip", text)
        self.assertIn('start "" "%~dp0runtime\\pythonw.exe" -E -s "%~dp0app\\subidor.pyw" %*\r\n', text)
        self.assertNotIn(" -I ", text)
        for line in text.split("\r\n"):
            if line.startswith("echo "):
                self.assertNotRegex(line, r"[()]", "a parenthesis in an echo would break the batch file")
        readme = files["OroHermandad Subidor/LEEME.txt"]
        self.assertTrue(readme.startswith(b"\xef\xbb\xbf"))
        body = readme.decode("utf-8-sig")
        self.assertEqual(body.count("\r\n"), body.count("\n"), "CRLF only")
        for needle in ("1. Clic derecho en el zip → Propiedades → marca «Desbloquear» → Aceptar.",
                       "2. Extrae la carpeta donde quieras (por ejemplo en Documentos).",
                       "3. Abre «Abrir subidor.cmd»; la primera vez te ofrece un acceso directo en el escritorio.",
                       "Cierra el subidor, desbloquea el zip nuevo y extrae su carpeta encima de la anterior (Reemplazar).",
                       "Tu clave y tu configuración se conservan.", "WoW solo escribe el archivo al usar /reload o al salir",
                       "Riesgo de baneo: muy bajo.", "nadie puede prometer «está permitido»",
                       "Quien tiene el subidor actualiza primero el addon y el subidor"):
            self.assertIn(needle, body.replace("\r\n  ", " ").replace("\r\n", " "))

    def test_the_zip_is_reproducible_sorted_and_stamped(self):
        files = e.entries(self.runtime)
        first, second = e.write_zip(files, self.tmp / "a.zip"), e.write_zip(dict(reversed(files.items())), self.tmp / "b.zip")
        self.assertEqual(e.sha256(first), e.sha256(second))
        with zipfile_open(first) as archive:
            infos = archive.infolist()
            self.assertEqual([i.filename for i in infos], sorted(files))
            self.assertTrue(all(i.date_time == (2026, 11, 4, 0, 0, 0) and i.compress_type == 8 for i in infos))
            self.assertEqual(archive.read("OroHermandad Subidor/app/subidor.pyw"), (HERE / "subidor.pyw").read_bytes())
        (self.runtime / "Lib" / "os.py").write_text("otro", encoding="utf-8")
        self.assertNotEqual(e.sha256(e.write_zip(e.entries(self.runtime), self.tmp / "c.zip")), e.sha256(first))

    def test_only_zip_build_and_the_repository_rule(self):
        digest = e.build(self.tmp / "salida" / "Subidor_Windows.zip", self.runtime, only_zip=True, scratch=self.tmp)
        self.assertEqual(digest, e.sha256(self.tmp / "salida" / "Subidor_Windows.zip"))
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ["Python313", "salida"], "the second build is removed")
        with self.assertRaises(e.BuildError):
            e.build(HERE / "Subidor_Windows.zip", self.runtime, only_zip=True, scratch=self.tmp)
        self.assertFalse((HERE / "Subidor_Windows.zip").exists())

    def test_full_build_runs_the_smoke_tests_and_checks_signatures(self):
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if "powershell.exe" in command[0]:
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=0)
        summary = self.tmp / "resumen.md"
        with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
            digest = e.build(self.tmp / "Subidor_Windows.zip", self.runtime, scratch=self.tmp, run=run)
        smoke = [command for command, _ in calls if "powershell.exe" not in command[0]]
        tested = self.tmp / "prueba" / "OroHermandad Subidor"
        self.assertEqual([command[1:] for command in smoke],
                         [["-B", "-E", "-s", "-c", "import ssl, ctypes, tkinter, json"],
                          ["-B", "-m", "unittest", "discover", "-s", "pc_sync", "-p", "test_*.py"],
                          ["-B", str(tested / "app" / "subidor.pyw"), "--comprobar"]])
        self.assertTrue(all(command[0] == str(tested / "runtime" / "python.exe") for command in smoke))
        self.assertTrue(all(kwargs["env"]["PYTHONDONTWRITEBYTECODE"] == "1" for _, kwargs in calls[:3]))
        self.assertEqual(calls[1][1]["cwd"], str(HERE.parent), "the suite runs from the checkout")
        powershell = [(command, kwargs) for command, kwargs in calls if "powershell.exe" in command[0]]
        self.assertEqual(len(powershell), 1)
        self.assertEqual(powershell[0][1]["env"]["OROHERMANDAD_RUNTIME"], str(tested / "runtime"))
        self.assertIn("Get-AuthenticodeSignature", powershell[0][0][-1])
        self.assertIn("$_.Status -ne 'Valid'", powershell[0][0][-1])
        self.assertNotIn(str(tested), powershell[0][0][-1])
        self.assertIn(f"SHA-256: {digest}", summary.read_text(encoding="utf-8"))

    def test_failures_stop_the_build(self):
        def unsigned(command, **kwargs):
            if "powershell.exe" in command[0]:
                return SimpleNamespace(returncode=0, stdout="NotSigned|C:\\x\\runtime\\DLLs\\tcl86t.dll\n", stderr="")
            return SimpleNamespace(returncode=0)
        with self.assertRaises(e.BuildError) as raised:
            e.build(self.tmp / "z.zip", self.runtime, scratch=self.tmp, run=unsigned)
        self.assertIn("NotSigned  C:\\x\\runtime\\DLLs\\tcl86t.dll", str(raised.exception))

        def writes_bytecode(command, **kwargs):
            if "--comprobar" in command:
                cache = Path(command[2]).parent / "__pycache__"
                cache.mkdir()
                (cache / "hermandad.cpython-313.pyc").write_bytes(b"x")
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        with self.assertRaises(e.BuildError) as raised:
            e.build(self.tmp / "z.zip", self.runtime, scratch=self.tmp, run=writes_bytecode)
        self.assertIn("__pycache__", str(raised.exception))

        def failing(command, **kwargs):
            return SimpleNamespace(returncode=3, stdout="", stderr="")
        with self.assertRaises(e.BuildError) as raised:
            e.build(self.tmp / "z.zip", self.runtime, scratch=self.tmp, run=failing)
        self.assertIn("código 3", str(raised.exception))
        with patch.object(e, "MAX_BYTES", 10), self.assertRaises(e.BuildError) as raised:
            e.report(self.tmp / "z.zip", "0" * 64, summary="")
        self.assertIn("más de 30 MB", str(raised.exception))

    def test_main_off_windows_needs_solo_zip(self):
        if os.name == "nt":
            self.skipTest("en Windows construye de verdad")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(e.main(["--salida", str(self.tmp / "x.zip")]), 2)
        self.assertIn("--solo-zip", err.getvalue())
        out = io.StringIO()
        with contextlib.redirect_stdout(out), patch.object(tempfile, "tempdir", str(self.tmp)):
            self.assertEqual(e.main(["--solo-zip", "--runtime", str(self.runtime), "--salida", str(self.tmp / "x.zip")]), 0)
        self.assertIn("Listo:", out.getvalue())


def zipfile_open(path):
    import zipfile
    return zipfile.ZipFile(path)


# -----------------------------------------------------------------------------------------------------------
# Real Windows (the Windows runner of subidor-windows.yml): DPAPI, the registry, schtasks and a real shortcut
# -----------------------------------------------------------------------------------------------------------
@unittest.skipUnless(os.name == "nt", "solo en Windows")
class RealWindowsTests(Quiet):
    def test_dpapi_round_trip(self):
        protector = h.DpapiProtector()
        sealed = h.seal_key(KEY, protector)
        self.assertEqual(sealed["protection"], "dpapi")
        self.assertNotIn(KEY, json.dumps(sealed))
        self.assertEqual(h.open_key(sealed, protector), KEY)
        self.assertIsInstance(h.default_protector(), h.DpapiProtector)

    def test_registry_and_task_scheduler_are_read(self):
        self.assertIsNone(h.RunKey().get("OroHermandadSubidor-prueba-que-no-existe"))
        self.assertIsInstance(h.autostart_installed(), bool)
        self.assertIsInstance(h.startup_task_installed(), bool)
        command = h.autostart_command()
        self.assertTrue(command.endswith(" --minimizado"))
        self.assertIn(' -E -s "', command)
        program = command.split('"')[1]
        self.assertTrue(Path(program).is_file(), program)

    @unittest.skipUnless(os.environ.get("GITHUB_ACTIONS") == "true", "solo en el runner de GitHub (escribe en el escritorio)")
    def test_a_real_shortcut_on_the_runner_desktop(self):
        desktop = Path(os.environ["USERPROFILE"]) / "Desktop"
        link = desktop / h.SHORTCUT_NAME
        self.addCleanup(lambda: link.exists() and link.unlink())
        self.assertTrue(h.create_shortcut())
        self.assertTrue(link.is_file())
        self.assertGreater(link.stat().st_size, 100)


# -----------------------------------------------------------------------------------------------------------
# The Tk view (skipped without Tk or a display, as in deploy-cloudflare.yml on Linux)
# -----------------------------------------------------------------------------------------------------------
def load_window_module():
    loader = importlib.machinery.SourceFileLoader("subidor_ventana", str(HERE / "subidor.pyw"))
    spec = importlib.util.spec_from_loader("subidor_ventana", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


@unittest.skipUnless(TK, "sin Tk o sin pantalla: las pruebas de la ventana solo corren en Windows o con pantalla")
class WindowTests(Quiet):
    def setUp(self):
        super().setUp()
        import tkinter
        from tkinter import ttk
        self.tk, self.ttk = tkinter, ttk
        self.module = load_window_module()
        self.root = tkinter.Tk()
        self.root.withdraw()
        self.addCleanup(self.destroy)

    def destroy(self):
        with contextlib.suppress(Exception):
            self.root.destroy()

    def app(self):
        return self.module.App(self.tk, self.ttk, self.root, self.tmp / "home", protector=h.TestOnlyProtector())

    def test_comprobar_builds_and_destroys_a_withdrawn_window(self):
        self.assertEqual(self.module.main(["--comprobar"]), 0)

    def test_the_main_view_shows_the_controller(self):
        app = self.app()
        controller = c.Controller(clock=lambda: NOW + 180, local=SPAIN)
        controller.started(URL, Path("C:/World of Warcraft"), KEY)
        controller.accounts = (2, NOW - 300)
        controller.handle(("resultado", {"status": "ok", "events": [event("uploaded", result=accepted())]},
                           {"aceptado": NOW, "ultimo": "ok", "suben": 2, "aportan": 7, "nueva": "0.6.1",
                            "quedan": 21, "dia": h.day_index(NOW)}))
        controller.handle(("linea", "[12:00:01] Cuenta JUSEP: envío aceptado (1 mercado, 2 objetos): 412 cambios."))
        app.window.show_main()
        app.window.refresh(controller)
        self.root.update_idletasks()
        window = app.window
        self.assertEqual(window.status["text"], "Todo enviado")
        self.assertEqual(window.detail["text"], "Último envío aceptado: hoy a las 12:00 (hace 3 min) · 412 cambios. "
                                                "Te quedan 21 envíos hoy.")
        self.assertEqual(window.rows["Hermandad"]["text"], "2 personas suben y 7 aportan precios (14 días)")
        self.assertIn("0.6.1", window.notice["text"])
        self.assertEqual(window.log.get("1.0", "end-1c"), "12:00 Cuenta JUSEP: envío aceptado (1 mercado, 2 objetos): "
                                                          "412 cambios.")
        self.assertEqual(window.light.itemcget(window.dot, "fill"), c.LIGHTS["verde"])
        controller.handle(("error", h.AuthenticationError("clave"), None, {}))
        window.refresh(controller)
        self.assertEqual(window.action["text"], "Cambiar clave")
        self.assertEqual(window.light.itemcget(window.dot, "fill"), c.LIGHTS["rojo"])

    def test_the_first_run_wizard_walks_its_steps(self):
        app = self.app()
        setup = c.Setup({}, h.TestOnlyProtector(), detect=lambda: [])
        done = []
        app.window.show_wizard(setup, lambda s, shortcut: done.append((s.url, shortcut)))
        self.root.update_idletasks()

        def texts():
            return [w.cget("text") for w in self.descendants(app.window.wizard) if "text" in w.keys()]
        self.assertIn(c.WELCOME, texts())
        self.assertIn(c.ASK_URL, texts())
        self.press(app.window.wizard, c.NEXT)                       # empty address: an error, still step 1
        self.assertIn(c.ASK_URL, texts())
        entry = next(w for w in self.descendants(app.window.wizard) if isinstance(w, self.ttk.Entry))
        entry.insert(0, URL)
        self.press(app.window.wizard, c.NEXT)
        self.assertIn(c.ASK_FOLDER, texts())
        self.assertIn(c.ASK_FOLDER_NONE, texts())
        setup.folder = self.tmp                                     # what «Elegir otra carpeta…» would set
        (self.tmp / "_forever_" / "WTF").mkdir(parents=True)
        app.window.show_wizard(setup, lambda s, shortcut: done.append((s.url, shortcut)))
        app.window._step(setup, ["folder", "key", "ready"], 0, lambda s, shortcut: done.append((s.url, shortcut)), None)
        self.press(app.window.wizard, c.NEXT)
        self.assertIn(c.ASK_KEY, texts())
        entry = next(w for w in self.descendants(app.window.wizard) if isinstance(w, self.ttk.Entry))
        self.assertEqual(str(entry.cget("show")), "•")
        entry.insert(0, KEY)
        self.press(app.window.wizard, c.NEXT)
        self.assertIn(c.READY, texts())
        self.press(app.window.wizard, c.START)
        self.assertEqual(done, [(URL, False)])
        self.assertEqual(setup.key, KEY)

    def descendants(self, widget):
        for child in widget.winfo_children():
            yield child
            yield from self.descendants(child)

    def press(self, frame, text):
        button = next(w for w in self.descendants(frame) if isinstance(w, self.ttk.Button) and w.cget("text") == text)
        button.invoke()
        self.root.update_idletasks()


if __name__ == "__main__":
    unittest.main()
