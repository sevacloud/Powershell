function Get-SSMInstancesMissingTag {
<#
.SYNOPSIS
    Audits all SSM instances for a missing tag key.

.DESCRIPTION
    AWS does not provide a way to filter instances without a specific tag. 
    This function inspects both EC2 and ManagedInstance resources and returns a structured list of instances missing the specified tag.

.PARAMETER TagKey
    The tag key to check for. Instances without this key will be returned.

.PARAMETER Region
    AWS region to query.

.PARAMETER Credential
    The AWSCredentials object to authenticate API calls. Usually returned from Get-AwsCred.

.OUTPUTS
    PSCustomObject with two collections:
    - EC2Instances: Instances of type EC2 missing the tag
    - ManagedInstances: Managed instances missing the tag
    - Totals per type

.EXAMPLE
    $Creds = Get-AwsCred -RoleArn "arn:aws:iam::123456789012:role/Example"
    $Missing = Get-SSMInstancesMissingTag -TagKey "MyTag" -Region "eu-west-1" -Credential $Creds.Credential

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
        [Amazon.Runtime.AWSCredentials]$Credential
    )

    $AuthSplat = @{
        Region      = $Region
        Credential  = $Credential
        ErrorAction = 'Stop'
    }

    Write-LocalLog "Retrieving SSM instance information..." -LogLevel INFO
    $InstanceInformationList = Get-SSMInstanceInformation @AuthSplat

    $EC2InstancesMissingTag = [System.Collections.ArrayList]@()
    $ManagedInstancesMissingTag = [System.Collections.ArrayList]@()

    $Counter = 0
    foreach ($Instance in $InstanceInformationList) {
        $Counter++
        Write-LocalLog "Checking for tag '$TagKey' on $($Instance.InstanceId) [$Counter / $($InstanceInformationList.Count)]" -LogLevel DEBUG

        try {
            if ($Instance.ResourceType -eq "EC2Instance") {
                $Tags = Get-EC2Tag @AuthSplat -Filter @{Name = "resource-id"; Values = $Instance.InstanceId}
                if ($Tags.Key -notcontains $TagKey) {
                    Write-LocalLog "Tag '$TagKey' missing on EC2 $($Instance.InstanceId)" -LogLevel WARN
                    $EC2InstancesMissingTag.Add([PSCustomObject]@{
                        InstanceId       = $Instance.InstanceId
                        ComputerName     = $Instance.ComputerName
                        PingStatus       = $Instance.PingStatus
                        LastPingDateTime = $Instance.LastPingDateTime
                        TagMissing       = $TagKey
                    }) | Out-Null
                }
            }
            elseif ($Instance.ResourceType -eq "ManagedInstance") {
                $Tags = Get-SSMResourceTag @AuthSplat -ResourceType "ManagedInstance" -ResourceId $Instance.InstanceId
                if ($Tags.Key -notcontains $TagKey) {
                    Write-LocalLog "Tag '$TagKey' missing on ManagedInstance $($Instance.InstanceId)" -LogLevel WARN
                    $ManagedInstancesMissingTag.Add([PSCustomObject]@{
                        InstanceId       = $Instance.InstanceId
                        ComputerName     = $Instance.ComputerName
                        PingStatus       = $Instance.PingStatus
                        LastPingDateTime = $Instance.LastPingDateTime
                        TagMissing       = $TagKey
                    }) | Out-Null
                }
            }
        } catch {
            Write-LocalLog "Error checking tags for $($Instance.InstanceId): $_" -LogLevel ERROR
        }
    }

    $Result = [PSCustomObject]@{
        EC2Instances        = $EC2InstancesMissingTag
        ManagedInstances    = $ManagedInstancesMissingTag
        TotalEC2Missing     = $EC2InstancesMissingTag.Count
        TotalManagedMissing = $ManagedInstancesMissingTag.Count
    }

    Write-LocalLog "Found $($Result.TotalEC2Missing) EC2 instance(s) and $($Result.TotalManagedMissing) ManagedInstance(s) missing tag '$TagKey'" -LogLevel INFO
    return $Result
}
