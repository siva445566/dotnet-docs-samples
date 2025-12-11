$organization = "minnekanti444"
$pat          = "Er0NqzvNjWqG59fiCNaEqxDgWT7n3Dpk2ZYdQCgktOe2b0w6BKRZJQQJ99BLACAAAAAAAAAAAAASAZDO4ALm"


# Target project + target wiki where you want to recreate the structure
$targetProject   = "docker application"          # <- CHANGE THIS
$targetWikiId    = "docker-application.wiki"    # <- CHANGE THIS (ID or name, both work)


$jsonInputPath   = "C:\WikiDownload\wiki-pages-with-content.json"   # <- CHANGE IF NEEDED

# If $true, log a tiny preview of each page being created
$verboseCreate   = $true

# ======================= AUTH SETUP ==========================================

# Create auth header for PAT
$encodedPAT = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers    = @{ Authorization = "Basic $encodedPAT" }

# Base URL for the TARGET wiki
$targetWikiBaseUrl = "https://dev.azure.com/$organization/$targetProject/_apis/wiki/wikis/$targetWikiId"

Write-Host "Target wiki base URL:" -ForegroundColor Cyan
Write-Host "  $targetWikiBaseUrl`n"

# ======================= LOAD JSON ===========================================

if (-not (Test-Path $jsonInputPath)) {
    Write-Host "❌ JSON file not found: $jsonInputPath" -ForegroundColor Red
    return
}

Write-Host "Loading source wiki JSON from: $jsonInputPath" -ForegroundColor Yellow
$jsonRaw = Get-Content $jsonInputPath -Raw
$pages   = $jsonRaw | ConvertFrom-Json

# Ensure $pages is always an array
if ($pages -isnot [System.Collections.IEnumerable]) {
    $pages = @($pages)
}

# Filter out blank paths and root-only path ("/") if present
$pages = $pages | Where-Object {
    $_.path -and $_.path.Trim() -ne "" -and $_.path -ne "/"
}

if (-not $pages -or $pages.Count -eq 0) {
    Write-Host "❌ No valid pages found in JSON (paths empty or only '/')." -ForegroundColor Red
    return
}

Write-Host ("Total pages found in JSON: {0}" -f $pages.Count) -ForegroundColor Green

# Sort pages by depth so parents are created before children
$pages = $pages | Sort-Object {
    ($_.path.TrimStart("/") -split "/").Count
}

Write-Host "`nExample paths (after sorting by depth):" -ForegroundColor Cyan
$pages | Select-Object -First 5 | ForEach-Object {
    Write-Host "  " $_.path
}

# ======================= HELPER: CHECK IF PAGE EXISTS ========================

function Test-TargetWikiPageExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $trimmed = $Path.TrimStart("/")
    $encoded = [uri]::EscapeDataString($trimmed)
    $url     = "$targetWikiBaseUrl/pages?path=$encoded&api-version=7.1"

    try {
        $null = Invoke-RestMethod -Uri $url -Headers $headers -Method GET -ErrorAction Stop
        # 200 → page exists
        return $true
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp -and $resp.StatusCode.value__ -eq 404) {
            # Not found → does not exist
            return $false
        }
        else {
            Write-Host "  !! Unexpected error while checking existence of '$Path': $($_.Exception.Message)" -ForegroundColor Red
            if ($resp) {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body   = $reader.ReadToEnd()
                Write-Host "     Response body: $body"
            }
            # On unknown errors, treat as "exists=false" but effectively skip creation to be safe
            return $true
        }
    }
}

# ======================= CREATE PAGES IN TARGET WIKI =========================

Write-Host "`n--- Recreating pages in target wiki ---`n" -ForegroundColor Yellow

$createdCount = 0
$skippedCount = 0
$failedCount  = 0

foreach ($page in $pages) {

    $path    = $page.path
    $content = $page.content

    if (-not $path) { continue }

    Write-Host "Processing path: '$path'" -ForegroundColor Cyan

    # If path already exists, skip
    $exists = Test-TargetWikiPageExists -Path $path
    if ($exists) {
        Write-Host "  ↳ Skipping (already exists in target wiki)" -ForegroundColor DarkYellow
        $skippedCount++
        continue
    }

    # Build PUT body
    # Even if content is empty, that's okay – it will just be a blank page.
    $bodyObj = @{
        content = $content
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 5

    $trimmedPath = $path.TrimStart("/")
    $encodedPath = [uri]::EscapeDataString($trimmedPath)

    $createUrl = "$targetWikiBaseUrl/pages?path=$encodedPath&api-version=7.1"

    if ($verboseCreate) {
        Write-Host "  Creating page at: $createUrl"
    }

    $params = @{
        Uri         = $createUrl
        Headers     = $headers
        Method      = 'Put'
        ContentType = 'application/json; charset=utf-8'
        Body        = $bodyJson
    }

    try {
        $result = Invoke-RestMethod @params
        $createdCount++
        Write-Host ("  ✅ Created page: {0} (id={1})" -f $result.path, $result.id) -ForegroundColor Green
    }
    catch {
        $failedCount++
        Write-Host "  ❌ Failed to create '$path': $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $respBody = $reader.ReadToEnd()
            Write-Host "     Response body: $respBody"
        }
        # Continue with the next page
    }
}

# ======================= SUMMARY ============================================

Write-Host "`n--- SUMMARY ---" -ForegroundColor Yellow
Write-Host ("  Created : {0}" -f $createdCount) -ForegroundColor Green
Write-Host ("  Skipped : {0} (already existed)" -f $skippedCount) -ForegroundColor DarkYellow
Write-Host ("  Failed  : {0}" -f $failedCount) -ForegroundColor Red

Write-Host "`nDone recreating wiki structure in target wiki." -ForegroundColor Yellow

