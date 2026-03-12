#Requires -Version 5.1
<#
  .SYNOPSIS
    Standalone Windows Update installer for use across a fleet of Windows servers.
    Originally invoked via AWS SSM RunCommand; refactored for direct/manual execution.

  .DESCRIPTION
    Uses PSWindowsUpdate to download and install Windows Updates on the local host.
    Handles .NET Core and SQL updates  via -MicrosoftUpdate flag

    Key behaviours:
      - Tracks local state in a JSON file to avoid unnecessary DynamoDB reads on resumption.
      - Reboot triggered within a specific maintenance window only
      - Staggers patching with an offset relative to Patch Tuesday if needed.

  .PARAMETER TimeoutMinutes
    Maximum time in minutes to wait for download or install jobs before timing out.
    Default: 90.

  .PARAMETER PatchingDaysDelay
    Amount of days to wait after Patch Tuesday to install patches. Useful if you want to offset production hosts from patching immediately.
    Default: 0 (Patch immediately if running on or after Patch Tuesday)

  .PARAMETER FailedUpdatesCacheFileName
    Filename (not full path) for the local cache that persists failed-update state across runs.
    Default: 'FailedUpdates-Cache.json'.

  .EXAMPLE
    # Minimal — no reporting, no repair triggering
    .\Invoke-WindowsUpdate.ps1

  .EXAMPLE
    # Full — production host, reporting, failure tracking and 3 days installation delay
    .\Invoke-WindowsUpdate.ps1 `
        -TimeoutMinutes 90 `
        -PatchingDaysDelay 3

  .NOTES
    Original Author : Liamarjit Bhogal (© Seva Cloud 2026)
    Refactored      : Standalone execution, optional DDB reporting, -Param style inputs
    Requires        : PSWindowsUpdate 2.2.1.3 (mandatory)
                      AWS.Tools.Common / DynamoDBv2 / SecurityToken / SSM 4.1.319 (optional)
    Disclaimer      : This script is provided as-is, with no warranty or guarantee of fitness for purpose. Please test before implementing in a production
                      environment. I am not liable for any damage caused by your execution of this code.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 480)]
    [int]$TimeoutMinutes = 90,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 7)]
    [int]$PatchingDaysDelay =  0,

    [Parameter(Mandatory = $false)]
    [string]$FailedUpdatesCacheFileName = 'FailedUpdates-Cache.json'
)

#region Functions
function Write-LocalLog
{
    <#
    .SYNOPSIS
        Writes a timestamped log entry to both the verbose stream and a log file.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        $LogMessage,

        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "FATAL")]
        [string]$LogLevel = "INFO"
    )

    $TimeStamp = (Get-Date).ToUniversalTime().ToString("yyyy/MM/dd HH:mm:ss")

    # Safely resolve script name — falls back when run interactively
    try   { $ScriptName = Split-Path $PSCommandPath -Leaf }
    catch { $ScriptName = 'LocalRun' }

    $NewLogLine = '{0}, {1}, {2}, {3}' -f $TimeStamp, $ScriptName, $LogLevel, ($LogMessage | Out-String).Trim()

    Write-Verbose $NewLogLine -Verbose

    if (Test-Path -Path $script:LogFile)
    {
        Add-Content -Path $script:LogFile -Value $NewLogLine
    }
    else
    {
        New-Item -Path $script:LogFile -ItemType File -Force -Confirm:$false | Out-Null
        Add-Content -Path $script:LogFile -Value $NewLogLine
    }
}

function Import-ModuleVersion
{
    <#
    .SYNOPSIS
        Imports a module at a specific required version.

    .PARAMETER Throw
        When $true (default), a missing/failed import terminates the script.
        When $false, logs a warning and continues — used for optional reporting modules.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [version]$ModuleVersion,

        [Parameter(Mandatory = $false)]
        [bool]$Throw = $true
    )

    Write-LocalLog "Importing module: $ModuleName v$ModuleVersion"

    try
    {
        Import-Module -Name $ModuleName -RequiredVersion $ModuleVersion -ErrorAction Stop
    }
    catch
    {
        $Msg = "Failed to import '$ModuleName' v'$ModuleVersion'. $_"

        if ($Throw)
        {
            Write-LocalLog $Msg -LogLevel FATAL
            throw $Msg
        }
        else
        {
            Write-LocalLog "$Msg — continuing without this module." -LogLevel WARN
        }
    }
}

