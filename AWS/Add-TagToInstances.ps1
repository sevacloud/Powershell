function Add-TagToInstances {
<#
.SYNOPSIS
    Adds a specified tag to one or more AWS SSM Managed or EC2 instances.

.DESCRIPTION
    This function applies a user-defined tag to each instance, either from a provided list or from all instances 
    discovered via Systems Manager in a specified AWS region.

    It supports both "ManagedInstance" and "EC2Instance" types. Errors are logged and optionally retried.

.PARAMETER TagKey
    The key name of the tag to apply.

.PARAMETER TagValue
    The value of the tag to apply.

.PARAMETER Region
    The AWS region where the instances are located.

.PARAMETER Credential
    An AWS credentials object (e.g., from Get-AwsCred). Must be an Amazon.Runtime.AWSCredentials object.

.PARAMETER Instances
    (Optional) A list of SSM instance information objects to tag. If not provided, instances are retrieved automatically.

.EXAMPLE
    $Creds = Get-AwsCred -RoleArn "arn:aws:iam::123456789012:role/MyRole"
    $Missing = Get-SSMInstancesMissingTag -TagKey 'MaintenanceWindow' -Region 'eu-west-1' -Credential $Creds.Credential
    Add-TagToInstances -TagKey 'MaintenanceWindow' -TagValue 'True' -Region 'eu-west-1' -Credential $Creds.Credential -Instances $Missing.ManagedInstances

.EXAMPLE
    Add-TagToInstances -TagKey 'Environment' -TagValue 'Prod' -Region 'us-east-1' -Credential $Creds.Credential

.NOTES
    Author: Liamarjit Bhogal
    Website: https://sevacloud.co.uk
    Make A Donation: https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
    Updated: 2025
    Supports AWSPowerShell.NetCore / AWS.Tools modules.
#>
    param (
        [Parameter(Mandatory = $true)]
        [string]$TagKey,

        [Parameter(Mandatory = $true)]
        [string]$TagValue,

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
        Write-LocalLog "No instance list provided. Fetching all SSM instance information from $Region..."
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

    Write-LocalLog "Total instances to process: $($AllInstances.Count)"
    Write-LocalLog "ManagedInstances: $($ManagedInstances.Count)"
    Write-LocalLog "EC2Instances: $($EC2Instances.Count)"

    while ($AllInstances.Count -gt 0) {
        $Instance = $AllInstances[0]
        $InstanceId = $Instance.InstanceId
        $ResourceType = $Instance.ResourceType

        Write-LocalLog "Processing instance: $InstanceId"
        Write-LocalLog "Remaining: $($AllInstances.Count)"

        $Tag = @(@{ Key = $TagKey; Value = $TagValue })

        $TagSplat = @{
            Tag         = $Tag
            ErrorAction = 'Stop'
        }

        try {
            if ($ResourceType -eq "ManagedInstance") {
                Write-LocalLog "Tagging ManagedInstance: $InstanceId"
                Add-SSMResourceTag -ResourceType "ManagedInstance" -ResourceId $InstanceId @AuthSplat @TagSplat
                $ManagedInstances.Remove($Instance)
            }
            elseif ($ResourceType -eq "EC2Instance") {
                Write-LocalLog "Tagging EC2Instance: $InstanceId"
                New-EC2Tag -Resource $InstanceId @AuthSplat @TagSplat
                $EC2Instances.Remove($Instance)
            }
            else {
                Write-LocalLog "Unknown ResourceType '$ResourceType' for $InstanceId" -LogLevel WARN
            }

            Write-LocalLog "Successfully tagged $InstanceId"
            $AllInstances.RemoveAt(0)
        }
        catch {
            Write-LocalLog "Failed to tag $InstanceId: $_" -LogLevel ERROR
            $AllInstances.RemoveAt(0)
            $AllInstances.Add($Instance)
            Start-Sleep -Seconds 2
        }
    }

    if ($AllInstances.Count -eq 0) {
        Write-LocalLog "All instances successfully processed!" -LogLevel INFO
    } else {
        Write-LocalLog -LogLevel WARN "Remaining unprocessed instances: $($AllInstances.Count)"
        Write-LocalLog -LogLevel WARN "Remaining ManagedInstances: $($ManagedInstances.Count)"
        Write-LocalLog -LogLevel WARN "Remaining EC2Instances: $($EC2Instances.Count)"
    }
}
