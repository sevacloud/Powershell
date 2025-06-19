<# This is a bug hunt challenge.  
The script batches host records and sends them to an SQS queue in groups of 10. It logs each attempt and catches errors gracefully. But there’s a hidden flaw that means some messages might never be sent.
Think you can find it?

NOTE: Some variables and functions have been removed to keep the bug hunt focused

Author: Liamarjit Bhogal, sevacloud.co.uk
#>

$RoleArn = ""
$QueueUrl = ""
$TtlHours = 2

function Get-AwsCred {
    Param(
        [Parameter(Mandatory = $false)]
        [string]$RoleArn
    )
    
    # Main logic removed
    
    return @{
        Expiration   = (Get-Date).AddMinutes(35)
        Credential   = "$AwsCred #Amazon.Runtime.SessionAWSCredentials | Amazon.Runtime.BasicAWSCredentials"
        AccessKey    = "$AwsCred.GetCredentials().AccessKey"
        SecretKey    = "$AwsCred.GetCredentials().SecretKey"
        SessionToken = "$AwsCred.GetCredentials().Token"
    }
}

$UploadCounter = 0
$BatchSize = 10
$CurrentBatch = @()

$AwsCred = Get-AwsCred -RoleArn $RoleArn

<# Assume $AllHostRecords is an array of 1000s of records with the following properties
    $AllHostRecords = @(
        @{
            hostname = "server01.domain.com"
            group    = "group01"
        },
        ...
    )
#>
foreach ($HostRecord in $AllHostRecords) {
    $UploadCounter++
    Write-Host "Processing $($HostRecord.hostname) ($UploadCounter / $($AllHostRecords.Count))"

    try {
        $ExpirationEpoch = [int][double]::Parse((Get-Date).AddHours($TtlHours).ToUniversalTime().Subtract((Get-Date "1/1/1970")).TotalSeconds)

        # Get hostname from FQDN (we obtain DNS suffix from server list pull)
        $Hostname = $HostRecord.hostname.Split('.')[0].ToUpper()

        $MessageBody = @{
            hostname   = $Hostname
            group      = $HostRecord.group
            expiration = $ExpirationEpoch
            # Add any other attributes here
        } | ConvertTo-Json -Compress

        $CurrentBatch += @{
            Id = [Guid]::NewGuid().ToString()
            MessageBody = $MessageBody
        }

        # If we've reached the batch size, send the batch
        if ($CurrentBatch.Count -eq $BatchSize) {
            # Update creds if expiration hit
            if ($AwsCred.Expiration -lt (Get-Date).AddMinutes(-2)) { $AwsCred = Get-AwsCred -RoleArn $RoleArn }

            $SendMessageBatchParams = @{
                QueueUrl = $QueueUrl
                Entries = $CurrentBatch
                Credential = $SqsAwsCred.Credential
            }

            try {
                $Result = Send-SQSMessageBatch @SendMessageBatchParams

                # Check for failed messages
                $FailedMessages = $Result.Failed
                if ($FailedMessages.Count -gt 0) {
                    foreach ($FailedMessage in $FailedMessages) {
                        Write-Host -ForegroundColor Red "Failed to send message: $($FailedMessage.Id). Error: $($FailedMessage.Message)"
                    }
                }

                Write-Host "Successfully sent batch of $($CurrentBatch.Count) messages to SQS"
            }
            catch {
                Write-Host -ForegroundColor Red "Error sending batch to SQS: $_"
            }

            # Clear the batch
            $CurrentBatch = @()

            # Add a small delay to prevent throttling
            Start-Sleep -Milliseconds 50
        }
    }
    catch {
        Write-Host -ForegroundColor Red "Error processing record for $($HostRecord.hostname): $_"
        # Continue with next record despite error
        continue
    }
}
