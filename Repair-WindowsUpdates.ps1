#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  .SYNOPSIS
    Repairs a failing Windows Update client by installing packages directly from
    a local folder.

  .DESCRIPTION
    Intended for manual execution by an administrator after one or more Windows
    Updates have failed to install via Invoke-WindowsUpdate.ps1.

    Download failing KBs from Microsoft Update Catalog

    Repair sequence (each step is wrapped in its own try/catch so a failure in
    one step does not abort the rest):
        1.  Fix-SxSErrors          — cleans stale CBS package registry entries
        2.  SFC /SCANNOW           — repairs corrupted system files
        3.  Reset-WUComponents     — resets the Windows Update service stack
        4.  DISM StartComponentCleanup + RestoreHealth — deeper component repair
        5.  Fix-SxSErrors (again)  — catches anything uncovered by steps 2-4
        6.  Install-PackageWithRetry — installs each KB with CBS-aware retry logic
            which internally calls Repair-CbsPackages and Repair-SxsAssemblyMissing

    KB list resolution order:
        1.  -KBList parameter (if provided)
        2.  FailedUpdates-Cache.json in $TempPath (written by Invoke-WindowsUpdate)
        3.  Script exits with a FATAL error if neither source provides a list

    Logs are written to the same folder as Invoke-WindowsUpdate.ps1 for unified
    troubleshooting. CBS detail is always in C:\Windows\Logs\CBS\CBS.log.

  .PARAMETER PackagePath
    Full path to the local folder containing the .msu or .cab files to install.
    All files in this folder are scanned; only those matching a KB in the target
    list are installed.
    Example: 'D:\WindowsUpdatePackages'

  .PARAMETER KBList
    Optional. Explicit list of KB article numbers to repair, e.g. 'KB5071544','KB5071545'.
    When supplied this overrides the local cache file entirely.

  .PARAMETER FailedUpdatesCacheFileName
    Filename (not full path) of the cache written by Invoke-WindowsUpdate.ps1.
    Default: 'FailedUpdates-Cache.json'

  .EXAMPLE
    # Read KB list from cache, packages in D:\Patches
    .\Repair-WindowsUpdateClient.ps1 -PackagePath 'D:\Patches'

  .EXAMPLE
    # Override KB list explicitly
    .\Repair-WindowsUpdateClient.ps1 `
        -PackagePath 'D:\Patches' `
        -KBList 'KB5071544','KB5071545'

  .NOTES
    Original Author : Liamarjit Bhogal (© Seva Cloud 2026)
    Refactored      : Standalone / manual execution, local package path replaces S3
    Requires        : Administrator rights (see #Requires above)
                      PSWindowsUpdate 2.2.1.3 (for Reset-WUComponents)
    Disclaimer      : Provided as-is with no warranty. Test before running in
                      production. The author is not liable for any damage caused.
    Make A Donation : https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Container))
        {
            throw "PackagePath '$_' does not exist or is not a folder."
        }
        $true
    })]
    [string]$PackagePath,

    [Parameter(Mandatory = $false)]
    [string[]]$KBList,

    [Parameter(Mandatory = $false)]
    [string]$FailedUpdatesCacheFileName = 'FailedUpdates-Cache.json'
)

#region Functions
# ==============================================================================
# LOGGING
# ==============================================================================

function Write-LocalLog
{
    <#
    .SYNOPSIS
        Writes a timestamped log entry to verbose output and a rolling log file.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        $LogMessage,

        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "FATAL")]
        [string]$LogLevel = "INFO"
    )

    $TimeStamp = (Get-Date).ToUniversalTime().ToString("yyyy/MM/dd HH:mm:ss")

    try   { $ScriptName = Split-Path $PSCommandPath -Leaf }
    catch { $ScriptName = 'LocalRun' }

    $Line = '{0}, {1}, {2}, {3}' -f $TimeStamp, $ScriptName, $LogLevel, ($LogMessage | Out-String).Trim()

    Write-Verbose $Line -Verbose

    if (Test-Path -Path $script:LogFile)
    {
        Add-Content -Path $script:LogFile -Value $Line
    }
    else
    {
        New-Item -Path $script:LogFile -ItemType File -Force -Confirm:$false | Out-Null
        Add-Content -Path $script:LogFile -Value $Line
    }
}

