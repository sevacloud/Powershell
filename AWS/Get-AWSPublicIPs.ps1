function Get-AWSPublicIPs {
<#
.SYNOPSIS
    Audits AWS accounts and regions for publicly exposed IPs across AWS services.

.DESCRIPTION
    This function collects public IP exposure from EC2 instances, Elastic IPs, Load Balancers, IGW routes,
    security group ingress rules, and NACL allow rules across multiple AWS accounts and regions. It returns
    categorized results and exports them to CSV for visibility and remediation planning.

.PARAMETER Accounts
    A hashtable mapping AWS account names to account IDs.

.PARAMETER SourceCredential
    The AWS credential object used to assume roles into target accounts.

.PARAMETER AuditRoleName
    The IAM Role name to assume within each account to perform the audit.

.PARAMETER Regions
    (Optional) An array of AWS regions to audit. Defaults to all standard commercial regions.

.PARAMETER OutputFolder
    (Optional) The directory where CSV results will be saved. Defaults to C:\Reports\AWS_PublicAudit.

.EXAMPLE
    Get-AWSPublicIPs -Accounts @{ Prod = '111122223333'; Dev = '444455556666' } \
                     -SourceCredential $Creds.Credential \
                     -AuditRoleName 'AuditResourcesROFromCorp'

.NOTES
    Author: Liamarjit Bhogal
    Website: https://sevacloud.co.uk
    Date: 2025
    Tags: AWS, Security, Public IPs, EC2, ELB, VPC, Audit
#>
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Accounts,

        [Parameter(Mandatory = $true)]
        [Amazon.Runtime.AWSCredentials]$SourceCredential,

        [Parameter(Mandatory = $true)]
        [string]$AuditRoleName,

        [string[]]$Regions = @(Get-AWSRegion | Where-Object { $_.Region -notlike '*iso*' } | Select-Object -ExpandProperty Region),

        [string]$OutputFolder = "C:\\Reports\\AWS_PublicAudit"
    )

    $Results = @{
        IGWRoutes      = [System.Collections.Generic.List[object]]::new()
        EC2PublicIPs   = [System.Collections.Generic.List[object]]::new()
        ElasticIPs     = [System.Collections.Generic.List[object]]::new()
        SecurityGroups = [System.Collections.Generic.List[object]]::new()
        NACLRules      = [System.Collections.Generic.List[object]]::new()
        LoadBalancers  = [System.Collections.Generic.List[object]]::new()
    }

    if (-not (Test-Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }

    foreach ($Account in $Accounts.Keys) {
        $AccountId = $Accounts[$Account]
        Write-LocalLog "Assuming role into account: $Account ($AccountId)"

        $TempCreds = (Use-STSRole -RoleArn "arn:aws:iam::$AccountId:role/$AuditRoleName" -Credential $SourceCredential -RoleSessionName 'PublicAudit').Credentials

        foreach ($Region in $Regions) {
            $RegionSplat = @{
                Region        = $Region
                AccessKey     = $TempCreds.AccessKeyId
                SecretKey     = $TempCreds.SecretAccessKey
                SessionToken  = $TempCreds.SessionToken
                ErrorAction   = 'SilentlyContinue'
            }

            Write-LocalLog "Auditing $Account ($AccountId) in region $Region"

            # Public IP Discovery code goes here for:
            # - EC2 Instances
            try {
                $instances = Get-EC2Instance @RegionSplat
                foreach ($instance in $instances.Instances) {
                    if ($instance.PublicIpAddress) {
                        $Results.EC2PublicIPs.Add([pscustomobject]@{
                            Account     = $Account
                            AccountId   = $AccountId
                            Region      = $Region
                            InstanceId  = $instance.InstanceId
                            PublicIP    = $instance.PublicIpAddress
                            SubnetId    = $instance.SubnetId
                            VpcId       = $instance.VpcId
                        })
                    }
                }
            } catch {
                Write-LocalLog -LogLevel:WARN "Failed to fetch EC2 Instances in $Region for $Account: $_"
            }

            # - Elastic IPs
            try {
                $eips = Get-EC2Address @RegionSplat
                foreach ($eip in $eips) {
                    $Results.ElasticIPs.Add([pscustomobject]@{
                        Account     = $Account
                        AccountId   = $AccountId
                        Region      = $Region
                        PublicIP    = $eip.PublicIp
                        InstanceId  = $eip.InstanceId
                        AllocationId = $eip.AllocationId
                        AssociationId = $eip.AssociationId
                    })
                }
            } catch {
                Write-LocalLog -LogLevel:WARN "Failed to fetch Elastic IPs in $Region for $Account: $_"
            }

            # - IGW Routes
            try {
                $routeTables = Get-EC2RouteTable @RegionSplat
                foreach ($rt in $routeTables) {
                    foreach ($route in $rt.Routes) {
                        if ($route.GatewayId -like 'igw-*' -and $route.DestinationCidrBlock -eq '0.0.0.0/0') {
                            $Results.IGWRoutes.Add([pscustomobject]@{
                                Account     = $Account
                                AccountId   = $AccountId
                                Region      = $Region
                                RouteTable  = $rt.RouteTableId
                                VpcId       = $rt.VpcId
                                GatewayId   = $route.GatewayId
                                CIDR        = $route.DestinationCidrBlock
                                State       = $route.State
                            })
                        }
                    }
                }
            } catch {
                Write-LocalLog -LogLevel:WARN "Failed to fetch IGW routes in $Region for $Account: $_"
            }

            # - Security Group Rules
            try {
                $sgs = Get-EC2SecurityGroup @RegionSplat
                foreach ($sg in $sgs) {
                    foreach ($perm in $sg.IpPermissions) {
                        foreach ($range in $perm.Ipv4Ranges) {
                            if ($range.CidrIp -eq '0.0.0.0/0') {
                                $Results.SecurityGroups.Add([pscustomobject]@{
                                    Account   = $Account
                                    AccountId = $AccountId
                                    Region    = $Region
                                    GroupId   = $sg.GroupId
                                    FromPort  = $perm.FromPort
                                    ToPort    = $perm.ToPort
                                    Protocol  = $perm.IpProtocol
                                    CidrIp    = $range.CidrIp
                                })
                            }
                        }
                    }
                }
            } catch {
                Write-LocalLog -LogLevel:WARN "Failed to fetch Security Groups in $Region for $Account: $_"
            }

            # - NACLs
            try {
                $nacls = Get-EC2NetworkAcl @RegionSplat
                foreach ($nacl in $nacls) {
                    foreach ($entry in $nacl.Entries) {
                        if (-not $entry.Egress -and $entry.RuleAction -eq 'allow' -and $entry.CidrBlock -eq '0.0.0.0/0') {
                            $Results.NACLRules.Add([pscustomobject]@{
                                Account   = $Account
                                AccountId = $AccountId
                                Region    = $Region
                                NaclId    = $nacl.NetworkAclId
                                RuleNum   = $entry.RuleNumber
                                CidrBlock = $entry.CidrBlock
                                Action    = $entry.RuleAction
                            })
                        }
                    }
                }
            } catch {
                Write-LocalLog -LogLevel:WARN "Failed to fetch NACLs in $Region for $Account: $_"
            }

            # - Load Balancers
            try {
                $lbs = Get-ELB2LoadBalancer @RegionSplat
                foreach ($lb in $lbs) {
                    $Results.LoadBalancers.Add([pscustomobject]@{
                        Account     = $Account
                        AccountId   = $AccountId
                        Region      = $Region
                        LoadBalancerName = $lb.LoadBalancerName
                        DNSName     = $lb.DNSName
                        VpcId       = $lb.VpcId
                    })
                }
            } catch {
                Write-LocalLog -LogLevel:WARN "Failed to fetch Load Balancers in $Region for $Account: $_"
            }
        }
    }

    foreach ($key in $Results.Keys) {
        $filePath = Join-Path $OutputFolder "$key.csv"
        Write-LocalLog "Exporting $key results to $filePath"
        $Results[$key] | Export-Csv -Path $filePath -NoTypeInformation -Force
    }

    Write-LocalLog "Public IP audit complete. Results saved in $OutputFolder"

    return $Results
}
