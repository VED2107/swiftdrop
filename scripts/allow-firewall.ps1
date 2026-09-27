# Allows phones on your private network to reach SwiftDrop. Run once, as administrator.
#   powershell -ExecutionPolicy Bypass -File scripts\allow-firewall.ps1 [-Port 8787]
param([int]$Port = 8787)
$name = "SwiftDrop (TCP $Port)"
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Private | Out-Null
Write-Host "Allowed inbound TCP $Port on Private networks. Make sure your Wi-Fi is set to 'Private' in Windows settings."
