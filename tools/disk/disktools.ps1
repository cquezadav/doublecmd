# Disk tools for Double Commander (my-custom): list, check, repair, format and
# partition disks on Windows. Prints one JSON object (last line); exit 0 = ok.
#
#   disktools.ps1 list
#   disktools.ps1 check     -Disk n -Partition p              (read-only scan)
#   disktools.ps1 repair    -Disk n -Partition p
#   disktools.ps1 format    -Disk n -Partition p -FileSystem ntfs|exfat|fat32|udf|ext4|f2fs|btrfs|xfs|hfsplus [-Label L]
#   disktools.ps1 create    -Disk n [-SizeMB m] [-OffsetMB o] -FileSystem fs [-Label L] [-Letter X]
#   disktools.ps1 delete    -Disk n -Partition p
#   disktools.ps1 resize    -Disk n -Partition p -SizeMB m     (NTFS only)
#   disktools.ps1 setletter -Disk n -Partition p -Letter X     (-Letter none = remove)
#   disktools.ps1 setlabel  -Disk n -Partition p -Label L
#   disktools.ps1 initialize -Disk n -Style gpt|mbr            (new / blank disks only)
#   disktools.ps1 wipe      -Disk n -Style gpt|mbr             (erase the partition table)
#
# Everything except "list" needs admin: the script re-runs itself elevated (one
# Windows admin prompt per action). Windows Storage cmdlets do NTFS/exFAT/FAT32
# (<= 32 GB); WSL Linux tools do what Windows can't: FAT32 on big partitions
# (mkfs.vfat), ext4 (mkfs.ext4, e2fsck) and FAT checks (fsck.vfat).
# Safety: the disk holding Windows (boot/system) is never changed, only checked.
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'check', 'repair', 'format', 'create', 'delete', 'resize', 'setletter', 'setlabel', 'initialize', 'wipe')]
  [string]$Action = 'list',
  [int]$Disk = -1,
  [int]$Partition = -1,
  [string]$FileSystem = '',
  [string]$Label = '',
  [string]$Letter = '',
  [long]$SizeMB = 0,
  [long]$OffsetMB = 0,
  [string]$Style = 'gpt',
  [string]$ResultFile = '',
  [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$GPT_BASIC = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$GPT_LINUX = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
$GptNames = @{
  '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' = 'Basic data'
  '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' = 'EFI system'
  '{48465300-0000-11aa-aa11-00306543ecac}' = 'Apple HFS+'
  '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' = 'Microsoft reserved'
  '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' = 'Windows recovery'
  '{0fc63daf-8483-4772-8e79-3d69d8477de4}' = 'Linux data'
  '{0657fd6d-a4ab-43c4-84e5-0933c84b4f4f}' = 'Linux swap'
  '{e6d6d379-f507-44c2-a23c-238f2a3df928}' = 'Linux LVM'
  '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}' = 'Linux root'
  '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}' = 'Linux home'
}

$LogFile = Join-Path $env:LOCALAPPDATA 'doublecmd-disktools\log.txt'
function Write-Log([string]$m) {
  try {
    New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
    Add-Content $LogFile ("{0} [{1}] {2}" -f (Get-Date -Format 's'), $(if ($Elevated) { 'admin' } else { 'user' }), $m)
  } catch {}
}

function Out-Json($obj, [int]$code = 0) {
  $json = $obj | ConvertTo-Json -Depth 6 -Compress
  if ($Action -ne 'list') { Write-Log "$Action disk=$Disk part=$Partition fs=$FileSystem -> $json" }
  if ($ResultFile) { [IO.File]::WriteAllText($ResultFile, $json, [Text.UTF8Encoding]::new($false)) }
  $json
  exit $code
}

function Get-SystemDisks {
  @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.IsBoot -or $_.IsSystem } |
    Select-Object -ExpandProperty DiskNumber -Unique)
}