# ==============================================================================
# HOST / PATCHING SCHEDULE HELPERS
# ==============================================================================
function Get-PatchTuesday
{
    <#
    .SYNOPSIS
        Calculates the second Tuesday (Microsoft Patch Tuesday) of the given month.
    #>
    Param (
        [Parameter(Mandatory = $true)]
        [DateTime]$TodaysDate
    )

    # Start at the 1st of the month and walk forward to the first Tuesday
    $DateObj = Get-Date -Year $TodaysDate.Year -Month $TodaysDate.Month -Day 1 -Hour 0 -Minute 0 -Second 0
    while ($DateObj.DayOfWeek -ne 'Tuesday') { $DateObj = $DateObj.AddDays(1) }

    # Patch Tuesday = 2nd Tuesday
    return $DateObj.AddDays(7)
}

function Get-ExecutionWithinMaintenanceWindow
{
    <#
    .SYNOPSIS
        Returns $true if the current time falls within the defined maintenance window.
    #>
    Param (
        [Parameter(Mandatory = $true)] [DateTime]$TimeNow,
        [Parameter(Mandatory = $true)] [DateTime]$Start,
        [Parameter(Mandatory = $true)] [DateTime]$End
    )

    if ($TimeNow.TimeOfDay -ge $Start.TimeOfDay -and $TimeNow.TimeOfDay -lt $End.TimeOfDay)
    {
        Write-LocalLog "Execution is within the maintenance window ($Start – $End)"
        return $true
    }

    Write-LocalLog "Execution is outside the maintenance window ($Start – $End)" -LogLevel WARN
    return $false
}

