<#
.SYNOPSIS
Retrieves AWS credentials from either EC2 instance metadata (with IMDSv2 support) or a local credentials file, with optional STS role assumption.

.DESCRIPTION
This function determines whether it's running on an EC2 instance or on-premises. It retrieves AWS credentials accordingly:

- On EC2: Fetches temporary IAM credentials from the instance metadata service (IMDSv2 supported).
- On-prem: Loads static credentials from a default shared credentials file.
- If a RoleArn is specified, it uses STS to assume that IAM role using the base credentials.

The function returns a hashtable containing:
- Credential object (AWSCredentials)
- Expiration time
- AccessKey
- SecretKey
- SessionToken

It also logs each major action using the custom `Write-LocalLog` function.

.PARAMETER RoleArn
(Optional) An IAM Role ARN to assume via STS using `Use-STSRole`.

.EXAMPLE
$Creds = Get-AwsCred

Automatically detects the environment and returns AWS credentials.

.EXAMPLE
$Creds = Get-AwsCred -RoleArn "arn:aws:iam::123456789012:role/MyAppRole"

Retrieves base credentials and assumes the specified role via STS.

.NOTES
- Uses IMDSv2 for secure metadata access on EC2 instances.
- The internal `Get-EC2InstanceMetadata` function handles token-based requests.
- Requires AWS Tools for PowerShell.
- Local credential file path is hardcoded to: `C:\Windows\System32\config\systemprofile\.aws\credentials`

.AUTHOR
Liamarjit @ Seva Cloud

#>
function Get-AwsCred {
    Param(
        [Parameter(Mandatory = $false)]
        [string]$RoleArn
    )

    function Get-EC2InstanceMetadata {
        Param(
            [Parameter(Mandatory = $false)]
            [string]$Uri
        )
    
        # Solves for IMDSv2
        [string]$Token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri 'http://169.254.169.254/latest/api/token'
        $EC2InstanceMetaData = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $Token} -Method GET -Uri $Uri
    
        return $EC2InstanceMetaData
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Uuid = (Get-CimInstance -class Win32_ComputerSystemProduct).UUID
    if ($Uuid -like 'EC2*') {
        try {
            Write-LocalLog "$($env:COMPUTERNAME) appears to be an EC2 instance. Pulling credentials from IAM role"

            $InstanceInfo = Get-EC2InstanceMetadata -Uri 'http://169.254.169.254/latest/meta-data/iam/info'
            $InstanceProfileArn = $InstanceInfo.InstanceProfileArn

            Write-LocalLog "Instance Profile Arn: $InstanceProfileArn"

            $EC2SecCredsUri = 'http://169.254.169.254/latest/meta-data/iam/security-credentials'
            $Iam = Get-EC2InstanceMetadata -Uri $EC2SecCredsUri
            $AwsCredentials = Get-EC2InstanceMetadata -Uri "$EC2SecCredsUri/$Iam"

            # Converts the credentials into Amazon.Runtime.AWSCredentials.
            $EC2ProfileName = 'TempEC2Creds'
            Set-AWSCredential -AccessKey $AwsCredentials.AccessKeyId -SecretKey $AwsCredentials.SecretAccessKey -SessionToken $AwsCredentials.Token -StoreAs $EC2ProfileName
            $AwsCred = Get-AWSCredential -ProfileName $EC2ProfileName
        } catch {
            Write-LocalLog -LogLevel:ERROR "Failed to pull credentials from Instance Metadata. $_"
        }
    } else {
        Write-LocalLog "$($env:COMPUTERNAME) appears to be an OnPrem instance, pulling creds from local credential file"

        try {
            $AwsCred = Get-AWSCredential -ProfileName default -ProfileLocation 'C:\Windows\System32\config\systemprofile\.aws\credentials'
        } catch {
            Write-LocalLog -LogLevel:ERROR "Error getting creds from local credential file. $_"
        }
    }

    if ($RoleArn) {
        Write-LocalLog "Generating STS credentials from role: $RoleArn"

        try {
            $StsCredentials = (Use-STSRole -RoleArn $RoleArn -Credential $AwsCred -Region $script:Region -RoleSessionName 'FCVisionHostclassAudit' -ErrorAction:Stop)

            # Converts the credentials into Amazon.Runtime.AWSCredentials.
            $StsProfileName = 'TempStsCreds'
            Set-AWSCredential -AccessKey $StsCredentials.Credentials.AccessKeyId -SecretKey $StsCredentials.Credentials.SecretAccessKey -SessionToken $StsCredentials.Credentials.SessionToken -StoreAs $StsProfileName
            $AwsCred = Get-AWSCredential -ProfileName $StsProfileName
        } catch {
            Write-LocalLog -LogLevel:ERROR "Failed to pull STS credentials from '$RoleArn'. $_"
        }
    }

    $Auth = @{
        Expiration   = (Get-Date).AddMinutes(35)
        Credential   = $AwsCred #Amazon.Runtime.SessionAWSCredentials | Amazon.Runtime.BasicAWSCredentials
        AccessKey    = $AwsCred.GetCredentials().AccessKey
        SecretKey    = $AwsCred.GetCredentials().SecretKey
        SessionToken = $AwsCred.GetCredentials().Token
    }

    return $Auth
}
