[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 78)
    Write-Host $Title
    Write-Host ("=" * 78)
}

function Get-EnterpriseMgmtTasks([string]$EnrollmentId) {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return @()
    }
    try {
        return @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$EnrollmentId\" -ErrorAction Stop)
    } catch {
        return @()
    }
}

Write-Host "Windows MDM Enrollment Diagnostics"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "This script is read-only. It does not enroll, unenroll, or change the device."
$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
Write-Host "Running as administrator: $isAdministrator"
if (-not $isAdministrator) {
    Write-Host "Run the launcher as Administrator if EnterpriseMgmt tasks are not visible."
}

Write-Section "1. Device join state (dsregcmd /status)"
$dsregPath = "$env:SystemRoot\System32\dsregcmd.exe"
if (Test-Path $dsregPath) {
    $dsregOutput = @(& $dsregPath /status 2>$null)
    $importantLines = @($dsregOutput | Where-Object {
        $_ -match '^\s*(AzureAdJoined|EnterpriseJoined|DomainJoined|WorkplaceJoined|DeviceId|TenantId|TenantName|MdmUrl|MdmTouUrl|MdmComplianceUrl)\s*:'
    })
    if ($importantLines.Count -gt 0) {
        $importantLines | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "dsregcmd returned no recognized join-state lines."
    }
} else {
    Write-Host "dsregcmd.exe is unavailable on this Windows version."
}

Write-Section "2. Enrollment registry keys and companion evidence"
$registryCandidates = @()
$activeCandidates = @()

try {
    $enrollmentKeys = @(Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction Stop)
    foreach ($key in $enrollmentKeys) {
        $enrollmentId = [string]$key.PSChildName
        if ($enrollmentId -notmatch '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$') {
            continue
        }

        $properties = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if (-not $properties) { continue }

        $providerId = [string]$properties.ProviderID
        $discoveryUrl = [string]$properties.DiscoveryServiceFullURL
        $triggerFields = @()
        if (-not [string]::IsNullOrWhiteSpace($providerId)) { $triggerFields += "ProviderID" }
        if (-not [string]::IsNullOrWhiteSpace($discoveryUrl)) { $triggerFields += "DiscoveryServiceFullURL" }
        if ($null -ne $properties.EnrollmentState) { $triggerFields += "EnrollmentState" }
        $hasEnrollmentMarker = (
            -not [string]::IsNullOrWhiteSpace($providerId) -or
            -not [string]::IsNullOrWhiteSpace($discoveryUrl) -or
            $null -ne $properties.EnrollmentState
        )
        if (-not $hasEnrollmentMarker) { continue }

        $omadmPath = "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$enrollmentId"
        $hasOmadmAccount = Test-Path $omadmPath
        $tasks = @(Get-EnterpriseMgmtTasks $enrollmentId)
        $isActiveEvidence = ($hasOmadmAccount -or $tasks.Count -gt 0)

        $candidate = [pscustomobject]@{
            EnrollmentId = $enrollmentId
            TriggerFields = $triggerFields -join "+"
            ProviderID = if ([string]::IsNullOrWhiteSpace($providerId)) { "(not named)" } else { $providerId }
            EnrollmentState = if ($null -eq $properties.EnrollmentState) { "(not reported)" } else { $properties.EnrollmentState }
            EnrollmentType = if ($null -eq $properties.EnrollmentType) { "(not reported)" } else { $properties.EnrollmentType }
            DiscoveryServiceFullURL = if ([string]::IsNullOrWhiteSpace($discoveryUrl)) { "(not reported)" } else { $discoveryUrl }
            UPN = if ([string]::IsNullOrWhiteSpace([string]$properties.UPN)) { "(not reported)" } else { [string]$properties.UPN }
            OMADMAccountPresent = $hasOmadmAccount
            EnterpriseMgmtTaskCount = $tasks.Count
            ActiveCompanionEvidence = $isActiveEvidence
        }

        $registryCandidates += $candidate
        if ($isActiveEvidence) { $activeCandidates += $candidate }

        $candidate | Format-List | Out-String | Write-Host
        if ($tasks.Count -gt 0) {
            Write-Host "EnterpriseMgmt tasks:"
            $tasks | Select-Object TaskPath, TaskName, State | Format-Table -AutoSize | Out-String | Write-Host
        }
    }
} catch {
    Write-Host "Could not read HKLM:\SOFTWARE\Microsoft\Enrollments"
    Write-Host $_.Exception.Message
}

if ($registryCandidates.Count -eq 0) {
    Write-Host "No enrollment-like GUID keys were found."
}

Write-Section "3. Recent MDM enrollment events"
$mdmLogName = "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin"
try {
    $mdmEvents = @(Get-WinEvent -FilterHashtable @{
        LogName = $mdmLogName
        Id = 75, 76
    } -MaxEvents 10 -ErrorAction Stop)
    if ($mdmEvents.Count -gt 0) {
        $mdmEvents |
            Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Format-List |
            Out-String |
            Write-Host
    } else {
        Write-Host "No Event ID 75 (success) or 76 (failure) entries were found."
    }
} catch {
    Write-Host "The MDM enrollment event log could not be read or contained no matching events."
    Write-Host $_.Exception.Message
}

Write-Section "4. Verdict and interpretation"
if ($activeCandidates.Count -gt 0) {
    Write-Host "VERDICT: Correlated enrollment artifacts detected; likely enrolled."
    Write-Host "WHY: At least one enrollment registry key has a matching OMADM account"
    Write-Host "or EnterpriseMgmt scheduled tasks. These companion artifacts make the"
    Write-Host "result stronger than a registry-key-only match, but it is not server-side"
    Write-Host "confirmation that the device is still present in the MDM console."
} elseif ($registryCandidates.Count -gt 0) {
    Write-Host "VERDICT: Registry artifacts only; active MDM is NOT confirmed."
    Write-Host "WHY: Enrollment-looking keys exist, but no matching OMADM account or"
    Write-Host "EnterpriseMgmt scheduled tasks were found. The keys may be stale remnants"
    Write-Host "of an old enrollment, provisioning attempt, or unenrollment."
} else {
    Write-Host "VERDICT: No MDM enrollment evidence detected by these checks."
}

Write-Host ""
Write-Host "Important: MdmUrl in dsregcmd means the tenant advertises an MDM endpoint;"
Write-Host "by itself it does not prove this device is actively enrolled."