# ==============================================================================
# FILESYSTEM HELPERS
# ==============================================================================

function New-DirectoryIfMissing
{
    <#
    .SYNOPSIS
        Creates a directory and all intermediate parents if it does not exist.
        Silently succeeds if the directory is already present.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path))
    {
        try
        {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-LocalLog "Created directory: $Path"
        }
        catch
        {
            throw "Failed to create directory '$Path'. $_"
        }
    }
}

# ==============================================================================
# CBS / REGISTRY REPAIR HELPERS
# ==============================================================================

function Export-RegistryKey
{
    <#
    .SYNOPSIS
        Exports a registry key to a .reg backup file before making any changes.
    #>
    Param (
        [Parameter(Mandatory = $true)] [string]$BackupFolder,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Key
    )

    $Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $BackupFile    = Join-Path $BackupFolder "${Name}_${Timestamp}.reg"

    Write-LocalLog "Backing up registry key '$Key' to: $BackupFile"
    Invoke-Command { reg export $Key $BackupFile } | Out-Null
}

function Enable-Privilege
{
    <#
    .SYNOPSIS
        Elevates a specific Windows privilege for the current process using P/Invoke.
        Required before taking ownership of protected registry keys.
    #>
    Param(
        [ValidateSet(
            'SeAssignPrimaryTokenPrivilege', 'SeAuditPrivilege', 'SeBackupPrivilege',
            'SeChangeNotifyPrivilege', 'SeCreateGlobalPrivilege', 'SeCreatePagefilePrivilege',
            'SeCreatePermanentPrivilege', 'SeCreateSymbolicLinkPrivilege', 'SeCreateTokenPrivilege',
            'SeDebugPrivilege', 'SeEnableDelegationPrivilege', 'SeImpersonatePrivilege',
            'SeIncreaseBasePriorityPrivilege', 'SeIncreaseQuotaPrivilege', 'SeIncreaseWorkingSetPrivilege',
            'SeLoadDriverPrivilege', 'SeLockMemoryPrivilege', 'SeMachineAccountPrivilege',
            'SeManageVolumePrivilege', 'SeProfileSingleProcessPrivilege', 'SeRelabelPrivilege',
            'SeRemoteShutdownPrivilege', 'SeRestorePrivilege', 'SeSecurityPrivilege',
            'SeShutdownPrivilege', 'SeSyncAgentPrivilege', 'SeSystemEnvironmentPrivilege',
            'SeSystemProfilePrivilege', 'SeSystemtimePrivilege', 'SeTakeOwnershipPrivilege',
            'SeTcbPrivilege', 'SeTimeZonePrivilege', 'SeTrustedCredManAccessPrivilege',
            'SeUndockPrivilege', 'SeUnsolicitedInputPrivilege')]
        $Privilege,

        $ProcessId = $pid,

        [Switch]$Disable
    )

    Write-LocalLog "Enabling privilege: $Privilege"

    $Definition = @'
using System;
using System.Runtime.InteropServices;
public class AdjPriv {
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError=true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    internal struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    internal const int SE_PRIVILEGE_ENABLED  = 0x00000002;
    internal const int SE_PRIVILEGE_DISABLED = 0x00000000;
    internal const int TOKEN_QUERY           = 0x00000008;
    internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    public static bool EnablePrivilege(long processHandle, string privilege, bool disable) {
        bool retVal; TokPriv1Luid tp;
        IntPtr hproc = new IntPtr(processHandle); IntPtr htok = IntPtr.Zero;
        retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
        tp.Count = 1; tp.Luid = 0;
        tp.Attr  = disable ? SE_PRIVILEGE_DISABLED : SE_PRIVILEGE_ENABLED;
        retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
        retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        return retVal;
    }
}
'@
    $ProcessHandle = (Get-Process -Id $ProcessId).Handle
    $Type          = Add-Type $Definition -PassThru
    $Type[0]::EnablePrivilege($ProcessHandle, $Privilege, $Disable)
}

