"""Oro de Hermandad · Subidor: the window that uploads the guild's prices while it is open.

A thin Tk view over subidor_control.py (states and texts) and hermandad.py (the engine, unchanged for the command
line). The uploader runs in a worker thread (subidor_control.Session) and talks to this window only through a
queue.Queue polled with root.after(200, ...): Tk is single-threaded. Nothing here runs hidden, touches the game or
reloads it: the window only reads the files WoW saved and writes the marker addon, and, when asked, a desktop
shortcut and the Run value of the start with Windows.

    pythonw subidor.pyw              opens the window (first run: three steps)
    pythonw subidor.pyw --minimizado starts minimized on the taskbar (the start with Windows uses it)
    python subidor.pyw --comprobar   builds the controller and a withdrawn window, then exits 0 (CI smoke test)
"""
from __future__ import annotations

import sys

if sys.version_info < (3, 10):
    sys.exit("Necesitas Python 3.10 o superior.")

# Sin .pyc junto al programa (app\__pycache__): al actualizar extrayendo el zip encima de la carpeta (Reemplazar), un
# .pyc de la versión anterior cuyo .py nuevo tuviera la misma hora y el mismo tamaño seguiría ejecutando el código viejo.
# Vale para «Abrir subidor.cmd», el acceso directo, el inicio con Windows y pyw -3 subidor.pyw (-E no deja usar
# PYTHONDONTWRITEBYTECODE). Antes de importar hermandad y subidor_control.
sys.dont_write_bytecode = True

import argparse
import contextlib
import os
import queue
import tempfile
import time
import webbrowser
from pathlib import Path

import hermandad as h
import subidor_control as c

FONT = ("Segoe UI", 10) if os.name == "nt" else ("TkDefaultFont", 10)
BOLD = (FONT[0], 11, "bold")
SMALL = (FONT[0], 9)


class Tooltip:
    """A plain tooltip: a borderless Toplevel shown while the pointer is over the widget."""

    def __init__(self, tk, widget, text):
        self.tk, self.widget, self.text, self.window = tk, widget, text, None
        widget.bind("<Enter>", self.show, add="+")
        widget.bind("<Leave>", self.hide, add="+")

    def show(self, _event=None):
        if self.window is not None:
            return
        x, y = self.widget.winfo_rootx() + 12, self.widget.winfo_rooty() + self.widget.winfo_height() + 4
        self.window = self.tk.Toplevel(self.widget)
        self.window.wm_overrideredirect(True)
        self.window.wm_geometry(f"+{x}+{y}")
        self.tk.Label(self.window, text=self.text, justify="left", wraplength=360, background="#ffffe0",
                      relief="solid", borderwidth=1, font=SMALL, padx=6, pady=4).pack()

    def hide(self, _event=None):
        if self.window is not None:
            self.window.destroy()
            self.window = None


