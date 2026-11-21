"""Builds Subidor_Windows.zip: the portable folder «OroHermandad Subidor» with the official, PSF-signed Python runtime
(the one running this script) and the window's files, so players open the uploader without installing Python.

Runs on the GitHub Actions Windows runner (.github/workflows/subidor-windows.yml) and never publishes anything:

    python pc_sync/empaquetar_windows.py --salida "$RUNNER_TEMP/Subidor_Windows.zip"

1. Copies sys.base_prefix into runtime/ without Lib/test, Lib/idlelib, Lib/turtledemo, Lib/ensurepip, what is in
   Lib/site-packages, Scripts, include, libs, Doc, Tools, tcl/nmake, the python.org installer that GitHub's runners
   leave in the folder (python-X.Y.Z-amd64.exe) and every __pycache__ (LICENSE.txt and the Tcl/Tk license files
   stay); the app files into app/; writes «Abrir subidor.cmd» and LEEME.txt (CRLF).
2. Writes the zip in sorted order with fixed timestamps and deflate level 9: the same sources give the same bytes.
3. Extracts it into a fresh folder and runs the smoke tests there, all with -B and PYTHONDONTWRITEBYTECODE=1 (no .pyc
   in what players get): the runtime imports ssl, ctypes, tkinter and json; the whole pc_sync suite runs with that
   runtime; app/subidor.pyw --comprobar. Then the extracted tree must hold no __pycache__ or .pyc.
4. Fails if any .exe, .dll or .pyd of runtime/ lacks a valid Authenticode signature (Get-AuthenticodeSignature).
5. Builds again and fails if the SHA-256 differs; prints size and SHA-256 (also to $GITHUB_STEP_SUMMARY); fails above
   30 MB.
The zip goes to the system's temporary folder by default and never inside the repository. --solo-zip builds and
checks only the zip (steps 1, 2 and 5 without the size report): it is how the tests try this script off Windows.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
ROOT = "OroHermandad Subidor"
ZIP_NAME = "Subidor_Windows.zip"
APP_FILES = ("hermandad.py", "sincronizar.py", "subidor_control.py", "subidor.pyw")
README = "LEEME_WINDOWS.txt"
# tcl/nmake: archivos de Tcl para compilar extensiones con nmake (incluye un .exe sin firmar); no se usan al ejecutar.
TRIMMED = ("Lib/test", "Lib/idlelib", "Lib/turtledemo", "Lib/ensurepip", "Scripts", "include", "libs", "Doc", "Tools",
           "tcl/nmake")
EMPTIED = ("Lib/site-packages",)      # the folder stays (site.py expects it), its contents go
SIGNED = (".exe", ".dll", ".pyd")
STAMP = (2026, 11, 4, 0, 0, 0)
MAX_BYTES = 30 * 1024 * 1024
LAUNCHER = ("@echo off\r\n"
            "setlocal\r\n"
            "rem Abre la ventana del subidor de Oro de Hermandad con el Python oficial de la carpeta runtime.\r\n"
            "if exist \"%~dp0runtime\\pythonw.exe\" goto abrir\r\n"
            "echo Extrae primero la carpeta del zip: clic derecho en el zip, Extraer todo.\r\n"
            "echo Despues abre \"Abrir subidor.cmd\" desde la carpeta extraida.\r\n"
            "pause\r\n"
            "exit /b 1\r\n"
            ":abrir\r\n"
            "start \"\" \"%~dp0runtime\\pythonw.exe\" -E -s \"%~dp0app\\subidor.pyw\" %*\r\n")
SIGNATURE_SCRIPT = ("$ErrorActionPreference = 'Stop'; "
                    "Get-ChildItem -LiteralPath $env:OROHERMANDAD_RUNTIME -Recurse -File | "
                    "Where-Object { $_.Extension -in '.exe', '.dll', '.pyd' } | "
                    "Get-AuthenticodeSignature | Where-Object { $_.Status -ne 'Valid' } | "
                    "ForEach-Object { '{0}|{1}' -f $_.Status, $_.Path }")


class BuildError(Exception):
    """The build cannot go on; the message says why (shown in the workflow log)."""


def _trimmed(relative):
    """True for a path of the runtime (posix, relative to it) that does not go in the zip."""
    parts = relative.split("/")
    if "__pycache__" in parts or relative.endswith((".pyc", ".pyo")):
        return True
    # El instalador de python.org (python-3.13.17-amd64.exe, unos 27 MB) se queda dentro del Python de los runners
    # de GitHub (actions/python-versions lo copia ahí para instalar); no forma parte del Python.
    name = relative.lower()
    if len(parts) == 1 and name.startswith("python-") and name.endswith(".exe"):
        return True
    for prefix in TRIMMED:
        if relative.lower() == prefix.lower() or relative.lower().startswith(prefix.lower() + "/"):
            return True
    return any(relative.lower().startswith(folder.lower() + "/") for folder in EMPTIED)


def entries(runtime, source=HERE):
    """{name in the zip: bytes} of the whole folder. runtime: the Python to copy (sys.base_prefix)."""
    runtime, source = Path(runtime), Path(source)
    if not (runtime / "python.exe").is_file() or not (runtime / "pythonw.exe").is_file():
        raise BuildError(f"{runtime} no es un Python para Windows (faltan python.exe o pythonw.exe).")
    files = {}
    for path in sorted(runtime.rglob("*")):
        relative = path.relative_to(runtime).as_posix()
        if path.is_file() and not path.is_symlink() and not _trimmed(relative):
            files[f"{ROOT}/runtime/{relative}"] = path.read_bytes()
    for name in APP_FILES:
        files[f"{ROOT}/app/{name}"] = (source / name).read_bytes()
    files[f"{ROOT}/Abrir subidor.cmd"] = LAUNCHER.encode("ascii")
    text = (source / README).read_text(encoding="utf-8").replace("\r\n", "\n").replace("\n", "\r\n")
    files[f"{ROOT}/LEEME.txt"] = text.encode("utf-8-sig")
    return files


def write_zip(files, path):
    """The zip of files in sorted order, with fixed timestamps and attributes: the same files give the same bytes."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=STAMP)
            info.create_system = 0
            info.external_attr = 0
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, files[name], compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return path


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def outside_repository(path):
    """The zip never goes inside the repository (nothing to add to .gitignore)."""
    path = Path(path).resolve()
    if path == REPO or REPO in path.parents:
        raise BuildError(f"El zip no se escribe dentro del repositorio: usa --salida fuera de {REPO}.")
    return path


