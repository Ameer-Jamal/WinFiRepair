# Entry point: loads logic, WPF UI, wires events. Run elevated.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$here     = Split-Path -Parent $PSCommandPath
$logicMod = Join-Path $here 'WifiRepair.Logic.psm1'
$xamlPath = Join-Path $here 'WifiRepair.GUI.xaml'

Import-Module $logicMod -Force
try { Assert-Admin } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, "WinFiRepair"); exit 1 }

# Load XAML with hard fail reporting
try {
  [string]$xaml = Get-Content -Path $xamlPath -Raw -ErrorAction Stop
  $window  = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
  [System.Windows.MessageBox]::Show(("UI load failed: {0}" -f $_.Exception.Message), "WinFiRepair")
  exit 1
}

# Controls
$cmbAdapter         = $window.FindName("cmbAdapter")
$txtSsid            = $window.FindName("txtSsid")
$btnDiag            = $window.FindName("btnDiag")
$btnBackup          = $window.FindName("btnBackup")
$btnSafe            = $window.FindName("btnSafe")
$btnAgg             = $window.FindName("btnAgg")
$btnRollbackLatest  = $window.FindName("btnRollbackLatest")
$btnRollbackChoose  = $window.FindName("btnRollbackChoose")
$txtLog             = $window.FindName("txtLog")

# File logger (ASCII-only messages; file encoded UTF-8)
$LogDir  = Join-Path $env:ProgramData "WifiRepair\Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir "winfirepair.log"

function Log([string]$m, [string]$lvl = "INFO") {
  $ascii = $m -replace '…','...' -replace '→','->' -replace '[“”]','"' -replace '[‘’]',"'" -replace '[^\u0000-\u007F]','?'
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[{0}][{1}] {2}" -f $ts, $lvl, $ascii
  $txtLog.AppendText("$line`r`n"); $txtLog.ScrollToEnd()
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# Populate adapters on load
$window.Add_Loaded({
  try {
    $cmbAdapter.Items.Clear()
    $names = Get-WifiAdapterNames
    foreach ($n in $names) { [void]$cmbAdapter.Items.Add($n) }
    if ($cmbAdapter.Items.Count -gt 0) { $cmbAdapter.SelectedIndex = 0 }
    Log ("Adapters: {0}" -f ($names -join ', '))
    Log "Application ready."
  } catch { Log ("Adapter init failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$btnDiag.Add_Click({
  try {
    Log "Running connectivity tests..."
    $r = Test-Connectivity
    Log ("TCP443: {0}, DNS: {1}, HTTP: {2}, Overall: {3}" -f $r.TCP443,$r.DNS,$r.HTTP,$r.Overall)
  } catch { Log ("Diagnose failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$btnBackup.Add_Click({
  if (-not $cmbAdapter.Text) { Log "Select an adapter.","ERROR"; return }
  try {
    $dir = New-BackupDir
    Save-NetworkState -AdapterName $cmbAdapter.Text -Dir $dir | Out-Null
    Log ("Backup created at: {0}" -f $dir)
  } catch { Log ("Backup failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$btnSafe.Add_Click({
  if (-not $cmbAdapter.Text) { Log "Select an adapter.","ERROR"; return }
  try {
    Log "Starting safe repair and backup..."
    $dir = Invoke-SafeRepair -AdapterName $cmbAdapter.Text -Ssid $txtSsid.Text
    $r = Test-Connectivity
    Log ("Connectivity -> TCP443:{0} DNS:{1} HTTP:{2} Overall:{3}" -f $r.TCP443,$r.DNS,$r.HTTP,$r.Overall)
    Log ("Backup at: {0}" -f $dir)
  } catch { Log ("Safe repair failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$btnAgg.Add_Click({
  if (-not $cmbAdapter.Text) { Log "Select an adapter.","ERROR"; return }
  $res = [System.Windows.MessageBox]::Show(
    "Aggressive reset rewrites TCP/IP and Winsock and usually requires reboot. Continue?",
    "Confirm Aggressive Reset",
    [System.Windows.MessageBoxButton]::YesNo,
    [System.Windows.MessageBoxImage]::Warning
  )
  if ($res -ne [System.Windows.MessageBoxResult]::Yes) { return }
  try {
    $dir = New-BackupDir
    Save-NetworkState -AdapterName $cmbAdapter.Text -Dir $dir | Out-Null
    Log ("Backup at: {0}" -f $dir)
    Invoke-AggressiveReset -LogDir $dir
    Log "Aggressive reset complete. Reboot is recommended."
  } catch { Log ("Aggressive reset failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$btnRollbackLatest.Add_Click({
  try {
    $root = Join-Path $env:ProgramData "WifiRepair\Backups"
    if (-not (Test-Path $root)) { Log "No backups found.","ERROR"; return }
    $latest = Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Log "No backups found.","ERROR"; return }
    Log ("Restoring from latest: {0}" -f $latest.FullName)
    Restore-NetworkState -Dir $latest.FullName
    $r = Test-Connectivity
    Log ("Connectivity -> TCP443:{0} DNS:{1} HTTP:{2} Overall:{3}" -f $r.TCP443,$r.DNS,$r.HTTP,$r.Overall)
    Log "Rollback finished."
  } catch { Log ("Rollback failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$btnRollbackChoose.Add_Click({
  try {
    $initial = Join-Path $env:ProgramData "WifiRepair\Backups"
    if (-not (Test-Path $initial)) { Log "No backups found.","ERROR"; return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "Select backup (state.json)"
    $dlg.InitialDirectory = $initial
    $dlg.Filter = "Backup state (state.json)|state.json|All files (*.*)|*.*"
    $dlg.CheckFileExists = $true
    if (-not $dlg.ShowDialog()) { return }
    $chosenDir = Split-Path -Parent $dlg.FileName
    Log ("Restoring from: {0}" -f $chosenDir)
    Restore-NetworkState -Dir $chosenDir
    $r = Test-Connectivity
    Log ("Connectivity -> TCP443:{0} DNS:{1} HTTP:{2} Overall:{3}" -f $r.TCP443,$r.DNS,$r.HTTP,$r.Overall)
    Log "Rollback finished."
  } catch { Log ("Rollback failed: {0}" -f $_.Exception.Message), "ERROR" }
})

$null = $window.ShowDialog()
