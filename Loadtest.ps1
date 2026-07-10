<#
.SYNOPSIS
    Downloads the results.zip / result artifacts for an Azure Load Testing run using the
    data-plane REST API and a SAS URL. Intended as the 3rd pipeline stage for tests that
    exceed 3 hours (or 45 engine instances), where Azure Load Testing does NOT auto-publish
    results.zip to the pipeline, and stage 2 (download artifact/consolidate) has nothing to pick up.

.NOTES
    Requires: Azure CLI logged in (use the AzureCLI@2 pipeline task with your service connection).
    The identity running this needs "Load Test Reader" (or Contributor) RBAC on the ALT resource.

.PARAMETER TestType
    Pipeline variable selecting which test to fetch. 'LoadTest' completes under 3 hours and is
    already handled by stage 2 (artifact is auto-published) — this script is a no-op for it.
    'EnduranceTest' runs longer than 3 hours, so this script finds the test by display name,
    then finds its latest completed run and pulls results via SAS URL.

.PARAMETER TestDisplayName
    Optional. The display name of the test in Azure Load Testing to resolve automatically.
    If omitted, defaults to the value of -TestType (e.g. a test literally named "EnduranceTest").
    Use this if your actual test display name in the portal differs from the pipeline variable value.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$LoadTestResourceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet("LoadTest", "EnduranceTest")]
    [string]$TestType,

    [string]$TestDisplayName,

    [string]$OutputDir = "$(Build.ArtifactStagingDirectory)/LoadTestResults",

    [int]$MaxRetries = 5,

    [string]$ApiVersion = "2024-05-01-preview"
)

$ErrorActionPreference = "Stop"

function Write-Section($msg) { Write-Host "##[section]$msg" }
function Write-Info($msg)    { Write-Host "##[command]$msg" }

Write-Section "Azure Load Testing - results retrieval stage"
Write-Info "TestType = $TestType"

if ($TestType -eq "LoadTest") {
    Write-Host "LoadTest completes in under 3 hours - Azure Load Testing already published results.zip"
    Write-Host "as a pipeline artifact, and stage 2 already downloaded/consolidated it. Nothing to do here."
    exit 0
}

if (-not $TestDisplayName) { $TestDisplayName = $TestType }

az account set --subscription $SubscriptionId | Out-Null

# ---------------------------------------------------------------------------
# 1. Resolve the data-plane endpoint for the Load Testing resource
# ---------------------------------------------------------------------------
Write-Info "Resolving data-plane endpoint for resource '$LoadTestResourceName'..."
$ltResourceJson = az load show --name $LoadTestResourceName --resource-group $ResourceGroup -o json
if (-not $ltResourceJson) { throw "Could not find load test resource '$LoadTestResourceName' in RG '$ResourceGroup'." }
$ltResource = $ltResourceJson | ConvertFrom-Json
$dataPlaneUri = $ltResource.dataPlaneURI
if (-not $dataPlaneUri) { throw "Resource lookup succeeded but no dataPlaneURI was returned." }
Write-Host "Data-plane endpoint: $dataPlaneUri"

# ---------------------------------------------------------------------------
# 2. Auto-resolve the Test ID from the display name (no hardcoded ID needed)
# ---------------------------------------------------------------------------
Write-Section "Resolving Test ID for display name '$TestDisplayName'"
$allTestsJson = az load test list --load-test-resource $LoadTestResourceName --resource-group $ResourceGroup -o json
if (-not $allTestsJson) { throw "Could not list tests on resource '$LoadTestResourceName'." }
$allTests = $allTestsJson | ConvertFrom-Json

$matches = $allTests | Where-Object { $_.displayName -eq $TestDisplayName }

if (-not $matches) {
    $available = ($allTests | Select-Object -ExpandProperty displayName) -join ", "
    throw "No test found with displayName '$TestDisplayName'. Available tests: $available"
}
if ($matches.Count -gt 1) {
    throw "Multiple tests found with displayName '$TestDisplayName'. Display names must be unique for auto-lookup to work, or pass -TestDisplayName with a more specific value."
}

