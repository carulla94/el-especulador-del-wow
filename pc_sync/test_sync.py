"""Uploader boundary tests: no network or real game installation is required."""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError

import sincronizar as sync

TOKEN = "device_test_only_0123456789abcdefghijklmnopqrstuvwxyz"
URL = "https://especulador.example.com"


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.directory = Path(self.folder.name)
        self.history = self.directory / "Auctioneer_Stats_OverTime.lua"
        self.bridge = self.directory / "EspeculadorBridge.lua"
        self.history.write_text('AuctioneerStatsOverTimeData = { ["PvP EU"] = {} }', encoding="utf-8")
        self.bridge.write_text('EspeculadorBridgeDB = { capturedAt = 1793560000 }', encoding="utf-8")
        self.calls = []

    def poster(self, url, token, payload, timeout):
        self.calls.append((url, token, json.loads(payload), timeout))
        return {"accepted": True}

    def client(self, poster=None):
        return sync.SyncClient(URL, TOKEN, self.directory, "PvP EU", poster=poster or self.poster)

    def test_url_accepts_only_origin_https_and_normalizes_case(self):
        self.assertEqual(sync.validate_url("https://ESPECULADOR.example.com/"), URL)
        self.assertEqual(sync.validate_url("https://especulador.example.com:443"), URL)
        for value in ("http://especulador.example.com", "https://user:pass@especulador.example.com",
                      URL+"?token=secret", URL+"#secret", URL+"/login", URL+":8443",
                      "https://localhost", "https://example.com\\@evil.example", "https://bad host.example",
                      "https://..example.com", "https://example.com\n/token"):
            with self.subTest(value=value), self.assertRaises(sync.SyncError):
                sync.validate_url(value)

    def test_token_validation_errors_do_not_echo_secret(self):
        for token in ("short-secret", "a"*24+"\n", "a "*30):
            with self.subTest(token=token), self.assertRaises(sync.SyncError) as raised:
                sync.validate_token(token)
            self.assertNotIn(token, str(raised.exception))

    def test_folder_must_be_local_existing_directory(self):
        self.assertEqual(sync.validate_folder(self.directory), self.directory.resolve())
        for value in ("\\\\server\\share", "//server/share", str(self.directory / "missing"), str(self.history)):
            with self.subTest(value=value), self.assertRaises(sync.SyncError):
                sync.validate_folder(value)

    def test_stable_read_is_read_only_and_preserves_original_text_and_mtime(self):
        before_bytes = self.history.read_bytes()
        before = self.history.stat()
        observation = sync.stable_read(self.history)
        after = self.history.stat()
        self.assertEqual(observation.text, before_bytes.decode())
        self.assertEqual(self.history.read_bytes(), before_bytes)
        self.assertEqual(before.st_mtime_ns, after.st_mtime_ns)
        self.assertEqual(before.st_size, after.st_size)
        self.assertEqual(len(observation.sha256), 64)

    def test_stable_read_rejects_other_file_empty_and_invalid_utf8(self):
        other = self.directory / "another.lua"
        other.write_text("not allowed")
        with self.assertRaises(sync.SyncError):
            sync.stable_read(other)
        self.bridge.write_bytes(b"")
        with self.assertRaises(sync.ReadPendingError):
            sync.stable_read(self.bridge)
        self.bridge.write_bytes(b"\xff")
        with self.assertRaises(sync.SyncError):
            sync.stable_read(self.bridge)

    def test_file_size_limit_checked_before_upload(self):
        with patch.object(sync, "MAX_FILE_BYTES", 5), self.assertRaises(sync.SyncError):
            self.client().cycle()
        self.assertEqual(self.calls, [])

    def test_stable_read_detects_source_replacement_without_sending(self):
        actual_stat = Path.stat
        calls = 0
        def changing_stat(path, *args, **kwargs):
            nonlocal calls
            result = actual_stat(path, *args, **kwargs)
            if path == self.history:
                calls += 1
                if calls == 3:
                    self.history.write_text("changed while reading", encoding="utf-8")
                    return actual_stat(path, *args, **kwargs)
            return result
        with patch.object(Path, "stat", changing_stat), self.assertRaises(sync.ReadPendingError):
            self.client().cycle()
        self.assertEqual(self.calls, [])

    def test_initial_upload_includes_both_files_context_and_then_deduplicates(self):
        client = self.client()
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in (self.history, self.bridge)}
        self.assertEqual(client.cycle()["status"], "uploaded")
        self.assertEqual(len(self.calls), 1)
        url, token, body, timeout = self.calls[0]
        self.assertEqual((url, token, timeout), (URL, TOKEN, 20))
        self.assertEqual(body["realm"], "PvP EU")
        self.assertIs(body["confirmedMarket"], True)
        self.assertIn("historyText", body)
        self.assertIn("bridgeText", body)
        self.assertEqual(client.cycle()["status"], "unchanged")
        self.assertEqual(len(self.calls), 1)
        for path in (self.history, self.bridge):
            self.assertEqual(before[path.name], (path.read_bytes(), path.stat().st_mtime_ns))

    def test_uploads_only_changed_file_after_success(self):
        client = self.client()
        client.cycle()
        self.bridge.write_text("EspeculadorBridgeDB={capturedAt=1793560010}", encoding="utf-8")
        client.cycle()
        self.assertIn("bridgeText", self.calls[-1][2])
        self.assertNotIn("historyText", self.calls[-1][2])

    def test_missing_one_file_is_allowed_but_missing_both_waits(self):
        self.bridge.unlink()
        client = self.client()
        self.assertEqual(client.cycle()["status"], "uploaded")
        self.assertNotIn("bridgeText", self.calls[-1][2])
        self.history.unlink()
        self.assertEqual(client.cycle()["status"], "missing")

    def test_failed_upload_keeps_hashes_pending_for_retry(self):
        count = 0
        def poster(*args, **kwargs):
            nonlocal count
            count += 1
            if count == 1:
                raise sync.RetryableSyncError("test offline")
            return self.poster(*args, **kwargs)
        client = self.client(poster)
        with self.assertRaises(sync.RetryableSyncError):
            client.cycle()
        self.assertEqual(client.hashes, {})
        self.assertEqual(client.cycle()["status"], "uploaded")
        self.assertEqual(len(client.hashes), 2)

    def test_non_explicit_acceptance_never_commits_hashes(self):
        for result in (None, {}, {"accepted": False}, {"accepted": 1}, {"accepted": "true"}):
            client = self.client(lambda *a, **kw: result)
            with self.subTest(result=result), self.assertRaises(sync.RetryableSyncError):
                client.cycle()
            self.assertEqual(client.hashes, {})

    def test_combined_json_size_limit_prevents_any_request(self):
        with patch.object(sync, "MAX_BODY_BYTES", 20), self.assertRaises(sync.SyncError):
            self.client().cycle()
        self.assertEqual(self.calls, [])

    def test_http_upload_uses_bearer_and_blocks_redirects(self):
        captured = {}
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, limit): return b'{"accepted":true}'
        class Opener:
            def open(self, request, timeout):
                captured.update(url=request.full_url, authorization=request.get_header("Authorization"), timeout=timeout)
                return Response()
        def fake_build(handler):
            self.assertIsInstance(handler, sync._NoRedirect)
            return Opener()
        with patch.object(sync, "build_opener", fake_build):
            sync.post_upload(URL, TOKEN, b"{}")
        self.assertEqual(captured["authorization"], "Bearer " + TOKEN)
        self.assertEqual(captured["url"], URL+"/api/device/sync")
        self.assertIsNone(sync._NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://elsewhere.example"))

    def test_http_auth_errors_stop_without_echoing_response_or_token(self):
        for status in (401,403):
            response = HTTPError(URL, status, "secret "+TOKEN, {}, io.BytesIO(TOKEN.encode()))
            with self.subTest(status=status), patch.object(sync, "build_opener") as builder:
                builder.return_value.open.side_effect = response
                with self.assertRaises(sync.AuthenticationError) as raised:
                    sync.post_upload(URL,TOKEN,b"{}")
                self.assertNotIn(TOKEN,str(raised.exception))

    def test_network_failure_hides_exception_details(self):
        with patch.object(sync, "build_opener") as builder:
            builder.return_value.open.side_effect = URLError("secret: "+TOKEN)
            with self.assertRaises(sync.RetryableSyncError) as raised:
                sync.post_upload(URL,TOKEN,b"{}")
        self.assertNotIn(TOKEN,str(raised.exception))

    def test_retry_backoff_is_bounded_and_resets_after_success(self):
        waits = []
        calls = 0
        class Client:
            def cycle(self):
                nonlocal calls
                calls += 1
                if calls <= 5:
                    raise sync.RetryableSyncError("offline")
                if calls == 6:
                    return {"status":"uploaded","files":["EspeculadorBridge.lua"]}
                raise sync.AuthenticationError("revoked")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = sync.run(Client(),sleep=waits.append)
        self.assertEqual(status,2)
        self.assertEqual(waits,[60,120,240,300,300,15])
        self.assertNotIn(TOKEN,output.getvalue())

    def test_once_exits_after_one_accepted_check(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sync.run(self.client(),once=True),0)
        self.assertEqual(len(self.calls),1)


if __name__ == "__main__":
    unittest.main()