function Enable-ModifyRegKey
{
    <#
    .SYNOPSIS
        Takes ownership of and grants FullControl on a HKLM registry key.
        Required to modify protected CBS package keys.
        Returns $false (and logs a warning) if the key does not exist.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string]$RegKey
    )

    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-LocalLog "$CurrentUser taking ownership of: $RegKey"

    Enable-Privilege SeTakeOwnershipPrivilege

    $Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $RegKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership
    )

    if ($null -eq $Key)
    {
        Write-LocalLog "Registry key does not exist: $RegKey — skipping." -LogLevel WARN
        return $false
    }

    # Set owner on a blank ACL first (required when we don't yet have read access)
    $Acl = $Key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
    $Acl.SetOwner([System.Security.Principal.NTAccount]$CurrentUser)
    $Key.SetAccessControl($Acl)

    # Now apply FullControl
    $Acl  = $Key.GetAccessControl()
    $Rule = New-Object System.Security.AccessControl.RegistryAccessRule($CurrentUser, 'FullControl', 'Allow')
    $Acl.SetAccessRule($Rule)
    $Key.SetAccessControl($Acl)
    $Key.Close()

    return $true
}

function Check-CbsErrors
{
    <#
    .SYNOPSIS
        Scans CBS.log for lines matching any of the supplied error strings.
        Returns the matching lines, or $null if none found.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string[]]$ErrorStrings
    )

    Write-LocalLog "Scanning CBS.log for: $($ErrorStrings -join ', ')"

    $Matches = Get-Content 'C:\Windows\Logs\CBS\CBS.log' -ErrorAction SilentlyContinue |
        Select-String ($ErrorStrings -join '|')

    if ($Matches)
    {
        Write-LocalLog "Found $($Matches.Count) matching CBS error line(s)." -LogLevel WARN
        $Matches | ForEach-Object { Write-LocalLog "$_" -LogLevel ERROR }
    }
    else
    {
        Write-LocalLog "No matching entries found in CBS.log."
    }

    return $Matches
}

function Repair-CbsPackages
{
    <#
    .SYNOPSIS
        Searches CBS.log for packages that failed to re-install as superseded versions,
        then re-registers them via DISM.
        Returns $true if any packages were processed, $false otherwise.
    #>

    Write-LocalLog "Starting CBS package repair"

    $CbsErrors      = Check-CbsErrors -ErrorStrings @("Failed to re-install supersed versions for package:")
    $PackagePattern = "Package-[0-9A-F]{64}~\S+"

    $FailedPackages = $CbsErrors |
        ForEach-Object { if ($_ -match $PackagePattern) { $Matches[0] } } |
        Sort-Object -Unique

    Write-LocalLog "Unique failed packages found: $($FailedPackages.Count)"

    if ($FailedPackages.Count -eq 0) { return $false }

    foreach ($Package in $FailedPackages)
    {
        $MumPath = "C:\Windows\Servicing\Packages\$Package.mum"
        $Files   = Get-ChildItem -Path $MumPath -ErrorAction SilentlyContinue

        if ($Files.Count -eq 0)
        {
            Write-LocalLog "No .mum file found for package: $Package" -LogLevel WARN
            continue
        }

        if ($Files.Count -gt 1)
        {
            Write-LocalLog "Multiple .mum files found for $Package — using first." -LogLevel WARN
        }

        try
        {
            Write-LocalLog "Re-registering via DISM: $($Files[0].FullName)"
            $Output = & DISM.exe /Online /Add-Package /PackagePath:"$($Files[0].FullName)" /NoRestart 2>&1
            Write-LocalLog "DISM output: $Output"

            if ($LASTEXITCODE -eq 0) { Write-LocalLog "Successfully re-registered: $Package" }
            else { Write-LocalLog "DISM exit $LASTEXITCODE for package: $Package" -LogLevel ERROR }
        }
        catch
        {
            Write-LocalLog "Exception re-registering $Package. $_" -LogLevel ERROR
        }
    }

    return $true
}

