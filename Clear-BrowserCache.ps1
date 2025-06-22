function Clear-BrowserCache {
    <#
        .SYNOPSIS
        Clears browser cache and cookie files for multiple users on a Windows system, supporting modern browsers.
        
        .DESCRIPTION
        This function scans each local user profile under C:\Users and attempts to clean browser cache and cookie data 
        for the following supported browsers: Google Chrome, Mozilla Firefox, Microsoft Edge, and Internet Explorer.
        
        It dynamically discovers user profiles, handles modern Firefox profile folders, and skips any paths that do not exist.
        Supports running on Windows 10/11 and is designed to be safe, silent, and reusable.
        
        .PARAMETER Browsers
        An array of browser names to target. Supported values are: "Chrome", "Firefox", "Edge", and "IE".
        Defaults to all supported browsers.
        
        .EXAMPLE
        Clear-BrowserCache
        
        Clears caches and cookies for Chrome, Firefox, Edge, and Internet Explorer for all local user profiles.
        
        .EXAMPLE
        Clear-BrowserCache -Browsers @("Chrome", "Firefox")
        
        Clears cache and cookies only for Chrome and Firefox.
        
        .NOTES
        - Requires administrative privileges to access other users' profiles.
        - Designed for Windows 10/11 environments.
        - Does not remove bookmarks or saved passwords.
        - Safe to use as part of login scripts, cleanup routines, or troubleshooting toolkits.
        
        .AUTHOR
        Originally coded by Liamarjit @ Seva Cloud (2014), modernized in 2025
        Make A Donation: https://www.paypal.com/donate/?hosted_button_id=6EB8U2A94PX5Q
        
    #>
    [CmdletBinding()]
    param (
        [string[]]$Browsers = @("Chrome", "Firefox", "Edge", "IE")
    )

    $UserDirs = Get-ChildItem 'C:\Users' -Directory | Where-Object {
        $_.Name -notin @("All Users", "Default", "Default User", "Public", "Administrator")
    }

    foreach ($User in $UserDirs) {
        $UserPath = $User.FullName
        Write-Host "Processing $UserPath" -ForegroundColor Cyan

        if ("Firefox" -in $Browsers) {
            Get-ChildItem "$UserPath\AppData\Local\Mozilla\Firefox\Profiles\" -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Remove-Item "$($_.FullName)\cache2\entries\*" -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item "$($_.FullName)\cookies.sqlite" -Force -ErrorAction SilentlyContinue
                }
        }

        if ("Chrome" -in $Browsers) {
            $ChromePath = "$UserPath\AppData\Local\Google\Chrome\User Data\Default"
            Remove-Item "$ChromePath\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$ChromePath\Cookies" -Force -ErrorAction SilentlyContinue
        }

        if ("Edge" -in $Browsers) {
            $EdgePath = "$UserPath\AppData\Local\Microsoft\Edge\User Data\Default"
            Remove-Item "$EdgePath\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$EdgePath\Cookies" -Force -ErrorAction SilentlyContinue
        }

        if ("IE" -in $Browsers) {
            Remove-Item "$UserPath\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$UserPath\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Finished clearing cache for $($User.Name)" -ForegroundColor Green
    }

    Write-Host "`nAll selected browser caches cleared." -ForegroundColor Yellow
}
