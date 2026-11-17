# Double Commander MCP server

Lets an AI agent drive Double Commander (my-custom build) the way you would:
read both panels, open folders, select files, copy/move/delete through the
normal operations queue, and run any `cm_...` command.

## How it works

1. **Inside Double Commander** (`src/uagentserver.pas`): a JSON-RPC endpoint on
   `127.0.0.1:47811` (next free port up to 47820). Every request needs a random
   token. Port and token are written to `<config dir>/agent/endpoint.json`
   while it runs. Off by default: turn on **Configuration → Agent control (MCP server)**.
2. **This bridge** (`doublecmd_mcp.py`): reads `endpoint.json` and exposes the
   endpoint as MCP tools over stdio.

Safety: deletes go to the recycle bin; `permanent=true` always shows Double
Commander's own confirmation dialog. Every call is logged as an `agent` event
in the metrics log (if that is on).

## Setup

```
pip install "mcp>=2"
```

**Claude Code**

```
claude mcp add --scope user doublecmd -- python /path/to/doublecmd_mcp.py
```

**goose** (open source, works with local Ollama models): Extensions → Add →
Command-line extension, command `python /path/to/doublecmd_mcp.py`.

**opencode** (open source): in `opencode.json`

```json
{ "mcp": { "doublecmd": { "type": "local", "command": ["python", "/path/to/doublecmd_mcp.py"] } } }
```

Set `DOUBLECMD_CONFIG_DIR` if Double Commander runs with `--config-dir`.

## Tools

| Tool | What it does |
|---|---|
| `get_state` | both panels: path, tabs, cursor, selection; active panel; running operations |
| `list_panel` | files in a panel (name, dir, size, modified, selected), paged |
| `navigate` | open a folder / archive / network path in a panel |
| `new_tab`, `set_active_panel` | tabs and focus |
| `select` | select files by name (`set`, `add`, `remove`, `all`, `none`) |
| `copy`, `move` | to `dest` or the other panel, through the operations queue |
| `delete` | to recycle bin (or permanent, with user confirmation) |
| `mkdir`, `rename` | in the panel's current folder |
| `operations` | queue with progress |
| `list_commands`, `run_command` | any Double Commander `cm_...` command |
