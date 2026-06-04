param(
    [string]$AddStorage         = "false",
    [string]$AddKeyVault        = "false",
    [string]$AddSQL             = "false",
    [string]$AddFunction        = "false",
    [string]$AddAppService      = "false",
    [string]$StorageAccountName = " ",
    [string]$KeyVaultName       = " ",
    [string]$SQLServerName      = " ",
    [string]$FunctionAppName    = " ",
    [string]$AppServiceName     = " ",
    [string]$IPAddresses        = " ",
    [string]$RuleNames          = " ",
    [string]$StartIPs           = " ",
    [string]$EndIPs             = " ",
    [string]$Priorities         = " "
)

$StorageAccountName = $StorageAccountName.Trim()
$KeyVaultName       = $KeyVaultName.Trim()
$SQLServerName      = $SQLServerName.Trim()
$FunctionAppName    = $FunctionAppName.Trim()
$AppServiceName     = $AppServiceName.Trim()
$IPAddresses        = $IPAddresses.Trim()
$RuleNames          = $RuleNames.Trim()
$StartIPs           = $StartIPs.Trim()
$EndIPs             = $EndIPs.Trim()
$Priorities         = $Priorities.Trim()

$runStorage    = $AddStorage    -eq "True"
$runKeyVault   = $AddKeyVault   -eq "True"
$runSQL        = $AddSQL        -eq "True"
$runFunction   = $AddFunction   -eq "True"
$runAppService = $AddAppService -eq "True"

if (-not ($runStorage -or $runKeyVault -or $runSQL -or $runFunction -or $runAppService)) {
    Write-Error "No resource selected. Tick at least one."; exit 1
}

