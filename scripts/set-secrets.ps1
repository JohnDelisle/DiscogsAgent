# Purpose: Grant the current signed-in user Key Vault RBAC to set secrets, then set Discogs-related secrets.
# Usage: ./scripts/set-secrets.ps1 -ResourceGroupName "jmd-discogs" -VaultName "jmd-discogs-kv" -DiscogsToken "<token>" -ClientApiKey "<api-key>"
param(
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)] [string]$VaultName,
    [Parameter(Mandatory = $true)] [string]$DiscogsToken,
    [Parameter(Mandatory = $true)] [string]$ClientApiKey
)

# Ensure you're logged in to the correct tenant/subscription
Write-Host "Fetching current signed-in user object ID..." -ForegroundColor Cyan
$user = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $user) { throw "Unable to get signed-in user. Run 'az login' and try again." }

Write-Host "Getting Key Vault resource ID..." -ForegroundColor Cyan
$kvId = az keyvault show -n $VaultName -g $ResourceGroupName --query id -o tsv 2>$null
if (-not $kvId) { throw "Key Vault '$VaultName' not found in resource group '$ResourceGroupName'." }

Write-Host "Assigning 'Key Vault Secrets Officer' RBAC to user $user on vault $VaultName..." -ForegroundColor Cyan
az role assignment create `
  --role "Key Vault Secrets Officer" `
  --assignee-object-id $user `
  --assignee-principal-type User `
  --scope $kvId 1>$null

Write-Host "Waiting 10 seconds for role propagation..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host "Setting secrets in Key Vault..." -ForegroundColor Cyan
az keyvault secret set --vault-name $VaultName --name "DISCOGS-TOKEN" --value $DiscogsToken 1>$null
az keyvault secret set --vault-name $VaultName --name "X-API-KEY" --value $ClientApiKey 1>$null

Write-Host "Done. Secrets stored: DISCOGS-TOKEN, X-API-KEY" -ForegroundColor Green
