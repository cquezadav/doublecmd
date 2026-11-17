"""MCP server that lets an AI agent drive Double Commander.

Double Commander (my-custom build) runs a small control endpoint on
127.0.0.1 when "Configuration > Agent control (MCP server)" is checked. It
writes its port and a random access token to <config dir>/agent/endpoint.json.
This bridge reads that file and exposes the endpoint as MCP tools over stdio,
so any MCP client (Claude Code, Claude Desktop, goose, opencode, ...) can use it.

Config dir lookup order:
  1. env DOUBLECMD_CONFIG_DIR
  2. Windows: %APPDATA%\\doublecmd   macOS: ~/Library/Preferences/doublecmd
     Linux: ~/.config/doublecmd

Requires: pip install "mcp>=2"
"""

from __future__ import annotations

import json
import os
import platform
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

READ_ONLY = ToolAnnotations(readOnlyHint=True, openWorldHint=False)
CHANGES_UI = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)
WRITES_FILES = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
DESTRUCTIVE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False)


def config_dir() -> Path:
    env = os.environ.get("DOUBLECMD_CONFIG_DIR")
    if env:
        return Path(env)
    system = platform.system()
    if system == "Windows":
        return Path(os.environ["APPDATA"]) / "doublecmd"
    if system == "Darwin":
        return Path.home() / "Library" / "Preferences" / "doublecmd"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "doublecmd"


def endpoint() -> dict[str, Any]:
    path = config_dir() / "agent" / "endpoint.json"
    if not path.exists():
        raise RuntimeError(
            "Double Commander's agent control is not running. In Double Commander, "
            "turn on Configuration > Agent control (MCP server). "
            f"(Looked for {path})"
        )
    return json.loads(path.read_text(encoding="utf-8"))


def rpc(method: str, **params: Any) -> Any:
    ep = endpoint()
    body = json.dumps({"method": method, "params": {k: v for k, v in params.items() if v is not None}}).encode()
    req = urllib.request.Request(
        ep["url"],
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {ep['token']}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            reply = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        reply = json.loads(e.read().decode("utf-8") or "{}")
    except urllib.error.URLError as e:
        raise RuntimeError(
            f"Cannot reach Double Commander at {ep['url']} ({e.reason}). "
            "Is it running with Agent control turned on?"
        ) from e
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error", "unknown error"))
    return reply.get("result")


mcp = MCPServer(
    "doublecmd",
    instructions=(
        "Controls the user's Double Commander file manager (two panels: left and right). "
        "Panels are 'left', 'right', 'active' or 'inactive'. Paths can be local "
        "(C:\\..., \\\\server\\share), mounted clouds (X: Google Drive, W: OneDrive) or "
        "anything Double Commander can open. Typical flow: get_state -> navigate -> "
        "list_panel -> select -> copy/move/delete. Copy/move run in Double Commander's "
        "operations queue; check progress with operations(). Delete goes to the recycle "
        "bin unless permanent=true, which always asks the user to confirm in the app. "
        "Navigation loads in the background: if list_panel shows loading=true, call it again."
    ),
)


@mcp.tool(annotations=READ_ONLY)
def get_state() -> Any:
    """Both panels (path, tabs, cursor, selected files), which one is active, and running operations."""
    return rpc("get_state")


@mcp.tool(annotations=READ_ONLY)
def list_panel(panel: str = "active", offset: int = 0, limit: int = 500) -> Any:
    """Files shown in a panel: name, dir, size, modified, selected. Use offset/limit to page."""
    return rpc("list_panel", panel=panel, offset=offset, limit=limit)


@mcp.tool(annotations=CHANGES_UI)
def navigate(path: str, panel: str = "active", activate: bool = False) -> Any:
    """Open a folder (or archive, or network path) in a panel."""
    return rpc("navigate", panel=panel, path=path, activate=activate)


@mcp.tool(annotations=CHANGES_UI)
def new_tab(panel: str = "active", path: str | None = None) -> Any:
    """Open a new tab in a panel, optionally at a path."""
    return rpc("new_tab", panel=panel, path=path)


@mcp.tool(annotations=CHANGES_UI)
def set_active_panel(panel: str) -> Any:
    """Make 'left' or 'right' the active panel."""
    return rpc("set_active_panel", panel=panel)


@mcp.tool(annotations=CHANGES_UI)
def select(
    names: list[str] | None = None,
    mode: str = "set",
    panel: str = "active",
    cursor: str | None = None,
) -> Any:
    """Select files by exact name in a panel.

    mode: 'set' (replace selection), 'add', 'remove', 'all', 'none'.
    cursor: optionally move the cursor to this file name.
    """
    return rpc("select", panel=panel, names=names, mode=mode, cursor=cursor)


@mcp.tool(annotations=WRITES_FILES)
def copy(panel: str = "active", names: list[str] | None = None, dest: str | None = None) -> Any:
    """Copy files from a panel (the given names, else the current selection) to dest
    (default: the other panel's folder). Runs in Double Commander's operations queue."""
    return rpc("copy", panel=panel, names=names, dest=dest)


@mcp.tool(annotations=DESTRUCTIVE)
def move(panel: str = "active", names: list[str] | None = None, dest: str | None = None) -> Any:
    """Move files from a panel (the given names, else the current selection) to dest
    (default: the other panel's folder). Runs in Double Commander's operations queue."""
    return rpc("move", panel=panel, names=names, dest=dest)


@mcp.tool(annotations=DESTRUCTIVE)
def delete(panel: str = "active", names: list[str] | None = None, permanent: bool = False) -> Any:
    """Delete files (the given names, else the selection). Default: to the recycle bin.
    permanent=true shows Double Commander's confirmation dialog to the user."""
    return rpc("delete", panel=panel, names=names, permanent=permanent)


@mcp.tool(annotations=WRITES_FILES)
def mkdir(name: str, panel: str = "active") -> Any:
    """Create a folder inside the panel's current folder."""
    return rpc("mkdir", panel=panel, name=name)


@mcp.tool(annotations=DESTRUCTIVE)
def rename(old_name: str, new_name: str, panel: str = "active") -> Any:
    """Rename a file or folder in the panel's current folder."""
    return rpc("rename", panel=panel, **{"from": old_name, "to": new_name})


@mcp.tool(annotations=READ_ONLY)
def operations() -> Any:
    """Running and queued file operations with progress percentage."""
    return rpc("operations")


@mcp.tool(annotations=READ_ONLY)
def list_commands(filter: str | None = None) -> Any:
    """Double Commander's internal commands (cm_...) with captions; filter by text."""
    return rpc("list_commands", filter=filter)


@mcp.tool(annotations=DESTRUCTIVE)
def run_command(command: str, params: list[str] | None = None) -> Any:
    """Run any Double Commander command, e.g. cm_ViewHistory, cm_CalculateSpace,
    cm_PackFiles, cm_SyncDirs, with optional 'key=value' params. Acts on the active panel."""
    return rpc("run_command", command=command, params=params)


if __name__ == "__main__":
    mcp.run()
