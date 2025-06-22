function Start-PowerShellProcessMonitor {
<#
.SYNOPSIS
Monitors PowerShell process CPU and memory usage and logs the results to CSV over time. Adapt this tool to report to Cloudwatch for historic trends over longer time periods

.DESCRIPTION
Periodically scans all PowerShell processes on the system, capturing CPU, memory, and command line details.
Data is written to a CSV file for performance analysis or auditing.

.PARAMETER DurationMinutes
The number of minutes to run monitoring. Default is 240 (4 hours).

.PARAMETER IntervalSeconds
The delay in seconds between each polling cycle. Default is 5 seconds.

.PARAMETER OutputPath
The full path to write or append the monitoring CSV file. Defaults to C:\Admin\_Logs\{hostname}_PowerShellMonitor.csv

.EXAMPLE
Start-PowerShellProcessMonitor -DurationMinutes 60 -IntervalSeconds 10

Monitors PowerShell usage every 10 seconds for 1 hour.

.EXAMPLE
Start-PowerShellProcessMonitor -OutputPath 'D:\Logs\Monitor.csv'

Writes logs to a custom path.

.NOTES
Author: Liamarjit Bhogal
Website: https://sevacloud.co.uk
Make A Donation: https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
Date: 2025
Requires: PowerShell 5.1+, WMI access
#>
    param (
        [int]$DurationMinutes = 240,
        [int]$IntervalSeconds = 5,
        [string]$OutputPath = "C:\Admin\_Logs\$($env:COMPUTERNAME)_PowerShellMonitor.csv"
    )

    # Ensure log folder exists
    $LogFolder = Split-Path -Parent $OutputPath
    if (-not (Test-Path $LogFolder)) {
        New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
    }

    # Local functions
    function Get-PowershellProcessExecutions {
        $Cpu = Get-WmiObject Win32_PerfFormattedData_PerfProc_Process |
            Where-Object { $_.Name -like '*powershell*' } |
            Select-Object IDProcess, Name, PercentProcessorTime

        $Memory = Get-WmiObject Win32_Process |
            Where-Object { $_.Name -like '*powershell*' } |
            Select-Object ProcessId, ParentProcessId, @{
                Name = 'MemoryUsageGB'
                Expression = { [math]::Round($_.WorkingSetSize / 1GB, 2) }
            }, CommandLine

        foreach ($Proc in $Memory) {
            [PSCustomObject]@{
                TimeStamp            = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                ProcessId            = $Proc.ProcessId
                ParentProcessId      = $Proc.ParentProcessId
                MemoryUsageGB        = $Proc.MemoryUsageGB
                PercentProcessorTime = ($Cpu | Where-Object { $_.IDProcess -eq $Proc.ProcessId }).PercentProcessorTime
                CommandLine          = $Proc.CommandLine
            }
        }
    }

    function Get-CpuUtilization {
        $Cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
        return [math]::Round($Cpu, 2)
    }

    # Monitoring start
    Write-LocalLog "Starting PowerShell process monitoring for $DurationMinutes minutes every $IntervalSeconds seconds."
    $EndTime = (Get-Date).AddMinutes($DurationMinutes)
    $CsvExists = Test-Path $OutputPath

    while ((Get-Date) -lt $EndTime) {
        $CpuUsage = Get-CpuUtilization
        $ProcessData = Get-PowershellProcessExecutions

        $Results = foreach ($p in $ProcessData) {
            [PSCustomObject]@{
                TimeStamp            = $p.TimeStamp
                ProcessId            = $p.ProcessId
                ParentProcessId      = $p.ParentProcessId
                MemoryUsageGB        = $p.MemoryUsageGB
                PercentProcessorTime = $p.PercentProcessorTime
                CommandLine          = $p.CommandLine
                TotalCpuUsage        = $CpuUsage
            }
        }

        if (-not $CsvExists) {
            Write-LocalLog "Creating new CSV at $OutputPath"
            $Results | Export-Csv -Path $OutputPath -NoTypeInformation -Force
            $CsvExists = $true
        } else {
            Write-LocalLog "Appending to CSV at $OutputPath"
            $Results | Export-Csv -Path $OutputPath -NoTypeInformation -Append -Force
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-LocalLog "Monitoring complete. Data written to $OutputPath"
}
