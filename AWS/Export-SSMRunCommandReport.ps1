function Export-SSMRunCommandReport {
<#
.SYNOPSIS
Exports a report of SSM Run Command executions over a specified time range and generates an Excel heat map.

.DESCRIPTION
Queries AWS SSM for command invocations between the provided start and end times (default: last 7 days).
The function exports the result as a detailed Excel report and a separate heat map by hour/day.

.PARAMETER Credential
An AWSCredentials object (e.g., from Get-AwsCred). Required for AWS access.

.PARAMETER Region
The AWS region to query.

.PARAMETER StartTime
(OPTIONAL) Start of the report range. Default: 7 days ago.

.PARAMETER EndTime
(OPTIONAL) End of the report range. Default: now.

.PARAMETER ExcelReportPath
(OPTIONAL) Path to export the main execution report. Default: C:\Reports\SSM_RunCommand_Executions.xlsx

.PARAMETER HeatMapPath
(OPTIONAL) Path to export the heat map report. Default: C:\Reports\SSM_HeatMap.xlsx

.EXAMPLE
Export-SSMRunCommandReport -Credential $Cred.Credential -Region 'us-east-1'

.EXAMPLE
Export-SSMRunCommandReport -Credential $Cred.Credential -Region 'eu-west-1' -StartTime (Get-Date).AddDays(-3)

.NOTES
Author: Liamarjit Bhogal
Website: https://sevacloud.co.uk
Make A Donation: https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
Date: 2025
#>
    param (
        [Parameter(Mandatory = $true)]
        [Amazon.Runtime.AWSCredentials]$Credential,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [datetime]$StartTime = (Get-Date).AddDays(-7).ToUniversalTime(),
        [datetime]$EndTime = (Get-Date).ToUniversalTime(),

        [string]$ExcelReportPath = "C:\Reports\SSM_RunCommand_Executions.xlsx",
        [string]$HeatMapPath = "C:\Reports\SSM_HeatMap.xlsx"
    )

    $AuthSplat = @{
        Region     = $Region
        Credential = $Credential
        ErrorAction = 'Stop'
    }

    $CommandFilter = @(
        @{Key = 'InvokedAfter'; Value = $StartTime.ToString("o") }
        @{Key = 'InvokedBefore'; Value = $EndTime.ToString("o") }
    )

    $ExecutionData = @()
    $CommandSplat = @{
        Filter    = $CommandFilter
        MaxResult = 50
        Select    = '*'
    }

    Write-LocalLog "Fetching SSM Run Command Executions from $StartTime to $EndTime"

    $NextToken = $null
    $Page = 0
    do {
        $Page++
        Write-LocalLog "Fetching page $Page of command invocations..."
        $Response = Get-SSMCommandInvocation @AuthSplat @CommandSplat -NextToken $NextToken
        if ($Response) {
            $ExecutionData += $Response.CommandInvocations
        }
        $NextToken = $Response.NextToken
    } while ($NextToken)

    if ($ExecutionData.Count -eq 0) {
        Write-LocalLog -LogLevel:WARN "No SSM Run Command Executions found for the selected period."
        return
    }

    Write-LocalLog "Retrieved $($ExecutionData.Count) command executions."

    $ProcessedData = $ExecutionData | ForEach-Object {
        [PSCustomObject]@{
            CommandId       = $_.CommandId
            InstanceId      = $_.InstanceId
            DocumentName    = $_.DocumentName
            Status          = $_.Status
            StatusDetails   = $_.StatusDetails
            ExecutionStart  = [datetime]$_.RequestedDateTime
            ExecutionEnd    = [datetime]$_.ExecutionEndDateTime
            DurationSeconds = ($_.ExecutionEndDateTime - $_.RequestedDateTime).TotalSeconds
        }
    }

    # Ensure folders exist
    foreach ($Path in @($ExcelReportPath, $HeatMapPath)) {
        $Dir = Split-Path -Parent $Path
        if (-not (Test-Path $Dir)) {
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
    }

    Write-LocalLog "Exporting detailed execution report to $ExcelReportPath"
    $ProcessedData | Export-Excel -Path $ExcelReportPath -AutoSize -BoldTopRow `
        -Title "SSM Run Command Executions" -TableName "SSMExecutions" -WorksheetName "Executions"

    # Generate heat map
    $HeatMapData = $ProcessedData | Select-Object `
        @{Name = "Hour"; Expression = { $_.ExecutionStart.Hour } },
        @{Name = "DayOfWeek"; Expression = { $_.ExecutionStart.DayOfWeek } },
        @{Name = "Count"; Expression = { 1 } } |
        Group-Object -Property Hour, DayOfWeek -NoElement |
        Select-Object `
            @{Name = "Hour"; Expression = { $_.Name.Split(',')[0] } },
            @{Name = "DayOfWeek"; Expression = { $_.Name.Split(',')[1] } },
            @{Name = "InvocationCount"; Expression = { $_.Count } }

    Write-LocalLog "Exporting heat map data to $HeatMapPath"
    $HeatMapData | Export-Excel -Path $HeatMapPath -AutoSize -BoldTopRow `
        -TableName "HeatMapData" -WorksheetName "HeatMap"

    Write-LocalLog "Reports successfully exported."
}
