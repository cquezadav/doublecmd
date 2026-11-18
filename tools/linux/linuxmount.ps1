# Linux partitions on Windows for Double Commander (my-custom).
#
#   linuxmount.ps1 list                               -> JSON: prerequisites + every Linux partition
#   linuxmount.ps1 mount -Disk 8 -Partition 2 [-ReadWrite] [-Letter R:]
#   linuxmount.ps1 unmount -Disk 8 [-Partition 2]
#
# list is fast (partition table only, no admin, does not start WSL).
# mount: WSL2 attaches the partition (one admin prompt), a hidden
#   "sleep infinity" keeps WSL running, rclone shows the folder as a drive
#   letter through WinFsp. Read-only unless -ReadWrite.
# unmount: stops the drive letter and detaches the disk (other mounted disks are
#   re-attached in the same admin prompt; WSL can only reliably release all).
# State of our mounts: %LOCALAPPDATA%\doublecmd-linuxmount\mounts.json
# Prints one JSON object; exit code 0 = ok.
param(
  [Parameter(Position = 0)][ValidateSet('list', 'mount', 'unmount')][string]$Action = 'list',
  [int]$Disk = -1,
  [int]$Partition = -1,
  [switch]$ReadWrite,
  [string]$Letter = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# GPT partition types WSL can mount (ext2/3/4, btrfs, xfs ... live in these)
$Mountable = @{
  '{0fc63daf-8483-4772-8e79-3d69d8477de4}' = 'Linux data'
  '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}' = 'Linux root (x86-64)'
  '{44479540-f297-41b2-9af7-d131d5f0458a}' = 'Linux root (x86)'
  '{b921b045-1df0-41c3-af44-4c6f280d3fae}' = 'Linux root (ARM64)'
  '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}' = 'Linux home'
  '{3b8f8425-20e0-4f3b-907f-1a25a76f98e8}' = 'Linux server data'
  '{bc13c2ff-59e6-4262-a352-b275fd6f7172}' = 'Linux boot (XBOOTLDR)'
}
$NotMountable = @{
  '{0657fd6d-a4ab-43c4-84e5-0933c84b4f4f}' = 'Linux swap'
  '{e6d6d379-f507-44c2-a23c-238f2a3df928}' = 'Linux LVM (not supported)'
  '{a19d880f-05fc-4d3b-a006-743f0f84911e}' = 'Linux RAID (not supported)'
  '{ca7d7ccb-63ed-4c53-861c-1742536059cc}' = 'LUKS encrypted (not supported)'
}

function Out-Json($obj, [int]$code = 0) {
  $obj | ConvertTo-Json -Depth 5 -Compress
  exit $code
}

function Get-Rclone {
  $c = (Get-Command rclone -ErrorAction SilentlyContinue).Source
  if ($c) { return $c }
  Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Rclone.Rclone*" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}

function Get-Distro {
  # First real distro (not docker-desktop*). wsl.exe -l -q prints UTF-16.
  $old = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::Unicode
  try { $names = & wsl.exe -l -q 2>$null } catch { $names = @() } finally { [Console]::OutputEncoding = $old }
  $names | ForEach-Object { $_.Trim([char]0, ' ') } | Where-Object { $_ -and $_ -notlike 'docker-desktop*' } | Select-Object -First 1
}

function Get-Prereqs {
  $wsl = Test-Path "$env:WINDIR\System32\wsl.exe"
  $distro = if ($wsl) { Get-Distro } else { $null }
  $rclone = Get-Rclone
  $winfsp = Test-Path "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll"
  $missing = @()
  if (-not $wsl) { $missing += 'WSL (run: wsl --install)' }
  elseif (-not $distro) { $missing += 'a WSL Linux distro (run: wsl --install -d Ubuntu)' }
  if (-not $rclone) { $missing += 'rclone (winget install Rclone.Rclone)' }
  if (-not $winfsp) { $missing += 'WinFsp (winget install WinFsp.WinFsp)' }
  [ordered]@{ ok = ($missing.Count -eq 0); missing = $missing; distro = $distro; rclone = $rclone }
}

function Get-MountedLetters {
  # rclone mounts we created: "...\PHYSICALDRIVE<n>p<p>" X:
  $map = @{}
  Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -match 'PHYSICALDRIVE(\d+)p(\d+)\S*\s+([A-Z]:)') { $map["$($Matches[1])-$($Matches[2])"] = $Matches[3] }
  }
  $map
}