function Repair-SxsAssemblyMissing
{
    <#
    .SYNOPSIS
        Identifies packages causing 'Failed to pin deployment' errors in CBS.log,
        moves them to a backup folder so they no longer block installation,
        and returns the list of affected package names for re-registration.
    #>
    Param(
        [Parameter(Mandatory = $true)] [string[]]$ErrorStrings,
        [Parameter(Mandatory = $true)] [string]$BackupPath
    )

    $ProblematicPackages = @()

    foreach ($ErrorString in $ErrorStrings)
    {
        if ($ErrorString -match "Failed to pin deployment while resolving Update" -and
            $ErrorString -match "[a-zA-Z]\w*-[a-zA-Z0-9._~-]{10,}")
        {
            # Normalise to base package name (strip trailing version segments)
            $PackageName = $Matches[0] -replace "(\d+\.\d+\.\d+\.\d+).*", '$1'
            Write-LocalLog "Problematic package identified: $PackageName"
            $ProblematicPackages += $PackageName

            $PackageFiles = Get-ChildItem -Path 'C:\Windows\Servicing\Packages' `
                                          -Filter "$PackageName*" `
                                          -ErrorAction SilentlyContinue

            if ($PackageFiles.Count -eq 0)
            {
                Write-LocalLog "No servicing files found for $PackageName — skipping." -LogLevel WARN
                continue
            }

            foreach ($File in $PackageFiles)
            {
                try
                {
                    Move-Item -Path $File.FullName -Destination $BackupPath -Force
                    Write-LocalLog "Moved '$($File.Name)' to backup: $BackupPath"
                }
                catch
                {
                    Write-LocalLog "Failed to move '$($File.Name)'. $_" -LogLevel ERROR
                }
            }
        }
    }

    return $ProblematicPackages
}

function Reregister-LatestPackageVersions
{
    <#
    .SYNOPSIS
        For each problematic package name, finds the highest versioned .mum file
        still present in the servicing stack and re-registers it via DISM.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string[]]$PackageNames
    )

    foreach ($PackageName in $PackageNames)
    {
        $Prefix      = $PackageName.Split('~')[0]
        $AllVersions = Get-ChildItem -Path 'C:\Windows\Servicing\Packages' `
                                     -Filter "$Prefix*.mum" `
                                     -ErrorAction SilentlyContinue

        if ($AllVersions.Count -eq 0)
        {
            Write-LocalLog "No .mum versions found for: $PackageName" -LogLevel WARN
            continue
        }

        # Sort descending by name so the highest version number comes first
        $Latest = $AllVersions | Sort-Object Name -Descending | Select-Object -First 1

        Write-LocalLog "Re-registering latest version: $($Latest.Name)"
        try
        {
            $Output = & DISM.exe /Online /Add-Package /PackagePath:"$($Latest.FullName)" /NoRestart 2>&1
            Write-LocalLog "DISM output: $Output"

            if ($LASTEXITCODE -eq 0) { Write-LocalLog "Successfully re-registered: $($Latest.Name)" }
            else { Write-LocalLog "DISM exit $LASTEXITCODE for: $($Latest.Name)" -LogLevel ERROR }
        }
        catch
        {
            Write-LocalLog "Exception re-registering $($Latest.Name). $_" -LogLevel ERROR
        }
    }
}

function Fix-SxSErrors
{
    <#
    .SYNOPSIS
        Cleans up stale 'Resolving Package' entries in the CBS registry hive.
        Idempotent — safe to run multiple times.
        Backs up the affected registry key before making any changes.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string]$BackupFolder
    )

    Write-LocalLog "Running Fix-SxSErrors — cleaning stale CBS registry packages."

    $RegKeyParent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'

    Export-RegistryKey -BackupFolder $BackupFolder -Name 'CBS_Packages' -Key "HKLM\$RegKeyParent"

    $ResolvingLines = Get-Content 'C:\Windows\Logs\CBS\CBS.log' -ErrorAction SilentlyContinue |
        Select-String 'Resolving Package:'

    if (-not $ResolvingLines)
    {
        Write-LocalLog "No 'Resolving Package' entries found in CBS.log — nothing to clean."
        return
    }

    # Extract unique package names from the log lines
    $Packages = $ResolvingLines | ForEach-Object {
        $Line = $_ | Out-String
        $Line.Split(':').Trim().Split(',').Trim() |
            Where-Object { $_ -match 'Package_' -or $_ -match 'Package-' }
    } | Select-Object -Unique

    Write-LocalLog "Stale packages to mark absent: $($Packages -join ', ')"

    foreach ($Package in $Packages)
    {
        $RegKey = "$RegKeyParent\$Package"
        try
        {
            $Enabled = Enable-ModifyRegKey -RegKey $RegKey
            if ($Enabled)
            {
                Write-LocalLog "Marking package absent: $Package"
                Set-ItemProperty -Path "HKLM:\$RegKey" -Name CurrentState -Value 0 -Type DWord -Force
            }
        }
        catch
        {
            Write-LocalLog "Failed to mark package absent: $Package. $_" -LogLevel ERROR
        }
    }
}