function Get-LinuxMounted {
  # disks with Linux partitions mounted through linuxmount.ps1 (must not be touched)
  $f = Join-Path $env:LOCALAPPDATA 'doublecmd-linuxmount\mounts.json'
  if (-not (Test-Path $f)) { return @() }
  try { @((Get-Content $f -Raw | ConvertFrom-Json) | ForEach-Object { [int]$_.disk }) } catch { @() }
}

function Get-DiskList {
  $system = Get-SystemDisks
  $linux = Get-LinuxMounted
  $vols = @{}
  foreach ($v in Get-Volume -ErrorAction SilentlyContinue) {
    if ($v.DriveLetter) { $vols["$($v.DriveLetter)"] = $v }
  }
  $out = @()
  $drives = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)
  foreach ($d in (Get-Disk | Sort-Object Number)) {
    $parts = @()
    $plist = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset)
    $cursor = [long]1MB   # first usable byte (alignment / protective area)
    if ($d.PartitionStyle -eq 'GPT') { $cursor = [long]17408 }
    foreach ($p in $plist) {
      $gap = [long]$p.Offset - $cursor
      if ($gap -ge 16MB) {
        $parts += [ordered]@{ kind = 'free'; offset_mb = [math]::Ceiling($cursor / 1MB); size_mb = [math]::Floor($gap / 1MB) }
      }
      $letter = if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { "$($p.DriveLetter)" } else { '' }
      $v = if ($letter -and $vols.ContainsKey($letter)) { $vols[$letter] } else { $null }
      $gpt = "$($p.GptType)".ToLower()
      $type = if ($gpt -and $GptNames.ContainsKey($gpt)) { $GptNames[$gpt] } elseif ($gpt) { $gpt } else { 'MBR 0x{0:X2}' -f [int]$p.MbrType }
      $fs = if ($v) { "$($v.FileSystemType)" } elseif ($gpt -eq $GPT_LINUX -or $p.MbrType -eq 131) { 'Linux' } else { '' }
      $parts += [ordered]@{
        kind = 'partition'; number = $p.PartitionNumber
        offset_mb = [math]::Floor($p.Offset / 1MB); size_mb = [math]::Floor($p.Size / 1MB)
        letter = $letter; type = $type; fs = $fs
        label = $(if ($v) { "$($v.FileSystemLabel)" } else { '' })
        free_mb = $(if ($v) { [math]::Floor($v.SizeRemaining / 1MB) } else { $null })
        health = $(if ($v) { "$($v.HealthStatus)" } else { '' })
        system = [bool]($p.IsBoot -or $p.IsSystem); hidden = [bool]$p.IsHidden
      }
      $cursor = [long]$p.Offset + [long]$p.Size
    }
    $end = [long]$d.Size - $(if ($d.PartitionStyle -eq 'GPT') { 17408 } else { 0 })
    if (($end - $cursor) -ge 16MB -and $d.PartitionStyle -ne 'RAW') {
      $parts += [ordered]@{ kind = 'free'; offset_mb = [math]::Ceiling($cursor / 1MB); size_mb = [math]::Floor(($end - $cursor) / 1MB) }
    }
    $locked = ''
    if ($system -contains $d.Number) { $locked = 'Windows runs from this disk: checking only' }
    elseif ($linux -contains $d.Number) { $locked = 'A Linux partition of this disk is mounted: unmount it first' }
    elseif ($d.Size -eq 0) { $locked = 'No media (empty card reader slot)' }
    elseif ($d.IsOffline) { $locked = 'Disk is offline (in use by WSL or another tool)' }
    $dd = $drives | Where-Object { $_.Index -eq $d.Number } | Select-Object -First 1
    $out += [ordered]@{
      removable = [bool]($dd -and "$($dd.MediaType)" -like 'Removable*')
      disk = $d.Number; name = "$($d.FriendlyName)".Trim(); bus = "$($d.BusType)"
      size_mb = [math]::Floor($d.Size / 1MB); style = "$($d.PartitionStyle)"
      locked = $locked; parts = $parts
    }
  }
  $out
}

