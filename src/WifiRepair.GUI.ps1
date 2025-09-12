# WifiRepair.GUI.ps1  (Run elevated)
# One-click Wi-Fi repair with backups, rollback, and optional aggressive reset.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Assert-Admin {
  $wi=[Security.Principal.WindowsIdentity]::GetCurrent()
  $wp=New-Object Security.Principal.WindowsPrincipal($wi)
  if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("Run as Administrator.","WifiRepair",0,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    exit 1
  }
}
Assert-Admin

$BackupRoot = Join-Path $env:ProgramData "WifiRepair\Backups"
if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot | Out-Null }

function New-BackupDir {
  $dir = Join-Path $BackupRoot (Get-Date -Format "yyyyMMdd_HHmmss")
  New-Item -ItemType Directory -Path $dir | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dir "wlan_profiles") | Out-Null
  return $dir
}

function Save-State {
  param([string]$Dir,[string]$AdapterName)
  $if = Get-NetAdapter | Where-Object { $_.Name -eq $AdapterName }
  if (-not $if) { throw "Adapter not found: $AdapterName" }

  $cfg = Get-NetIPConfiguration -InterfaceIndex $if.ifIndex
  $dns = Get-DnsClientServerAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
  $state = [ordered]@{
    Timestamp   = (Get-Date).ToString("s")
    AdapterName = $if.Name
    DHCP        = ($cfg.IPv4Address.Dhcp -contains "Enabled")
    IPv4        = ($cfg.IPv4Address | ForEach-Object { $_.IPv4Address.IPAddress })
    Prefix      = ($cfg.IPv4Address | ForEach-Object { $_.PrefixLength })
    Gateway     = ($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop })
    DnsFromDhcp = ($dns.ServerAddressesSource -eq "Dhcp")
    DnsServers  = $dns.ServerAddresses
  }
  $state | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $Dir "state.json")

  # Export all user WLAN profiles (key=clear keeps rollback deterministic; do not delete any profile here)
  cmd /c "netsh wlan export profile key=clear folder=""$Dir\wlan_profiles""" | Out-Null
}

function Restore-State {
  param([string]$Dir)
  $json = Join-Path $Dir "state.json"
  if (-not (Test-Path $json)) { throw "Missing backup state: $json" }
  $s = Get-Content $json -Raw | ConvertFrom-Json
  $if = Get-NetAdapter | Where-Object { $_.Name -eq $s.AdapterName }
  if (-not $if) { throw "Adapter missing: $($s.AdapterName)" }

  $ifx = $if.ifIndex
  if ($s.DHCP) {
    ipconfig /release $if.Name | Out-Null
    Set-NetIPInterface -InterfaceIndex $ifx -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $ifx -ResetServerAddresses
    ipconfig /renew $if.Name | Out-Null
  } else {
    Get-NetIPAddress -InterfaceIndex $ifx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    for ($i=0; $i -lt $s.IPv4.Count; $i++) {
      New-NetIPAddress -InterfaceIndex $ifx -IPAddress $s.IPv4[$i] -PrefixLength $s.Prefix[$i] -DefaultGateway $s.Gateway[0] -ErrorAction SilentlyContinue | Out-Null
    }
    if ($s.DnsFromDhcp) { Set-DnsClientServerAddress -InterfaceIndex $ifx -ResetServerAddresses }
    elseif ($s.DnsServers) { Set-DnsClientServerAddress -InterfaceIndex $ifx -ServerAddresses $s.DnsServers }
  }

  $pdir = Join-Path $Dir "wlan_profiles"
  if (Test-Path $pdir) {
    Get-ChildItem $pdir -Filter *.xml | ForEach-Object {
      cmd /c "netsh wlan add profile filename=""$($_.FullName)"" user=current" | Out-Null
    }
  }
}