function Get-LinuxPartitions {
  $mounted = Get-MountedLetters
  $st = @{}; foreach ($e in Get-State) { $st["$($e.disk)-$($e.partition)"] = $e }
  $systemDisks = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.IsBoot -or $_.IsSystem } | Select-Object -ExpandProperty DiskNumber -Unique)
  $list = @()
  foreach ($d in Get-Disk) {
    foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
      $type = $null; $ok = $false; $reason = ''
      $gpt = "$($p.GptType)".ToLower()
      if ($gpt -and $Mountable.ContainsKey($gpt)) { $type = $Mountable[$gpt]; $ok = $true }
      elseif ($gpt -and $NotMountable.ContainsKey($gpt)) { $type = $NotMountable[$gpt]; $reason = $type }
      elseif ($p.MbrType -eq 131) { $type = 'Linux (MBR)'; $ok = $true }
      elseif ($p.MbrType -eq 130) { $type = 'Linux swap (MBR)'; $reason = 'swap' }
      elseif ($p.MbrType -eq 142) { $type = 'Linux LVM (MBR)'; $reason = 'LVM not supported' }
      else { continue }
      if ($ok -and ($systemDisks -contains $d.Number)) { $ok = $false; $reason = 'on the Windows system disk' }
      $key = "$($d.Number)-$($p.PartitionNumber)"
      # WSL takes the whole disk: Windows drive letters on it disappear while mounted
      $hides = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                 Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
                 ForEach-Object { "$($_.DriveLetter):" })
      $list += [ordered]@{
        disk = $d.Number; partition = $p.PartitionNumber
        disk_name = "$($d.FriendlyName)".Trim(); size_gb = [math]::Round($p.Size / 1GB, 1)
        type = $type; mountable = $ok; reason = $reason
        letter = $(if ($mounted.ContainsKey($key)) { $mounted[$key] } else { '' })
        hides = $(if ($st.ContainsKey($key)) { "$($st[$key].hides)" } else { $hides -join ' ' })
        label = $(if ($st.ContainsKey($key)) { "$($st[$key].label)" } else { '' })
      }
    }
  }
  $list
}

function Get-FreeLetter {
  $used = @((Get-PSDrive -PSProvider FileSystem).Name) + @(Get-CimInstance Win32_LogicalDisk | ForEach-Object { $_.DeviceID.TrimEnd(':') })
  # R first (Retro), then from Z backwards; skip M (Wii SD card) and V (reserved for S3)
  foreach ($l in @('R') + @('Z','Y','U','T','S','Q','P','N')) { if ($used -notcontains $l) { return "${l}:" } }
  throw 'No free drive letter.'
}

