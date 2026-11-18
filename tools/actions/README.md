# Right-click actions

Small scripts wired into Double Commander's right-click menu (via file
associations in `extassoc.xml`, using `%LU` = UTF-8 list of selected files) and
exposed to AI agents through the MCP bridge (`tools/mcp`). Python 3, standard
library only. Settings in `actions.json`.

| Script | Right-click on | What it does |
|---|---|---|
| `send_to_ps4.py` | `.pkg` | Serves the files over HTTP and asks the PS4's Remote Package Installer to install them. One request per package (RPI leaks a thread per request); progress is measured from the bytes served. Keep the window open until 100%. |
| `wii_install.py` | `.rvz .iso .gcm .gcz .wia .ciso .wbfs` | GameCube → `<drive>/games/<Title> [ID]/game.iso` (Nintendont, converted with DolphinTool, ID re-checked); Wii `.wbfs` → `<drive>/wbfs/<Title> [ID]/<ID>.wbfs`. Skips installed games; never changes sources. |

## Double Commander setup

In `extassoc.xml` (or Options → File associations), per file type add an action:

- Command: path to `python`
- Parameters: `"<repo>/tools/actions/send_to_ps4.py" --list %LU`