# ---------- helpers for actions (elevated) ----------

function Assert-Changeable([int]$n) {
  if ((Get-SystemDisks) -contains $n) { throw 'Windows runs from this disk. It can only be checked.' }
  if ((Get-LinuxMounted) -contains $n) { throw 'A Linux partition of this disk is mounted. Unmount it first.' }
}

function Get-Part([int]$n, [int]$p) {
  $part = Get-Partition -DiskNumber $n -PartitionNumber $p -ErrorAction SilentlyContinue
  if (-not $part) { throw "Disk $n has no partition $p." }
  $part
}

function Get-Distro {
  $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::Unicode
  try { $names = & wsl.exe -l -q 2>$null } catch { $names = @() } finally { [Console]::OutputEncoding = $old }
  $d = $names | ForEach-Object { $_.Trim([char]0, ' ') } | Where-Object { $_ -and $_ -notlike 'docker-desktop*' } | Select-Object -First 1
  if (-not $d) { throw 'This needs WSL with a Linux distro (wsl --install -d Ubuntu).' }
  $d
}

function Invoke-Wsl([string]$Distro, [string]$Script) {
  # Run a shell script as root inside WSL. The script goes through a temp file
  # (LF line endings), so no Windows command-line quoting can mangle it.
  $tmp = Join-Path $env:TEMP ("disktools-{0}.sh" -f [guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($tmp, ($Script -replace "`r", '') + "`n", [Text.UTF8Encoding]::new($false))
  $drive = $tmp.Substring(0, 1).ToLower()
  $lin = "/mnt/$drive" + $tmp.Substring(2).Replace('\', '/')
  $ErrorActionPreference = 'Continue'
  $out = & wsl.exe -d $Distro -u root -e sh $lin 2>&1 | ForEach-Object { "$_" -replace "`0", '' }
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  Remove-Item $tmp -ErrorAction SilentlyContinue
  @{ code = $code; text = (($out | Where-Object { $_ }) -join "`n") }
}

function Test-Removable([int]$n) {
  # SD card readers and USB sticks report "Removable Media"; WSL can't attach them
  # with "wsl --mount", so they go through usbipd (USB pass-through) instead.
  $dd = Get-CimInstance Win32_DiskDrive -Filter "Index=$n" -ErrorAction SilentlyContinue
  return ($dd -and "$($dd.MediaType)" -like 'Removable*')
}

function Get-Usbipd {
  $c = "$env:ProgramFiles\usbipd-win\usbipd.exe"
  if (Test-Path $c) { return $c }
  (Get-Command usbipd -ErrorAction SilentlyContinue).Source
}

function Get-UsbBusId([int]$n) {
  # Windows disk -> its USB device -> usbipd bus id (e.g. 1-25)
  $dd = Get-CimInstance Win32_DiskDrive -Filter "Index=$n" -ErrorAction SilentlyContinue
  if (-not $dd) { return $null }
  $parent = (Get-PnpDeviceProperty -InstanceId $dd.PNPDeviceID -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data
  if (-not $parent) { return $null }
  $state = & (Get-Usbipd) state 2>$null | ConvertFrom-Json
  ($state.Devices | Where-Object { $_.InstanceId -eq $parent -and $_.BusId } | Select-Object -First 1).BusId
}

function Find-WslDev([string]$Distro, [long]$Size) {
  # the disk inside WSL with exactly this size (bytes)
  for ($i = 0; $i -lt 15; $i++) {
    $r = Invoke-Wsl $Distro ("lsblk -b -dn -o NAME,SIZE | awk '`$2==" + $Size + " {print `$1}' | head -1")
    $dev = "$($r.text)".Trim()
    if ($r.code -eq 0 -and $dev -match '^[a-z0-9]+$') { return $dev }
    Start-Sleep -Seconds 1
  }
  throw 'Could not find the disk inside Linux (WSL).'
}

function Use-LinuxDevice([int]$n, [scriptblock]$Body) {
  # Give the disk to Linux (WSL) without mounting it, run Body($distro, '/dev/sdX'),
  # give it back. Fixed disks: "wsl --mount --bare". SD cards / USB sticks: usbipd.
  # (variable names here must not clash with the caller's: Body reads $p, $fs,
  #  $label, $Fix from the caller through PowerShell's dynamic scoping)
  $distro = Get-Distro
  $disk = Get-Disk -Number $n
  if (Test-Removable $n) {
    $usb = Get-Usbipd
    if (-not $usb) { throw 'SD cards / USB sticks need usbipd-win for Linux formats (winget install dorssel.usbipd-win).' }
    $bus = Get-UsbBusId $n
    if (-not $bus) { throw 'Could not find this card reader / stick among the USB devices.' }
    $alive = Start-Process wsl.exe -ArgumentList '-d', $distro, '--', 'sleep', '3600' -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $ErrorActionPreference = 'Continue'
    & $usb bind --busid $bus 2>&1 | Out-Null
    $att = & $usb attach --wsl --busid $bus 2>&1 | ForEach-Object { "$_" }
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    try {
      if (-not $ok) { throw "usbipd could not pass the device to Linux: $($att -join ' ')" }
      $dev = Find-WslDev $distro $disk.Size
      & $Body $distro "/dev/$dev"
    } finally {
      $ErrorActionPreference = 'Continue'
      & $usb detach --busid $bus 2>&1 | Out-Null
      # the device re-connects to Windows; unbind once it is back (retry)
      for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        & $usb unbind --busid $bus 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
      }
      $ErrorActionPreference = 'Stop'
      Stop-Process -Id $alive.Id -ErrorAction SilentlyContinue
      Update-HostStorageCache -ErrorAction SilentlyContinue
    }
    return
  }

  if ((Get-LinuxMounted).Count -gt 0) {
    throw 'Unmount the Linux partitions first (WSL can only release all disks at once).'
  }
  foreach ($winPart in (Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)) {
    if ($winPart.DriveLetter -and $winPart.DriveLetter -ne [char]0) { & fsutil volume dismount "$($winPart.DriveLetter):" 2>&1 | Out-Null }
  }
  # Windows (Explorer, Defender, indexing) keeps new volumes open; taking the
  # disk offline closes every handle so WSL can attach it. Retry a few times.
  Set-Disk -Number $n -IsOffline $true -ErrorAction SilentlyContinue
  $attached = $false; $msg = ''
  for ($try = 0; $try -lt 4 -and -not $attached; $try++) {
    if ($try) { Start-Sleep -Seconds 2 }
    $ErrorActionPreference = 'Continue'
    $att = & wsl.exe --mount "\\.\PHYSICALDRIVE$n" --bare 2>&1
    $attached = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    $msg = (($att | ForEach-Object { "$_" -replace "`0", '' }) | Where-Object { $_ -and $_ -notmatch 'github.com' }) -join ' '
  }
  if (-not $attached) {
    Set-Disk -Number $n -IsOffline $false -ErrorAction SilentlyContinue
    throw "WSL could not attach the disk: $msg"
  }
  try {
    $dev = Find-WslDev $distro $disk.Size
    & $Body $distro "/dev/$dev"
  } finally {
    & wsl.exe --unmount 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Set-Disk -Number $n -IsOffline $false -ErrorAction SilentlyContinue
    Update-HostStorageCache -ErrorAction SilentlyContinue
  }
}

function Get-Fat32Format {
  $c = (Get-Command fat32format -ErrorAction SilentlyContinue).Source
  if ($c) { return $c }
  Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Ridgecrop.fat32format*" -Recurse -Filter fat32format.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}

function Get-PartDev([string]$dev, [int]$num) {
  if ($dev -match '\d$') { "${dev}p$num" } else { "$dev$num" }
}

# Linux formats: partition type + mkfs command (label goes in {0}, device in {1})
$LinuxFs = @{
  ext4    = @{ gpt = $GPT_LINUX; mbr = 131; max = 16; cmd = "mkfs.ext4 -F -L '{0}' {1}" }
  f2fs    = @{ gpt = $GPT_LINUX; mbr = 131; max = 16; cmd = "mkfs.f2fs -f -l '{0}' {1}" }
  btrfs   = @{ gpt = $GPT_LINUX; mbr = 131; max = 16; cmd = "mkfs.btrfs -f -L '{0}' {1}" }
  xfs     = @{ gpt = $GPT_LINUX; mbr = 131; max = 12; cmd = "mkfs.xfs -f -L '{0}' {1}" }
  hfsplus = @{ gpt = '{48465300-0000-11aa-aa11-00306543ecac}'; mbr = 175; max = 27; cmd = "mkfs.hfsplus -v '{0}' {1}" }
  fat32   = @{ gpt = $GPT_BASIC; mbr = 12; max = 11; cmd = "mkfs.vfat -F 32 -n '{0}' {1}" }
}

function Format-Part([int]$n, [int]$p, [string]$fs, [string]$label) {
  $part = Get-Part $n $p
  $fs = $fs.ToLower()
  if (-not $label) { $label = 'DATA' }
  $sizeGb = $part.Size / 1GB
  $letter = if ($part.DriveLetter -and $part.DriveLetter -ne [char]0) { "$($part.DriveLetter)" } else { '' }

  # 1. Windows itself: NTFS, exFAT, small FAT32
  if ($fs -in 'ntfs', 'exfat' -or ($fs -eq 'fat32' -and $sizeGb -le 32)) {
    if ($part.GptType -and "$($part.GptType)".ToLower() -ne $GPT_BASIC) { Set-Partition -DiskNumber $n -PartitionNumber $p -GptType $GPT_BASIC }
    $fsName = @{ ntfs = 'NTFS'; exfat = 'exFAT'; fat32 = 'FAT32' }[$fs]
    if ($fs -eq 'fat32') { $label = $label.ToUpper(); if ($label.Length -gt 11) { $label = $label.Substring(0, 11) } }
    if ($letter) { & fsutil volume dismount "${letter}:" 2>&1 | Out-Null }
    $part | Format-Volume -FileSystem $fsName -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
    return "Formatted as $fsName ($label)."
  }

  # 2. UDF (readable by Windows, Mac, Linux, TVs): Windows format.com
  if ($fs -eq 'udf') {
    if (-not $letter) { throw 'UDF needs a drive letter: give the partition one first.' }
    if ($part.GptType -and "$($part.GptType)".ToLower() -ne $GPT_BASIC) { Set-Partition -DiskNumber $n -PartitionNumber $p -GptType $GPT_BASIC }
    $lbl = ($label -replace '[^\w\- ]', ''); if ($lbl.Length -gt 30) { $lbl = $lbl.Substring(0, 30) }
    $ErrorActionPreference = 'Continue'
    $out = & format.com "${letter}:" /FS:UDF /Q "/V:$lbl" /Y 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "UDF format failed: $(($out | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' ')" }
    return "Formatted as UDF ($lbl)."
  }

  # 3. Big FAT32 with a drive letter: fat32format (fast, works on SD cards too).
  #    64 sectors = 32 KB clusters, what consoles (Wii, PS2 loaders...) expect.
  if ($fs -eq 'fat32' -and $letter -and (Get-Fat32Format)) {
    if ($part.GptType -and "$($part.GptType)".ToLower() -ne $GPT_BASIC) { Set-Partition -DiskNumber $n -PartitionNumber $p -GptType $GPT_BASIC }
    $lbl = $label.ToUpper() -replace '[^A-Z0-9_\-]', ''
    if ($lbl.Length -gt 11) { $lbl = $lbl.Substring(0, 11) }
    # fat32format needs the volume to itself: make Windows drop every open
    # handle (Explorer, antivirus, file managers) right before, retry if some
    # program grabs it again.
    $ErrorActionPreference = 'Continue'
    for ($try = 1; $try -le 3; $try++) {
      & fsutil volume dismount "${letter}:" 2>&1 | Out-Null
      $out = 'y' | & (Get-Fat32Format) -c64 "${letter}:" 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'RemoteException' }
      $code = $LASTEXITCODE
      Write-Log "fat32format try $try exit $code : $(($out | Select-Object -Last 3) -join ' | ')"
      if ($code -eq 0) { break }
      Start-Sleep -Seconds 2
    }
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) {
      $why = ($out | Where-Object { $_ -match 'GetLastError|error|fail' } | Select-Object -Last 1)
      if ("$why" -match '=32') { $why = 'Another program keeps the drive open. Close windows showing it (Explorer, other file manager tabs) and try again.' }
      throw "fat32format failed: $why"
    }
    if ($lbl) { Set-Volume -DriveLetter $letter -NewFileSystemLabel $lbl -ErrorAction SilentlyContinue }
    return "Formatted as FAT32 ($lbl) with fat32format, 32 KB clusters."
  }

  # 4. Linux tools in WSL: ext4, F2FS, btrfs, xfs, HFS+, big FAT32 without a letter
  if (-not $LinuxFs.ContainsKey($fs)) { throw "Unknown file system: $fs" }
  $spec = $LinuxFs[$fs]
  if ($part.GptType) { Set-Partition -DiskNumber $n -PartitionNumber $p -GptType $spec.gpt }
  else { Set-Partition -DiskNumber $n -PartitionNumber $p -MbrType $spec.mbr }
  $lbl = $label -replace '[^\w\-]', ''
  if ($fs -eq 'fat32') { $lbl = $lbl.ToUpper() }
  if ($lbl.Length -gt $spec.max) { $lbl = $lbl.Substring(0, $spec.max) }
  $cmdTemplate = $spec.cmd
  $msg = Use-LinuxDevice $n {
    param($distro, $dev)
    $r = Invoke-Wsl $distro ($cmdTemplate -f $lbl, (Get-PartDev $dev $p))
    if ($r.code -ne 0) { throw "Format failed: $($r.text)" }
    "Formatted as $($fs.ToUpper()) ($lbl) with Linux tools."
  }
  return $msg
}

function Check-Part([int]$n, [int]$p, [switch]$Fix) {
  $part = Get-Part $n $p
  $letter = if ($part.DriveLetter -and $part.DriveLetter -ne [char]0) { "$($part.DriveLetter)" } else { '' }
  $winFs = ''
  if ($letter) { $winFs = "$((Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue).FileSystemType)" }

  # Windows file systems with a letter: chkdsk
  if ($letter -and $winFs -in 'NTFS', 'FAT32', 'FAT', 'exFAT', 'ReFS') {
    if ($Fix) { $out = & chkdsk "${letter}:" /f /x 2>&1 | ForEach-Object { "$_" } }
    else { $out = & chkdsk "${letter}:" 2>&1 | ForEach-Object { "$_" } }
    $tail = ($out | Where-Object { $_ -match '\S' } | Select-Object -Last 12) -join "`n"
    return @{ code = $LASTEXITCODE; text = $tail }
  }

  # Everything else: let Linux find the file system and use its checker
  if ((Get-SystemDisks) -contains $n) { throw 'This partition is on the Windows disk and cannot be checked here.' }
  Assert-Changeable $n
  Use-LinuxDevice $n {
    param($distro, $dev)
    $pd = Get-PartDev $dev $p
    $mode = if ($Fix) { 'fix' } else { 'check' }
    $script = @"
t=`$(blkid -o value -s TYPE $pd)
echo "File system: `${t:-unknown}"
case "`$t:$mode" in
  ext2:check|ext3:check|ext4:check) e2fsck -f -n $pd ;;
  ext2:fix|ext3:fix|ext4:fix)       e2fsck -f -p $pd ;;
  vfat:check)    fsck.vfat -n $pd ;;
  vfat:fix)      fsck.vfat -a $pd ;;
  exfat:check)   fsck.exfat -n $pd ;;
  exfat:fix)     fsck.exfat -y $pd ;;
  f2fs:check)    fsck.f2fs --dry-run $pd ;;
  f2fs:fix)      fsck.f2fs -f $pd ;;
  xfs:check)     xfs_repair -n $pd ;;
  xfs:fix)       xfs_repair $pd ;;
  hfsplus:check) fsck.hfsplus -f -n $pd ;;
  hfsplus:fix)   fsck.hfsplus -f -y $pd ;;
  btrfs:check)   btrfs check --readonly $pd ;;
  btrfs:fix)     echo "btrfs: automatic repair is risky and not offered; mount it and run 'btrfs scrub'."; exit 8 ;;
  *) echo "No checker for this file system."; exit 8 ;;