function Safe-Repair {
  param([string]$AdapterName,[string]$Ssid)
  $if = Get-NetAdapter | Where-Object { $_.Name -eq $AdapterName }
  if (-not $if) { throw "Adapter not found: $AdapterName" }

  $dir = New-BackupDir
  Save-State -Dir $dir -AdapterName $AdapterName

  try { Checkpoint-Computer -Description "WifiRepair $($dir.Split('\')[-1])" -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue } catch {}

  ipconfig /flushdns | Out-Null
  try { Restart-Service -Name WlanSvc -Force -ErrorAction SilentlyContinue } catch {}
  try { Restart-Service -Name Dnscache -Force -ErrorAction SilentlyContinue } catch {}
  try { Restart-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

  $dhcp = (Get-NetIPConfiguration -InterfaceIndex $if.ifIndex).IPv4Address.Dhcp -contains "Enabled"
  if ($dhcp) {
    ipconfig /release $AdapterName | Out-Null
    Start-Sleep -Seconds 2
    ipconfig /renew $AdapterName | Out-Null
  }

  if ($Ssid) {
    cmd /c "netsh wlan connect name=""$Ssid"" interface=""$AdapterName""" | Out-Null
  }

  return $dir
}

function Aggressive-Reset {
  param([string]$LogDir)
  cmd /c "netsh int ip reset `"$LogDir\ip_reset.log`"" | Out-Null
  cmd /c "netsh winsock reset" | Out-Null
}

function Test-Connectivity {
  $ok1 = Test-NetConnection -ComputerName 1.1.1.1 -InformationLevel Quiet
  $ok2 = $false
  try { $ok2 = [bool](Resolve-DnsName -Name "www.microsoft.com" -ErrorAction Stop) } catch {}
  return [PSCustomObject]@{ ICMP=$ok1; DNS=$ok2; Overall=($ok1 -and $ok2) }
}

# ——— GUI ———
$form              = New-Object Windows.Forms.Form
$form.Text         = "Wi-Fi Repair"
$form.Size         = New-Object Drawing.Size(560,420)
$form.StartPosition= "CenterScreen"

$lblAdapter = New-Object Windows.Forms.Label
$lblAdapter.Text = "Adapter:"
$lblAdapter.Location = "12,15"
$lblAdapter.AutoSize = $true
$form.Controls.Add($lblAdapter)

$cmbAdapter = New-Object Windows.Forms.ComboBox
$cmbAdapter.Location = "80,12"
$cmbAdapter.Width = 440
$cmbAdapter.DropDownStyle = "DropDownList"
(Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and $_.NdisPhysicalMedium -match '802.11'} | Select-Object -ExpandProperty Name) | ForEach-Object { [void]$cmbAdapter.Items.Add($_) }
if ($cmbAdapter.Items.Count -gt 0) { $cmbAdapter.SelectedIndex = 0 }
$form.Controls.Add($cmbAdapter)

$lblSsid = New-Object Windows.Forms.Label
$lblSsid.Text = "SSID (optional):"
$lblSsid.Location = "12,47"; $lblSsid.AutoSize = $true
$form.Controls.Add($lblSsid)

$txtSsid = New-Object Windows.Forms.TextBox
$txtSsid.Location = "120,44"; $txtSsid.Width = 400
$form.Controls.Add($txtSsid)

$btnDiag = New-Object Windows.Forms.Button
$btnDiag.Text = "Diagnose"
$btnDiag.Location = "12,80"; $btnDiag.Width = 100

$btnSafe = New-Object Windows.Forms.Button
$btnSafe.Text = "Safe Repair"
$btnSafe.Location = "120,80"; $btnSafe.Width = 120

$btnAgg  = New-Object Windows.Forms.Button
$btnAgg.Text = "Aggressive Reset"
$btnAgg.Location = "248,80"; $btnAgg.Width = 140

$btnRollback = New-Object Windows.Forms.Button
$btnRollback.Text = "Rollback (Latest)"
$btnRollback.Location = "396,80"; $btnRollback.Width = 124

$form.Controls.AddRange(@($btnDiag,$btnSafe,$btnAgg,$btnRollback))

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Location = "12,120"
$txtLog.Size = New-Object Drawing.Size(508,240)
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

function Log([string]$m){ $ts=(Get-Date).ToString("HH:mm:ss"); $txtLog.AppendText("[$ts] $m`r`n") }

$btnDiag.Add_Click({
  Log "Running connectivity tests…"
  $r = Test-Connectivity
  Log ("ICMP: {0}, DNS: {1}, Overall: {2}" -f $r.ICMP,$r.DNS,$r.Overall)
})

$btnSafe.Add_Click({
  if (-not $cmbAdapter.Text) { Log "Select an adapter."; return }
  try {
    Log "Starting safe repair and backup…"
    $dir = Safe-Repair -AdapterName $cmbAdapter.Text -Ssid $txtSsid.Text
    $r = Test-Connectivity
    Log ("Connectivity → ICMP:{0} DNS:{1} Overall:{2}" -f $r.ICMP,$r.DNS,$r.Overall)
    Log "Backup at: $dir"
  } catch { Log "Error: $($_.Exception.Message)" }
})

$btnAgg.Add_Click({
  if (-not $cmbAdapter.Text) { Log "Select an adapter."; return }
  $res = [System.Windows.Forms.MessageBox]::Show("Aggressive reset rewrites TCP/IP and Winsock and usually requires reboot.","Confirm",4,[System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    $dir = New-BackupDir
    Save-State -Dir $dir -AdapterName $cmbAdapter.Text
    Log "Backup at: $dir"
    Aggressive-Reset -LogDir $dir
    Log "Aggressive reset complete. Reboot is recommended."
  } catch { Log "Error: $($_.Exception.Message)" }
})

$btnRollback.Add_Click({
  if (-not (Test-Path $BackupRoot)) { Log "No backups found."; return }
  $latest = Get-ChildItem $BackupRoot | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $latest) { Log "No backups found."; return }
  try {
    Log "Restoring from $($latest.FullName)…"
    Restore-State -Dir $latest.FullName
    $r = Test-Connectivity
    Log ("Connectivity → ICMP:{0} DNS:{1} Overall:{2}" -f $r.ICMP,$r.DNS,$r.Overall)
    Log "Rollback finished."
  } catch { Log "Error: $($_.Exception.Message)" }
})

[void]$form.ShowDialog()