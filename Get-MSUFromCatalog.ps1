function Get-MSUFromCatalog
{
<#
.SYNOPSIS
    Downloads a Windows Update (.msu) file directly from the Microsoft Update Catalog.

.DESCRIPTION
    Workaround for the known Get-WUOfflineMSU bug in PSWindowsUpdate
    (https://github.com/mgajda83/PSWindowsUpdate/issues/22) where the cmdlet
    throws "Specified argument was out of the range of valid values. Parameter name: i"
    when the catalog returns multiple results for a KB article.

    This function searches the Microsoft Update Catalog, filters results by
    architecture, retrieves the download URL, and saves the MSU file to disk.

    Replace this function with Get-WUOfflineMSU once the upstream issue is resolved.

.PARAMETER KBArticleID
    The KB article ID to download. Accepts with or without the "KB" prefix.
    Example: "KB5031539" or "5031539"

.PARAMETER Destination
    The folder path where the MSU file will be saved.
    Example: "C:\Temp"

.PARAMETER Architecture
    The target CPU architecture to filter results. Defaults to 'x64'.
    Common values: 'x64', 'x86', 'ARM64'

.EXAMPLE
    Get-MSUFromCatalog -KBArticleID "KB5031539" -Destination "C:\Temp"

    Downloads the x64 build of KB5031539 to C:\Temp.

.EXAMPLE
    Get-MSUFromCatalog -KBArticleID "KB5031539" -Destination "C:\Temp" -Architecture "ARM64"

    Downloads the ARM64 build of KB5031539 to C:\Temp.

.NOTES
    Author    : Liamarjit Bhogal (© Seva Cloud 2026)
    Website   : https://sevacloud.co.uk
    Version   : 1.0.0
    Requires  : PowerShell 5.1+, internet access to catalog.update.microsoft.com
    Disclaimer: Provided as-is with no warranty. Test before use in production.
    Donate    : https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q

#>

    Param(
        [Parameter(Mandatory = $true)]
        [string]$KBArticleID,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string]$Architecture = 'x64'
    )

    # Strip "KB" prefix if present
    $KBNumber = $KBArticleID -replace '^KB', ''

    # Search the Microsoft Update Catalog
    $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=KB$KBNumber"
    $Response = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing -ErrorAction Stop -TimeoutSec 120

    # The catalog renders update IDs in input elements and table rows.
    # Update IDs appear in the onclick handlers as: updateIDs with GUID patterns
    # They also appear in id attributes like: <input id="{GUID}" ... />
    $UpdateIds = [regex]::Matches($Response.Content, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique

    if (-not $UpdateIds -or @($UpdateIds).Count -eq 0)
    {
        throw "No updates found in Microsoft Update Catalog for KB$KBNumber"
    }

    # Extract titles from the page to match against architecture
    # Titles appear between specific span tags in the results table
    $TitleMatches = [regex]::Matches($Response.Content, '<a[^>]*id="[^"]*_link"[^>]*>\s*([^<]+)\s*</a>')
    $Titles = @()
    foreach ($Match in $TitleMatches)
    {
        $Titles += $Match.Groups[1].Value.Trim()
    }

    # Also try extracting from span elements within table cells
    if (@($Titles).Count -eq 0)
    {
        $TitleMatches = [regex]::Matches($Response.Content, '<span[^>]*>([^<]*KB' + $KBNumber + '[^<]*)</span>')
        foreach ($Match in $TitleMatches)
        {
            $Titles += $Match.Groups[1].Value.Trim()
        }
    }

    # Try to find the update ID that corresponds to an x64 server update
    # The catalog page has rows where each row has an update ID and a title
    # Extract rows: each row has a unique GUID in an input element
    $RowPattern = '<tr[^>]*id="([0-9a-f\-]{36})[^"]*"[^>]*>.*?</tr>'
    $Rows = [regex]::Matches($Response.Content, $RowPattern, 'Singleline')

    $SelectedId = $null
    $SelectedTitle = ''

    if (@($Rows).Count -gt 0)
    {
        foreach ($Row in $Rows)
        {
            $RowContent = $Row.Value
            $RowId = $Row.Groups[1].Value

            # Check if this row contains x64 and not ARM64
            if ($RowContent -match $Architecture -and $RowContent -notmatch 'ARM64')
            {
                $SelectedId = $RowId
                $TitleInRow = [regex]::Match($RowContent, '<a[^>]*>([^<]+)</a>')
                if ($TitleInRow.Success) { $SelectedTitle = $TitleInRow.Groups[1].Value.Trim() }
                Write-Output "      Selected: $SelectedTitle"
                break
            }
        }
    }

    # Fallback: try matching titles array against update IDs
    if (-not $SelectedId -and @($Titles).Count -gt 0)
    {
        for ($i = 0; $i -lt @($Titles).Count; $i++)
        {
            if ($Titles[$i] -match $Architecture -and $Titles[$i] -notmatch 'ARM64')
            {
                if ($i -lt @($UpdateIds).Count)
                {
                    $SelectedId = $UpdateIds[$i]
                    $SelectedTitle = $Titles[$i]
                    Write-Output "      Selected (fallback): $SelectedTitle"
                    break
                }
            }
        }
    }

    # Last resort: use the first update ID
    if (-not $SelectedId)
    {
        $SelectedId = $UpdateIds[0]
        Write-Output "      No $Architecture-specific match found, using first result (ID: $SelectedId)"
    }

    # Get the download URL from the catalog download dialog
    $PostBody = @{ updateIDs = "[{""uidInfo"":""$SelectedId"",""updateID"":""$SelectedId""}]" }
    $DownloadPage = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
        -Method POST -Body $PostBody -UseBasicParsing -ErrorAction Stop -TimeoutSec 120

    $DlContent = $DownloadPage.Content

    # Extract download URLs (MSU or CAB)
    $DownloadUrls = @([regex]::Matches($DlContent, 'https?://[^\s''"]+\.msu') |
        ForEach-Object { $_.Value })

    if (@($DownloadUrls).Count -eq 0)
    {
        $DownloadUrls = @([regex]::Matches($DlContent, 'https?://[^\s''"]+\.cab') |
            ForEach-Object { $_.Value })
    }

    if (@($DownloadUrls).Count -eq 0)
    {
        throw "No download URL found for KB$KBNumber (UpdateID: $SelectedId)"
    }

    $DownloadUrl = [string]$DownloadUrls[0]

    if ($DownloadUrl.Length -lt 10 -or $DownloadUrl -notmatch '^https?://')
    {
        throw "Invalid download URL for KB$KBNumber`: '$DownloadUrl'"
    }

    $FileName = $DownloadUrl.Substring($DownloadUrl.LastIndexOf('/') + 1)
    if ($FileName.Contains('?')) { $FileName = $FileName.Substring(0, $FileName.IndexOf('?')) }
    $OutPath = Join-Path -Path $Destination -ChildPath $FileName

    Write-Output "      Downloading from: $($DownloadUrl.Substring(0, [Math]::Min(80, $DownloadUrl.Length)))..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutPath -UseBasicParsing -ErrorAction Stop -TimeoutSec 900

    if (-not (Test-Path $OutPath) -or (Get-Item $OutPath).Length -eq 0)
    {
        throw "Download failed or file is empty: $OutPath"
    }

    Write-Output "      Saved: $FileName ($([math]::Round((Get-Item $OutPath).Length / 1MB, 1)) MB)"
}
