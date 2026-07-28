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
$blobPrefix = "testresults/a/s/loadtest-results/results/"

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

    # Endurance test: multiple loose CSVs under a prefix (e.g. .../results/engine1/*.csv), no zip
    $blobs = Get-AzStorageBlob -Container $containerName -Blob "$blobPrefix*" -Context $StorageContext |
             Where-Object { $_.Name -like "*.csv" }

    if (-not $blobs) {
        Write-Error "No CSV blobs found under prefix: $blobPrefix"
        exit 1
    }

    foreach ($blob in $blobs) {
        # flatten into $extractPath, keep unique names in case of duplicate filenames across subfolders (e.g. engine1, engine2)
        $safeName = ($blob.Name.Substring($blobPrefix.Length)) -replace '[\\/]', '_'
        $destFile = Join-Path -Path $extractPath -ChildPath $safeName
        Get-AzStorageBlobContent -Blob $blob.Name -Container $containerName -Destination $destFile -Context $StorageContext -Force | Out-Null
    }

} else {

    # Standard load test: zip download + extract
    Get-AzStorageBlobContent -Blob $blobPath -Container $containerName -Destination $localZipPath -Context $StorageContext

    if ($localZipPath -and (Test-Path -Path $localZipPath)) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($localZipPath, $extractPath)
    } else {
        Write-Error "The ZIP file was not downloaded correctly."
        exit 1
    }
}

# ---- Same consolidation logic for both test types ----
$csvFiles = Get-ChildItem -Path $extractPath -Filter *.csv
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
