$ErrorActionPreference = 'Stop'
$upstream = $env:LINKDESK_DESKFLOW_WINDOWS
if (!$upstream -or !(Test-Path (Join-Path $upstream 'deskflow-core.exe'))) { throw 'Set LINKDESK_DESKFLOW_WINDOWS to the extracted official x64 portable folder.' }
$project = Join-Path $PSScriptRoot '../Windows/LinkDesk.csproj'
$patched = $env:LINKDESK_PATCHED_WINDOWS_CORE
if (!$patched -or !(Test-Path $patched)) { throw 'Set LINKDESK_PATCHED_WINDOWS_CORE to the validated display-safe deskflow-core.exe artifact.' }
$out = Join-Path $PSScriptRoot '../../Windows'
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $out
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
python3 (Join-Path $PSScriptRoot 'bundle-runtime.py') windows $upstream $out --patched-windows-core $patched
if ($LASTEXITCODE -ne 0) { throw 'Runtime bundling failed' }
