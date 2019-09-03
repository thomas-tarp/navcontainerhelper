﻿<# 
 .Synopsis
  Restore databases in a NAV/BC Container from .bak files
 .Description
  If the Container is multi-tenant, this command will restore an app.bak and a number of tenant databases
  If the Container is single-tenant, this command will restore one .bak file called database.bak.
 .Parameter containerName
  Name of the container in which you want to restore databases
 .Parameter bakFolder
  The folder to which the bak files are exported (default is the container folder c:\programdata\navcontainerhelper\extensions\<containername>)
 .Parameter tenant
  The tenant database(s) to restore, only applies to multi-tenant containers. Omit to restore all tenants
 .Example
  Restore-DatabasesInNavContainer -containerName test
 .Example
  Restore-DatabasesInNavContainer -containerName test -tenant @("default")
#>
function Restore-DatabasesInNavContainer {
    Param(
        [string] $containerName = "navserver", 
        [string] $bakFolder = "",
        [string[]] $tenant,
        [Parameter(Mandatory=$false)]
        [string] $databaseFolder = "c:\databases",
        [int] $sqlTimeout = 300
    )

    $extensionsFolder = "C:\programdata\navcontainerhelper\extensions"

    $containerFolder = Join-Path $ExtensionsFolder $containerName
    if ("$bakFolder" -eq "") {
        $bakFolder = $containerFolder
    }
    $containerBakFolder = Get-NavContainerPath -containerName $containerName -path $bakFolder -throw

    Invoke-ScriptInBCContainer -containerName $containerName -scriptblock { Param($bakFolder, $tenant, $databaseFolder, $sqlTimeout)

        function Restore {
            Param (
                [string] $databaseServer,
                [string] $databaseInstance,
                [string] $databaseName,
                [string] $bakFile,
                [string] $databaseFolder,
                [int] $sqlTimeout
            )
            if (!(Test-Path -Path $bakFile -PathType Leaf)) {
                throw "Database backup $bakFile not found"
            }
            if (Test-NavDatabase -DatabaseServer $databaseServer `
                                 -DatabaseInstance $databaseInstance `
                                 -DatabaseName $databaseName) {

                Remove-NavDatabase -DatabaseServer $databaseServer `
                                   -DatabaseInstance $databaseInstance `
                                   -DatabaseName $databaseName
            }
        
            Write-Host "Restoring $bakFile to $databaseName"
            New-NAVDatabase -DatabaseServer $databaseServer `
                            -DatabaseInstance $databaseInstance `
                            -DatabaseName $databaseName `
                            -FilePath $bakFile `
                            -DestinationPath $databaseFolder `
                            -Timeout $SqlTimeout | Out-Null
        }

        $customConfigFile = Join-Path (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service").FullName "CustomSettings.config"
        [xml]$customConfig = [System.IO.File]::ReadAllText($customConfigFile)
        $multitenant = ($customConfig.SelectSingleNode("//appSettings/add[@key='Multitenant']").Value -eq "true")
        $databaseServer = $customConfig.SelectSingleNode("//appSettings/add[@key='DatabaseServer']").Value
        $databaseInstance = $customConfig.SelectSingleNode("//appSettings/add[@key='DatabaseInstance']").Value
        $databaseName = $customConfig.SelectSingleNode("//appSettings/add[@key='DatabaseName']").Value

        if ($multitenant -and !($tenant)) {
            $tenant = @(get-navtenant bc | % { $_.Id }) + "tenant"
        }

        Set-NavServerInstance -ServerInstance $serverInstance -stop

        if ($multitenant) {
            Restore -databaseServer $databaseServer -databaseInstance $databaseInstance -databaseName $DatabaseName -bakFile (Join-Path $bakFolder "app.bak") -databaseFolder $databaseFolder -sqlTimeout $sqlTimeout
            $tenant | ForEach-Object {
                Restore -databaseServer $databaseServer -databaseInstance $databaseInstance -databaseName $_ -bakFile (Join-Path $bakFolder "$_.bak") -databaseFolder $databaseFolder -sqlTimeout $sqlTimeout
            }
        } else {
            Restore -databaseServer $databaseServer -databaseInstance $databaseInstance -databaseName $DatabaseName -bakFile (Join-Path $bakFolder "database.bak") -databaseFolder $databaseFolder -sqlTimeout $sqlTimeout
        }

        Set-NavServerInstance -ServerInstance $serverInstance -start
    
    } -argumentList $containerBakFolder, $tenant, $databaseFolder, $sqlTimeout

}
Set-Alias -Name Restore-DatabasesInBCContainer -Value Restore-DatabasesInNavContainer
Export-ModuleMember -Function Restore-DatabasesInNavContainer -Alias Restore-DatabasesInBCContainer

