param(
  [string]$SubscriptionId,
  [string]$ResourceGroup = "jmd-discogs",
  [string]$NamePrefix = "jmd-discogs",
  [string]$Location = "canadacentral",  # for symmetry; not directly used here
  [Parameter(Mandatory=$true)][string]$ClientApiKey,
  [string]$DiscogsToken,                 # optional: can override local env to ensure PAT presence
  [string]$Username,
  [int]$PauseSeconds = 2,
  [switch]$IncludeWriteTests,
  [switch]$ResolveHost                    # if set, query Azure for current host instead of static Base
)

# Auto-resolve host if requested, using the same naming convention as deploy script
if ($ResolveHost) {
  if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }
  $functionAppName = "${NamePrefix}-func"
  try {
    $resolvedHost = az functionapp show --resource-group $ResourceGroup --name $functionAppName --query defaultHostName -o tsv
    if ($resolvedHost) { $Base = "https://$resolvedHost/api" }
    else { Write-Warning "Could not resolve function app host; using provided Base: $Base" }
  } catch { Write-Warning "Host resolution failed: $($_.Exception.Message)" }
}

if (-not $Base) {
  # Fallback if user cleared Base and did not request resolve
  $Base = "https://${NamePrefix}-func.azurewebsites.net/api"
}

if ($DiscogsToken) { $env:DISCOGS_TOKEN = $DiscogsToken }

Write-Host "== DiscogsAgent Smoke Test ==" -ForegroundColor Cyan
Write-Host "Base: $Base" -ForegroundColor DarkCyan
Write-Host "RG: $ResourceGroup  NamePrefix: $NamePrefix  Subscription: $SubscriptionId" -ForegroundColor DarkGray
Write-Host ("Auth: DiscogsToken present: {0}" -f ([bool]$env:DISCOGS_TOKEN)) -ForegroundColor DarkGray

$global:TestResults = @()

function Record-Result {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][int]$StatusCode,
    [int[]]$ExpectCodes = @(200),
    [switch]$Skipped
  )
  $passed = $false
  if ($Skipped) { $passed = $true }
  else { $passed = $ExpectCodes -contains $StatusCode }
  $global:TestResults += [pscustomobject]@{
    Name=$Name; Status=$StatusCode; Expected=($ExpectCodes -join ','); Passed=$passed; Skipped=[bool]$Skipped
  }
}

function Show-Headers {
  param($Response)
  $wanted = "Link","ETag","X-Discogs-Ratelimit","X-Discogs-Ratelimit-Used","X-Discogs-Ratelimit-Remaining","X-Discogs-Ratelimit-Reset"
  $obj = [ordered]@{}
  foreach ($h in $wanted) {
    if ($Response.Headers[$h]) { $obj[$h] = ($Response.Headers[$h] -join ', ') }
  }
  if ($obj.Count -gt 0) {
    Write-Host "-- Selected Headers --" -ForegroundColor Cyan
    $obj.GetEnumerator() | ForEach-Object { "{0}: {1}" -f $_.Key, $_.Value } | Write-Host
  }
}

function Invoke-Smoke {
  param([string]$Name,[ScriptBlock]$Action,[int[]]$ExpectCodes=@(200))
  Write-Host "`n[TEST] $Name" -ForegroundColor Yellow
  $resp = $null
  try {
    $resp = & $Action
  } catch {
    Write-Warning "Test '$Name' threw: $($_.Exception.Message)"
  }
  if ($null -ne $resp -and $resp.PSObject.Properties.Match('StatusCode').Count -gt 0) {
    Record-Result -Name $Name -StatusCode ([int]$resp.StatusCode) -ExpectCodes $ExpectCodes
  } else {
    # If no response captured, record as Status 0 (likely exception already printed)
    Record-Result -Name $Name -StatusCode 0 -ExpectCodes $ExpectCodes
  }
  Start-Sleep -Seconds $PauseSeconds
}

$headers = @{ "x-api-key" = $ClientApiKey }

Invoke-Smoke -Name "Ping" -Action {
  $resp = Invoke-WebRequest -Uri "$Base/ping" -Headers $headers -SkipHttpErrorCheck
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  $resp.Content | Write-Host
  return $resp
}

Invoke-Smoke -Name "Artist" -Action {
  $resp = Invoke-WebRequest -Uri "$Base/artists/108713" -Headers $headers -SkipHttpErrorCheck
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  ($resp.Content | ConvertFrom-Json | Select-Object id,name,resource_url) | Format-List | Out-String | Write-Host
  Show-Headers $resp
  return $resp
}

Invoke-Smoke -Name "Artist Releases" -Action {
  $resp = Invoke-WebRequest -Uri "$Base/artists/108713/releases?page=1&per_page=5" -Headers $headers -SkipHttpErrorCheck
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  ($resp.Content | ConvertFrom-Json).releases | Select-Object -First 5 | Format-Table | Out-String | Write-Host
  Show-Headers $resp
  return $resp
}

Invoke-Smoke -Name "Database Search" -Action {
  $resp = Invoke-WebRequest -Uri "$Base/database/search?q=beatles&per_page=5" -Headers $headers -SkipHttpErrorCheck
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  ($resp.Content | ConvertFrom-Json).results | Select-Object id,type,title -First 5 | Format-Table | Out-String | Write-Host
  Show-Headers $resp
  return $resp
}

# Capture ETag from a release
$global:ReleaseEtag = $null
Invoke-Smoke -Name "Release (capture ETag)" -Action {
  $resp = Invoke-WebRequest -Uri "$Base/releases/249504" -Headers $headers -SkipHttpErrorCheck
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  $global:ReleaseEtag = $resp.Headers['ETag']
  Write-Host "ETag: $global:ReleaseEtag" -ForegroundColor Magenta
  Show-Headers $resp
  return $resp
}

