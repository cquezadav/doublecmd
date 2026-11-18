{
   [my-custom] Icons that tell drives apart on the drive bar:
     Google Drive / OneDrive (rclone mounts)  -> product icon (pixmaps\my-custom)
     other rclone cloud mounts                -> cloud icon
     Linux partitions mounted by linuxmount   -> Tux (wsl.exe)
   Everything else keeps Double Commander's normal icon.
}
unit uDriveIcons;

{$mode objfpc}{$H+}

interface

uses
  Graphics, uDrive;

{ Returns a custom icon for Drive, or nil to use the normal one. }
function CustomDriveIcon(Drive: PDrive; IconSize: Integer; clBackColor: TColor): Graphics.TBitmap;

implementation

uses
  SysUtils, Classes, fpjson, jsonparser, uPixMapManager, uGlobsPaths
  {$IFDEF MSWINDOWS}, Windows{$ENDIF};

var
  LinuxLetters: String = '';      // e.g. 'RZ'
  LinuxStamp: LongInt = -2;

{$IFDEF MSWINDOWS}
function LinuxStateFile: String;
begin
  Result := SysUtils.GetEnvironmentVariable('LOCALAPPDATA') + '\doublecmd-linuxmount\mounts.json';
end;

procedure RefreshLinuxLetters;
var
  Stamp: LongInt;
  SL: TStringList;
  D: TJSONData;
  I: Integer;
  L: String;
begin
  Stamp := FileAge(LinuxStateFile);
  if Stamp = LinuxStamp then Exit;
  LinuxStamp := Stamp;
  LinuxLetters := '';
  if Stamp = -1 then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(LinuxStateFile);
      D := GetJSON(SL.Text);
      try
        if D is TJSONArray then
          for I := 0 to TJSONArray(D).Count - 1 do
            if TJSONArray(D).Items[I] is TJSONObject then
            begin
              L := TJSONObject(TJSONArray(D).Items[I]).Get('letter', '');
              if L <> '' then LinuxLetters := LinuxLetters + UpperCase(L[1]);
            end;
      finally
        D.Free;
      end;
    except
      LinuxLetters := '';
    end;
  finally
    SL.Free;
  end;
end;

function FileSystemName(const Root: String): String;
var
  Buf: array[0..63] of WideChar;
  Dummy, Flags: DWORD;
begin
  Result := '';
  if GetVolumeInformationW(PWideChar(WideString(Root)), nil, 0, nil, Dummy, Flags, @Buf[0], Length(Buf)) then
    Result := String(WideString(PWideChar(@Buf[0])));
end;
{$ENDIF}

function CustomDriveIcon(Drive: PDrive; IconSize: Integer; clBackColor: TColor): Graphics.TBitmap;
{$IFDEF MSWINDOWS}
var
  Root, Lbl, Src: String;
{$ENDIF}
begin
  Result := nil;
{$IFDEF MSWINDOWS}
  Root := Drive^.Path;
  if (Length(Root) < 2) or (Root[2] <> ':') then Exit;
  Src := '';
  RefreshLinuxLetters;
  Lbl := LowerCase(Trim(Drive^.DriveLabel));
  if Pos(UpCase(Root[1]), LinuxLetters) > 0 then
    Src := SysUtils.GetEnvironmentVariable('WINDIR') + '\System32\wsl.exe,0'
  else if Lbl = 'google drive' then
    Src := gpExePath + 'pixmaps\my-custom\gdrive.png'
  else if Lbl = 'onedrive' then
    Src := gpExePath + 'pixmaps\my-custom\onedrive.png'
  else if Drive^.DriveType in [dtHardDisk, dtUnknown] then
  begin
    // any other rclone mount (S3, FTP...) gets a cloud. Network drives are
    // skipped: asking a disconnected share for its file system can hang.
    if Pos('rclone', LowerCase(FileSystemName(Copy(Root, 1, 2) + '\'))) > 0 then
      Src := SysUtils.GetEnvironmentVariable('WINDIR') + '\System32\imageres.dll,232';
  end;
  if Src <> '' then
    Result := PixMapManager.LoadBitmapEnhanced(Src, IconSize, True, clBackColor);
{$ENDIF}
end;

end.
