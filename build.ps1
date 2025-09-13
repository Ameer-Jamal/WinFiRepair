# build.ps1 — robust packager; isolates ps2exe; optional self-sign
[CmdletBinding()]
param(
  [ValidateSet('embed','portable')] [string]$Mode = 'embed',
  [string]$Version = '1.0.0',
  [ValidateSet('none','self')] [string]$Sign = 'self',
  [string]$DevCertSubject = 'CN=WinFiRepair Dev',
  [string]$TimeURL = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths (script must be run, not pasted) ---
$Root   = $PSScriptRoot
$Entry  = Join-Path $Root 'src\WifiRepair.ps1'
$Logic  = Join-Path $Root 'src\WifiRepair.Logic.psm1'
$View   = Join-Path $Root 'src\WifiRepair.GUI.xaml'
$Icon   = Join-Path $Root 'assets\wifi.ico'
$Dist   = Join-Path $Root 'dist'
$OutExe = Join-Path $Dist 'WinFiRepair.exe'

# Metadata (keep minimal to avoid old-ps2exe param issues)
$Product     = 'WinFiRepair'
$Description = 'Wi-Fi repair tool with diagnostics, rollback, and aggressive reset.'
$Company     = 'A.Jamal Tools'
$Copyright   = '(c) A.Jamal'

foreach ($p in @($Entry,$Logic,$View)) { if (-not (Test-Path $p)) { throw "Missing: $p" } }
if (-not (Test-Path $Dist)) { New-Item -ItemType Directory -Path $Dist -Force | Out-Null }
if (-not (Test-Path $Icon)) { $Icon = $null }  # optional

# --- Ensure ps2exe module and locate its script file ---
if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
  Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
$Ps2ExeModule = Get-Module -ListAvailable ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $Ps2ExeModule) { throw 'ps2exe module not found after install.' }
$Ps2ExeScript = Join-Path $Ps2ExeModule.ModuleBase 'ps2exe.ps1'
if (-not (Test-Path $Ps2ExeScript)) { throw "ps2exe.ps1 not found at $Ps2ExeScript" }

# --- Build argument list for ps2exe.ps1 (minimally compatible) ---
$psArgs = @(
  '-File', $Ps2ExeScript,
  '-inputFile', $Entry,
  '-outputFile', $OutExe,
  '-noConsole',
  '-requireAdmin',
  '-title', $Product,
  '-description', $Description,
  '-company', $Company,
  '-sta'                    # WPF
)
if ($Icon) { $psArgs += @('-iconFile', $Icon) }

# Embed required files (older ps2exe uses repeated -include)
if ($Mode -eq 'embed') {
  $psArgs += @('-include', $Logic, '-include', $View)
}

# --- Invoke ps2exe in a clean 64-bit Windows PowerShell host ---
$pwsh5 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $pwsh5)) { throw 'Windows PowerShell 5.1 not found.' }

Write-Host "Building $Product $Version ($Mode)..." -ForegroundColor Green
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $pwsh5
$psi.Arguments = @('-NoProfile','-ExecutionPolicy','Bypass') + $psArgs -join ' '
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
if ($stdout) { Write-Host $stdout }
if ($stderr) { Write-Host $stderr -ForegroundColor Yellow }
if ($proc.ExitCode -ne 0) { throw "ps2exe failed with exit code $($proc.ExitCode)" }

if ($Mode -eq 'portable') {
  Copy-Item $Logic, $View -Destination $Dist -Force
}
Write-Host "Build complete: $OutExe" -ForegroundColor Green

# --- Optional self-sign (dev/testing only) ---
if ($Sign -eq 'self') {
  function Get-SignToolPath {
    foreach ($base in @("$Env:ProgramFiles (x86)\Windows Kits\11\bin", "$Env:ProgramFiles (x86)\Windows Kits\10\bin")) {
      if (-not (Test-Path $base)) { continue }
      $hit = Get-ChildItem $base -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\x64\\' } |
             Sort-Object FullName -Descending | Select-Object -First 1
      if ($hit) { return $hit.FullName }
    }
    return $null
  }

  $signtool = Get-SignToolPath
  if (-not $signtool) {
    Write-Host 'signtool.exe not found. Skipping signing.' -ForegroundColor Yellow
    return
  }

  # Ensure the EXE exists (handle AV lag or odd ps2exe behaviors)
  1..10 | ForEach-Object {
    if (Test-Path $OutExe) { return }
    Start-Sleep -Milliseconds 250
  }
  if (-not (Test-Path $OutExe)) {
    # Fallback: pick most recent .exe in dist
    $latest = Get-ChildItem -Path $Dist -Filter *.exe -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $script:OutExe = $latest.FullName }
  }
  if (-not (Test-Path $OutExe)) { throw "Build reported success but no EXE present in '$Dist'." }

  # Dev cert (self-signed)
  $subject = $DevCertSubject
  $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
          Where-Object { $_.Subject -eq $subject } |
          Sort-Object NotAfter -Descending | Select-Object -First 1
  if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
      -Subject $subject -KeyExportPolicy Exportable -KeyLength 2048 `
      -KeyAlgorithm RSA -HashAlgorithm SHA256 -CertStoreLocation Cert:\CurrentUser\My
  }

  # Sign
  & $signtool sign /fd SHA256 /td SHA256 /tr $TimeURL /as /sha1 $cert.Thumbprint "$OutExe"
  if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (rc=$LASTEXITCODE)." }

  # Verify (policy + timestamp)
  & $signtool verify /pa /tw /v "$OutExe"
  if ($LASTEXITCODE -ne 0) { throw "signtool verify failed (rc=$LASTEXITCODE)." }

  Write-Host "Signed: $OutExe with $($cert.Subject)" -ForegroundColor Green
} else {
  Write-Host 'Signing disabled.' -ForegroundColor Yellow
}