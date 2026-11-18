# rclone copy / move / sync / compare

Right-click files (or use the commands below) to copy or move them to the other
panel with [rclone](https://rclone.org). It works the same on Windows, macOS and
Linux. The built-in copy (F5) and move (F6) are unchanged; this is an extra option.

| Menu item | Command | What it does |
|---|---|---|
| Copy to other panel (verified) | `cm_RcloneCopy` | Copies the selected items. It skips files that are already identical and checks each copied file against the original. |
| Move to other panel (verified) | `cm_RcloneMove` | Same as copy, then removes the originals and the emptied folders. |
| Sync folder to other panel... | `cm_RcloneSync` | Makes B an exact copy of A. It first lists what it would copy and **delete**, then asks before doing anything. |
| Compare with other panel (checksums) | `cm_RcloneCheck` | Lists files that are the same, different, or only on one side. It changes nothing. |

**Which folders it uses (sync and compare):** if the cursor is on a folder, A is
that folder and B is the folder with the same name in the other panel.
Otherwise, A is the current folder and B is the other panel's folder.

Copy and move run in a progress window. Click **Stop** to stop; running the
same command again continues where it stopped.

## Mounted cloud drives

When either side is a mounted cloud drive, rclone talks to the cloud service
directly instead of going through the mounted drive's local cache. That is
faster, and it finishes only when the files are really uploaded. Tell it which
drive belongs to which remote in `<config dir>/rclone.json`:

```json
{
  "rclone": "",
  "mounts": {
    "X:\\": "gdrive:",
    "W:\\": "onedrive:"
  }
}
```

On macOS or Linux, use the mount folders, for example
`"/Users/me/GoogleDrive/": "gdrive:"`. Set `"rclone"` to rclone's full path
only if it isn't found automatically. It is looked for on `PATH`, in WinGet and
Program Files on Windows, and in Homebrew, `/usr/local/bin` and `/usr/bin` on
macOS and Linux.

Install rclone: `winget install Rclone.Rclone` on Windows, `brew install rclone`
on macOS, or your package manager on Linux.