# ==============================================================================
# REBOOT DETECTION
# ==============================================================================
function Get-WURebootPending
{
    <#
    .SYNOPSIS
        Checks multiple registry keys and WMI for any pending reboot condition.

    .DESCRIPTION
        Checks CBS, Windows Update, SCCM, and PendingFileRenameOperations.
        Returns $true if any reboot is pending.
        Adapted from: https://w.amazon.com/bin/view/AEP/Customers#HHostisstillshowingmissingpatchesafteronboarding
    #>

    $RebootPending = @{
        CBSRebootPending            = $false
        WindowsUpdateRebootRequired = $false
        FileRenamePending           = $false
        SCCMRebootPending           = $false
    }

    # --- CBS reboot keys ---
    foreach ($Key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
    ))
    {
        if ($null -ne (Get-Item $Key -ErrorAction SilentlyContinue))
        {
            $RebootPending.CBSRebootPending = $true
        }
    }

    # --- Windows Update reboot key ---
    if ($null -ne (Get-Item 'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue))
    {
        $RebootPending.WindowsUpdateRebootRequired = $true
    }

    # --- SCCM reboot check (optional — SCCM may not be present) ---
    try
    {
        $CcmUtil = [wmiclass]'\\.\root\ccm\clientsdk:CCM_ClientUtilities'
        $Status  = $CcmUtil.DetermineIfRebootPending()
        if (($null -ne $Status) -and $Status.RebootPending) { $RebootPending.SCCMRebootPending = $true }
    }
    catch { <# SCCM not installed — silently ignore #> }

    # --- PendingFileRenameOperations — only flag if a .NET file is pending ---
    $Prop = Get-ItemProperty 'HKLM:SYSTEM\CurrentControlSet\Control\Session Manager' `
                             -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($null -ne $Prop)
    {
        foreach ($RawPath in ($Prop.PendingFileRenameOperations | Where-Object { $_ -match '\w' }))
        {
            $CleanPath = $RawPath -replace '^(\*\d)?\\\?\?\\'
            try
            {
                $FileObj = Get-ChildItem -Path $CleanPath -ErrorAction Stop
                if ($FileObj.VersionInfo.ProductName -match '\.NET')
                {
                    $RebootPending.FileRenamePending = $true
                    break
                }
            }
            catch { Write-LocalLog "Could not inspect pending file '$CleanPath'. $_" -LogLevel ERROR }
        }
    }

    $IsPending = $RebootPending.ContainsValue($true)
    if ($IsPending) { Write-LocalLog "Reboot is pending: $($RebootPending | Out-String)" }
    else            { Write-LocalLog "No reboot pending." }

    return $IsPending
}

function Get-LastBootInfo
{
    <#
    .SYNOPSIS
        Returns the last boot time and elapsed time since last boot.
    #>
    $LastBoot  = Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object LastBootUpTime, LocalDateTime
    $BootDelta = New-TimeSpan -Start $LastBoot.LocalDateTime -End $LastBoot.LastBootUpTime

    return @{ LastBootTime = $LastBoot; BootTimeDelta = $BootDelta }
}

function Invoke-PatchReboot
{
    <#
    .SYNOPSIS
        Initiates a system reboot following a successful patch installation.
        Only called when within the defined maintenance window.
    #>
    Param(
        [Parameter(Mandatory = $false)]
        [int]$DelaySeconds = 0
    )

    if ($DelaySeconds -gt 0)
    {
        Write-LocalLog "Rebooting in $DelaySeconds second(s) — patch installation complete."
        shutdown.exe /r /t $DelaySeconds /c "Windows Update patching complete"
    }
    else
    {
        Write-LocalLog "Rebooting now — patch installation complete."
        Restart-Computer -Force
    }
}

# ==============================================================================
# CACHE HELPERS
# ==============================================================================
function Write-CacheEntryAsJson
{
    <#
    .SYNOPSIS
        Serialises a hashtable to JSON and writes it to the specified file path.
        Used to persist state locally so DynamoDB is not required on every run.
    #>
    Param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]$AttributeUpdates,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $CacheJson = @{}
    foreach ($Item in $AttributeUpdates.GetEnumerator()) { $CacheJson[$Item.Name] = $Item.Value }

    $CacheJson | ConvertTo-Json | Set-Content -Path $FilePath
    Write-LocalLog "State written to local cache: $FilePath"
}

function Write-PatchCompliance
{
    <#
    .SYNOPSIS
        Writes patch compliance data to local JSON cache.

    .DESCRIPTION
        All patching logic continues regardless of reporting success.
    #>
    Param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]$AttributeUpdates
    )

    # Always write to local cache — this is independent of DDB availability
    $AttributeUpdates['timezone_local']  = Get-Timezone | Select-Object -ExpandProperty DisplayName
    $AttributeUpdates['timestamp_utc']   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $AttributeUpdates['timestamp_local'] = (Get-Date).ToLocalTime().ToString("yyyy-MM-ddTHH:mm:ss")
    $AttributeUpdates['os_version']      = (Get-CimInstance -ClassName Win32_OperatingSystem).Version
    $AttributeUpdates['ubr']             = $script:CurrentUbrValue

    Write-CacheEntryAsJson -FilePath $script:LocalCacheFile -AttributeUpdates $AttributeUpdates
}
#endregion Functions

# ==============================================================================
# SCRIPT VARIABLES
# ==============================================================================
#region ScriptVariables

$DateStamp              = Get-Date -Format "dd-MMM-yyyy"
$LogFilePath            = 'C:\Admin\_Logs\WindowsUpdate'
$TempPath               = 'C:\Admin\Temp'
$script:LocalCacheFile  = Join-Path $TempPath "WindowsUpdate-Status.json"
$script:LogFile         = Join-Path $LogFilePath "WindowsUpdates_$DateStamp.log"
$FailedUpdatesCachePath = Join-Path $TempPath $FailedUpdatesCacheFileName
$LogDaysToKeep          = 70

# Maintenance Window Configuration
$MaintenanceWindowStart     = Get-Date -Hour 4  -Minute 0
$MaintenanceWindowEnd       = Get-Date -Hour 7  -Minute 0   # Reboot deferred to next day after this time
$MaintenanceWindowParams    = @{ Start = $MaintenanceWindowStart; End = $MaintenanceWindowEnd }

$TimeoutSeconds = (New-TimeSpan -Minutes $TimeoutMinutes).TotalSeconds
#endregion ScriptVariables

if (-not (Test-Path $LogFilePath))  { New-Item -Path $LogFilePath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $TempPath))     { New-Item -Path $TempPath    -ItemType Directory -Force | Out-Null }

Write-LocalLog "=== Starting WindowsUpdate | Host: $env:COMPUTERNAME ==="

# ==============================================================================
# LOG CLEANUP
# ==============================================================================

Write-LocalLog "Cleaning up log files older than $([math]::Abs(-$LogDaysToKeep)) days."
Get-ChildItem -Path $LogFilePath -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDaysToKeep) } |
    Remove-Item -Force -Confirm:$false

# ==============================================================================
# REBOOT CHECK (pre-update)
# ==============================================================================
#region CheckReboot

$RebootPending   = Get-WURebootPending
$LastBootInfo    = Get-LastBootInfo
$WithinWindow    = Get-ExecutionWithinMaintenanceWindow @MaintenanceWindowParams -TimeNow (Get-Date)

# Reboot now only if: a reboot is pending AND the last boot was >1h ago AND we are in the window.
# The >1h guard prevents a boot loop if the script runs immediately after a reboot.
if ($RebootPending -and ($LastBootInfo.BootTimeDelta.TotalHours -lt -1) -and $WithinWindow)
{
    Write-LocalLog "Pre-update reboot required — rebooting now."
    Invoke-PatchReboot -DelaySeconds 30
}

#endregion CheckReboot

# Current Update Build Revision — used to detect whether a patch was applied after reboot
$script:CurrentUbrValue = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR).UBR
Write-LocalLog "Current UBR: $script:CurrentUbrValue"

# ==============================================================================
# MODULE IMPORTS
# ==============================================================================
#region ImportModules

Write-LocalLog "Importing required modules."

# PSWindowsUpdate is mandatory — script cannot patch without it
Import-ModuleVersion -ModuleName 'PSWindowsUpdate'              -ModuleVersion '2.2.1.3'

# AWS.Tools modules are optional — only needed for DDB/SSM reporting and repair triggering
Import-ModuleVersion -ModuleName 'AWS.Tools.Common'             -ModuleVersion '4.1.319' -Throw $false
Import-ModuleVersion -ModuleName 'AWS.Tools.SecurityToken'      -ModuleVersion '4.1.319' -Throw $false
Import-ModuleVersion -ModuleName 'AWS.Tools.DynamoDBv2'         -ModuleVersion '4.1.319' -Throw $false
Import-ModuleVersion -ModuleName 'AWS.Tools.SimpleSystemsManagement' -ModuleVersion '4.1.319' -Throw $false

#endregion ImportModules

# ==============================================================================
# WINDOWS UPDATE CONNECTIVITY CHECK
# ==============================================================================

$WuConnTest = Test-NetConnection 'update.microsoft.com' -Port 80 -ErrorAction SilentlyContinue
if ($null -ne $WuConnTest -and $WuConnTest.TcpTestSucceeded -eq $false)
{
    Write-LocalLog "Cannot reach update.microsoft.com:80." -LogLevel FATAL
    Write-PatchCompliance -AttributeUpdates @{ process_status = 'NoUpdateConnection' }
    exit 0
}
Write-LocalLog "Connectivity to update.microsoft.com confirmed."

# ==============================================================================
# PATCH TUESDAY / PATCHING SCHEDULE
# ==============================================================================
#region PatchTuesday

$Today             = Get-Date
$PatchTuesday      = Get-PatchTuesday -TodaysDate $Today
$PatchingDay       = $PatchTuesday.AddDays($PatchingDaysDelay)

Write-LocalLog "Patch Tuesday: $PatchTuesday | Patching day for this host: $PatchingDay"

#endregion PatchTuesday

# ==============================================================================
# POST-REBOOT COMPLETION CHECK
# ==============================================================================
#region ProcessComplete

# Read local caches if they exist
$CacheContent = if (Test-Path $script:LocalCacheFile)  { Get-Content $script:LocalCacheFile  | ConvertFrom-Json } else { $null }

$AttributeUpdates = @{
    patch_tuesday_delta = ($PatchTuesday - $Today).Days
    process_status      = 'InProgress'
    reboot_required     = $RebootPending
}

Write-PatchCompliance -AttributeUpdates $AttributeUpdates

# If a reboot was previously recorded and the UBR has since increased, patching is done
if ($CacheContent -and ($CacheContent.reboot_required -eq 'True') -and ($CacheContent.ubr -lt $script:CurrentUbrValue))
{
    Write-LocalLog "Post-reboot UBR increase detected (cached: $($CacheContent.ubr) → current: $script:CurrentUbrValue). Marking complete."
    Write-PatchCompliance -AttributeUpdates @{ process_status = 'Complete'; repair_cycles = 0 }
    exit 0
}

#endregion ProcessComplete

# ==============================================================================
# DOWNLOAD UPDATES
# ==============================================================================
#region DownloadUpdates

Write-LocalLog "Troubleshooting tip: check '$env:WINDIR\Logs\Dism\dism.log' and '$env:WINDIR\Logs\CBS\cbs.log' for errors."

$TotalStopWatch    = [System.Diagnostics.Stopwatch]::StartNew()
$DownloadStopWatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-LocalLog "Downloading updates — timeout: $TimeoutMinutes minutes."
Write-PatchCompliance -AttributeUpdates @{ process_status = 'DownloadingUpdates' }

$DownloadJob = Start-Job -ScriptBlock {
    try   { Get-WindowsUpdate -MicrosoftUpdate -Download -AcceptAll -IgnoreReboot -ErrorAction Stop }
    catch { "DownloadUpdates failed. $_" }
}

if (Wait-Job $DownloadJob -Timeout $TimeoutSeconds)
{
    $ProcessStatus  = "Download$($DownloadJob.State)"
    $DownloadOutput = Receive-Job -Id $DownloadJob.Id -Keep
    Write-LocalLog "Download complete — Status: $ProcessStatus"
}
else
{
    Write-PatchCompliance -AttributeUpdates @{ process_status = 'DownloadTimedOut' }
    $Msg = "Download timed out after $TimeoutSeconds seconds."
    Write-LocalLog $Msg -LogLevel FATAL
    throw $Msg
}

Write-PatchCompliance -AttributeUpdates @{ process_status = $ProcessStatus }

if ($ProcessStatus -ne 'DownloadCompleted')
{
    $Msg = "Download failed with status '$ProcessStatus'. Output: $($DownloadOutput | Out-String)"
    Write-LocalLog $Msg -LogLevel FATAL
    throw $Msg
}

$DownloadStopWatch.Stop()
Write-LocalLog "Download completed in $([math]::Round($DownloadStopWatch.Elapsed.TotalMinutes)) minute(s)."

#endregion DownloadUpdates

# ==============================================================================
# PATCHING DAY GATE
# ==============================================================================
#region IsItPatchingDay

# Downloads are allowed before patching day so updates are ready to install on schedule.
# Installation is held back until the host's assigned patching day.
if (($Today -ge $PatchTuesday) -and ($Today -lt $PatchingDay))
{
    Write-LocalLog "$env:COMPUTERNAME is waiting for its patching day: $PatchingDay. Exiting."
    Write-PatchCompliance -AttributeUpdates @{ process_status = 'WaitingForPatchingDay' }
    exit 0
}

#endregion IsItPatchingDay

# ==============================================================================
# INSTALL UPDATES
# ==============================================================================
#region InstallUpdates

$InstallStopWatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-LocalLog "Installing updates — timeout: $TimeoutMinutes minutes."
Write-PatchCompliance -AttributeUpdates @{ process_status = 'InstallingUpdates' }

$InstallJob = Start-Job -ScriptBlock {
    try   { Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot -ErrorAction Stop }
    catch { "InstallUpdates failed. $_" }
}

if (Wait-Job $InstallJob -Timeout $TimeoutSeconds)
{
    $ProcessStatus = "Install$($InstallJob.State)"
    $InstallOutput = Receive-Job -Id $InstallJob.Id -Keep
    Write-LocalLog "Install complete — Status: $ProcessStatus"
}
else
{
    Write-PatchCompliance -AttributeUpdates @{ process_status = 'InstallTimedOut' }
    $Msg = "Install timed out after $TimeoutSeconds seconds."
    Write-LocalLog $Msg -LogLevel FATAL
    throw $Msg
}

# ==============================================================================
# FAILURE HANDLING AND AUTO-REPAIR
# ==============================================================================

if ($InstallJob.State -like '*failed*' -or ($InstallOutput.Result -like 'Failed'))
{
    $FailedUpdates = $InstallOutput | Where-Object { $_.Result -eq 'Failed' } | Select-Object -Unique
    Write-LocalLog "Failed updates detected: $($FailedUpdates | Out-String)" -LogLevel ERROR

    # Repair is only triggered for cumulative update failures
    $FailedCumulativeUpdates = $FailedUpdates | Where-Object { $_.Title -like '*Cumulative*' } | Select-Object -Unique

    if ($FailedCumulativeUpdates.Count -gt 0)
    {
        Write-LocalLog "Failed cumulative updates: $($FailedCumulativeUpdates | Out-String)" -LogLevel ERROR

        $CurrentRepairCycles  = if ($FailedUpdatesCacheContent.RepairCycles)       { [int]$FailedUpdatesCacheContent.RepairCycles }       else { 0 }
        $CurrentRepairCycles++

        # Persist failed KB list before sending command (the repair document reads from this file)
        Write-CacheEntryAsJson -FilePath $FailedUpdatesCachePath -AttributeUpdates @{
            FailedUpdates       = @($FailedCumulativeUpdates.KB)
            RepairCycles        = $CurrentRepairCycles
        }
    }
    else
    {
        Write-LocalLog "No cumulative update failures — skipping repair logging."

        # Reset failed update cache
        Write-CacheEntryAsJson -FilePath $FailedUpdatesCachePath -AttributeUpdates @{
            FailedUpdates       = @()
            RepairCycles        = 0
        }
    }
}

if ($ProcessStatus -ne 'InstallCompleted')
{
    $Msg = "Install failed with status '$ProcessStatus'. Output: $($InstallOutput | Out-String)"
    Write-LocalLog $Msg -LogLevel FATAL
    throw $Msg
}

$InstallStopWatch.Stop()
Write-LocalLog "Install completed in $([math]::Round($InstallStopWatch.Elapsed.TotalMinutes)) minute(s)."
Write-LocalLog "Total (download + install) completed in $([math]::Round($TotalStopWatch.Elapsed.TotalMinutes)) minute(s)."

#endregion InstallUpdates

# ==============================================================================
# REBOOT DECISION (post-install)
# ==============================================================================
#region RebootValidation

$LastBootInfo  = Get-LastBootInfo
Write-LocalLog "Last boot: $($LastBootInfo.LastBootTime.LastBootUpTime) ($([string]$LastBootInfo.BootTimeDelta.Days).Trim('-') day(s) ago)"

$RebootPending  = Get-WURebootPending
$ExitRebootCode = 0
$ProcessStatus  = 'Complete'

if ($RebootPending)
{
    $TimeNow     = Get-Date
    $WithinWindow = Get-ExecutionWithinMaintenanceWindow @MaintenanceWindowParams -TimeNow $TimeNow

    if ($WithinWindow)
    {
        # EXIT CODE 3010 signals SSM (or a calling wrapper) to reboot the host.
        # IMPORTANT: Do not move the exit 3010 call — it must remain at the end
        # of the script to avoid boot loops caused by early exits.
        $ProcessStatus  = 'Rebooting'
        $ExitRebootCode = 3010
        Write-LocalLog "Within maintenance window — reboot will be issued (exit 3010)."
    }
    else
    {
        $ProcessStatus = 'WaitingForReboot'
        Write-LocalLog "Outside maintenance window — reboot deferred to next window."
    }
}

# Warn if total wall-clock time exceeded the configured timeout
$TotalStopWatch.Stop()
$TotalMinutes = [math]::Round($TotalStopWatch.Elapsed.TotalMinutes)
if ($TotalMinutes -gt $TimeoutMinutes)
{
    Write-LocalLog "Wall-clock time ($TotalMinutes min) exceeded configured timeout ($TimeoutMinutes min). Review: https://w.amazon.com/bin/view/GSO-VI/Resources/Windows_Patching#HTroubleshooting" -LogLevel WARN
    $ProcessStatus = 'TimeoutReached'
}

Write-PatchCompliance -AttributeUpdates @{
    process_status  = $ProcessStatus
    reboot_required = $RebootPending
}

Write-LocalLog "=== WindowsUpdate complete | Status: $ProcessStatus ==="

# Issue reboot signal last — see note above regarding boot-loop guard
if ($ExitRebootCode -eq 3010)
{
    # See: https://docs.aws.amazon.com/systems-manager/latest/userguide/send-commands-reboot.html
    Write-LocalLog "Exiting with reboot.  ExitCode 3010"
    Invoke-PatchReboot -DelaySeconds 30
}

#endregion RebootValidation