$LoadTestId = $matches.testId
Write-Host "Resolved Test ID: $LoadTestId  (displayName: $TestDisplayName)"

# ---------------------------------------------------------------------------
# 3. Get an AAD token for the Load Testing data plane
# ---------------------------------------------------------------------------
$resource = "https://cnt-prod.loadtesting.azure.com"
$token = az account get-access-token --resource $resource --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token" }

# ---------------------------------------------------------------------------
# 4. List test runs for this Test ID, find latest completed (DONE) run
# ---------------------------------------------------------------------------
Write-Section "Looking up latest completed run for TestId '$LoadTestId'"
$listUrl = "https://$dataPlaneUri/test-runs?api-version=$ApiVersion&testId=$LoadTestId&orderby=executedDateTime%20desc"
$runsResponse = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get

$latestRun = $runsResponse.value |
    Where-Object { $_.status -eq "DONE" } |
    Sort-Object { [datetime]$_.endDateTime } -Descending |
    Select-Object -First 1

if (-not $latestRun) {
    throw "No completed (status=DONE) test run found for TestId '$LoadTestId'. Check the test is finished."
}

$testRunId = $latestRun.testRunId
Write-Host "Latest completed run: $testRunId  (ended $($latestRun.endDateTime), result: $($latestRun.testResult))"

# ---------------------------------------------------------------------------
# 5. Get full run detail -> SAS URL to the result artifact
# ---------------------------------------------------------------------------
$runDetailUrl = "https://$dataPlaneUri/test-runs/$($testRunId)?api-version=$ApiVersion"
$runDetail = Invoke-RestMethod -Uri $runDetailUrl -Headers $headers -Method Get

$sasUrl = $runDetail.testArtifacts.outputArtifacts.resultFileInfo.url

if (-not $sasUrl) {
    Write-Warning "resultFileInfo.url was empty on the test run object."
    Write-Warning "For runs over 3 hours / 45 engines, Azure sometimes only exposes results via the storage"
    Write-Warning "account container (portal: Test run > Download > Results > Copy SAS URL). If this keeps"
    Write-Warning "happening, switch to a Bring-Your-Own-Storage load test resource so you can pull blobs"
    Write-Warning "directly with az storage / azcopy using RBAC instead of relying on this API field."
    throw "Could not resolve a SAS URL for the result artifact on run $testRunId."
}

Write-Host "SAS URL resolved (masked): $($sasUrl.Substring(0, [Math]::Min(80,$sasUrl.Length)))..."

# ---------------------------------------------------------------------------
# 6. Download with retry (endurance test result files can be large)
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$destination = Join-Path $OutputDir "results.zip"

$ProgressPreference = "SilentlyContinue"
$attempt = 0
$downloaded = $false

while (-not $downloaded -and $attempt -lt $MaxRetries) {
    $attempt++
    try {
        Write-Info "Download attempt $attempt/$MaxRetries -> $destination"
        Invoke-WebRequest -Uri $sasUrl -OutFile $destination -UseBasicParsing
        $downloaded = $true
    }
    catch {
        Write-Warning "Attempt $attempt failed: $($_.Exception.Message)"
        if ($attempt -lt $MaxRetries) {
            $backoff = 10 * $attempt
            Write-Host "Retrying in $backoff seconds..."
            Start-Sleep -Seconds $backoff
        }
        else {
            throw
        }
    }
}

$sizeMB = [math]::Round((Get-Item $destination).Length / 1MB, 2)
Write-Section "Downloaded results.zip successfully ($sizeMB MB) -> $destination"

Write-Host "##vso[task.setvariable variable=LoadTestResultsZipPath]$destination"





yaml:






- task: AzureCLI@2
  inputs:
    azureSubscription: '$(serviceConnection)'
    scriptType: 'ps'
    scriptLocation: 'scriptPath'
    scriptPath: '$(System.DefaultWorkingDirectory)/Get-LoadTestResults.ps1'
    arguments: >
      -LoadTestResourceName $(loadTestResource)
      -ResourceGroup $(loadTestResourceGroup)
      -SubscriptionId $(subscriptionId)
      -TestType $(TestType)