function Install-DismPackage
{
    <#
    .SYNOPSIS
        Installs a single .cab or .msu package via DISM.
        Returns a hashtable with Success ($true/$false), Output, and Errors.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    Write-LocalLog "DISM installing: $PackagePath (detail in C:\Windows\Logs\CBS\CBS.log)"

    $Output = DISM /Online /Add-Package /PackagePath:$PackagePath /NoRestart 2>&1
    Write-LocalLog "DISM output: $($Output | Out-String)"

    $Errors = $Output | Select-String "An error occurred"

    if ($Errors)
    {
        $Errors | ForEach-Object { Write-LocalLog "DISM error line: $($_.Line)" -LogLevel ERROR }
        return @{ Success = $false; Output = ($Output -join ', '); Errors = $Errors }
    }

    return @{ Success = $true; Output = ($Output -join ', '); Errors = $null }
}

function Install-PackageWithRetry
{
    <#
    .SYNOPSIS
        Installs a .msu or .cab package with CBS-aware retry logic.

    .DESCRIPTION
        For .msu files: expands the archive, installs any bundled SSU first,
        then installs the main KB .cab.

        On each attempt:
            1. Repair-CbsPackages     — fixes superseded package re-install failures
            2. DISM install attempt
            3. If DISM fails, Check-CbsErrors for SXS_ASSEMBLY_MISSING errors
            4. Repair-SxsAssemblyMissing — moves blocking packages to backup
            5. Reregister-LatestPackageVersions — re-registers moved packages
            6. Fix-SxSErrors          — marks stale registry packages absent

        Loop exits as soon as DISM reports success.
        Throws if the package still has errors after all repair attempts.

    .NOTES
        The do/while condition uses assignment ($Retry = $true) in the original
        source — this has been corrected to a comparison ($Retry -eq $true).
    #>
    Param(
        [Parameter(Mandatory = $true)] [string]$PkgPath,
        [Parameter(Mandatory = $true)] [string[]]$CbsErrorStrings,
        [Parameter(Mandatory = $true)] [string]$BackupPath
    )

    Write-LocalLog "=== Install-PackageWithRetry: $PkgPath ==="

    # --- .msu expansion ---
    if ($PkgPath -like '*.msu')
    {
        Write-LocalLog ".msu detected — expanding to extract .cab"

        $ExpandDir = Join-Path $BackupPath 'MSU_Expand'
        New-DirectoryIfMissing -Path $ExpandDir

        # Extract KB number from filename if present (used to pick the right .cab)
        $KbNumber = if ((Split-Path $PkgPath -Leaf) -match '(KB\d+)') { $Matches[1] } else { $null }

        expand.exe $PkgPath $ExpandDir -F:* | Out-Null

        # Install Servicing Stack Update first if bundled
        $SsuFile = Get-ChildItem -Path $ExpandDir -Filter '*SSU*.cab' | Select-Object -First 1
        if ($SsuFile)
        {
            Write-LocalLog "Installing bundled SSU: $($SsuFile.Name)"
            $SsuResult = Install-DismPackage -PackagePath $SsuFile.FullName
            if (-not $SsuResult.Success)
            {
                Write-LocalLog "SSU install had issues — continuing with KB package." -LogLevel WARN
            }
        }

        # Locate the main KB .cab
        $CabFile = if ($KbNumber)
        {
            Get-ChildItem -Path $ExpandDir -Filter "*$KbNumber*.cab" | Select-Object -First 1
        }
        else
        {
            Get-ChildItem -Path $ExpandDir -Filter '*.cab' | Select-Object -First 1
        }

        if (-not $CabFile)
        {
            throw "Could not find a .cab file after expanding '$PkgPath'."
        }

        Write-LocalLog "Using expanded .cab: $($CabFile.FullName)"
        $PkgPath = $CabFile.FullName
    }

    # --- Retry loop ---
    $RetryCounter  = 0
    $InstallResult = $null

    do
    {
        $RetryCounter++
        Write-LocalLog "--- Repair/install attempt $RetryCounter ---"

        # Step 1 — repair CBS packages from log
        try
        {
            Write-LocalLog "Step 1: Repair-CbsPackages"
            $CbsRepaired = Repair-CbsPackages
        }
        catch
        {
            Write-LocalLog "Repair-CbsPackages threw an exception. $_" -LogLevel ERROR
            $CbsRepaired = $false
        }

        # Step 2 — attempt DISM install
        Write-LocalLog "Step 2: DISM install"
        $InstallResult = Install-DismPackage -PackagePath $PkgPath

        if ($InstallResult.Success)
        {
            Write-LocalLog "DISM install succeeded on attempt $RetryCounter."
            break
        }

        # Step 3 — CBS SXS error check
        Write-LocalLog "Step 3: Check CBS for SXS errors"
        $SxsErrors = Check-CbsErrors -ErrorStrings $CbsErrorStrings

        # Steps 4-5 — SXS assembly repair (only if CBS repair didn't already handle it)
        if ($SxsErrors -and (-not $CbsRepaired))
        {
            Write-LocalLog "Step 4: Repair-SxsAssemblyMissing"
            $Problematic = Repair-SxsAssemblyMissing -ErrorStrings $SxsErrors -BackupPath $BackupPath

            if ($Problematic.Count -gt 0)
            {
                Write-LocalLog "Step 5: Reregister-LatestPackageVersions"
                Reregister-LatestPackageVersions -PackageNames $Problematic
            }
        }

        # Step 6 — Fix stale SxS registry entries
        try
        {
            Write-LocalLog "Step 6: Fix-SxSErrors"
            Fix-SxSErrors -BackupFolder $BackupPath
        }
        catch
        {
            Write-LocalLog "Fix-SxSErrors threw an exception. $_" -LogLevel ERROR
        }

    } while ($RetryCounter -lt 5)   # Safety cap — prevents infinite loops

    # --- Final validation ---
    $FinalErrors = Check-CbsErrors -ErrorStrings $CbsErrorStrings

    Write-LocalLog "Install-PackageWithRetry complete. Attempts: $RetryCounter"

    if ($FinalErrors)
    {
        throw "Package '$PkgPath' still has CBS errors after $RetryCounter attempt(s). Review C:\Windows\Logs\CBS\CBS.log."
    }

    if (-not $InstallResult.Success)
    {
        throw "Package '$PkgPath' did not install successfully after $RetryCounter attempt(s)."
    }

    Write-LocalLog "Package installed cleanly: $PkgPath"
}

