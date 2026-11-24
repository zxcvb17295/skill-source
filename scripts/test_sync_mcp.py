#!/usr/bin/env python3
"""Local fixtures only: python3 -B scripts/test_sync_mcp.py."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("sync-mcp.py")
loader = importlib.util.spec_from_file_location("sync_mcp", SCRIPT)
sync = importlib.util.module_from_spec(loader)
loader.loader.exec_module(sync)


class SyncChecks(unittest.TestCase):
    def test_platform_and_client_formats(self):
        registry = {"oracle": {"command": "node", "args": ["${windows_home}\\server.js"],
                              "env": {"CONFIG": "config.json"},
                              "wsl": {"command": "${windows_node}", "env": {"WSLENV": "CONFIG"}}},
                    "docs": {"url": "https://example.test/mcp", "headers": {"Accept": "application/json"}}}
        with patch.dict(os.environ, {"WSLENV": "EXISTING:CONFIG"}), patch.object(sync.shutil, "which", return_value="/mnt/d/node/node.exe"):
            wsl = sync.render_servers(registry, "wsl", "/mnt/c/Users/test")
            windows = sync.render_servers(registry, "windows", "/mnt/c/Users/test")
        self.assertEqual(wsl["oracle"]["command"], "/mnt/d/node/node.exe")
        self.assertEqual(wsl["oracle"]["env"], {"CONFIG": "config.json", "WSLENV": "EXISTING:CONFIG"})
        self.assertEqual(windows["oracle"]["args"], ["C:\\Users\\test\\server.js"])
        self.assertEqual(sync.client_servers(windows, "claude")["oracle"]["type"], "stdio")
        self.assertEqual(sync.client_servers(windows, "vscode")["docs"]["type"], "http")
        self.assertEqual(sync.client_servers(wsl, "codex")["docs"]["http_headers"], {"Accept": "application/json"})

    def test_sync_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="mcp check ") as directory:
            root = Path(directory)
            path = root / "config.toml"
            original = '# keep comment\nmodel = "existing"\n[projects."path with spaces"]\ntrust_level = "trusted"\n[mcp_servers.unmanaged]\ncommand = "keep"\n[mcp_servers.oracle]\ncommand = "old"\n'
            path.write_text(original)
            desired = {"oracle": {"command": "new", "env": {"CONFIG": "file"}}}
            with self.assertRaises(ValueError):
                sync.plan_target(path, "codex", desired, False)
            plan = sync.plan_target(path, "codex", desired, True)
            sync.write_plan(plan, True)
            self.assertEqual(path.read_text(), original)
            self.assertEqual(list(root.iterdir()), [path])
            sync.write_plan(plan, False)
            self.assertEqual(tomllib.loads(path.read_text())["mcp_servers"]["unmanaged"], {"command": "keep"})
            self.assertIn("# keep comment", path.read_text())
            self.assertEqual(next(root.glob("*.bak-*")).read_text(), original)
            snapshot = {p.name: p.read_bytes() for p in root.iterdir()}
            sync.write_plan(sync.plan_target(path, "codex", desired, False), False)
            self.assertEqual(snapshot, {p.name: p.read_bytes() for p in root.iterdir()})
            path.write_text(path.read_text().replace('"new"', '"local edit"'))
            with self.assertRaises(ValueError):
                sync.plan_target(path, "codex", {}, False)
            sync.write_plan(sync.plan_target(path, "codex", {}, True), False)
            self.assertEqual(tomllib.loads(path.read_text())["mcp_servers"], {"unmanaged": {"command": "keep"}})

    def test_json_preserves_settings_and_removes_only_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".claude.json"
            original = {"account": {"keep": True}, "projects": {"demo": {"mcpServers": {"local": {"command": "keep"}}}},
                        "mcpServers": {"unmanaged": {"command": "keep"}}}
            path.write_text(json.dumps(original), encoding="utf-8-sig")
            sync.write_plan(sync.plan_target(path, "claude", {"demo": {"command": "node"}}, False), False)
            sync.write_plan(sync.plan_target(path, "claude", {}, False), False)
            self.assertEqual(sync.read_json(path), original)
            self.assertEqual(sync.read_json(path.with_name(path.name + ".skill-source-mcp.json")), {})

    def test_toml_quoted_names_and_unsafe_layout(self):
        source = '[mcp_servers."with.dot".env]\nKEY = "value"\n[windows]\nsandbox = "elevated"\n'
        servers = {"with.dot": {"command": "node", "env": {"KEY": "value"}}}
        parsed = tomllib.loads(sync.update_toml(source, servers))
        self.assertEqual(parsed["mcp_servers"], servers)
        self.assertEqual(parsed["windows"], {"sandbox": "elevated"})
        with self.assertRaises(ValueError):
            sync.update_toml('notes = """\n[mcp_servers.fake]\nkeep me\n"""\n', servers)

    def test_cli_preflight_and_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            win, wsl = root / "windows", root / "wsl"
            (win / ".codex").mkdir(parents=True)
            broken = win / ".codex/config.toml"
            broken.write_text("invalid = [")
            registry = root / "servers.json"
            registry.write_text(json.dumps({"servers": {"demo": {"command": "node"}}}))
            command = [sys.executable, "-B", str(SCRIPT), "--registry", str(registry),
                       "--windows-home", str(win), "--wsl-home", str(wsl), "--target", "windows"]
            if os.name != "nt":
                command += ["--target", "wsl"]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertFalse((win / ".claude.json").exists())
            broken.write_text('model = "keep"\n')
            self.assertEqual(subprocess.run(command + ["--dry-run"], capture_output=True).returncode, 0)
            self.assertFalse((win / ".claude.json").exists())
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sync.read_json(win / "AppData/Roaming/Code/User/mcp.json")["servers"]["demo"]["type"], "stdio")
            self.assertEqual(tomllib.loads(broken.read_text())["model"], "keep")
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_concurrent_edit_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text('model = "old"\n')
            plan = sync.plan_target(path, "codex", {"demo": {"command": "node"}}, False)
            path.write_text('model = "edited"\n')
            with self.assertRaises(ValueError):
                sync.write_plan(plan, False)
            self.assertEqual(path.read_text(), 'model = "edited"\n')


if __name__ == "__main__":
    unittest.main()
