function Get-ParsedObjectsFromDynamo {
<#
.SYNOPSIS
    Converts raw DynamoDB document model objects into simple PowerShell objects.

.DESCRIPTION
    This function processes an array of items retrieved from DynamoDB (e.g., from a Query or Scan)
    and unwraps the inner values of the complex types (e.g., DynamoDBBool, strings, numbers, etc.)
    into plain PowerShell types. This allows for easier comparisons, filtering, and formatting.

    Extend the function to handle other types as needed

.PARAMETER Array
    The array of raw objects returned from a DynamoDB query, typically where each item is a document
    with typed values (e.g., Amazon.DynamoDBv2.DocumentModel.DynamoDBBool).

.EXAMPLE
    $items = Get-DDBItemsFromTable
    $parsed = Get-ParsedObjectsFromDynamo -Array $items

.RETURNS
    An array of [PSCustomObject]s with native PowerShell types.

.NOTES
    Author: Liamarjit Bhogal
    Website: https://sevacloud.co.uk
    Make A Donation: https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
    Updated: 2025
#>
    param (
        [Parameter(Mandatory = $true,
                   HelpMessage = "Array of DynamoDB objects to be parsed")]
        [ValidateNotNull()]
        [System.Collections.IEnumerable]$Array
    )

    $ParsedObjects = $Array | ForEach-Object {
        $ParsedObject = @{}

        foreach ($Property in $_.PSObject.Properties) {
            $Value = $Property.Value
            if ($Property.TypeNameOfValue -eq 'Amazon.DynamoDBv2.DocumentModel.DynamoDBBool') {
                $ParsedObject[$Property.Name] = [bool]$Value.Value
            } elseif ($Value -and $Value.PSObject.Properties['Value']) {
                $ParsedObject[$Property.Name] = $Value.Value
            } else {
                $ParsedObject[$Property.Name] = $Value
            }
        }

        [PSCustomObject]$ParsedObject
    }

    return $ParsedObjects
}