function Write-CacheEntryAsJson
{
    <#
    .SYNOPSIS
        Serialises a hashtable to JSON and writes it to the specified file.
    #>
    Param(
        [Parameter(Mandatory = $true)] [System.Collections.Hashtable]$Data,
        [Parameter(Mandatory = $true)] [string]$FilePath
    )

    $Json = @{}
    foreach ($Item in $Data.GetEnumerator()) { $Json[$Item.Name] = $Item.Value }

    $Json | ConvertTo-Json | Set-Content -Path $FilePath
    Write-LocalLog "Cache updated: $FilePath"
}
#endregion Functions

# ==============================================================================
# SCRIPT VARIABLES
# ==============================================================================
#region ScriptVariables

$ErrorActionPreference  = 'Continue'    # Individual try/catch blocks handle errors
$WarningPreference      = 'SilentlyContinue'

$DateStamp              = Get-Date -Format 'dd-MMM-yyyy'
$LogFilePath            = 'C:\Admin\_Logs\WindowsUpdate'
$TempPath               = 'C:\Admin\Temp'
$FileBackupPath         = Join-Path $TempPath 'WindowsUpdateRepair'
$FileArchivePath        = Join-Path $FileBackupPath 'Archive'
$FailedUpdatesCachePath = Join-Path $TempPath $FailedUpdatesCacheFileName
$script:LogFile         = Join-Path $LogFilePath "WindowsUpdates_$DateStamp.log"
$CbsErrorStrings        = @('ERROR_SXS_ASSEMBLY_MISSING')