esac
"@
    $r = Invoke-Wsl $distro $script
    # 0 = clean; e2fsck 1 = fixed; 4+ = problems left
    @{ code = $r.code; text = $r.text }
  }
}

# ---------- run ----------

try {
  if ($Action -eq 'list') {
    Out-Json ([ordered]@{ ok = $true; disks = @(Get-DiskList) })
  }

  # Everything else needs admin: re-run elevated and relay the result.
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    $rf = Join-Path $env:TEMP ("disktools-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Action,
              '-Disk', $Disk, '-Partition', $Partition, '-SizeMB', $SizeMB, '-OffsetMB', $OffsetMB,
              '-Style', $Style, '-Elevated', '-ResultFile', "`"$rf`"")
    if ($FileSystem) { $argv += @('-FileSystem', $FileSystem) }
    if ($Label) { $argv += @('-Label', "`"$Label`"") }
    if ($Letter) { $argv += @('-Letter', $Letter) }
    try {
      Start-Process powershell.exe -ArgumentList $argv -Verb RunAs -Wait -WindowStyle Hidden
    } catch { throw 'The admin prompt was cancelled.' }
    if (-not (Test-Path $rf)) { throw "The admin step did not report back (prompt cancelled?). Details may be in $LogFile" }
    $json = Get-Content $rf -Raw
    Remove-Item $rf -ErrorAction SilentlyContinue
    $json
    if ($json -match '"ok":true') { exit 0 } else { exit 1 }
  }

  if ($Disk -lt 0) { throw "$Action needs -Disk" }
  switch ($Action) {
    'check' {
      $r = Check-Part $Disk $Partition
      Out-Json ([ordered]@{ ok = $true; clean = ($r.code -eq 0); message = $r.text })
    }
    'repair' {
      Assert-Changeable $Disk
      $r = Check-Part $Disk $Partition -Fix
      Out-Json ([ordered]@{ ok = ($r.code -lt 4); message = $r.text })
    }
    'format' {
      Assert-Changeable $Disk
      if (-not $FileSystem) { throw 'format needs -FileSystem' }
      Out-Json ([ordered]@{ ok = $true; message = (Format-Part $Disk $Partition $FileSystem $Label) })
    }
    'create' {
      Assert-Changeable $Disk
      $args2 = @{ DiskNumber = $Disk }
      if ($SizeMB -gt 0) { $args2.Size = $SizeMB * 1MB } else { $args2.UseMaximumSize = $true }
      if ($OffsetMB -gt 0) { $args2.Offset = $OffsetMB * 1MB }
      if ($Letter) { $args2.DriveLetter = $Letter.TrimEnd(':') } elseif ($FileSystem -ne 'ext4') { $args2.AssignDriveLetter = $true }
      $new = New-Partition @args2
      $msg = "Created partition $($new.PartitionNumber) ($([math]::Round($new.Size / 1GB, 1)) GB)."
      if ($FileSystem) { $msg += ' ' + (Format-Part $Disk $new.PartitionNumber $FileSystem $Label) }
      Out-Json ([ordered]@{ ok = $true; partition = $new.PartitionNumber; message = $msg })
    }
    'delete' {
      Assert-Changeable $Disk
      Get-Part $Disk $Partition | Out-Null
      Remove-Partition -DiskNumber $Disk -PartitionNumber $Partition -Confirm:$false
      Out-Json ([ordered]@{ ok = $true; message = "Partition $Partition deleted." })
    }
    'resize' {
      Assert-Changeable $Disk
      $part = Get-Part $Disk $Partition
      $v = $part | Get-Volume -ErrorAction SilentlyContinue
      if (-not $v -or $v.FileSystemType -ne 'NTFS') { throw 'Only NTFS partitions can be resized here.' }
      $sup = Get-PartitionSupportedSize -DiskNumber $Disk -PartitionNumber $Partition
      $want = $SizeMB * 1MB
      if ($want -lt $sup.SizeMin -or $want -gt $sup.SizeMax) {
        throw ("Size must be between {0} and {1} MB." -f [math]::Ceiling($sup.SizeMin / 1MB), [math]::Floor($sup.SizeMax / 1MB))
      }
      Resize-Partition -DiskNumber $Disk -PartitionNumber $Partition -Size $want
      Out-Json ([ordered]@{ ok = $true; message = "Resized to $SizeMB MB." })
    }
    'setletter' {
      Assert-Changeable $Disk
      $part = Get-Part $Disk $Partition
      $cur = if ($part.DriveLetter -and $part.DriveLetter -ne [char]0) { "$($part.DriveLetter)" } else { '' }
      if ($cur) { Remove-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $Partition -AccessPath "${cur}:\" }
      if ($Letter -and $Letter -ne 'none') { Set-Partition -DiskNumber $Disk -PartitionNumber $Partition -NewDriveLetter $Letter.TrimEnd(':') }
      Out-Json ([ordered]@{ ok = $true; message = $(if ($Letter -and $Letter -ne 'none') { "Now $($Letter.TrimEnd(':')):" } else { 'Drive letter removed.' }) })
    }
    'setlabel' {
      Assert-Changeable $Disk
      $part = Get-Part $Disk $Partition
      $part | Get-Volume | Set-Volume -NewFileSystemLabel $Label
      Out-Json ([ordered]@{ ok = $true; message = "Label set to '$Label'." })
    }
    'initialize' {
      Assert-Changeable $Disk
      $d = Get-Disk -Number $Disk
      if ($d.PartitionStyle -ne 'RAW') { throw 'Disk already has a partition table (use wipe to erase it).' }
      Initialize-Disk -Number $Disk -PartitionStyle $Style.ToUpper()
      Out-Json ([ordered]@{ ok = $true; message = "Initialized as $($Style.ToUpper())." })
    }
    'wipe' {
      Assert-Changeable $Disk
      Clear-Disk -Number $Disk -RemoveData -RemoveOEM -Confirm:$false
      Initialize-Disk -Number $Disk -PartitionStyle $Style.ToUpper()
      Out-Json ([ordered]@{ ok = $true; message = "All partitions erased; new empty $($Style.ToUpper()) table." })
    }
  }
} catch {
  $m = "$($_.Exception.Message)".Trim()
  if (-not $m) { $m = ("$_" + ' ' + $_.ScriptStackTrace).Trim() }
  if (-not $m) { $m = 'Unknown error (no details from Windows).' }
  Out-Json ([ordered]@{ ok = $false; error = $m }) 1
}