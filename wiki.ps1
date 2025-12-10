$organization = "minnekanti444"
$project      = "Newhotel"
$wikiName     = "6ea44373-2b9b-46b5-82a3-2d22a0a940df"
$pat          = "4Rt7EhdtRjbUe962MIZHTxz4LGNW62O3YJNqt4wdf8n0vGJX8VjBJQQJ99BLACAAAAAAAAAAAAASAZDO41jH"
$outputFolder = "C:\WikiDownload"
$outputJson   = Join-Path $outputFolder "wiki-pages-recursive.json"

# Output
$outputFolder = "C:\WikiDownload"
$jsonOutput   = Join-Path $outputFolder "wiki-pages-with-content.json"
$exportMarkdownFiles = $true   # set $false if you don't want .md files

# ---- PREP OUTPUT FOLDER -------------------------------------------
if (-not (Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

# ---- AUTH ----------------------------------------------------------
$encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $encoded" }

$wikiBaseUrl = "https://dev.azure.com/$organization/$project/_apis/wiki/wikis/$wikiId"

# ---- RECURSIVE FUNCTION -------------------------------------------
function Get-WikiPageTreeWithContent {
    param(
        [string]$Path = "/"   # default = root
    )

    # 1) Call tree endpoint to get this page + its subPages
    $encodedPath = [uri]::EscapeDataString($Path)
    $treeUrl     = "$wikiBaseUrl/pages?path=$encodedPath&recursionLevel=OneLevel&api-version=7.1"
    Write-Host "Tree call: $treeUrl" -ForegroundColor Cyan

    try {
        $tree = Invoke-RestMethod -Uri $treeUrl -Headers $headers -Method GET
    }
    catch {
        Write-Host "❌ ERROR getting tree for path '$Path': $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $body   = $reader.ReadToEnd()
            Write-Host "Response body: $body"
        }
        return @()
    }

    # 2) Call includeContent endpoint to fetch markdown for THIS page
    $contentUrl = "$wikiBaseUrl/pages?path=$encodedPath&includeContent=true&api-version=7.1"
    Write-Host "Content call: $contentUrl" -ForegroundColor DarkCyan

    try {
        $pageWithContent = Invoke-RestMethod -Uri $contentUrl -Headers $headers -Method GET
    }
    catch {
        Write-Host "❌ ERROR getting content for '$Path': $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $body   = $reader.ReadToEnd()
            Write-Host "Response body: $body"
        }
        $pageWithContent = $null
    }

    $pageResults = @()

    if ($pageWithContent) {
        $content = $pageWithContent.content
        $len     = if ($content) { $content.Length } else { 0 }
        Write-Host "  → Path: $($pageWithContent.path) | Content length: $len" -ForegroundColor Green

        $pageObj = [PSCustomObject]@{
            id        = $pageWithContent.id
            path      = $pageWithContent.path
            url       = $pageWithContent.url
            remoteUrl = $pageWithContent.remoteUrl
            content   = $content
        }

        $pageResults += $pageObj

        # Optionally export a .md file for this page
        if ($exportMarkdownFiles -and $content) {
            $relativePath = $pageWithContent.path.TrimStart("/")
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $relativePath = "Root"
            }

            # Windows-safe filename
            $safeRelativePath = ($relativePath -replace '[:*?"<>|]', "_")
            $filePath = Join-Path $outputFolder ($safeRelativePath + ".md")
            $fileDir  = Split-Path $filePath -Parent

            if (-not (Test-Path $fileDir)) {
                New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            }

            $content | Out-File -FilePath $filePath -Encoding UTF8
        }
    }

    # 3) Recurse into subPages from the tree result
    if ($tree.subPages) {
        foreach ($sub in $tree.subPages) {
            # sub.path will look like "/SamplePage973/SubPage449"
            $pageResults += Get-WikiPageTreeWithContent -Path $sub.path
        }
    }

    return $pageResults
}

# ---- RUN FROM ROOT ------------------------------------------------
Write-Host "Starting recursive wiki crawl..." -ForegroundColor Yellow
$allPages = Get-WikiPageTreeWithContent -Path "/"

Write-Host "`nTotal pages with objects returned: $($allPages.Count)" -ForegroundColor Yellow

# Quick console summary: path + content length
$allPages |
    Select-Object path, @{Name="ContentLength";Expression={ if ($_.content) { $_.content.Length } else { 0 } }}

# ---- EXPORT TO JSON -----------------------------------------------
$allPages | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonOutput -Encoding UTF8
Write-Host "`nJSON exported to: $jsonOutput" -ForegroundColor Magenta

