<#
.SYNOPSIS
  Build a joggo release: joggo-<version>.zip from a tagged commit, and joggo-setup.exe pinned to it.

.DESCRIPTION
  1. git archive of the tag -> dist/joggo-<version>.zip (contents only, no .git).
  2. SHA-256 of that zip, compiled into setup/JoggoSetup.cs as ZIP_SHA256.
  3. csc.exe from .NET Framework 4.8 (in every Windows 10/11) -> dist/joggo-setup.exe.
  4. dist/SHA256SUMS for the zip. Add the exe's line AFTER signing; signing changes its bytes.

  The exe is UNSIGNED. Sign it (Authenticode) before uploading, and do not rebuild after
  signing: the signature is over these exact bytes. Upload joggo-<version>.zip, the signed
  joggo-setup.exe and SHA256SUMS to the GitHub release v<version>.

  The zip must be the one uploaded: the exe accepts no other bytes.

.EXAMPLE
  ./setup/build.ps1 -Version 0.1.0     # the tag v0.1.0 must exist
#>
param(
  [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tag  = "v$Version"
$dist = Join-Path $root 'dist'
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

Push-Location $root
try {
  & git rev-parse --verify --quiet "refs/tags/$tag" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "tag $tag does not exist; create it on the commit to release first" }
  if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc (.NET Framework 4.8)" }

  New-Item -ItemType Directory -Force $dist | Out-Null
  $zip = Join-Path $dist "joggo-$Version.zip"
  $exe = Join-Path $dist 'joggo-setup.exe'
  Remove-Item $zip, $exe -ErrorAction SilentlyContinue

  & git archive --format=zip -o $zip $tag
  if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
  $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()

  $src = (Get-Content (Join-Path $PSScriptRoot 'JoggoSetup.cs') -Raw).Replace('@VERSION@', $Version).Replace('@ZIP_SHA256@', $sha)
  $tmp = Join-Path $dist 'JoggoSetup.build.cs'
  Set-Content -Path $tmp -Value $src -Encoding UTF8
  & $csc /nologo /optimize+ /target:exe /platform:anycpu "/out:$exe" `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll $tmp
  if ($LASTEXITCODE -ne 0) { throw 'csc failed' }
  Remove-Item $tmp

  $sums = @($zip) | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_ -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $_) }
  Set-Content -Path (Join-Path $dist 'SHA256SUMS') -Value $sums -Encoding ASCII

  Write-Host "built from $tag ($(& git rev-parse --short "$tag^{commit}")):"
  $sums | ForEach-Object { Write-Host "  $_" }
  Write-Host 'next: sign dist/joggo-setup.exe, append its SHA-256 to SHA256SUMS, then upload all three to the release.'
} finally { Pop-Location }