class Window:
    """The widgets. Every text comes from the controller; every action goes to the App."""

    def __init__(self, tk, ttk, root, app):
        self.tk, self.ttk, self.root, self.app = tk, ttk, root, app
        root.title(c.TITLE)
        root.geometry("560x480")
        root.minsize(480, 400)
        ttk.Style(root).configure("Fila.TButton", padding=(4, 0))
        self.main = ttk.Frame(root, padding=10)
        self.wizard = ttk.Frame(root, padding=14)
        self.build_main()

    # -- main view ----------------------------------------------------------------------------------------------
    def build_main(self):
        tk, ttk, frame = self.tk, self.ttk, self.main
        top = ttk.Frame(frame)
        top.pack(fill="x")
        self.light = tk.Canvas(top, width=16, height=16, highlightthickness=0)
        self.dot = self.light.create_oval(2, 2, 14, 14, fill=c.LIGHTS["gris"], outline="")
        self.light.pack(side="left", padx=(0, 6))
        self.status = ttk.Label(top, font=BOLD, wraplength=440, justify="left")
        self.status.pack(side="left", fill="x", expand=True)
        self.action = ttk.Button(top, command=self.app.status_action)
        self.detail = ttk.Label(frame, wraplength=520, justify="left")
        self.detail.pack(fill="x", padx=(22, 0))
        self.notice = ttk.Label(frame, wraplength=520, justify="left", foreground="#8a5a00")
        grid = ttk.Frame(frame)
        grid.pack(fill="x", pady=(8, 4))
        grid.columnconfigure(1, weight=1)
        self.rows, self.wide, self.change_buttons = {}, [], []
        for row, label in enumerate(c.ROWS):
            ttk.Label(grid, text=label, width=12).grid(row=row, column=0, sticky="nw")
            value = ttk.Label(grid, wraplength=360, justify="left")
            self.rows[label] = value
            if label in ("Panel", "Carpeta WoW"):
                step = "url" if label == "Panel" else "folder"
                value.grid(row=row, column=1, sticky="we")
                button = ttk.Button(grid, text=c.CHANGE, style="Fila.TButton",
                                    command=lambda s=step: self.app.change((s,)))
                button.grid(row=row, column=2, sticky="ne")
                self.change_buttons.append(button)
            else:
                value.grid(row=row, column=1, columnspan=2, sticky="we")
                self.wide.append(value)
        grid.bind("<Configure>", self.wrap)
        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(6, 2))
        upload = ttk.Button(buttons, text=c.UPLOAD_NOW, command=self.app.upload_now)
        upload.pack(side="left")
        Tooltip(self.tk, upload, c.UPLOAD_TIP)
        ttk.Button(buttons, text=c.OPEN_PANEL, command=self.app.open_panel).pack(side="left", padx=4)
        ttk.Button(buttons, text=c.SHOW_LOG, command=self.app.open_log).pack(side="left")
        self.more = ttk.Menubutton(buttons, text=c.MORE)
        menu = tk.Menu(self.more, tearoff=False)
        menu.add_command(label=c.CHANGE_KEY, command=lambda: self.app.change(("key",)))
        self.config_entries = [menu.index("end")]
        if self.app.windows:
            menu.add_command(label=c.SHORTCUT, command=self.app.create_shortcut)
        menu.add_command(label=c.REMOVE_MARKER, command=self.app.remove_marker)
        menu.add_command(label=c.RESET, command=self.app.reset)
        self.config_entries.append(menu.index("end"))
        self.menu, self.more["menu"] = menu, menu
        self.blocked = False
        self.more.pack(side="left", padx=4)
        self.autostart = tk.BooleanVar(value=False)
        if self.app.windows:
            ttk.Checkbutton(frame, text=c.AUTOSTART, variable=self.autostart,
                            command=lambda: self.app.set_autostart(self.autostart.get())).pack(anchor="w")
        ttk.Label(frame, text=c.FOOTER, font=SMALL, foreground="#555").pack(side="bottom", anchor="w")
        box = ttk.LabelFrame(frame, text=c.LOG_TITLE, padding=4)
        box.pack(fill="both", expand=True, pady=(6, 4))
        self.log = tk.Text(box, height=6, wrap="word", font=SMALL, state="disabled", relief="flat")
        scroll = ttk.Scrollbar(box, orient="vertical", command=self.log.yview)
        self.log["yscrollcommand"] = scroll.set
        scroll.pack(side="right", fill="y")
        self.log.pack(side="left", fill="both", expand=True)

    def wrap(self, event):
        """The texts follow the window's width (they would be cut on the right otherwise)."""
        width = max(200, event.width - 110)
        for label, value in self.rows.items():
            value["wraplength"] = width if value in self.wide else max(160, width - 90)
        for value in (self.status, self.detail, self.notice):
            value["wraplength"] = max(200, event.width - 30)

    def show_main(self):
        self.wizard.pack_forget()
        self.main.pack(fill="both", expand=True)

    def refresh(self, controller):
        blocked = controller.state == "bloqueado"
        if blocked != self.blocked:              # another uploader owns config.json: nothing here may change it
            self.blocked = blocked
            for button in self.change_buttons:
                button.state(["disabled"] if blocked else ["!disabled"])
            for index in self.config_entries:
                self.menu.entryconfigure(index, state="disabled" if blocked else "normal")
        light, text = controller.status_line()
        self.light.itemconfigure(self.dot, fill=c.LIGHTS[light])
        self.status["text"] = text
        action = controller.action()
        if action:
            self.action["text"] = action
            self.action.pack(side="right")
        else:
            self.action.pack_forget()
        self.detail["text"] = controller.detail_line()
        notice = controller.version_notice()
        self.notice["text"] = notice
        if notice and not self.notice.winfo_ismapped():
            self.notice.pack(fill="x", padx=(22, 0), after=self.detail)
        elif not notice:
            self.notice.pack_forget()
        for label, value in controller.rows():
            self.rows[label]["text"] = value
        lines = controller.take_lines()
        if lines:
            self.log["state"] = "normal"
            empty = self.log.index("end-1c") == "1.0"
            self.log.insert("end", ("" if empty else "\n") + "\n".join(lines))
            excess = int(self.log.index("end-1c").split(".")[0]) - c.LOG_LINES
            if excess > 0:
                self.log.delete("1.0", f"{excess + 1}.0")
            self.log["state"] = "disabled"
            self.log.see("end")

    # -- first run and «Cambiar» --------------------------------------------------------------------------------
    def show_wizard(self, setup, on_done, on_cancel=None):
        self.main.pack_forget()
        for child in self.wizard.winfo_children():
            child.destroy()
        self.wizard.pack(fill="both", expand=True)
        steps = list(setup.steps) + ["ready"]
        self._step(setup, steps, 0, on_done, on_cancel)

    def _clear(self):
        for child in self.wizard.winfo_children():
            child.destroy()

    def _step(self, setup, steps, index, on_done, on_cancel):
        tk, ttk, frame = self.tk, self.ttk, self.wizard
        self._clear()
        step = steps[index]
        error = ttk.Label(frame, foreground="#c62828", wraplength=500, justify="left")
        buttons = ttk.Frame(frame)

        def go_on():
            self._step(setup, steps, index + 1, on_done, on_cancel)

        first_run = len(steps) == 4                 # url, folder, key and ready: the first run
        if step == "url":
            if index == 0 and first_run:
                ttk.Label(frame, text=c.WELCOME, wraplength=500, justify="left").pack(anchor="w", pady=(0, 10))
            ttk.Label(frame, text=c.ASK_URL, font=BOLD).pack(anchor="w")
            ttk.Label(frame, text=c.ASK_URL_HELP, wraplength=500, justify="left").pack(anchor="w")
            value = tk.StringVar(value=setup.url or "")
            entry = ttk.Entry(frame, textvariable=value, width=60)
            entry.pack(anchor="w", fill="x", pady=4)
            entry.focus_set()

            def check():
                problem = setup.check_url(value.get())
                error["text"] = problem
                if not problem:
                    go_on()
            ttk.Button(buttons, text=c.NEXT, command=check).pack(side="right")
        elif step == "folder":
            ttk.Label(frame, text=c.ASK_FOLDER, font=BOLD).pack(anchor="w")
            found = setup.folders()
            choice = tk.StringVar(value=str(setup.folder or (found[0] if found else "")))
            summary = ttk.Label(frame, wraplength=500, justify="left")
            if not found:
                ttk.Label(frame, text=c.ASK_FOLDER_NONE, wraplength=500, justify="left").pack(anchor="w")
            options = ttk.Frame(frame)
            options.pack(anchor="w", fill="x", pady=4)

            def show_summary(*_):
                problem = setup.check_folder(choice.get()) if choice.get() else ""
                error["text"] = problem
                summary["text"] = "" if problem or not choice.get() else c.folder_summary(setup.folder)
            for folder in found:
                ttk.Radiobutton(options, text=str(folder), value=str(folder), variable=choice,
                                command=show_summary).pack(anchor="w")
            if setup.folder and str(setup.folder) not in [str(f) for f in found]:
                ttk.Radiobutton(options, text=str(setup.folder), value=str(setup.folder), variable=choice,
                                command=show_summary).pack(anchor="w")

            def pick():
                from tkinter import filedialog
                chosen = filedialog.askdirectory(parent=self.root, title=c.ASK_FOLDER, mustexist=True)
                if chosen:
                    choice.set(os.path.normpath(chosen))
                    ttk.Radiobutton(options, text=choice.get(), value=choice.get(), variable=choice,
                                    command=show_summary).pack(anchor="w")
                    show_summary()
            ttk.Button(frame, text=c.CHOOSE_FOLDER, command=pick).pack(anchor="w")
            summary.pack(anchor="w", pady=4)
            if choice.get():
                show_summary()

            def check():
                problem = setup.check_folder(choice.get())
                error["text"] = problem
                if not problem:
                    go_on()
            ttk.Button(buttons, text=c.NEXT, command=check).pack(side="right")
        elif step == "key":
            ttk.Label(frame, text=c.ASK_KEY, font=BOLD).pack(anchor="w")
            value = tk.StringVar()
            row = ttk.Frame(frame)
            row.pack(anchor="w", fill="x", pady=4)
            entry = ttk.Entry(row, textvariable=value, show="•", width=52)
            entry.pack(side="left", fill="x", expand=True)
            entry.focus_set()

            def paste():                       # the clipboard is read only on this click
                with contextlib.suppress(Exception):
                    value.set(self.root.clipboard_get().strip())
            ttk.Button(row, text=c.PASTE, command=paste).pack(side="left", padx=4)
            ttk.Label(frame, text=setup.key_text(), wraplength=500, justify="left").pack(anchor="w")

            def check():
                problem = setup.check_key(value.get())
                error["text"] = problem
                if not problem:
                    value.set("")
                    go_on()
            ttk.Button(buttons, text=c.NEXT, command=check).pack(side="right")
        else:
            ttk.Label(frame, text=c.READY, wraplength=500, justify="left").pack(anchor="w", pady=(0, 8))
            shortcut = tk.BooleanVar(value=self.app.windows and first_run)
            if self.app.windows and first_run:
                ttk.Checkbutton(frame, text=c.SHORTCUT, variable=shortcut).pack(anchor="w")
            ttk.Button(buttons, text=c.START, command=lambda: on_done(setup, shortcut.get())).pack(side="right")
        if on_cancel is not None:
            ttk.Button(buttons, text=c.CANCEL, command=on_cancel).pack(side="right", padx=4)
        error.pack(anchor="w", pady=4)
        buttons.pack(fill="x", side="bottom")

    # -- dialogs ------------------------------------------------------------------------------------------------
    def ask(self, question):
        from tkinter import messagebox
        return messagebox.askyesno(c.TITLE, question, parent=self.root)

    def tell(self, text):
        from tkinter import messagebox
        messagebox.showinfo(c.TITLE, text, parent=self.root)

    def ask_close(self):
        """[Cerrar] [Minimizar] (or the window's own close: nothing)."""
        tk, ttk = self.tk, self.ttk
        dialog = tk.Toplevel(self.root)
        dialog.title(c.TITLE)
        dialog.transient(self.root)
        dialog.resizable(False, False)
        answer = {"value": None}
        ttk.Label(dialog, text=c.CLOSE_WARNING, wraplength=360, justify="left", padding=12).pack()
        row = ttk.Frame(dialog, padding=(12, 0, 12, 12))
        row.pack(fill="x")

        def choose(value):
            answer["value"] = value
            dialog.destroy()
        ttk.Button(row, text=c.MINIMIZE, command=lambda: choose("minimizar")).pack(side="right")
        ttk.Button(row, text=c.CLOSE, command=lambda: choose("cerrar")).pack(side="right", padx=4)
        dialog.grab_set()
        self.root.wait_window(dialog)
        return answer["value"]


