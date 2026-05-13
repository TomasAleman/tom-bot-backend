# Crea una instancia en Evolution API local sin usar el Manager (evita 401 si el token en localStorage falla).
# Requisitos: contenedor evolution-api levantado (docker-compose.local.yml).
#
# Uso:
#   .\scripts\evolution_local_create_instance.ps1 -InstanceName "tom-bot-local"
#   .\scripts\evolution_local_create_instance.ps1 -InstanceName "test" -ApiKey "tu-clave" -BaseUrl "http://127.0.0.1:8081"

param(
    [Parameter(Mandatory = $true)]
    [string] $InstanceName,
    [string] $ApiKey = "tom-bot-evo-local",
    [string] $BaseUrl = "http://localhost:8081",
    [switch] $Qrcode
)

$BaseUrl = $BaseUrl.TrimEnd('/')
$bodyObj = @{
    instanceName = $InstanceName
    integration  = "WHATSAPP-BAILEYS"
    qrcode       = [bool]$Qrcode
}
$body = $bodyObj | ConvertTo-Json

try {
    $r = Invoke-RestMethod -Uri "$BaseUrl/instance/create" -Method Post `
        -Headers @{ apikey = $ApiKey } -ContentType "application/json; charset=utf-8" -Body $body
    Write-Host "OK instancia creada:" $r.instance.instanceName "estado:" $r.instance.status
    if ($r.hash.PSObject.Properties.Name -contains "apikey" -and $r.hash.apikey) {
        Write-Host "Token de instancia (apikey de instancia):" $r.hash.apikey
    } elseif ($r.hash -is [string]) {
        Write-Host "Hash/token instancia:" $r.hash
    }
}
catch {
    Write-Error $_
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    exit 1
}