function Invoke-Elevated([string[]]$Commands) {
  # Runs a chain of commands in ONE elevated cmd (one admin prompt) and captures
  # wsl's messages. Each item is a full command line ("wsl --unmount", ...).
  $log = Join-Path $env:TEMP ("linuxmount-{0}.txt" -f [guid]::NewGuid().ToString('N'))
  $parts = foreach ($c in $Commands) {
    if ($c -like 'wsl *' -or $c -like '(*wsl *') { "$c >> `"$log`" 2>&1" } else { "$c >nul 2>&1" }
  }
  try {
    $p = Start-Process cmd.exe -ArgumentList '/c', ($parts -join ' & ') -Verb RunAs -Wait -PassThru -WindowStyle Hidden
  } catch {
    return @{ code = -2; text = 'The admin prompt was cancelled.' }
  }
  $text = ''
  if (Test-Path $log) {
    $text = ([IO.File]::ReadAllText($log, [Text.Encoding]::Unicode) -replace "`0", '').Trim()
    if ($text -notmatch '[a-zA-Z]{3}') { $text = ([IO.File]::ReadAllText($log) -replace "`0", '').Trim() }
    Remove-Item $log -ErrorAction SilentlyContinue
  }
  $text = ($text -split "`r?`n" | Where-Object { $_ -and $_ -notmatch 'github.com/microsoft/WSL|completed successfully' }) -join ' '
  return @{ code = $p.ExitCode; text = $text }
}

function Get-AttachedInWsl([string]$Distro) {
  # names like PHYSICALDRIVE8p2 currently mounted inside WSL (does not need admin)
  try {
    $ErrorActionPreference = 'Continue'
    @(& wsl.exe -d $Distro -e sh -c 'ls /mnt/wsl 2>/dev/null' 2>$null | Where-Object { $_ -like 'PHYSICALDRIVE*' })
  } finally { $ErrorActionPreference = 'Stop' }
}

# ---- state: what we mounted, so one disk can be released without losing the others
$StateDir = Join-Path $env:LOCALAPPDATA 'doublecmd-linuxmount'
$StateFile = Join-Path $StateDir 'mounts.json'

function Get-State {
  if (-not (Test-Path $StateFile)) { return @() }
  try { @((Get-Content $StateFile -Raw | ConvertFrom-Json)) | Where-Object { $_ } } catch { @() }
}

function Save-State($entries) {
  New-Item -ItemType Directory -Force $StateDir | Out-Null
  $arr = @($entries | Where-Object { $_ })
  if ($arr.Count -eq 0) { Set-Content $StateFile '[]' -Encoding UTF8; return }
  ConvertTo-Json -InputObject $arr -Depth 4 | Set-Content $StateFile -Encoding UTF8
}

function Get-LiveState([string]$Distro) {
  # Only entries whose partition is really attached in WSL right now.
  $att = Get-AttachedInWsl $Distro
  @(Get-State | Where-Object { $att -contains "PHYSICALDRIVE$($_.disk)p$($_.partition)" })
}

function Get-AttachCommands($e, [switch]$AfterRelease) {
  # fsutil: Windows must let go of other volumes on that disk (O:, J: ...) or WSL
  # fails with ERROR_DRIVE_LOCKED. They come back on their own after release.
  # After "wsl --unmount" Windows needs a moment to bring the disk back online
  # (and re-opens its volumes), so wait first and retry the mount once.
  $dismount = (@("$($e.hides)" -split ' ' | Where-Object { $_ -match '^[A-Z]:$' }) | ForEach-Object { "fsutil volume dismount $_ >nul 2>&1" }) -join ' & '
  $mount = "wsl --mount \\.\PHYSICALDRIVE$($e.disk) --partition $($e.partition)"
  if (-not $e.readwrite) { $mount += ' --options ro' }
  $wait = 'ping -n 4 127.0.0.1'
  $step = if ($dismount) { "$dismount & $mount" } else { $mount }
  $cmds = @()
  if ($AfterRelease) { $cmds += $wait }
  $cmds += "($step || ($wait >nul & $step))"
  $cmds
}

function Stop-KeepAlive {
  Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -like '*sleep infinity*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

function Start-KeepAlive([string]$Distro) {
  $alive = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -like '*sleep infinity*' }
  if (-not $alive) {
    Start-Process wsl.exe -ArgumentList '-d', $Distro, '--', 'sleep', 'infinity' -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
  }
}

function Stop-Letter($e) {
  Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "PHYSICALDRIVE$($e.disk)p$($e.partition)\b" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

function Start-Letter($e, [string]$Distro, [string]$Rclone) {
  $mnt = "PHYSICALDRIVE$($e.disk)p$($e.partition)"
  $unc = "\\wsl.localhost\$Distro\mnt\wsl\$mnt"
  for ($i = 0; $i -lt 20 -and -not (Test-Path $unc); $i++) { Start-Sleep -Milliseconds 300 }
  if (-not (Test-Path $unc)) { throw "Mounted in WSL but not visible at $unc" }
  New-Item -ItemType Directory -Force $StateDir | Out-Null
  $rargs = @('mount', "`"$unc`"", $e.letter, '--volname', "`"$($e.label)`"", '--dir-cache-time', '1m',
             '--log-file', "`"$(Join-Path $StateDir "$mnt.log")`"", '--log-level', 'NOTICE')
  if ($e.readwrite) { $rargs += @('--vfs-cache-mode', 'writes') } else { $rargs += '--read-only' }
  Start-Process $Rclone -ArgumentList $rargs -WindowStyle Hidden
  for ($i = 0; $i -lt 30 -and -not (Test-Path "$($e.letter)\"); $i++) { Start-Sleep -Milliseconds 300 }
  if (-not (Test-Path "$($e.letter)\")) { throw "rclone did not create $($e.letter) (see $StateDir)" }
}

function Get-SmartLabel([string]$Distro, [string]$Mnt, [double]$SizeGb) {
  # "SHARE" etc. say nothing; name it after what is on it, plus the size.
  $size = if ($SizeGb -ge 1000) { '{0:0.#}T' -f ($SizeGb / 1024) } else { '{0:0}G' -f $SizeGb }
  $probe = 'd=/mnt/wsl/' + $Mnt + '; ' +
    'if [ -f $d/system/batocera.conf ] || { [ -d $d/roms ] && [ -d $d/bios ] && [ -d $d/system ]; }; then echo Batocera; ' +
    'elif [ -f $d/system/recalbox.conf ]; then echo Recalbox; ' +
    'elif [ -d $d/RetroPie ] || [ -d $d/home/pi/RetroPie ]; then echo RetroPie; ' +
    'elif [ -f $d/etc/os-release ]; then . $d/etc/os-release 2>/dev/null; echo "${NAME:-Linux}"; ' +
    'else echo; fi; lsblk -no LABEL $(findmnt -no SOURCE $d) 2>/dev/null'
  # -e runs sh directly, so the probe reaches it unchanged; any failure just
  # means a plain name.
  $out = @()
  try {
    $ErrorActionPreference = 'Continue'
    $out = @(& wsl.exe -d $Distro -e sh -c $probe 2>$null)
  } catch { $out = @() } finally { $ErrorActionPreference = 'Stop' }
  $kind = "$($out | Select-Object -First 1)".Trim()
  $fsLabel = "$($out | Select-Object -Skip 1 -First 1)".Trim()
  $generic = @('', 'SHARE', 'DATA', 'ROOT', 'ROOTFS', 'LINUX', 'USERDATA', 'STORAGE', 'DISK')
  if ($kind) { $name = $kind }
  elseif ($generic -notcontains $fsLabel.ToUpper()) { $name = $fsLabel }
  else { $name = 'Linux' }
  $name = ($name -replace '[^\w\- ]', '').Trim()
  if ($name.Length -gt 10) { $name = $name.Substring(0, 10).Trim() }
  "$name $size"
}

try {
  switch ($Action) {
    'list' {
      Out-Json ([ordered]@{ ok = $true; prereqs = (Get-Prereqs); partitions = @(Get-LinuxPartitions) })
    }

    'mount' {
      if ($Disk -lt 0 -or $Partition -lt 0) { throw 'mount needs -Disk and -Partition' }
      $pre = Get-Prereqs
      if (-not $pre.ok) { throw ('Missing: ' + ($pre.missing -join ', ')) }
      $part = Get-LinuxPartitions | Where-Object { $_.disk -eq $Disk -and $_.partition -eq $Partition }
      if (-not $part) { throw "Disk $Disk partition $Partition is not a Linux partition." }
      if (-not $part.mountable) { throw "Cannot mount: $($part.reason)" }
      if ($part.letter) { Out-Json ([ordered]@{ ok = $true; letter = $part.letter; already = $true }) }
      $distro = $pre.distro
      $mnt = "PHYSICALDRIVE${Disk}p$Partition"
      $state = @(Get-LiveState $distro | Where-Object { -not ($_.disk -eq $Disk -and $_.partition -eq $Partition) })

      $entry = [pscustomobject]@{
        disk = $Disk; partition = $Partition; readwrite = [bool]$ReadWrite
        letter = $(if ($Letter) { $Letter } else { Get-FreeLetter }); label = ''
        hides = "$($part.hides)"; size_gb = $part.size_gb; disk_name = $part.disk_name
      }

      # 1. attach (one admin prompt). If WSL still holds this disk (stale), start
      #    from a clean slate: release all, re-attach the others we track.
      $cmds = @()
      if (@(Get-AttachedInWsl $distro | Where-Object { $_ -like "PHYSICALDRIVE${Disk}p*" }).Count -gt 0) {
        $cmds += 'wsl --unmount'
        foreach ($o in $state) { Stop-Letter $o; $cmds += Get-AttachCommands $o -AfterRelease }
      }
      $cmds += Get-AttachCommands $entry
      $r = Invoke-Elevated $cmds
      if (@(Get-AttachedInWsl $distro | Where-Object { $_ -eq $mnt }).Count -eq 0) {
        throw "WSL could not mount it: $($r.text)"
      }
      Start-KeepAlive $distro

      # 2. name + drive letter
      try { $entry.label = Get-SmartLabel $distro $mnt $part.size_gb }
      catch { $entry.label = 'Linux {0:0}G' -f $part.size_gb }
      Start-Letter $entry $distro $pre.rclone
      if ($cmds[0] -eq 'wsl --unmount') { foreach ($o in $state) { try { Start-Letter $o $distro $pre.rclone } catch {} } }
      Save-State (@($state) + $entry)
      Out-Json ([ordered]@{ ok = $true; letter = $entry.letter; label = $entry.label; readwrite = [bool]$ReadWrite })
    }

    'unmount' {
      if ($Disk -lt 0) { throw 'unmount needs -Disk' }
      $pre = Get-Prereqs
      $distro = $pre.distro
      $state = @(Get-LiveState $distro)
      $gone = @($state | Where-Object { $_.disk -eq $Disk })
      $keep = @($state | Where-Object { $_.disk -ne $Disk })
      $hides = @($gone | ForEach-Object { "$($_.hides)" -split ' ' } | Where-Object { $_ })

      # "wsl --unmount \.\PHYSICALDRIVEn" fails with Wsl/ERROR_INVALID_FUNCTION,
      # the plain "wsl --unmount" (all disks) works. So: release everything and
      # re-attach the disks that should stay, in the same admin prompt.
      foreach ($e in $state) { Stop-Letter $e }
      Start-Sleep -Milliseconds 800
      $cmds = @('wsl --unmount')
      foreach ($e in $keep) { $cmds += Get-AttachCommands $e -AfterRelease }
      $r = Invoke-Elevated $cmds
      if ($r.code -eq -2) {
        foreach ($e in $state) { try { Start-Letter $e $distro $pre.rclone } catch {} }
        throw $r.text
      }

      $att = Get-AttachedInWsl $distro
      $still = @($att | Where-Object { $_ -like "PHYSICALDRIVE${Disk}p*" })
      $lost = @()
      foreach ($e in $keep) {
        if ($att -contains "PHYSICALDRIVE$($e.disk)p$($e.partition)") {
          try { Start-Letter $e $distro $pre.rclone } catch { $lost += "$($e.letter) $($e.label)" }
        } else { $lost += "$($e.letter) $($e.label)" }
      }
      $keep = @($keep | Where-Object { $lost -notcontains "$($_.letter) $($_.label)" })
      Save-State $keep
      if ($keep.Count -eq 0) { Stop-KeepAlive }
      if ($still.Count -gt 0) { throw "WSL could not release the disk: $($r.text) (try: wsl --shutdown)" }

      # wait until Windows shows the disk's own drive letters again (O:, J: ...)
      for ($i = 0; $i -lt 30; $i++) {
        if (@($hides | Where-Object { -not (Test-Path "$_\") }).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
      }
      $back = if ($hides.Count) { ' ' + ($hides -join ' ') + ' back.' } else { '' }
      if ($lost.Count) {
        Out-Json ([ordered]@{ ok = $false; disk = $Disk; error = "Released (safe to unplug), but could not keep $($lost -join ', ') mounted: $($r.text). Mount it again from the menu." })
      }
      Out-Json ([ordered]@{ ok = $true; disk = $Disk; message = "Released. Safe to unplug.$back" })
    }
  }
} catch {
  Out-Json ([ordered]@{ ok = $false; error = $_.Exception.Message }) 1
}