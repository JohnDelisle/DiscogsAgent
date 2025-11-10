param(
  [string]$SubscriptionId,
  [string]$ResourceGroup = "jmd-discogs",
  [string]$NamePrefix = "jmd-discogs",
  [string]$Location = "canadacentral",
  [string]$DiscogsToken,
  [string]$ClientApiKey,
  [string]$ZipPath,
  [switch]$CodeOnly
)

Write-Host "== DiscogsAgent deploy ==" -ForegroundColor Cyan

if ($SubscriptionId) {
  az account set --subscription $SubscriptionId | Out-Null
}

# Resolve workspace root early (used by Bicep path and packaging)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
${null} = New-Item -ItemType Directory -Path (Join-Path $root "dist") -Force
$distDir = Join-Path $root "dist"
$stamp = Get-Date -Format "yyyyMMddHHmmss"

if (-not $CodeOnly) {
  # 1) Provision infra via Bicep, passing current user object id so they can set secrets
  $userId = az ad signed-in-user show --query id -o tsv
  if (-not $userId) { throw "Unable to get signed-in user id. Please run 'az login'." }

  # Role definition id for Key Vault Secrets Officer
  $kvSecretsOfficer = az role definition list --name "Key Vault Secrets Officer" --query "[0].id" -o tsv
  if (-not $kvSecretsOfficer) { throw "Unable to resolve role id for 'Key Vault Secrets Officer'" }

  Write-Host "== Deploying infrastructure (Bicep) ==" -ForegroundColor Cyan
  $templateFile = Join-Path $root "infra/main.bicep"
  az deployment sub create --location $Location --template-file $templateFile --parameters rgName=$ResourceGroup location=$Location namePrefix=$NamePrefix userObjectId=$userId userRoleDefinitionId=$kvSecretsOfficer | Out-Null
}

$functionAppName = "${NamePrefix}-func"
$vaultName = "${NamePrefix}-kv"

# 2) Set secrets in Key Vault (RBAC assumed) with simple retry to allow RBAC propagation
function Set-SecretWithRetry {
  param(
    [string]$VaultName,
    [string]$Name,
    [string]$Value,
    [int]$Retries = 10,
    [int]$DelaySeconds = 3
  )
  for ($i = 1; $i -le $Retries; $i++) {
    $res = az keyvault secret set --vault-name $VaultName --name $Name --value $Value 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    Start-Sleep -Seconds $DelaySeconds
  }
  throw "Failed to set secret '$Name' in vault '$VaultName' after $Retries attempts."
}

if (-not $CodeOnly) {
  if (-not $DiscogsToken -or -not $ClientApiKey) {
    throw "DiscogsToken and ClientApiKey are required unless -CodeOnly is specified."
  }
  Write-Host "== Setting secrets in Key Vault ==" -ForegroundColor Cyan
  Set-SecretWithRetry -VaultName $vaultName -Name "DISCOGS-TOKEN" -Value $DiscogsToken | Out-Null
  Set-SecretWithRetry -VaultName $vaultName -Name "X-API-KEY" -Value $ClientApiKey | Out-Null
}

# Build a zip payload of az-function (excluding local-only files)
$funcDir = Join-Path $root "az-function"
if (-not (Test-Path $funcDir)) {
  throw "Function directory not found: $funcDir"
}

if (-not $ZipPath) { $ZipPath = Join-Path $distDir "discogsagent-func-$stamp.zip" }

Write-Host "Packaging function app into: $ZipPath" -ForegroundColor Yellow

# Stage folder to preserve correct structure in the zip
$stageDir = Join-Path $distDir "stage-$stamp"
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# Copy all function files except local.settings.json and .pyc; remove cache/venv dirs
Copy-Item -Path (Join-Path $funcDir '*') -Destination $stageDir -Recurse -Force -Exclude 'local.settings.json','*.pyc'
Get-ChildItem -Path $stageDir -Recurse -Directory | Where-Object { $_.Name -in @('.venv','__pycache__') } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }

# Build Python dependencies locally into .python_packages to ensure availability on Azure
$sitePackagesDir = Join-Path $stageDir ".python_packages/lib/site-packages"
New-Item -ItemType Directory -Path $sitePackagesDir -Force | Out-Null
if (Test-Path (Join-Path $stageDir "requirements.txt")) {
  Write-Host "Installing Python dependencies locally into .python_packages..." -ForegroundColor Yellow
  try {
    python -m pip install --upgrade pip | Out-Null
    python -m pip install -r (Join-Path $stageDir "requirements.txt") -t $sitePackagesDir | Out-Null
  } catch {
    Write-Warning "Local pip install failed; relying on Oryx build on Azure."
  }
}

if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $ZipPath -Force

Write-Host "Ensuring Kudu build is enabled (Oryx)" -ForegroundColor Yellow
az functionapp config appsettings set --resource-group $ResourceGroup --name $functionAppName --settings SCM_DO_BUILD_DURING_DEPLOYMENT=1 ENABLE_ORYX_BUILD=true | Out-Null
az functionapp config appsettings set --resource-group $ResourceGroup --name $functionAppName --settings WEBSITE_RUN_FROM_PACKAGE=1 | Out-Null
az functionapp config appsettings set --resource-group $ResourceGroup --name $functionAppName --settings DEBUG_REQUEST_LOG=true | Out-Null

Write-Host "Deploying zip..." -ForegroundColor Yellow
az functionapp deployment source config-zip --resource-group $ResourceGroup --name $functionAppName --src $ZipPath

# Restart to force host to reload functions immediately
az functionapp restart --resource-group $ResourceGroup --name $functionAppName | Out-Null

Write-Host "Deployment complete." -ForegroundColor Green

# 3) Generate an OpenAPI spec bound to this function app host for ChatGPT Action import
try {
  $hostName = az functionapp show --resource-group $ResourceGroup --name $functionAppName --query defaultHostName -o tsv
  if ($hostName) {
    $proxySpecIn = Join-Path $root "openapi/proxy.yaml"
    if (Test-Path $proxySpecIn) {
      $proxySpecOut = Join-Path $distDir "proxy.published.yaml"
      $specText = Get-Content -Path $proxySpecIn -Raw
      # 1) Handle legacy server variable block if present
      if ($specText -match 'url:\s*https://\{host\}/api') {
        $pattern = 'servers:\s*- url:\s*https://\{host\}/api\s*variables:\s*host:\s*default:\s*[^\r\n]+'
        $replacement = "servers:`n  - url: https://$hostName/api"
        $specText = [regex]::Replace($specText, $pattern, $replacement, 'IgnoreCase, Singleline')
      }
      # 2) Replace placeholder token format {{FUNCTION_HOST}} if present
      $specText = $specText -replace 'https://\{\{FUNCTION_HOST\}\}/api', ("https://{0}/api" -f $hostName)
      # 3) If still contains the raw placeholder inside URL, swap it
      $specText = $specText -replace '\{\{FUNCTION_HOST\}\}', $hostName
      $updated = $specText
      Set-Content -Path $proxySpecOut -Value $updated -NoNewline
      Write-Host "Published OpenAPI spec generated: $proxySpecOut" -ForegroundColor Cyan
      Write-Host "Import this file into your ChatGPT Action, and set the API key header there (x-api-key)." -ForegroundColor DarkCyan
    } else {
      Write-Warning "OpenAPI spec not found at $proxySpecIn; skipping published spec generation."
    }
  } else {
    Write-Warning "Could not resolve function host name; skipping OpenAPI published spec generation."
  }
} catch {
  Write-Warning "Failed to generate OpenAPI published spec: $($_.Exception.Message)"
}
