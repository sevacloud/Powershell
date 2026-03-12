function Write-LocalLog
{
<#
  .SYNOPSIS
    Writes a timestamped log message to a file and optionally to the console,
    with colour-coding based on log level.

  .DESCRIPTION
    Reusable logging function for PowerShell scripts. Writes formatted log entries
    to a file and optionally prints them to the console with colour-coded output.

    Log file path is resolved in this order:
        1. -LogFile parameter (explicit override)
        2. $script:LogFilePath scoped variable (set by the calling script)
        3. Falls back to C:\Admin\_Logs\local.log

    Log directory is created automatically if it does not exist.
    File writes use a retry loop to handle transient file-lock contention.

  .PARAMETER LogMessage
    The content of the log entry.

  .PARAMETER LogLevel
    Severity of the message. Options: DEBUG, INFO, WARN, ERROR, FATAL.
    Default: INFO.

  .PARAMETER LogFile
    Optional override for the log file path. When omitted, $script:LogFilePath
    is used, falling back to C:\Admin\_Logs\local.log.

  .PARAMETER TimestampFormat
    DateTime format string for the log entry timestamp (UTC).
    Default: yyyy/MM/dd HH:mm:ss.

  .PARAMETER WriteToConsole
    When $true (default), prints the log entry to the console with colour.

  .EXAMPLE
    Write-LocalLog -LogMessage "Deployment started"

  .EXAMPLE
    Write-LocalLog -LogMessage "Disk space low" -LogLevel "WARN" -WriteToConsole $false

  .NOTES
    Original Author : Liamarjit Bhogal (© Seva Cloud 2026)
    Disclaimer      : Provided as-is with no warranty. Test before use in production.
    Donate          : https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
#>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogMessage,

        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "FATAL")]
        [string]$LogLevel = "INFO",

        # Explicit path overrides the script-scoped variable and the default
        [Parameter(Mandatory = $false)]
        [string]$LogFile = "",

        [Parameter(Mandatory = $false)]
        [string]$TimestampFormat = "yyyy/MM/dd HH:mm:ss",

        [Parameter(Mandatory = $false)]
        [bool]$WriteToConsole = $true
    )

    # --- Resolve log file path ---
    # Priority: parameter → $script:LogFilePath → default
    if ([string]::IsNullOrWhiteSpace($LogFile))
    {
        $LogFile = if ($script:LogFilePath -match '\w') { $script:LogFilePath }
                   else { 'C:\Admin\_Logs\local.log' }
    }

    # --- Ensure log directory exists ---
    $LogDirectory = Split-Path $LogFile -Parent
    if (-not (Test-Path $LogDirectory))
    {
        try
        {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        catch
        {
            Write-Warning "Could not create log directory '$LogDirectory': $_"
            return
        }
    }

    # --- Build log line ---
    $Timestamp  = (Get-Date).ToUniversalTime().ToString($TimestampFormat)
    $ScriptName = try { Split-Path $PSCommandPath -Leaf } catch { 'LocalRun' }
    $LogLine    = '{0}, {1}, {2}, {3}' -f $Timestamp, $ScriptName, $LogLevel, $LogMessage.Trim()

    # --- Write to console with colour ---
    if ($WriteToConsole)
    {
        $Color = switch ($LogLevel)
        {
            "DEBUG" { "Gray"    }
            "INFO"  { "White"   }
            "WARN"  { "Yellow"  }
            "ERROR" { "Red"     }
            "FATAL" { "Magenta" }
        }
        Write-Host $LogLine -ForegroundColor $Color
    }

    # --- Write to file with retry (handles transient file-lock contention) ---
    $MaxRetries = 3
    $Attempt    = 0

    while ($Attempt -lt $MaxRetries)
    {
        try
        {
            [System.IO.File]::AppendAllText($LogFile, "$LogLine`r`n")
            break
        }
        catch
        {
            $Attempt++
            if ($Attempt -ge $MaxRetries)
            {
                Write-Warning "Failed to write to log file '$LogFile' after $MaxRetries attempts: $_"
            }
            else
            {
                Start-Sleep -Milliseconds 50
            }
        }
    }
}