def bytecode(folder):
    """Every __pycache__ folder and .pyc file under folder."""
    return sorted(str(p) for p in Path(folder).rglob("*") if p.name == "__pycache__" or p.suffix in (".pyc", ".pyo"))


def smoke_tests(folder, run=subprocess.run, repo=REPO):
    """The checks on the extracted folder, with its own runtime and -B (nothing writes .pyc into it)."""
    root = Path(folder) / ROOT
    python = root / "runtime" / "python.exe"
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    steps = (([str(python), "-B", "-E", "-s", "-c", "import ssl, ctypes, tkinter, json"], root),
             ([str(python), "-B", "-m", "unittest", "discover", "-s", "pc_sync", "-p", "test_*.py"], repo),
             ([str(python), "-B", str(root / "app" / "subidor.pyw"), "--comprobar"], root))
    for command, cwd in steps:
        print("::group::" + " ".join(command[1:]), flush=True)
        result = run(command, cwd=str(cwd), env=env)
        print("::endgroup::", flush=True)
        if result.returncode != 0:
            raise BuildError(f"Falla la prueba con el Python del zip: {' '.join(command[1:])} (código {result.returncode}).")
    left = bytecode(folder)
    if left:
        raise BuildError("La carpeta extraída tiene .pyc o __pycache__:\n" + "\n".join(left[:20]))


