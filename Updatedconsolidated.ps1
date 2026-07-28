if (-not $azModule) {
    Install-Module -Name Az -AllowClobber -Force
} else {
    Import-Module Az
}

$tenantId = $env:tenantId
$clientId = $env:clientId
$clientSecret = $env:clientSecret
$subscriptionId = $env:subscriptionId
$storageAccountName = $env:storageAccountName
$containerName = $env:containerName
$testType = $env:testType   # LoadTest or EnduranceLoadTest

$blobPath = "artifact_results/a/loadTest/results.zip"
# Allow override via pipeline env var; falls back to default if not set
$blobPrefix = if ($env:enduranceBlobPrefix) { $env:enduranceBlobPrefix } else { "testresults/a/s/loadtest-results/results/" }

$tempDir = [System.IO.Path]::GetTempPath()
$localZipPath = Join-Path -Path $tempDir -ChildPath "results.zip"
$extractPath = [System.IO.Path]::Combine($tempDir, "extracted")
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$consolidateCsvPath = "$extractPath\consolidate_result.csv"
$destinationBlobPath = "consolidated_result/$env:filename/consolidate_result_$timestamp.csv"
$outputpath = "$env:BUILD_SOURCESDIRECTORY\consolidate_result.csv"

$StartTime = Get-Date
$EndTime = $StartTime.AddMinutes(30)

if ($localZipPath -and (Test-Path -Path $localZipPath)) {
    Remove-Item -Path $localZipPath -Force
}
if ($extractPath -and (Test-Path -Path $extractPath)) {
    Remove-Item -Path $extractPath -Recurse -Force
}
New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

$securePassword = ConvertTo-SecureString $clientSecret -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($clientId, $securePassword)
Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $tenantId

$context = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
$SasToken = New-AzStorageContainerSASToken -Name $containerName -Permission rwl -StartTime $StartTime -ExpiryTime $EndTime -Context $context
$StorageContext = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $SasToken

if ($testType -eq "EnduranceLoadTest") {

    Write-Output "Looking for CSV blobs under prefix: $blobPrefix"

    # -Prefix is the correct way to list by virtual folder path; -Blob with a wildcard is unreliable for this
    $blobs = Get-AzStorageBlob -Container $containerName -Prefix $blobPrefix -Context $StorageContext |
             Where-Object { $_.Name -like "*.csv" }

    if (-not $blobs) {
        # Diagnostic: show what's actually in the container so you can see the real path
        Write-Warning "No CSV blobs found under prefix: $blobPrefix"
        Write-Warning "Listing top-level items in container '$containerName' for debugging:"
        Get-AzStorageBlob -Container $containerName -Context $StorageContext -MaxCount 50 |
            Select-Object -ExpandProperty Name |
            ForEach-Object { Write-Warning " - $_" }
        Write-Error "Aborting: no CSV blobs matched. Check the prefix above against the listed blob names."
        exit 1
    }

    Write-Output "Found $($blobs.Count) CSV blob(s) under prefix."

    foreach ($blob in $blobs) {
        $safeName = ($blob.Name.Substring($blobPrefix.Length)) -replace '[\\/]', '_'
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = [System.IO.Path]::GetFileName($blob.Name) }
        $destFile = Join-Path -Path $extractPath -ChildPath $safeName
        Get-AzStorageBlobContent -Blob $blob.Name -Container $containerName -Destination $destFile -Context $StorageContext -Force | Out-Null
    }

} else {

    Get-AzStorageBlobContent -Blob $blobPath -Container $containerName -Destination $localZipPath -Context $StorageContext

    if ($localZipPath -and (Test-Path -Path $localZipPath)) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($localZipPath, $extractPath)
    } else {
        Write-Error "The ZIP file was not downloaded correctly."
        exit 1
    }
}

$csvFiles = Get-ChildItem -Path $extractPath -Filter *.csv
if (-not $csvFiles) {
    Write-Error "No CSV files found in $extractPath after retrieval step."
    exit 1
}

$Data = @()
foreach ($csvfile in $csvFiles) {
    $csvData = Import-Csv -Path $csvfile.FullName
    $Data += $csvData
}

$Data | Export-Csv -Path $consolidateCsvPath -NoTypeInformation
Set-AzStorageBlobContent -File $consolidateCsvPath -Container $containerName -Blob $destinationBlobPath -Context $StorageContext
Copy-Item -Path $consolidateCsvPath -Destination $outputpath
Write-Output "Files extracted to: $extractPath"
Write-Output "Consolidated CSV file created at: $consolidateCsvPath"
