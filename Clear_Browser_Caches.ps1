Write-Host -ForegroundColor Yellow "#######################################################"
""
Write-Host -ForegroundColor Green "Powershell commands to delete cache & cookies in Firefox, Chrome & IE browsers"
Write-Host -ForegroundColor Green "By Lee Bhogal, Paradise Computing Ltd - June 2014"
Write-Host -ForegroundColor Green "VERSION: 3"
Write-Host -ForegroundColor Green "Starinin Andrey (AnSt). 2017"
Write-Host -ForegroundColor Green "Очистка кэша и Корзины, удаление временных файлов"
Write-Host -ForegroundColor Green "GitHub - https://github.com/anst-foto/Broom"
""
Write-Host -ForegroundColor Yellow "#######################################################"
""
Write-Host -ForegroundColor Green "CHANGE_LOG:
v3:   - Добавление функций, логирования действий в файл
v2.4: - Resolved *.default issue, issue was with the file path name not with *.default, but issue resolved
v2.3: - Added Cache2 to Mozilla directories but found that *.default is not working
v2.2: - Added Cyan colour to verbose output
v2.1: - Added the location 'C:\Windows\Temp\*' and 'C:\`$recycle.bin\'
v2:   - Changed the retrieval of user list to dir the c:\users folder and export to csv
v1:   - Compiled script"
""
Write-Host -ForegroundColor Yellow "#######################################################"
""
#*******************************************************

$PathLog = "C:\users\$env:USERNAME\broom.log"
$DateLog = Get-Date -Format "dd MMMM yyyy HH:mm:ss"
$Head1Log = "------------------------------"
$Head2Log = "---------------"
$Head3Log = "-------"
$Title1 = "Delete cache browsers"
$Title2 = "Delete RecycleBin & Temp"
$Title3 = "Delete cache browsers, RecycleBin & Temp"
$TitleMozilla = "Mozilla"
$TitleChrome = "Chrome"
$TitleChromium = "Chromium"
$TitleYandex = "Yandex"
$TitleOpera = "Opera"
$TitleIE = "Internet Explorer"
$TitleRecileBinTemp = "RecileBin & Temp"

New-Item -Path $PathLog -ItemType File -ErrorAction SilentlyContinue -Verbose
Out-File -FilePath $PathLog -InputObject $Head1Log -Append -Encoding Unicode
Out-File -FilePath $PathLog -InputObject $DateLog -Append -Encoding Unicode
Out-File -FilePath $PathLog -InputObject $Head1Log -Append -Encoding Unicode

#*******************************************************

# Mozilla Firefox
Function Clear_Mozilla ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleMozilla -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	
    Import-CSV -Path $a -Header Name | ForEach-Object {
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Mozilla\Firefox\Profiles\*.default\cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
	        Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Mozilla\Firefox\Profiles\*.default\cache2\entries\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Mozilla\Firefox\Profiles\*.default\thumbnails\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Mozilla\Firefox\Profiles\*.default\cookies.sqlite" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Mozilla\Firefox\Profiles\*.default\webappsstore.sqlite" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Mozilla\Firefox\Profiles\*.default\chromeappsstore.sqlite" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            }
}

# Google Chrome
Function Clear_Chrome ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleChrome -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	
    Import-CSV -Path $a -Header Name | ForEach-Object {
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Google\Chrome\User Data\Default\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Google\Chrome\User Data\Default\Cache2\entries\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Google\Chrome\User Data\Default\Cookies\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Google\Chrome\User Data\Default\Media Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Google\Chrome\User Data\Default\Cookies-Journal\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Google\Chrome\User Data\Default\ChromeDWriteFontCache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            }
}

# Chromium
Function Clear_Chromium ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleChromium -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode

    Import-CSV -Path $a -Header Name | ForEach-Object {
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Chromium\User Data\Default\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Chromium\User Data\Default\GPUCache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Chromium\User Data\Default\Media Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Chromium\User Data\Default\Pepper Data\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Chromium\User Data\Default\Application Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            }
}

# Yandex
Function Clear_Yandex ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleYandex -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode

	Import-CSV -Path $a -Header Name | ForEach-Object {
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Yandex\YandexBrowser\User Data\Default\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Yandex\YandexBrowser\User Data\Default\GPUCache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Yandex\YandexBrowser\User Data\Default\Media Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Yandex\YandexBrowser\User Data\Default\Pepper Data\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Yandex\YandexBrowser\User Data\Default\Application Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
			Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Yandex\YandexBrowser\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            }
}