if ($ReleaseEtag) {
  Invoke-Smoke -Name "Conditional Release (If-None-Match)" -Action {
    $resp = Invoke-WebRequest -Uri "$Base/releases/249504" -Headers @{"x-api-key"=$ClientApiKey;"If-None-Match"=$ReleaseEtag} -SkipHttpErrorCheck
    Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
    Show-Headers $resp
    return $resp
  } -ExpectCodes @(304)
} else {
  Write-Host "`n[TEST] Conditional Release (If-None-Match)" -ForegroundColor Yellow
  Write-Host "Skipping: no ETag captured from prior test" -ForegroundColor DarkYellow
  Record-Result -Name "Conditional Release (If-None-Match)" -StatusCode 0 -ExpectCodes @(304) -Skipped
}

if ($env:DISCOGS_TOKEN) {
  Invoke-Smoke -Name "Price Suggestions" -Action {
    $resp = Invoke-WebRequest -Uri "$Base/marketplace/price_suggestions/249504" -Headers $headers -SkipHttpErrorCheck
    Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
    ($resp.Content | ConvertFrom-Json) | Format-List | Out-String | Write-Host
    Show-Headers $resp
    return $resp
  } -ExpectCodes @(200)
} else {
  Write-Host "`n[TEST] Price Suggestions" -ForegroundColor Yellow
  Write-Host "Skipping: requires Discogs token" -ForegroundColor DarkYellow
  Record-Result -Name "Price Suggestions" -StatusCode 0 -ExpectCodes @(200) -Skipped
}

if ($Username) {
  if ($env:DISCOGS_TOKEN) {
    Invoke-Smoke -Name "Collection Folders" -Action {
      $resp = Invoke-WebRequest -Uri "$Base/users/$Username/collection/folders" -Headers $headers -SkipHttpErrorCheck
      Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
      if ($resp.StatusCode -eq 200) { ($resp.Content | ConvertFrom-Json).folders | Select-Object id,name | Format-Table | Out-String | Write-Host }
      Show-Headers $resp
      return $resp
    } -ExpectCodes @(200)

    Invoke-Smoke -Name "Wantlist" -Action {
      $resp = Invoke-WebRequest -Uri "$Base/users/$Username/wants?page=1&per_page=5" -Headers $headers -SkipHttpErrorCheck
      Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
      if ($resp.StatusCode -eq 200) { ($resp.Content | ConvertFrom-Json).wants | Select-Object -First 5 | Format-Table | Out-String | Write-Host }
      Show-Headers $resp
      return $resp
    } -ExpectCodes @(200)

    if ($IncludeWriteTests) {
      $releaseToWant = 249504
      Invoke-Smoke -Name "Wantlist Upsert" -Action {
        $resp = Invoke-WebRequest -Uri "$Base/users/$Username/wants/$releaseToWant" -Headers @{"x-api-key"=$ClientApiKey;"Content-Type"="application/json"} -Method PUT -Body (@{} | ConvertTo-Json) -SkipHttpErrorCheck
        Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
        Show-Headers $resp
        return $resp
      } -ExpectCodes @(200,201)

      Invoke-Smoke -Name "Wantlist Delete" -Action {
        $resp = Invoke-WebRequest -Uri "$Base/users/$Username/wants/$releaseToWant" -Headers $headers -Method DELETE -SkipHttpErrorCheck
        Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
        Show-Headers $resp
        return $resp
      } -ExpectCodes @(204)
    }
  } else {
    Write-Host "`n[TEST] Collection Folders" -ForegroundColor Yellow
    Write-Host "Skipping: requires Discogs token" -ForegroundColor DarkYellow
    Record-Result -Name "Collection Folders" -StatusCode 0 -ExpectCodes @(200) -Skipped

    Write-Host "`n[TEST] Wantlist" -ForegroundColor Yellow
    Write-Host "Skipping: requires Discogs token" -ForegroundColor DarkYellow
    Record-Result -Name "Wantlist" -StatusCode 0 -ExpectCodes @(200) -Skipped

    if ($IncludeWriteTests) {
      Write-Host "`n[TEST] Wantlist Upsert" -ForegroundColor Yellow
      Write-Host "Skipping: requires Discogs token" -ForegroundColor DarkYellow
      Record-Result -Name "Wantlist Upsert" -StatusCode 0 -ExpectCodes @(200,201) -Skipped

      Write-Host "`n[TEST] Wantlist Delete" -ForegroundColor Yellow
      Write-Host "Skipping: requires Discogs token" -ForegroundColor DarkYellow
      Record-Result -Name "Wantlist Delete" -StatusCode 0 -ExpectCodes @(204) -Skipped
    }
  }
}

Write-Host "`nAll smoke tests complete." -ForegroundColor Cyan

# Final summary
$passed = $TestResults | Where-Object { $_.Passed -and -not $_.Skipped }
$failed = $TestResults | Where-Object { -not $_.Passed -and -not $_.Skipped }
$skipped = $TestResults | Where-Object { $_.Skipped }

Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $passed.Count, $failed.Count, $skipped.Count) -ForegroundColor Cyan
if ($failed.Count -gt 0) {
  Write-Host "Failures:" -ForegroundColor Red
  $failed | ForEach-Object { Write-Host (" - {0}: got {1}, expected [{2}]" -f $_.Name, $_.Status, $_.Expected) -ForegroundColor Red }
  exit 1
} else {
  Write-Host "OVERALL: PASS" -ForegroundColor Green
}
