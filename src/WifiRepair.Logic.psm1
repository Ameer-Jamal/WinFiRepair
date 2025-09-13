<#
MIT License

Core logic for WinFiRepair.
#>

Import-Module NetAdapter -ErrorAction SilentlyContinue
Import-Module NetTCPIP  -ErrorAction SilentlyContinue
Import-Module DnsClient -ErrorAction SilentlyContinue

$script:BackupRoot = Join-Path $env:ProgramData "WifiRepair\Backups"
if (-not (Test-Path $script:BackupRoot)) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null }

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
  }
}

function Get-WifiAdapterNames {
  $names = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Status -eq 'Up' -and (
        ($_.NdisPhysicalMedium -as [string]) -match '802\.11|Wireless' -or
        $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11' -or
        $_.Name -match 'Wi-?Fi'
      )
    } | Select-Object -ExpandProperty Name
  if (-not $names -or $names.Count -eq 0) {
    $names = netsh wlan show interfaces |
      Select-String '^\s*Name\s*:\s*(.+)$' |
      ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
      Sort-Object -Unique
  }
  return $names
}

function New-BackupDir {
  param([string]$Root = $script:BackupRoot)
  if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
  $dir = Join-Path $Root (Get-Date -Format "yyyyMMdd_HHmmss")
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dir "wlan_profiles") -Force | Out-Null
  return $dir
}

function Save-NetworkState {
  param(
    [Parameter(Mandatory)] [string]$AdapterName,
    [Parameter(Mandatory)] [string]$Dir
  )
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
  cmd /c "netsh wlan export profile key=clear folder=""$Dir\wlan_profiles""" | Out-Null
  return $Dir
}

function Restore-NetworkState {
  param([Parameter(Mandatory)] [string]$Dir)

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
    Get-NetIPAddress -InterfaceIndex $ifx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    for ($i=0; $i -lt $s.IPv4.Count; $i++) {
      New-NetIPAddress -InterfaceIndex $ifx -IPAddress $s.IPv4[$i] -PrefixLength $s.Prefix[$i] -DefaultGateway $s.Gateway[0] -ErrorAction SilentlyContinue | Out-Null
    }
    if ($s.DnsFromDhcp) {
      Set-DnsClientServerAddress -InterfaceIndex $ifx -ResetServerAddresses
    } elseif ($s.DnsServers) {
      Set-DnsClientServerAddress -InterfaceIndex $ifx -ServerAddresses $s.DnsServers
    }
  }

  $pdir = Join-Path $Dir "wlan_profiles"
  if (Test-Path $pdir) {
    Get-ChildItem $pdir -Filter *.xml | ForEach-Object {
      cmd /c "netsh wlan add profile filename=""$($_.FullName)"" user=current" | Out-Null
    }
  }
}

function Invoke-SafeRepair {
  param([Parameter(Mandatory)] [string]$AdapterName, [string]$Ssid)
  $if = Get-NetAdapter | Where-Object { $_.Name -eq $AdapterName }
  if (-not $if) { throw "Adapter not found: $AdapterName" }

  $dir = New-BackupDir
  Save-NetworkState -AdapterName $AdapterName -Dir $dir | Out-Null
  try { Checkpoint-Computer -Description "WifiRepair $([IO.Path]::GetFileName($dir))" -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue } catch {}

  ipconfig /flushdns | Out-Null
  try { Restart-Service -Name WlanSvc  -Force -ErrorAction SilentlyContinue } catch {}
  try { Restart-Service -Name Dnscache -Force -ErrorAction SilentlyContinue } catch {}
  try { Restart-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

  $dhcp = (Get-NetIPConfiguration -InterfaceIndex $if.ifIndex).IPv4Address.Dhcp -contains "Enabled"
  if ($dhcp) {
    ipconfig /release $AdapterName | Out-Null
    Start-Sleep -Seconds 2
    ipconfig /renew  $AdapterName | Out-Null
  }
  if ($Ssid) { cmd /c "netsh wlan connect name=""$Ssid"" interface=""$AdapterName""" | Out-Null }
  return $dir
}

function Invoke-AggressiveReset {
  param([Parameter(Mandatory)] [string]$LogDir)
  cmd /c "netsh int ip reset `"$LogDir\ip_reset.log`"" | Out-Null
  cmd /c "netsh winsock reset" | Out-Null
}

function Test-Connectivity {
  param([int]$TcpTimeoutMs=2000, [int]$HttpTimeoutSec=3)

  $dnsOk = $false
  try { $null = Resolve-DnsName -Name "www.microsoft.com" -ErrorAction Stop; $dnsOk = $true } catch {}

  $tcpOk = $false
  foreach ($ep in @(@{Host='1.1.1.1';Port=443}, @{Host='8.8.8.8';Port=443})) {
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $iar = $c.BeginConnect($ep.Host, $ep.Port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne($TcpTimeoutMs)) { $c.EndConnect($iar); $tcpOk = $true; $c.Close(); break }
      $c.Close()
    } catch {}
  }

  $httpOk = $false
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://www.msftconnecttest.com/connecttest.txt")
    $req.Method="GET"; $req.Timeout=$HttpTimeoutSec*1000; $req.ReadWriteTimeout=$HttpTimeoutSec*1000
    $req.UserAgent="WinFiRepair"; $req.Proxy=[System.Net.WebRequest]::GetSystemWebProxy(); $req.Proxy.Credentials=[System.Net.CredentialCache]::DefaultCredentials
    $res = $req.GetResponse(); if ($res.StatusCode -eq 200) { $httpOk = $true }; $res.Close()
  } catch {}

  [PSCustomObject]@{ TCP443=$tcpOk; DNS=$dnsOk; HTTP=$httpOk; Overall=($dnsOk -and ($tcpOk -or $httpOk)) }
}

function Get-Backups {
  if (-not (Test-Path $script:BackupRoot)) { return @() }
  Get-ChildItem $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object @{n='Name';e={$_.Name}}, @{n='Path';e={$_.FullName}}
}

Export-ModuleMember -Function Assert-Admin,Get-WifiAdapterNames,New-BackupDir,Save-NetworkState,Restore-NetworkState,Invoke-SafeRepair,Invoke-AggressiveReset,Test-Connectivity,Get-Backups