# Opera
Function Clear_Opera ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleOpera -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	
	Import-CSV -Path $a -Header Name | ForEach-Object {
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Opera Software\Opera Stable\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            }
}

# Internet Explorer
Function Clear_IE ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleIE -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	
    Import-CSV -Path $a | ForEach-Object {
            Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
	        Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Microsoft\Windows\WER\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
			Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Microsoft\Windows\INetCache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
			Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Microsoft\Windows\WebCache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
            }
}

# Clear RecileBin & Temp
Function Clear_RecileBin_Temp ($a) {
	#Добавление информации в log-файл
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $TitleRecileBinTemp -Append -Encoding Unicode
	Out-File -FilePath $PathLog -InputObject $Head3Log -Append -Encoding Unicode
	
	#Очистка Корзины на всех дисках
	$Drives = Get-PSDrive -PSProvider FileSystem
	ForEach ($Drive in $Drives)
	{
		$Path_RecicleBin = "$Drive" + ':\$Recycle.Bin'
		Remove-Item -Path $Path_RecicleBin -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
	}
	
	#Удаление temp-файлов
	Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
	Import-Csv -Path $a | ForEach-Object {
		Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
		Remove-Item -Path "C:\Users\$($_.Name)\AppData\Local\Microsoft\Windows\AppCache\*" -Recurse -Force -ErrorAction SilentlyContinue -Verbose 4>&1 | Out-File $PathLog -Append -Encoding Unicode
	}
}


"-------------------"
Write-Host -ForegroundColor Green "SECTION 1: Getting the list of users"
"-------------------"
# Write Information to the screen
Write-Host -ForegroundColor Yellow "Exporting the list of users to c:\users\%username%\users.csv"
# List the users in c:\users and export to the local profile for calling later
$Path = "C:\users\$env:USERNAME\users.csv"
Dir C:\Users | Select Name | Export-Csv -Path $Path -NoTypeInformation
$list=Test-Path C:\users\$env:USERNAME\users.csv
""
#########################
"-------------------"
Write-Host -ForegroundColor Green "SECTION 2: Beginning Script..."
"-------------------"
if ($list) {
    "-------------------"
    #Clear Mozilla Firefox Cache
    Write-Host -ForegroundColor Green "SECTION 3: Clearing Mozilla Firefox Caches"
    "-------------------"
    Write-Host -ForegroundColor Yellow "Clearing Mozilla caches"
    Write-Host -ForegroundColor Cyan
    Clear_Mozilla ($Path)
    Write-Host -ForegroundColor Yellow "Clearing Mozilla caches"
    Write-Host -ForegroundColor Yellow "Done..."
    ""
    "-------------------"
    # Clear Google Chrome 
    Write-Host -ForegroundColor Green "SECTION 4: Clearing Google Chrome Caches"
    "-------------------"
    Write-Host -ForegroundColor Yellow "Clearing Google caches"
    Write-Host -ForegroundColor Cyan
    Clear_Chrome ($Path)
    Write-Host -ForegroundColor Yellow "Done..."
    ""
    "-------------------"
    # Clear Internet Explorer
    Write-Host -ForegroundColor Green "SECTION 5: Clearing Internet Explorer Caches"
     "-------------------"
    Write-Host -ForegroundColor Yellow "Clearing Internet Explorer caches"
    Write-Host -ForegroundColor Cyan
    Clear_IE ($Path)
    Write-Host -ForegroundColor Yellow "Done..."
    ""
    # Clear Opera & Chromium 
    Write-Host -ForegroundColor Green "SECTION 6: Clearing Opera & Chromium Caches"
    "-------------------"
    Write-Host -ForegroundColor Yellow "Clearing Opera & Chromium caches"
    Write-Host -ForegroundColor Cyan
    Clear_Opera ($Path)
	Clear_Yandex ($Path)
	Clear_Chromium ($Path)
    Write-Host -ForegroundColor Yellow "Done..."
    ""
    "-------------------"
	# Clear RecileBin & Temp
    Write-Host -ForegroundColor Green "SECTION 7: Clearing RecileBin & Temp"
    "-------------------"
    Write-Host -ForegroundColor Yellow "Clearing RecileBin & Temp"
    Write-Host -ForegroundColor Cyan
    Clear_RecileBin_Temp ($Path)
    Write-Host -ForegroundColor Yellow "Done..."
    ""
    "-------------------"
    Write-Host -ForegroundColor Green "All Tasks Done!"
    } else {
	Write-Host -ForegroundColor Yellow "Session Cancelled"	
	Exit
	}
