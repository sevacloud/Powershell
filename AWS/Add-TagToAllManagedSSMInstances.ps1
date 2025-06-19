<#
.SYNOPSIS
Adds a specified tag to all Systems Manager (SSM) Managed Instances and EC2 Instances within a given region.

.DESCRIPTION
This script retrieves all instances registered with AWS Systems Manager in a specified AWS region, 
then applies a user-defined tag to each instance.

It supports both "ManagedInstance" (typically on-prem or hybrid) and "EC2Instance" types, and applies the tag using 
the appropriate AWS PowerShell cmdlets. Errors are caught and retried, and the script provides a summary of successes 
and failures at the end.

.PARAMETER TagKey
The name of the tag key to be applied to all discovered instances.

.PARAMETER TagValue
The value of the tag to assign to the provided TagKey.

.PARAMETER Region
The AWS region in which to find and tag SSM and EC2 instances.

.PARAMETER Credential
An AWS credentials object (e.g., from Get-AwsCred). Must be an Amazon.Runtime.AWSCredentials object.
Used to authenticate API calls when tagging SSM and EC2 instances.

.EXAMPLE
.\Add-TagToAllInstances.ps1 -TagKey 'Maintenance' -TagValue 'True' -Region 'eu-west-1' -Credential $AwsCreds.Credential

Adds the tag `MaintenanceWindowTagsRequired=True` to all SSM Managed and EC2 instances in the `us-east-1` region using AWS credentials.

.NOTES
Author: Liamarjit Bhogal
Website: https://sevacloud.co.uk
Date: 2025
AWS PowerShell Module Required: AWSPowerShell.NetCore or AWS.Tools.*

- Supports retry mechanism for failed attempts.
- Processes each instance individually for better fault tolerance.
- Useful for automating tagging policies or preparing for maintenance window automation.

#>

param (
  [Parameter(Mandatory = $true)]
  [string]$TagKey,
  [Parameter(Mandatory = $true)]
  [string]$TagValue,
  [Parameter(Mandatory = $true)]
  [string]$Region,
  [Parameter(Mandatory = $true)]
  [Amazon.Runtime.SessionAWSCredentials]$Credential
)

$AuthSplat = @{
    Region      = $Region
    Credential  = $Credential
    ErrorAction = 'Stop'
}

$InstanceInformationList = Get-SSMInstanceInformation @AuthSplat

$Instances = [System.Collections.ArrayList]@()
$EC2Instances = [System.Collections.ArrayList]@()
$ManagedInstances = [System.Collections.ArrayList]@()
foreach ($Instance in $InstanceInformationList) {
    $Instances.Add($Instance) | Out-Null
    if ($Instance.ResourceType -eq "ManagedInstance") {
        $ManagedInstances.Add($Instance) | Out-Null
    } elseif ($Instance.ResourceType -eq "EC2Instance") {
        $EC2Instances.Add($Instance) | Out-Null
    }
}

Write-LocalLog "Initial count of instances to process: $($Instances.Count)"
Write-LocalLog "ManagedInstances Count: $($ManagedInstances.Count)"
Write-LocalLog "EC2Instances Count: $($EC2Instances.Count)"

# Loop through each instance ID and add the tag
while ($Instances.Count -gt 0) {
    $Instance = $Instances[0]  # Get first instance in the list
    $InstanceId = $Instance.InstanceId
    $ResourceType = $Instance.ResourceType

    Write-LocalLog "nProcessing instance: $InstanceId"
    Write-LocalLog "Remaining instances to process: $($Instances.Count)"

    # Create the tag
    $Tag = @(
        @{
            Key   = $TagKey
            Value = $TagValue
        }
    )

    $TagSplat = @{
        Tag         = $Tag
        ErrorAction = 'Stop'
    }

    try {
        # Apply the tag
        if ($ResourceType -eq "ManagedInstance") {
            Write-LocalLog "Updating ManagedInstance tag"
            Add-SSMResourceTag 
                -ResourceType "ManagedInstance" 
                -ResourceId $InstanceId 
                @AuthSplat 
                @TagSplat

            $ManagedInstances.RemoveAt(0)
        } elseif ($ResourceType -eq "EC2Instance") {
            Write-LocalLog "Updating EC2Instance tag"
            New-EC2Tag -Resource $InstanceId @AuthSplat @TagSplat

            $EC2Instances.RemoveAt(0)
        } else {
            Write-LocalLog  "ResourceType '$ResourceType' not recognized"
            $Instances.RemoveAt(0)
            $Instances.Add($InstanceId)
        }

        Write-LocalLog "Successfully tagged instance $InstanceId"

        # Remove the successfully processed instance from the array
        $Instances.RemoveAt(0)
    }
    catch {
        Write-LocalLog -LogLevel:ERROR "Failed to tag instance $InstanceId. $_"

        # Optional: Move failed instance to end of the array to try again
        $Instances.RemoveAt(0)
        $Instances.Add($InstanceId)

        if ($ResourceType -eq "ManagedInstance") {
            $ManagedInstances.RemoveAt(0)
            $ManagedInstances.Add($InstanceId)
        } elseif ($ResourceType -eq "EC2Instance") {
            $EC2Instances.RemoveAt(0)
            $EC2Instances.Add($InstanceId)
        }
        # Optional: Add a pause before trying the next instance
        Start-Sleep -Seconds 2
    }
}

if ($Instances.Count -eq 0) {
    Write-LocalLog "nAll instances successfully processed!"
} else {
    Write-LocalLog -LogLevel:WARN "nRemaining unprocessed instances. $($Instances.Count)"
    Write-LocalLog -LogLevel:WARN "nRemaining unprocessed ManagedInstances. $($ManagedInstances.Count)"
    Write-LocalLog -LogLevel:WARN "nRemaining unprocessed EC2nstances. $($EC2Instances.Count)"
    Write-LocalLog -LogLevel:WARN "Instances still to process. $($Instances.InstanceId)"
}
