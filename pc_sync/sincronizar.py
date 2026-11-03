"""Read-only PC uploader for El Especulador del WoW.

Only the two selected Auctioneer SavedVariables files are read. Device tokens
and deduplication hashes remain in memory; this program never executes Lua,
changes WoW files or interacts with the running game.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import ssl
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

FILES = {
    "Auctioneer_Stats_OverTime.lua": "historyText",
    "EspeculadorBridge.lua": "bridgeText",
}
MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_BODY_BYTES = 16 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
POLL_SECONDS = 15
REQUEST_TIMEOUT = 20


class SyncError(ValueError):
    """A safe, user-facing error which contains no token or file contents."""


class ReadPendingError(SyncError):
    """A source changed while being read; retry after WoW finishes saving."""


class AuthenticationError(SyncError):
    """The cloud refused the paired device; stop rather than retrying forever."""


class RetryableSyncError(SyncError):
    def __init__(self, message, retry_after=60):
        super().__init__(message)
        self.retry_after = max(60, min(300, retry_after))


@dataclass(frozen=True)
class Observation:
    text: str
    sha256: str
    size: int


def validate_url(value):
    """Accept one HTTPS application origin; never a token-bearing URL."""
    if not isinstance(value, str):
        raise SyncError("Introduce la dirección HTTPS de tu aplicación.")
    value = value.strip()
    if not value or any(c.isspace() or ord(c) < 32 for c in value) or "\\" in value:
        raise SyncError("La dirección debe ser una URL HTTPS sin espacios.")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        raise SyncError("La dirección de la aplicación no es válida.") from None
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise SyncError("Usa la dirección HTTPS de la aplicación alojada en Cloudflare.")
    if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        raise SyncError("La dirección no debe contener credenciales, parámetros ni fragmentos.")
    if parsed.path not in ("", "/") or port not in (None, 443):
        raise SyncError("Introduce solo la dirección principal de la aplicación, sin rutas adicionales.")
    try:
        hostname = parsed.hostname.encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise SyncError("El dominio de la aplicación no es válido.") from None
    if hostname == "localhost" or ":" in hostname or "." not in hostname:
        raise SyncError("Usa el dominio HTTPS de tu aplicación en la nube.")
    if hostname.startswith(".") or hostname.endswith(".") or ".." in hostname:
        raise SyncError("El dominio de la aplicación no es válido.")
    return urlunsplit(("https", hostname, "", "", ""))


def validate_token(value):
    if not isinstance(value, str) or not 24 <= len(value) <= 512 or any(c.isspace() or ord(c) < 33 for c in value):
        raise SyncError("La clave del dispositivo no tiene un formato válido. Cópiala de nuevo desde la aplicación.")
    return value


def validate_folder(value):
    if not isinstance(value, (str, Path)):
        raise SyncError("Selecciona la carpeta local SavedVariables de tu cliente.")
    text = str(value).strip().strip('"')
    if not text or text.startswith(("\\\\", "//")):
        raise SyncError("Selecciona una carpeta de este PC, no una ubicación de red.")
    try:
        folder = Path(text).expanduser().resolve()
        if not folder.is_dir():
            raise SyncError("No se encuentra la carpeta local seleccionada.")
    except OSError:
        raise SyncError("No se puede abrir la carpeta local seleccionada.") from None
    return folder


def stable_read(path, allowed=None):
    """Read a complete, stable UTF-8 file without changing it or its timestamps.

    allowed: the file names another uploader may read (default: the two FILES of this connector).
    """
    path = Path(path)
    if path.name not in (FILES if allowed is None else allowed):
        raise SyncError("Solo se admiten los dos archivos SavedVariables del conector." if allowed is None
                        else "Solo se admiten los archivos SavedVariables previstos.")
    try:
        before = path.stat()
        if not path.is_file() or before.st_size > MAX_FILE_BYTES:
            raise SyncError(f"{path.name}: el archivo no es regular o supera los 10 MB.")
        with path.open("rb") as stream:
            opened = os.fstat(stream.fileno())
            raw = stream.read(MAX_FILE_BYTES + 1)
            completed = os.fstat(stream.fileno())
        after = path.stat()
    except OSError:
        raise ReadPendingError(f"{path.name}: no se puede leer todavía. Espera a que WoW termine de guardar.") from None
    signature = lambda stat: (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
    if (len(raw) > MAX_FILE_BYTES or len(raw) != before.st_size
            or any(signature(current) != signature(before) for current in (opened, completed, after))):
        raise ReadPendingError(f"{path.name}: está cambiando. Se volverá a intentar cuando termine el guardado.")
    if not raw:
        raise ReadPendingError(f"{path.name}: está vacío. Espera al siguiente guardado de WoW.")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise SyncError(f"{path.name}: el archivo no es UTF-8 válido.") from None
    return Observation(text=text, sha256=hashlib.sha256(raw).hexdigest(), size=len(raw))


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post_upload(url, token, payload, timeout=REQUEST_TIMEOUT):
    """One HTTPS upload. Redirects cannot forward the Authorization header."""
    request = Request(
        validate_url(url) + "/api/device/sync", data=payload, method="POST",
        headers={"Authorization": "Bearer " + validate_token(token),
                 "Content-Type": "application/json; charset=utf-8",
                 "Accept": "application/json", "User-Agent": "ElEspeculadorPC/0.3"},
    )
    opener = build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as error:
        error.close()
        if error.code in (401, 403):
            raise AuthenticationError("La nube ha rechazado la clave del dispositivo. Se detiene la sincronización; crea una clave nueva en la aplicación.") from None
        retry_after = 60
        try:
            retry_after = int(error.headers.get("Retry-After", "60"))
        except (ValueError, TypeError):
            pass
        if 300 <= error.code < 400:
            raise RetryableSyncError("La dirección devuelve una redirección. Usa el dominio HTTPS final de la aplicación.") from None
        raise RetryableSyncError(f"La nube no ha aceptado los datos (HTTP {error.code}). Revisa el mercado y que el puente esté confirmado.", retry_after) from None
    except (URLError, TimeoutError, OSError, ssl.SSLError):
        raise RetryableSyncError("No se ha podido conectar con la aplicación. Tus archivos no se han modificado.") from None
    if len(raw) > MAX_RESPONSE_BYTES:
        raise RetryableSyncError("La aplicación ha devuelto una respuesta demasiado grande.")
    try:
        result = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise RetryableSyncError("La aplicación no ha devuelto una confirmación válida.") from None
    if not isinstance(result, dict) or result.get("accepted") is not True:
        raise RetryableSyncError("La nube no ha confirmado la importación. Se conservarán los cambios pendientes.")
    return result


class SyncClient:
    def __init__(self, url, token, folder, realm, poster=post_upload):
        self.url = validate_url(url)
        self._token = validate_token(token)
        self.folder = validate_folder(folder)
        if not isinstance(realm, str) or not realm.strip() or len(realm.strip()) > 160 or any(ord(c) < 32 for c in realm):
            raise SyncError("Introduce el nombre exacto del reino que aparece en tus datos.")
        self.realm = realm.strip()
        self.poster = poster
        self.hashes = {}

    def cycle(self):
        """Commit hashes only after the server confirms the whole upload."""
        changed = {}
        existing = 0
        for filename, field in FILES.items():
            path = self.folder / filename
            if not path.exists():
                continue
            existing += 1
            observation = stable_read(path)
            if observation.sha256 != self.hashes.get(filename):
                changed[filename] = (field, observation)
        if existing == 0:
            return dict(status="missing", files=[])
        if not changed:
            return dict(status="unchanged", files=[])
        data = dict(realm=self.realm, confirmedMarket=True)
        data.update({field: observation.text for field, observation in changed.values()})
        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if len(payload) > MAX_BODY_BYTES:
            raise SyncError("Los archivos combinados superan los 16 MB permitidos. No se ha enviado ningún archivo.")
        result = self.poster(self.url, self._token, payload, timeout=REQUEST_TIMEOUT)
        if not isinstance(result, dict) or result.get("accepted") is not True:
            raise RetryableSyncError("La nube no ha confirmado la importación. Se conservarán los cambios pendientes.")
        self.hashes.update({filename: observation.sha256 for filename, (_, observation) in changed.items()})
        return dict(status="uploaded", files=list(changed))


def log(message):
    print(datetime.now().strftime("[%H:%M:%S] ") + message, flush=True)


def run(client, once=False, sleep=time.sleep):
    backoff = 60
    last_status = None
    while True:
        try:
            result = client.cycle()
            backoff = 60
            status = result["status"]
            if status == "uploaded":
                names = ", ".join(result["files"])
                log("Sincronización aceptada: " + names + ".")
            elif status != last_status:
                log("Sin cambios pendientes." if status == "unchanged" else "Esperando los archivos del addon en la carpeta seleccionada.")
            last_status = status
            if once:
                return 0
            sleep(POLL_SECONDS)
        except AuthenticationError as error:
            log(str(error))
            return 2
        except (ReadPendingError, RetryableSyncError, SyncError) as error:
            log(str(error))
            if once:
                return 1
            delay = max(backoff, getattr(error, "retry_after", 60))
            log(f"Nuevo intento dentro de {delay} segundos. Ctrl+C para cerrar.")
            sleep(delay)
            backoff = min(300, backoff * 2)
            last_status = None


def main(argv=None):
    parser = argparse.ArgumentParser(description="Sincroniza Auctioneer con El Especulador del WoW en Cloudflare.")
    parser.add_argument("--url", help="Dirección principal HTTPS de la aplicación")
    parser.add_argument("--folder", help="Carpeta local SavedVariables del cliente Forever")
    parser.add_argument("--realm", help="Nombre exacto del reino de tus observaciones")
    parser.add_argument("--once", action="store_true", help="Realiza una comprobación y termina")
    args = parser.parse_args(argv)
    print("El Especulador del WoW · sincronizador de este PC")
    print("Lee dos archivos del addon y envía sus cambios a tu aplicación. No modifica WoW.")
    try:
        url = validate_url(args.url or input("Dirección HTTPS de tu aplicación: "))
        folder = validate_folder(args.folder or input("Carpeta SavedVariables: "))
        realm = args.realm or input("Nombre exacto del reino: ").strip()
        confirmation = input("Confirma el mercado escribiendo EU PVP ALIANZA: ").strip().upper()
        if confirmation != "EU PVP ALIANZA":
            raise SyncError("El mercado no se ha confirmado. No se ha enviado ningún archivo.")
        token = os.environ.get("ESPECULADOR_DEVICE_TOKEN") or getpass.getpass("Clave del dispositivo (no se mostrará ni se guardará): ")
        client = SyncClient(url, token, folder, realm)
        print("Mantén esta ventana abierta. WoW escribe los archivos al usar /reload o al salir.")
        print("La clave y los hashes se conservan solo durante esta ejecución.")
        return run(client, once=args.once)
    except (SyncError, EOFError) as error:
        log(str(error) if isinstance(error, SyncError) else "Entrada cancelada. No se ha iniciado la sincronización.")
        return 1
    except KeyboardInterrupt:
        print("\nSincronización detenida.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