class App:
    """Glue between the window, the controller, the Session in its thread and the engine. view: the class of the
    widgets (Window; the tests give one without Tk)."""
    view = Window

    def __init__(self, tk, ttk, root, home, *, protector, minimized=False):
        self.tk, self.root, self.home, self.protector = tk, root, Path(home), protector
        self.windows = h._windows()
        self.messages = queue.Queue()
        self.controller = c.Controller()
        self.session = None
        self.key = None
        self.locked = False                    # True once this window holds subidor.lock (take_lock «ok»)
        self.polls = 0
        self.config = {}
        self.stack = contextlib.ExitStack()
        self.window = self.view(tk, ttk, root, self)
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.report_callback_exception = self.callback_error
        if minimized:
            root.iconify()

    def callback_error(self, kind, value, trace):
        """pythonw has no console: an error in a button goes to the log (type and place, never values)."""
        import traceback
        place = traceback.extract_tb(trace)[-1] if trace else None
        where = f" en {Path(place.filename).name}:{place.lineno}" if place else ""
        h.say(f"Error inesperado en la ventana ({kind.__name__}{where}).")

    # -- start --------------------------------------------------------------------------------------------------
    def start(self):
        h.set_log_file(self.home / "registro.txt")
        h.set_output_sink(lambda line: self.messages.put(("linea", line)))
        outcome, text = c.take_lock(self.home, self.stack, self.window.ask,
                                    task_installed=lambda: h.startup_task_installed(hidden=True))
        if outcome == "abierto":
            self.window.tell(text)
            self.root.destroy()
            return False
        self.window.show_main()
        if outcome == "bloqueado":
            if self.windows:
                self.window.autostart.set(h.autostart_installed())
            self.controller.blocked(text)
        else:
            self.took_lock(text)
        self.root.after(c.POLL_MS, self.poll)
        return True

    def took_lock(self, text):
        """This window holds subidor.lock from now on: config.json is loaded and the upload starts. After removing the
        old hidden start with Windows (MIGRATED), which started an uploader at every logon, the window offers to open
        itself then: the Run value is only written when the user says yes."""
        self.locked = True
        if text:
            h.say(text)
        if (text == c.MIGRATED and self.windows and not h.autostart_installed()
                and self.window.ask(c.MIGRATED_AUTOSTART)):
            self.set_autostart(True)
        self.load()

    def need_lock(self):
        """True while this window holds subidor.lock. Without it (state «bloqueado») nothing may save config.json or
        start a Session: another uploader owns them. It tries the lock again; once taken, config.json is loaded from
        disk (the other uploader may have changed it) instead of going on with what was asked; if not, it stays
        blocked. Returns False in both cases."""
        if self.locked:
            return True
        outcome, text = c.take_lock(self.home, self.stack, self.window.ask,
                                    task_installed=lambda: h.startup_task_installed(hidden=True))
        self.window.show_main()
        if outcome == "ok":
            self.took_lock(text)
        else:
            self.controller.blocked(text)
        return False

    def load(self):
        if not self.need_lock():
            return
        self.config = h.load_config(self.home)
        if self.windows:                       # every start: what opens another folder now opens this one
            self.claim_copy()
            self.window.autostart.set(h.autostart_installed())
        missing = c.needed_steps(self.config, self.protector)
        if missing:
            self.controller.configuring()
            self.window.show_wizard(c.Setup(self.config, self.protector, steps=missing), self.finish_setup)
            return
        if self.windows:
            if not self.config.get("acceso_ofrecido"):
                self.config["acceso_ofrecido"] = True
                with contextlib.suppress(OSError):
                    h.save_config(self.home, self.config)
                if self.window.ask(c.SHORTCUT_OFFER):
                    self.create_shortcut()
        self.begin()

    def claim_copy(self):
        """The Run value and the desktop shortcut follow this copy when its folder was moved or a new version was
        extracted elsewhere, and never go back to an older copy opened again from its old folder (c.claim_copy). The
        copy is kept in config.json (a first run keeps it at «Empezar»)."""
        _, script, folder = h.launch_parts()
        before = self.config.get("subidor")
        mine, moved, text = c.claim_copy(self.config, script, folder)
        if not mine:
            h.say(text)
            return
        h.repair_autostart()
        if self.config.get("schema") != 1:
            return
        if self.config.get("subidor") != before:
            with contextlib.suppress(OSError):
                h.save_config(self.home, self.config)
        if moved:
            with contextlib.suppress(h.SyncError):
                if h.create_shortcut(only_existing=True):
                    h.say(c.SHORTCUT_MOVED)

    def begin(self, key=None):
        if not self.need_lock():
            return
        setup = c.Setup(self.config, self.protector, detect=lambda: [])
        key = key or setup.key or self.key
        if not (setup.url and setup.folder and key):
            self.controller.configuring()
            self.window.show_wizard(c.Setup(self.config, self.protector), self.finish_setup)
            return
        self.key = key
        self.window.show_main()
        self.session = c.Session(setup.url, key, setup.folder, self.config, self.home, self.messages)
        self.controller.started(setup.url, setup.folder, key, self.session.snapshot())
        self.controller.accounts = c.scan_accounts(setup.folder)
        h.say(f"Subidor {h.VERSION} abierto. Vigilando {setup.folder}.")
        self.session.start()

    def finish_setup(self, setup, shortcut=False):
        def apply():
            if not self.need_lock():
                return
            try:
                _, _, key = setup.finish()
                self.config["acceso_ofrecido"] = True         # the first run already offered the shortcut
                h.save_config(self.home, self.config)
            except (h.SyncError, OSError) as error:
                self.window.tell(str(error))
                return
            if shortcut:
                self.create_shortcut()
            self.begin(key)
        self.after_session(apply)

    # -- the worker -------------------------------------------------------------------------------------------
    def after_session(self, action):
        """Runs action once the worker thread has ended (it owns config.json while it runs)."""
        if self.session is not None and self.session.alive():
            self.session.request_stop()
            self.root.after(100, lambda: self.after_session(action))
            return
        self.session = None
        action()

    def poll(self):
        c.drain(self.messages, self.controller)
        self.polls += 1
        if self.controller.folder is not None and self.polls % 25 == 0:      # the accounts row: every 5 s
            self.controller.accounts = c.scan_accounts(self.controller.folder)
        self.window.refresh(self.controller)
        self.root.after(c.POLL_MS, self.poll)

    # -- buttons ------------------------------------------------------------------------------------------------
    def status_action(self):
        state = self.controller.state
        if state == "clave":
            self.change(("key",))
        elif state == "bloqueado":
            self.need_lock()
        elif state == "detenido":
            self.after_session(self.begin)

    def upload_now(self):
        if self.session is not None and self.controller.upload_now():
            self.session.upload_now()

    def open_panel(self):
        if self.controller.url:
            webbrowser.open(self.controller.url + "/hermandad")

    def open_log(self):
        path = self.home / "registro.txt"
        if not path.exists():
            return
        if hasattr(os, "startfile"):
            os.startfile(path)
        else:
            webbrowser.open(path.as_uri())

    def change(self, steps):
        if not self.need_lock():
            return

        def show():
            self.controller.configuring()
            self.window.show_wizard(c.Setup(self.config, self.protector, steps=steps), self.finish_setup,
                                    on_cancel=lambda: self.after_session(self.begin))
        self.after_session(show)

    def set_autostart(self, on):
        try:
            if on:
                h.install_autostart()
                h.say("El subidor se abrirá minimizado al iniciar Windows.")
            else:
                h.uninstall_autostart()
                h.say("El subidor ya no se abrirá al iniciar Windows.")
        except h.SyncError as error:
            h.say(str(error))
        self.window.autostart.set(h.autostart_installed())

    def create_shortcut(self):
        try:
            h.create_shortcut()
            h.say(c.SHORTCUT_DONE)
        except h.SyncError as error:
            h.say(str(error))

    def remove_marker(self):
        folder = self.controller.folder
        if self.session is not None:
            self.session.marker_removed.set()
        status = h.remove_marker(folder) if folder else "unknown"
        h._say_marker_removal(status)
        if status in ("removed", "absent"):
            self.controller.marker = "removed"

    def reset(self):
        if not self.need_lock() or not self.window.ask(c.RESET_CONFIRM):
            return

        def apply():
            folder = self.controller.folder
            if folder:
                h.remove_marker(folder)
            with contextlib.suppress(FileNotFoundError, OSError):
                (self.home / "config.json").unlink()
            if self.windows:
                with contextlib.suppress(h.SyncError):
                    h.uninstall_autostart()
                self.window.autostart.set(False)
            self.key = None
            h.say(c.RESET_DONE)
            self.load()
        self.after_session(apply)

    def close(self):
        if self.session is not None and self.session.alive():
            answer = self.window.ask_close()
            if answer == "minimizar":
                self.root.iconify()
            if answer != "cerrar":
                return
        self.shutdown()

    def shutdown(self):
        if self.session is not None:
            self.session.request_stop()
            deadline = time.monotonic() + 3          # an upload in flight ends on its own; config writes are atomic
            while self.session.alive() and time.monotonic() < deadline:
                time.sleep(0.05)
        h.set_output_sink(None)
        self.stack.close()
        with contextlib.suppress(Exception):
            self.root.destroy()


def check_window():
    """--comprobar: the controller, a withdrawn Tk window with every widget, destroyed at once. Exit code 0."""
    import tkinter as tk
    from tkinter import ttk
    controller = c.Controller()
    controller.handle(("linea", "[00:00:00] comprobación"))
    root = tk.Tk()
    try:
        root.withdraw()
        app = App(tk, ttk, root, Path(tempfile.gettempdir()), protector=None)
        app.window.show_main()
        app.window.refresh(controller)
        root.update_idletasks()
    finally:
        root.destroy()
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="subidor.pyw", description=c.TITLE)
    parser.add_argument("--minimizado", action="store_true", help="empieza minimizado en la barra de tareas")
    parser.add_argument("--comprobar", action="store_true", help="comprueba que la ventana se puede crear y termina")
    args = parser.parse_args(argv)
    if args.comprobar:
        return check_window()
    if h._windows():
        with contextlib.suppress(Exception):         # sharp text on scaled screens
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
    import tkinter as tk
    from tkinter import ttk
    root = tk.Tk()
    app = App(tk, ttk, root, h.config_dir(), protector=h.default_protector(), minimized=args.minimizado)
    try:
        if app.start():
            root.mainloop()
    finally:
        h.set_output_sink(None)
        app.stack.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
