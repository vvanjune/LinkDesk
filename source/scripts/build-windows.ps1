$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '../Windows/LinkDesk.csproj'
$out = Join-Path $PSScriptRoot '../../Windows'
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $out
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