#endregion ScriptVariables

# ==============================================================================
# DIRECTORY SETUP
# ==============================================================================

foreach ($Dir in @($LogFilePath, $TempPath, $FileBackupPath, $FileArchivePath))
{
    New-DirectoryIfMissing -Path $Dir
}

Write-LocalLog "=== Starting Repair-WindowsUpdateClient | Host: $env:COMPUTERNAME ==="

# ==============================================================================
# KB LIST RESOLUTION
# ==============================================================================
#region KBResolution

# Load the local cache (always attempted — used for RepairCycles tracking too)
$CacheContent = if (Test-Path $FailedUpdatesCachePath)
{
    Get-Content $FailedUpdatesCachePath | ConvertFrom-Json
}
else { $null }

# Resolve the KB target list: parameter wins, cache is fallback
if ($KBList -and $KBList.Count -gt 0)
{
    Write-LocalLog "KB list supplied via parameter: $($KBList -join ', ')"
    $TargetKBs = $KBList
}
elseif ($CacheContent -and $CacheContent.FailedUpdates -and $CacheContent.FailedUpdates.Count -gt 0)
{
    $TargetKBs = $CacheContent.FailedUpdates
    Write-LocalLog "KB list loaded from cache ($FailedUpdatesCachePath): $($TargetKBs -join ', ')"
}
else
{
    $Msg = "No KB list available. Provide -KBList or ensure '$FailedUpdatesCachePath' contains a non-empty FailedUpdates array."
    Write-LocalLog $Msg -LogLevel FATAL
    throw $Msg
}

#endregion KBResolution

# ==============================================================================
# LOCATE PACKAGE FILES
# ==============================================================================
#region LocatePackages

Write-LocalLog "Scanning '$PackagePath' for packages matching: $($TargetKBs -join ', ')"

# Build a single regex from all KB numbers for efficient matching
$KbRegex = ($TargetKBs | ForEach-Object { [regex]::Escape($_) }) -join '|'

$MatchingFiles = Get-ChildItem -Path $PackagePath -File |
    Where-Object { $_.Name -match $KbRegex }

if ($MatchingFiles.Count -eq 0)
{
    $Msg = "No files matching '$($TargetKBs -join ', ')' found in '$PackagePath'. Verify the folder contains the correct .msu or .cab files."
    Write-LocalLog $Msg -LogLevel FATAL
    throw $Msg
}

Write-LocalLog "Found $($MatchingFiles.Count) matching package file(s): $($MatchingFiles.Name -join ', ')"

#endregion LocatePackages

# ==============================================================================
# ARCHIVE PREVIOUS REPAIR FILES
# ==============================================================================

Write-LocalLog "Archiving previous repair artefacts from '$FileBackupPath' to '$FileArchivePath'."
Get-ChildItem -Path $FileBackupPath -File -ErrorAction SilentlyContinue |
    Move-Item -Destination $FileArchivePath -Force -ErrorAction SilentlyContinue

# ==============================================================================
# REPAIR SEQUENCE — PRE-INSTALL
# ==============================================================================

# --- Step 1: Fix-SxSErrors (initial pass) ---
Write-LocalLog "--- Pre-install Step 1: Fix-SxSErrors ---"
try   { Fix-SxSErrors -BackupFolder $FileBackupPath }
catch { Write-LocalLog "Fix-SxSErrors failed. $_" -LogLevel ERROR }

# --- Step 2: SFC /SCANNOW ---
Write-LocalLog "--- Pre-install Step 2: SFC /SCANNOW (output in C:\Windows\Logs\CBS\CBS.log) ---"
try   { SFC /SCANNOW }
catch { Write-LocalLog "SFC /SCANNOW failed. $_" -LogLevel ERROR }