function Split-CSV([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return [string[]]@() }
    [string[]]$result = $value.Split([char]',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    return $result
}

function Resolve-IPEntry([string]$ip) {
    $ip = $ip.Trim()
    if ($ip -match "/") {
        if ($ip -match "^(\d{1,3}\.){3}\d{1,3}/(\d+)$" -and [int]$Matches[2] -ge 24 -and [int]$Matches[2] -le 31) { return $ip }
        Write-Error "Invalid CIDR '$ip'. Azure accepts /24 to /31 only."; exit 1
    }
    if ($ip -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") { return $ip }
    Write-Error "Invalid IP: '$ip'"; exit 1
}

function Resolve-FreePriority([int]$requested, [System.Collections.Generic.HashSet[int]]$takenPriorities) {
    $candidate = $requested
    while ($takenPriorities.Contains($candidate)) {
        Write-Host "  [PRIORITY] $candidate is taken, trying $($candidate + 1)..." -ForegroundColor DarkYellow
        $candidate++
    }
    return $candidate
}

function Get-WebAppRG([string]$appName) {
    $app = Get-AzWebApp -Name $appName -ErrorAction SilentlyContinue
    if (-not $app) {
        $app = Get-AzWebApp | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
    }
    if (-not $app) { Write-Error "App '$appName' not found in any resource group."; exit 1 }
    return $app.ResourceGroup
}

Write-Host "========================================" -ForegroundColor Magenta
Write-Host " Storage:$runStorage | KV:$runKeyVault | SQL:$runSQL | Func:$runFunction | AppSvc:$runAppService"
Write-Host "  RAW IPAddresses : [$IPAddresses]"
Write-Host "  RAW RuleNames   : [$RuleNames]"
Write-Host "  RAW Priorities  : [$Priorities]"
Write-Host "========================================" -ForegroundColor Magenta

if ($runStorage) {
    Write-Host "`n[STORAGE]" -ForegroundColor Cyan
    if (-not $StorageAccountName) { Write-Error "StorageAccountName is required."; exit 1 }
    if (-not $IPAddresses)        { Write-Error "IPAddresses is required."; exit 1 }

    [string[]]$resolvedIPs = Split-CSV $IPAddresses | ForEach-Object { Resolve-IPEntry $_ }
    $rg = (Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $StorageAccountName }).ResourceGroupName
    if (-not $rg) { Write-Error "Storage Account '$StorageAccountName' not found."; exit 1 }

    $existing = (Get-AzStorageAccount -ResourceGroupName $rg -Name $StorageAccountName).NetworkRuleSet.IpRules.IPAddressOrRange
    foreach ($ip in $resolvedIPs) {
        if ($existing -contains $ip) {
            Write-Host "  [SKIP]  $ip already exists" -ForegroundColor Yellow
        } else {
            Add-AzStorageAccountNetworkRule -ResourceGroupName $rg -Name $StorageAccountName -IPAddressOrRange $ip
            Write-Host "  [ADDED] $ip" -ForegroundColor Green
        }
    }
}

if ($runKeyVault) {
    Write-Host "`n[KEYVAULT]" -ForegroundColor Cyan
    if (-not $KeyVaultName) { Write-Error "KeyVaultName is required."; exit 1 }
    if (-not $IPAddresses)  { Write-Error "IPAddresses is required."; exit 1 }

    [string[]]$resolvedIPs = Split-CSV $IPAddresses | ForEach-Object { Resolve-IPEntry $_ }
    $rg = (Get-AzKeyVault | Where-Object { $_.VaultName -eq $KeyVaultName }).ResourceGroupName
    if (-not $rg) { Write-Error "Key Vault '$KeyVaultName' not found."; exit 1 }

    $existingNorm = (Get-AzKeyVault -ResourceGroupName $rg -VaultName $KeyVaultName).NetworkAcls.IpAddressRanges |
                    ForEach-Object { $_ -replace "/32$", "" }
    foreach ($ip in $resolvedIPs) {
        if ($existingNorm -contains ($ip -replace "/32$", "")) {
            Write-Host "  [SKIP]  $ip already exists" -ForegroundColor Yellow
        } else {
            Add-AzKeyVaultNetworkRule -ResourceGroupName $rg -VaultName $KeyVaultName -IpAddressRange $ip
            Write-Host "  [ADDED] $ip" -ForegroundColor Green
        }
    }
}


if ($runSQL) {
    Write-Host "`n[SQL]" -ForegroundColor Cyan
    if (-not $SQLServerName) { Write-Error "SQLServerName is required."; exit 1 }
    if (-not $RuleNames)     { Write-Error "RuleNames is required."; exit 1 }
    if (-not $StartIPs)      { Write-Error "StartIPs is required."; exit 1 }
    if (-not $EndIPs)        { Write-Error "EndIPs is required."; exit 1 }

    [string[]]$ruleList  = Split-CSV $RuleNames
    [string[]]$startList = Split-CSV $StartIPs
    [string[]]$endList   = Split-CSV $EndIPs

    if ($ruleList.Count -ne $startList.Count -or $ruleList.Count -ne $endList.Count) {
        Write-Error "Count mismatch — RuleNames:$($ruleList.Count) StartIPs:$($startList.Count) EndIPs:$($endList.Count)"; exit 1
    }

    $rg = (Get-AzSqlServer | Where-Object { $_.ServerName -eq $SQLServerName }).ResourceGroupName
    if (-not $rg) { Write-Error "SQL Server '$SQLServerName' not found."; exit 1 }

    for ($i = 0; $i -lt $ruleList.Count; $i++) {
        $ruleName = $ruleList[$i]; $startIP = $startList[$i]; $endIP = $endList[$i]
        if (-not [System.Net.IPAddress]::TryParse($startIP, [ref]$null)) { Write-Error "Invalid Start IP: $startIP"; exit 1 }
        if (-not [System.Net.IPAddress]::TryParse($endIP,   [ref]$null)) { Write-Error "Invalid End IP: $endIP"; exit 1 }

        Write-Host "  Rule: $ruleName | $startIP -> $endIP"
        $existing = Get-AzSqlServerFirewallRule -ResourceGroupName $rg -ServerName $SQLServerName `
                        -FirewallRuleName $ruleName -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.StartIpAddress -eq $startIP -and $existing.EndIpAddress -eq $endIP) {
                Write-Host "  [SKIP] Same IPs already set" -ForegroundColor Yellow
            } else {
                Set-AzSqlServerFirewallRule -ResourceGroupName $rg -ServerName $SQLServerName `
                    -FirewallRuleName $ruleName -StartIpAddress $startIP -EndIpAddress $endIP
                Write-Host "  [UPDATED] $ruleName" -ForegroundColor Green
            }
        } else {
            New-AzSqlServerFirewallRule -ResourceGroupName $rg -ServerName $SQLServerName `
                -FirewallRuleName $ruleName -StartIpAddress $startIP -EndIpAddress $endIP
            Write-Host "  [ADDED] $ruleName" -ForegroundColor Green
        }
    }
}

function Set-WebAppIPRules {
    param(
        [string]   $AppName,
        [string]   $AppLabel,
        [string]   $RuleNamesParam,
        [string]   $IPAddressesParam,
        [string]   $PrioritiesParam
    )

    Write-Host "`n[$AppLabel]" -ForegroundColor Cyan
    Write-Host "  RAW inputs — Rules:[$RuleNamesParam] IPs:[$IPAddressesParam] Priorities:[$PrioritiesParam]"

    [string[]]$ruleList     = Split-CSV $RuleNamesParam
    [string[]]$resolvedIPs  = Split-CSV $IPAddressesParam | ForEach-Object { Resolve-IPEntry $_ }
    [string[]]$priorityList = Split-CSV $PrioritiesParam

    Write-Host "  Parsed — Rules:$($ruleList.Count) | IPs:$($resolvedIPs.Count) | Priorities:$($priorityList.Count)"
    Write-Host "    Rules      : $($ruleList -join ' | ')"
    Write-Host "    IPs        : $($resolvedIPs -join ' | ')"
    Write-Host "    Priorities : $($priorityList -join ' | ')"

    if ($ruleList.Count -ne $resolvedIPs.Count -or $ruleList.Count -ne $priorityList.Count) {
        Write-Error "$AppLabel count mismatch — Rules:$($ruleList.Count) IPs:$($resolvedIPs.Count) Priorities:$($priorityList.Count)"
        exit 1
    }

    foreach ($p in $priorityList) {
        if ($p -notmatch "^\d+$") { Write-Error "Priority '$p' must be a positive integer."; exit 1 }
    }

    $rg = Get-WebAppRG $AppName
    Write-Host "  App: $AppName | RG: $rg | Rules to process: $($ruleList.Count)"

    $existingRules = (Get-AzWebApp -ResourceGroupName $rg -Name $AppName).SiteConfig.IpSecurityRestrictions

    $takenPriorities = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($r in $existingRules) {
        if ($r.Priority -gt 0) { [void]$takenPriorities.Add([int]$r.Priority) }
    }
    Write-Host "  Existing priorities in use: $( ($takenPriorities | Sort-Object) -join ', ' )"

    for ($i = 0; $i -lt $ruleList.Count; $i++) {
        $ruleName     = $ruleList[$i]
        $ipCidr       = if ($resolvedIPs[$i] -match "/") { $resolvedIPs[$i] } else { "$($resolvedIPs[$i])/32" }
        $requestedPri = [int]$priorityList[$i]

        Write-Host "  [$($i+1)/$($ruleList.Count)] Rule:$ruleName | IP:$ipCidr | Requested Priority:$requestedPri"

        $nameMatch = $existingRules | Where-Object { $_.Name     -eq $ruleName  }
        $ipMatch   = $existingRules | Where-Object { $_.IpAddress -eq $ipCidr   }

        if ($nameMatch) {
            Write-Host "  [SKIP] Rule name '$ruleName' already exists (IP:$($nameMatch.IpAddress) Priority:$($nameMatch.Priority)). Skipping." -ForegroundColor Yellow
            continue
        }
        if ($ipMatch) {
            Write-Host "  [SKIP] IP '$ipCidr' already exists under rule '$($ipMatch.Name)' (Priority:$($ipMatch.Priority)). Skipping." -ForegroundColor Yellow
            continue
        }
        $finalPri = Resolve-FreePriority -requested $requestedPri -takenPriorities $takenPriorities

        if ($finalPri -ne $requestedPri) {
            Write-Host "  [PRIORITY CONFLICT] Priority $requestedPri is taken. Auto-assigned next free priority: $finalPri" -ForegroundColor Yellow
        }

        Add-AzWebAppAccessRestrictionRule -ResourceGroupName $rg -WebAppName $AppName `
            -Name $ruleName -IpAddress $ipCidr -Action Allow -Priority $finalPri

        [void]$takenPriorities.Add($finalPri)
        Write-Host "  [ADDED] $ruleName -> $ipCidr | Priority:$finalPri" -ForegroundColor Green
    }
}

if ($runFunction) {
    if (-not $FunctionAppName) { Write-Error "FunctionAppName is required."; exit 1 }
    Set-WebAppIPRules -AppName $FunctionAppName -AppLabel "AZURE FUNCTION" `
        -RuleNamesParam $RuleNames -IPAddressesParam $IPAddresses -PrioritiesParam $Priorities
}

if ($runAppService) {
    if (-not $AppServiceName) { Write-Error "AppServiceName is required."; exit 1 }
    Set-WebAppIPRules -AppName $AppServiceName -AppLabel "APP SERVICE" `
        -RuleNamesParam $RuleNames -IPAddressesParam $IPAddresses -PrioritiesParam $Priorities
}
