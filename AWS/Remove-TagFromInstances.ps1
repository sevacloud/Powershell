function Remove-TagFromInstances {
<#
.SYNOPSIS
Removes a specific tag from all or a subset of SSM Managed Instances and EC2 Instances.

.DESCRIPTION
This function finds all instances (or takes a provided list) and removes the specified tag from each.
Supports both EC2 and ManagedInstance resources using appropriate AWS PowerShell modules.

.PARAMETER TagKey
The name of the tag to remove.

.PARAMETER Region
AWS region where the instances are located.

.PARAMETER Credential
The AWS credentials object used for authentication.

.PARAMETER Instances
(Optional) A list of instances to process. If not provided, all instances are retrieved via SSM.

.EXAMPLE
$Creds = Get-AwsCred -RoleArn "arn:aws:iam::123456789012:role/MyOps"
Remove-TagFromInstances -TagKey 'LegacyTag' -Region 'eu-west-1' -Credential $Creds.Credential

.EXAMPLE
$Audit = Get-SSMInstancesMissingTag -TagKey 'LegacyTag' -Region 'eu-west-1' -Credential $Creds.Credential
Remove-TagFromInstances -TagKey 'LegacyTag' -Region 'eu-west-1' -Credential $Creds.Credential -Instances $Audit.EC2Instances + $Audit.ManagedInstances

.NOTES
Author: Liamarjit Bhogal
Website: https://sevacloud.co.uk
Make A Donation: https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
Date: 2025
AWS PowerShell Module Required: AWSPowerShell.NetCore or AWS.Tools.*
#>
    param (
        [Parameter(Mandatory = $true)]
        [string]$TagKey,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [Amazon.Runtime.AWSCredentials]$Credential,

        [Parameter(Mandatory = $false)]
        [System.Collections.IEnumerable]$Instances
    )

    $AuthSplat = @{
        Region      = $Region
        Credential  = $Credential
        ErrorAction = 'Stop'
    }

    if (-not $Instances) {
        Write-LocalLog "Fetching all SSM instances from $Region..."
        $Instances = Get-SSMInstanceInformation @AuthSplat
    }

    $AllInstances = [System.Collections.ArrayList]@($Instances)
    $EC2Instances = [System.Collections.ArrayList]@()
    $ManagedInstances = [System.Collections.ArrayList]@()

    foreach ($Instance in $AllInstances) {
        if ($Instance.ResourceType -eq "ManagedInstance") {
            $ManagedInstances.Add($Instance) | Out-Null
        } elseif ($Instance.ResourceType -eq "EC2Instance") {
            $EC2Instances.Add($Instance) | Out-Null
        }
    }

    Write-LocalLog "Starting tag removal: total instances = $($AllInstances.Count)"
    Write-LocalLog "ManagedInstances = $($ManagedInstances.Count), EC2Instances = $($EC2Instances.Count)"

    while ($AllInstances.Count -gt 0) {
        $Instance = $AllInstances[0]
        $InstanceId = $Instance.InstanceId
        $ResourceType = $Instance.ResourceType

        Write-LocalLog "Processing instance $InstanceId ($ResourceType)"

        try {
            if ($ResourceType -eq "ManagedInstance") {
                Write-LocalLog "Removing tag from ManagedInstance $InstanceId"
                Remove-SSMResourceTag -ResourceType "ManagedInstance" -ResourceId $InstanceId -TagKey $TagKey @AuthSplat -Confirm:$false
                $ManagedInstances.Remove($Instance)
            }
            elseif ($ResourceType -eq "EC2Instance") {
                Write-LocalLog "Removing tag from EC2Instance $InstanceId"
                Remove-EC2Tag -Resource $InstanceId -Tag @{ Key = $TagKey } @AuthSplat -Force
                $EC2Instances.Remove($Instance)
            }
            else {
                Write-LocalLog -LogLevel:WARN "Unknown ResourceType '$ResourceType' for $InstanceId"
            }

            Write-LocalLog "Successfully removed tag from $InstanceId"
            $AllInstances.RemoveAt(0)
        }
        catch {
            Write-LocalLog -LogLevel:ERROR "Failed to remove tag from $InstanceId: $_"
            $AllInstances.RemoveAt(0)
            $AllInstances.Add($Instance)
            Start-Sleep -Seconds 2
        }
    }

    if ($AllInstances.Count -eq 0) {
        Write-LocalLog "All instances successfully processed."
    } else {
        Write-LocalLog -LogLevel:WARN "Unprocessed instances remaining: $($AllInstances.Count)"
        Write-LocalLog -LogLevel:WARN "Remaining ManagedInstances: $($ManagedInstances.Count)"
        Write-LocalLog -LogLevel:WARN "Remaining EC2Instances: $($EC2Instances.Count)"
    }
}
