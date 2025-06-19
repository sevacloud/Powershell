function Write-LocalLog {
<#
.SYNOPSIS
Writes a timestamped log message to a file and optionally to the console, with color-coding based on log level.

.DESCRIPTION
This function creates a reusable and extensible logging mechanism for PowerShell scripts. It writes formatted log messages to a specified file (defaulting to C:\Admin\_Logs\local.log) and optionally prints them to the console with colored output based on severity.

Log levels include: DEBUG, INFO, WARN, ERROR, and FATAL. If the log directory does not exist, it will be created automatically.

.PARAMETER LogMessage
The main content of the log entry.

.PARAMETER LogLevel
The severity of the log message. Options: DEBUG, INFO, WARN, ERROR, FATAL. Default is INFO.

.PARAMETER LogFile
Path to the log file. Defaults to C:\Admin\_Logs\local.log.

.PARAMETER TimestampFormat
Format for the timestamp. Default is yyyy/MM/dd HH:mm:ss (UTC).

.PARAMETER WriteToConsole
If true, also prints the message to the console with color. Default is true.

.EXAMPLE
Write-LocalLog -LogMessage "Deployment started" -LogLevel "INFO"

.EXAMPLE
Write-LocalLog -LogMessage "Disk space low" -LogLevel "WARN" -WriteToConsole:$false

.NOTES
Author: Liamarjit @ Seva Cloud
Use in automation, monitoring, or troubleshooting workflows.
#>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$LogMessage,

        [Parameter()]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "FATAL")]
        [string]$LogLevel = "INFO",

        [Parameter()]
        [string]$LogFile = "C:\Admin\_Logs\local.log",

        [Parameter()]
        [string]$TimestampFormat = "yyyy/MM/dd HH:mm:ss",

        [Parameter()]
        [bool]$WriteToConsole = $true
    )

    $TimeStamp = (Get-Date).ToUniversalTime().ToString($TimestampFormat)
    $ScriptName = try { Split-Path $PSCommandPath -Leaf } catch { 'LocalRun' }
    $NewLogLine = '{0}, {1}, {2}, {3}' -f $TimeStamp, $ScriptName, $LogLevel, $LogMessage.Trim()

    # Ensure the log directory exists
    $LogDirectory = Split-Path $LogFile -Parent
    if (-not (Test-Path $LogDirectory)) {
        try {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        } catch {
            Write-Warning "Could not create log directory '$LogDirectory': $_"
            return
        }
    }

    # Map log levels to colors
    $ColorMap = @{
        "DEBUG" = "Gray"
        "INFO"  = "White"
        "WARN"  = "Yellow"
        "ERROR" = "Red"
        "FATAL" = "Magenta"
    }

    # Write to console with color if enabled
    if ($WriteToConsole) {
        $Color = $ColorMap[$LogLevel]
        Write-Host $NewLogLine -ForegroundColor $Color
    }

    # Write to log file
    try {
        $NewLogLine | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch {
        Write-Warning "Failed to write to log file: $_"
    }
}