# --- Step 3: Reset-WUComponents (2-minute timeout with one retry) ---
Write-LocalLog "--- Pre-install Step 3: Reset-WUComponents ---"
try
{
    $WuJob = Start-Job -ScriptBlock { Reset-WUComponents }

    if (Wait-Job $WuJob -Timeout 120)
    {
        Receive-Job $WuJob | Out-Null
        Write-LocalLog "Reset-WUComponents completed."
    }
    else
    {
        Write-LocalLog "Reset-WUComponents timed out — retrying once." -LogLevel WARN
        Stop-Job  $WuJob
        Remove-Job $WuJob

        $WuJob = Start-Job -ScriptBlock { Reset-WUComponents }
        if (Wait-Job $WuJob -Timeout 120)
        {
            Receive-Job $WuJob | Out-Null
            Write-LocalLog "Reset-WUComponents completed on retry."
        }
        else
        {
            Write-LocalLog "Reset-WUComponents timed out on retry." -LogLevel ERROR
            Stop-Job $WuJob
        }
    }
    Remove-Job $WuJob -ErrorAction SilentlyContinue
}
catch { Write-LocalLog "Reset-WUComponents threw an exception. $_" -LogLevel ERROR }

# --- Step 4: DISM StartComponentCleanup ---
Write-LocalLog "--- Pre-install Step 4: DISM /Cleanup-Image /StartComponentCleanup ---"
try   { DISM /Online /Cleanup-Image /StartComponentCleanup }
catch { Write-LocalLog "DISM StartComponentCleanup failed. $_" -LogLevel ERROR }

# --- Step 5: DISM RestoreHealth ---
Write-LocalLog "--- Pre-install Step 5: DISM /Cleanup-Image /RestoreHealth ---"
try   { DISM /Online /Cleanup-Image /RestoreHealth }
catch { Write-LocalLog "DISM RestoreHealth failed. $_" -LogLevel ERROR }

# --- Step 6: Fix-SxSErrors (second pass — catches anything uncovered above) ---
Write-LocalLog "--- Pre-install Step 6: Fix-SxSErrors (second pass) ---"
try   { Fix-SxSErrors -BackupFolder $FileBackupPath }
catch { Write-LocalLog "Fix-SxSErrors (second pass) failed. $_" -LogLevel ERROR }

# ==============================================================================
# PACKAGE INSTALLATION
# ==============================================================================
#region InstallPackages

$InstallErrors = @()

foreach ($File in $MatchingFiles)
{
    Write-LocalLog "Installing: $($File.Name)"
    try
    {
        Install-PackageWithRetry `
            -PkgPath        $File.FullName `
            -CbsErrorStrings $CbsErrorStrings `
            -BackupPath     $FileBackupPath
    }
    catch
    {
        Write-LocalLog "Failed to repair/install '$($File.Name)'. $_" -LogLevel ERROR
        $InstallErrors += $File.Name
    }
}

#endregion InstallPackages

# ==============================================================================
# CACHE UPDATE
# ==============================================================================

# Persist repair outcome — clears the failed list on full success, preserves history
$NewRepairCycles = if ($CacheContent.RepairCycles) { [int]$CacheContent.RepairCycles + 1 } else { 1 }

Write-CacheEntryAsJson -Data @{
    FailedUpdates        = if ($InstallErrors.Count -gt 0) { $InstallErrors } else { @() }
    RepairCycles         = if ($InstallErrors.Count -gt 0) { $NewRepairCycles } else { 0 }
    PreviousRepairCycles = $CacheContent.RepairCycles
    LastRepairTriggered  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
} -FilePath $FailedUpdatesCachePath

# ==============================================================================
# COMPLETION
# ==============================================================================

if ($InstallErrors.Count -gt 0)
{
    $Msg = "Repair completed with $($InstallErrors.Count) failure(s): $($InstallErrors -join ', '). Review C:\Windows\Logs\CBS\CBS.log."
    Write-LocalLog $Msg -LogLevel ERROR
    throw $Msg
}

Write-LocalLog "=== Repair-WindowsUpdateClient complete — all packages installed successfully ==="