def unsigned(runtime_folder, run=subprocess.run):
    """[(status, path)] of the .exe, .dll and .pyd of runtime/ without a valid Authenticode signature."""
    shell = Path(os.environ.get("SystemRoot", "C:\\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    result = run([str(shell), "-NoProfile", "-NonInteractive", "-Command", SIGNATURE_SCRIPT],
                 env=dict(os.environ, OROHERMANDAD_RUNTIME=str(runtime_folder)), capture_output=True, text=True,
                 stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        raise BuildError("No se han podido comprobar las firmas: " + (result.stderr or "").strip()[:500])
    bad = []
    for line in (result.stdout or "").splitlines():
        if "|" in line:
            status, path = line.strip().split("|", 1)
            bad.append((status, path))
    return bad


def check_signatures(folder, run=subprocess.run):
    runtime = Path(folder) / ROOT / "runtime"
    if not any(p.suffix.lower() in SIGNED for p in runtime.rglob("*")):
        raise BuildError("No hay ningún .exe, .dll o .pyd que comprobar en runtime/.")
    bad = unsigned(runtime, run)
    if bad:
        raise BuildError("Hay archivos sin una firma Authenticode válida:\n" + "\n".join(f"{s}  {p}" for s, p in bad))


def report(path, digest, summary=None):
    size = Path(path).stat().st_size
    lines = [f"Subidor_Windows.zip: {size} bytes ({size / 1024 / 1024:.1f} MB)", f"SHA-256: {digest}"]
    print("\n".join(lines), flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY") if summary is None else summary
    if summary:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write("### Subidor para Windows\n\n" + "\n".join(f"- {line}" for line in lines) + "\n")
    if size > MAX_BYTES:
        raise BuildError(f"El zip ocupa {size} bytes: más de 30 MB.")
    return size


def build(output, runtime=None, *, only_zip=False, scratch=None, run=subprocess.run):
    """Every step of the module docstring. Returns the SHA-256 of the zip."""
    output = outside_repository(output)
    runtime = Path(runtime or sys.base_prefix)
    write_zip(entries(runtime), output)
    digest = sha256(output)
    work = Path(scratch or os.environ.get("RUNNER_TEMP") or tempfile.gettempdir())
    if not only_zip:
        tested = work / "prueba"
        if tested.exists():
            shutil.rmtree(tested)
        with zipfile.ZipFile(output) as archive:
            archive.extractall(tested)
        smoke_tests(tested, run)
        check_signatures(tested, run)
    second = Path(tempfile.mkdtemp(prefix="segunda-", dir=work))
    try:
        same = sha256(write_zip(entries(runtime), outside_repository(second / ZIP_NAME))) == digest
    finally:
        shutil.rmtree(second, ignore_errors=True)
    if not same:
        raise BuildError("Dos construcciones seguidas no dan el mismo zip (SHA-256 distinto).")
    if not only_zip:
        report(output, digest)
    return digest


def main(argv=None):
    parser = argparse.ArgumentParser(prog="empaquetar_windows.py", description="Construye Subidor_Windows.zip.")
    parser.add_argument("--salida", default=str(Path(tempfile.gettempdir()) / ZIP_NAME),
                        help="dónde escribir el zip (por defecto, la carpeta temporal del sistema)")
    parser.add_argument("--runtime", help="el Python que se copia (por defecto, el que ejecuta este script)")
    parser.add_argument("--solo-zip", action="store_true", help="solo construye y compara el zip (fuera de Windows)")
    args = parser.parse_args(argv)
    if os.name != "nt" and not args.solo_zip:
        print("Esto se ejecuta en Windows (el Python que se copia tiene que ser el de Windows). Fuera de Windows usa "
              "--solo-zip --runtime <carpeta>.", file=sys.stderr)
        return 2
    try:
        digest = build(args.salida, args.runtime, only_zip=args.solo_zip)
    except BuildError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Listo: {args.salida} ({digest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
