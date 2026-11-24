#!/usr/bin/env python3
"""Distribute mcp/servers.json without replacing unrelated client settings."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import tomllib
from datetime import datetime


REPO = Path(__file__).resolve().parent.parent


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def windows_path(path):
    value = str(path)
    match = re.match(r"^/mnt/([a-zA-Z])(?:/|$)", value)
    if match:
        return match[1].upper() + ":\\" + value[match.end():].replace("/", "\\")
    return value


def render_servers(registry, platform, win_home):
    result = {}
    for name, raw in registry.items():
        if not isinstance(name, str) or not name or not isinstance(raw, dict):
            raise ValueError("Each server needs a nonempty name and an object")
        spec = {k: v for k, v in raw.items() if k not in ("windows", "wsl")}
        override = raw.get(platform, {})
        if not isinstance(override, dict):
            raise ValueError(f"Invalid platform override: {name}")
        spec.update(override)
        if "env" in raw or "env" in override:
            spec["env"] = {**raw.get("env", {}), **override.get("env", {})}
        if set(spec) - {"command", "args", "env", "cwd", "url", "headers"}:
            raise ValueError(f"Unknown server fields: {name}")

        def expand(value):
            if isinstance(value, dict):
                return {k: expand(v) for k, v in value.items()}
            if isinstance(value, list):
                return [expand(v) for v in value]
            if not isinstance(value, str):
                raise ValueError(f"Server values must be strings: {name}")
            value = value.replace("${windows_home}", windows_path(win_home))
            if "${windows_node}" in value:
                node = shutil.which("node.exe")
                if not node:
                    raise ValueError("Windows node.exe is missing from PATH")
                value = value.replace("${windows_node}", node)
            if "${" in value:
                raise ValueError(f"Unknown placeholder: {name}")
            return value

        spec = expand(spec)
        if ("command" in spec) == ("url" in spec):
            raise ValueError(f"Specify either command or url: {name}")
        if "command" in spec:
            if "headers" in spec or not isinstance(spec["command"], str) or not spec["command"]:
                raise ValueError(f"Invalid STDIO server: {name}")
            if not isinstance(spec.get("args", []), list) or not all(isinstance(v, str) for v in spec.get("args", [])):
                raise ValueError(f"Invalid args: {name}")
            if not isinstance(spec.get("env", {}), dict) or not all(isinstance(v, str) for v in spec.get("env", {}).values()):
                raise ValueError(f"Invalid args/env: {name}")
            if "cwd" in spec and not isinstance(spec["cwd"], str):
                raise ValueError(f"Invalid cwd: {name}")
        elif set(spec) - {"url", "headers"} or not isinstance(spec["url"], str) or not spec["url"]:
            raise ValueError(f"Invalid HTTP server: {name}")
        if "headers" in spec and (not isinstance(spec["headers"], dict) or not all(isinstance(v, str) for v in spec["headers"].values())):
            raise ValueError(f"Invalid HTTP headers: {name}")
        if platform == "wsl" and "WSLENV" in spec.get("env", {}):
            entries = os.environ.get("WSLENV", "").split(":") + spec["env"]["WSLENV"].split(":")
            spec["env"]["WSLENV"] = ":".join(dict.fromkeys(x for x in entries if x))
        result[name] = spec
    return result


def client_servers(servers, client):
    result = {}
    for name, spec in servers.items():
        value = dict(spec)
        if client == "codex":
            if "headers" in value:
                value["http_headers"] = value.pop("headers")
        else:
            value["type"] = "http" if "url" in value else "stdio"
        result[name] = value
    return result


def merge_servers(current, desired, owned, adopt):
    if not isinstance(current, dict) or not isinstance(owned, dict):
        raise ValueError("MCP servers and ownership state must be objects")
    merged = dict(current)
    for name in set(owned) | set(desired):
        if name in current:
            changed = name in owned and fingerprint(current[name]) != owned[name]
            collision = name not in owned and current[name] != desired.get(name)
            if (changed or collision) and not adopt:
                raise ValueError(f"MCP '{name}' already exists or was edited locally; review it, then use --adopt")
        if name in desired:
            merged[name] = desired[name]
        else:
            merged.pop(name, None)
    return merged


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{toml_value(k)} = {toml_value(v)}" for k, v in value.items()) + " }"
    if hasattr(value, "isoformat"):
        return value.isoformat()
    raise ValueError("Unsupported TOML value")


def update_toml(original, servers):
    before = tomllib.loads(original)
    kept = []
    removing = False
    for line in original.splitlines(keepends=True):
        if re.match(r"^\s*\[", line):
            try:
                header = tomllib.loads(line)
            except tomllib.TOMLDecodeError:
                pass
            else:
                removing = set(header) == {"mcp_servers"}
        if not removing:
            kept.append(line)
    output = "".join(kept).rstrip() + "\n"
    for name, spec in servers.items():
        output += f"\n[mcp_servers.{toml_value(name)}]\n"
        output += "".join(f"{toml_value(k)} = {toml_value(v)}\n" for k, v in spec.items())
    expected = {**before, "mcp_servers": servers}
    if not servers:
        expected.pop("mcp_servers", None)
    if tomllib.loads(output) != expected:
        raise ValueError("Cannot safely edit this TOML layout; use [mcp_servers.<name>] tables")
    return output


def plan_target(path, client, desired, adopt):
    path = path.resolve()
    original = path.read_bytes() if path.exists() else None
    text = original.decode("utf-8-sig") if original is not None else ""
    document = tomllib.loads(text) if client == "codex" else json.loads(text or "{}")
    if not isinstance(document, dict):
        raise ValueError(f"Configuration must be an object: {path}")
    key = {"codex": "mcp_servers", "claude": "mcpServers", "vscode": "servers"}[client]
    state_path = path.with_name(path.name + ".skill-source-mcp.json")
    state_original = state_path.read_bytes() if state_path.exists() else None
    owned = read_json(state_path) if state_original is not None else {}
    merged = merge_servers(document.get(key, {}), desired, owned, adopt)
    if merged == document.get(key, {}) and original is not None:
        output = original
    elif client == "codex":
        output = update_toml(text, merged).encode("utf-8")
    else:
        document[key] = merged
        output = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    state = (json.dumps({name: fingerprint(value) for name, value in desired.items()}, indent=2) + "\n").encode()
    return [(path, original, output), (state_path, state_original, state)]


def write_plan(plan, dry_run):
    # Preflight every target before touching any file.
    for path, original, output in plan:
        actual = path.read_bytes() if path.exists() else None
        if actual != original:
            raise ValueError(f"File changed during sync; run again: {path}")
    for path, original, output in plan:
        if original == output:
            continue
        print(f"{'Would update' if dry_run else 'Updating'}: {path}")
        if dry_run:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if original is not None:
            backup = path.with_name(path.name + ".bak-skill-source-mcp-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
            fd = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(original)
        fd, temporary = tempfile.mkstemp(prefix=".sync-mcp-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(output)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=REPO / "mcp/servers.json")
    parser.add_argument("--windows-home", type=Path)
    parser.add_argument("--wsl-home", type=Path, default=Path.home())
    parser.add_argument("--target", choices=("windows", "wsl"), action="append")
    parser.add_argument("--dry-run", action="store_true", help="Validate and preview without writing")
    parser.add_argument("--adopt", action="store_true", help="Replace same-name entries and local edits after review")
    args = parser.parse_args()
    win_home = args.windows_home
    if win_home is None:
        if os.name == "nt":
            win_home = Path.home()
        else:
            win_home = next((p for p in REPO.parents if p.parent.name.lower() == "users"), None)
    targets = args.target or (["windows", "wsl"] if win_home and os.name != "nt" else ["windows"] if os.name == "nt" else ["wsl"])
    if "windows" in targets and (win_home is None or not win_home.is_dir()):
        parser.error("Windows home not found; supply --windows-home")
    if "wsl" in targets and os.name == "nt":
        parser.error("Use sync-mcp.ps1 to sync WSL from Windows")
    registry = read_json(args.registry)
    if set(registry) != {"servers"} or not isinstance(registry["servers"], dict):
        raise ValueError("Registry must contain a servers object")
    plan = []
    for platform in dict.fromkeys(targets):
        servers = render_servers(registry["servers"], platform, win_home or "")
        destinations = [(args.wsl_home / ".codex/config.toml", "codex")]
        if platform == "windows":
            destinations = [(win_home / ".claude.json", "claude"),
                            (win_home / "AppData/Roaming/Code/User/mcp.json", "vscode"),
                            (win_home / ".codex/config.toml", "codex")]
        for path, client in destinations:
            plan.extend(plan_target(path, client, client_servers(servers, client), args.adopt))
    write_plan(plan, args.dry_run)
    print("Preview complete; no files written." if args.dry_run else "MCP sync complete. Restart clients to load changes.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError) as error:
        # JSON/TOML values can include credentials; report locations, never document contents.
        if isinstance(error, (json.JSONDecodeError, tomllib.TOMLDecodeError)):
            print("Error: invalid JSON/TOML; no changes applied. Check the registry and client configs.", file=sys.stderr)
        elif isinstance(error, OSError):
            print(f"Error: {error.strerror}: {error.filename}", file=sys.stderr)
        else:
            print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
