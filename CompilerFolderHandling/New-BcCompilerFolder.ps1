<#
 .SYNOPSIS
  Create a new Compiler Folder
 .DESCRIPTION
  Create a folder containing all the necessary pieces from the artifatcs to compile apps without the need of a container
  Returns a compilerFolder path, which can be used for functions like Compile-AppWithBcCompilerFolder or Remove-BcCompilerFolder
 .PARAMETER artifactUrl
  Artifacts URL to download the compiler and all .app files from
 .PARAMETER containerName
  Name of the folder in which to create the compiler folder or empty to use a default name consisting of type-version-country
 .PARAMETER cacheFolder
  If present:
  - if the cacheFolder exists, the artifacts will be grabbed from here instead of downloaded.
  - if the cacheFolder doesn't exist, it is created and populated with the needed content from the ArtifactURL
 .PARAMETER packagesFolder
  If present, the symbols/apps will be copied from the compiler folder to this folder as well
 .PARAMETER vsixFile
  If present, use this vsixFile instead of the one included in the artifacts
 .PARAMETER includeAL
  Include this switch in order to populate folder with AL files (like New-BcContainer)
 .EXAMPLE
  $version = $artifactURL.Split('/')[4]
  $country = $artifactURL.Split('/')[5]
  $compilerFolder = New-BcCompilerFolder -artifactUrl $artifactURL -includeAL
  $baseAppSource = Join-Path $compilerFolder "BaseApp"
  Copy-Item -Path (Join-Path $bcContainerHelperConfig.hostHelperFolder "Extensions\Original-$version-$country-al") $baseAppSource -Container -Recurse
  Compile-AppWithBcCompilerFolder `
      -compilerFolder $compilerFolder `
      -appProjectFolder $baseAppSource `
      -appOutputFolder (Join-Path $compilerFolder '.output') `
      -appSymbolsFolder (Join-Path $compilerFolder 'symbols') `
      -CopyAppToSymbolsFolder
#>
function New-BcCompilerFolder {
    Param(
        [string] $artifactUrl,
        [string] $containerName = '',
        [string] $cacheFolder = '',
        [string] $packagesFolder = '',
        [string] $vsixFile = '',
        [switch] $includeAL
    )

$telemetryScope = InitTelemetryScope -name $MyInvocation.InvocationName -parameterValues $PSBoundParameters -includeParameters @()
try {
    $parts = $artifactUrl.Split('?')[0].Split('/')
    if ($parts.Count -lt 6) {
        throw "Invalid artifact URL"
    }
    $type = $parts[3]
    $version = [System.Version]($parts[4])
    $country = $parts[5]

    if ($version -lt "16.0.0.0") {
        throw "Containerless compiling is not supported with versions before 16.0"
    }
    
    if (!$containerName) {
        $containerName = "$type-$version-$country"
    }

    $compilerFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder "compiler\$containerName"
    if (Test-Path $compilerFolder) {
        Remove-Item -Path $compilerFolder -Force -Recurse -ErrorAction Ignore
    }
    New-Item -Path $compilerFolder -ItemType Directory -ErrorAction Ignore | Out-Null

    # Populate artifacts cache
    if ($cacheFolder) {
        $symbolsPath = Join-Path $cacheFolder 'symbols'
        $compilerPath = Join-Path $cacheFolder 'compiler'
        $dllsPath = Join-Path $cacheFolder 'dlls'
    }
    else {
        $symbolsPath = Join-Path $compilerFolder 'symbols'
        $compilerPath = Join-Path $compilerFolder 'compiler'
        $dllsPath = Join-Path $compilerFolder 'dlls'
    }

    if ($includeAL -or !(Test-Path $symbolsPath)) {
        $artifactPaths = Download-Artifacts -artifactUrl $artifactUrl -includePlatform
        $appArtifactPath = $artifactPaths[0]
        $platformArtifactPath = $artifactPaths[1]
    }

    # IncludeAL will populate folder with AL files (like New-BcContainer)
    if ($includeAL) {
        $alFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder "Extensions\Original-$version-$country-al"
        if (!(Test-Path $alFolder) -or (Get-ChildItem -Path $alFolder -Recurse | Measure-Object).Count -eq 0) {
            if (!(Test-Path $alFolder)) {
                New-Item $alFolder -ItemType Directory | Out-Null
            }
            $countryApplicationsFolder = Join-Path $appArtifactPath "Applications.$country"
            if (Test-Path $countryApplicationsFolder) {
                $baseAppSource = @(get-childitem -Path $countryApplicationsFolder -recurse -filter "Base Application.Source.zip")
            }
            else {
                $baseAppSource = @(get-childitem -Path (Join-Path $platformArtifactPath "Applications") -recurse -filter "Base Application.Source.zip")
            }
            if ($baseAppSource.Count -ne 1) {
                throw "Unable to locate Base Application.Source.zip"
            }
            Write-Host "Extracting $($baseAppSource[0].FullName)"
            Expand-7zipArchive -Path $baseAppSource[0].FullName -DestinationPath $alFolder
        }
    }

    # Populate cache folder (or compiler folder)
    if (!(Test-Path $symbolsPath)) {
        New-Item $symbolsPath -ItemType Directory | Out-Null
        New-Item $compilerPath -ItemType Directory | Out-Null
        New-Item $dllsPath -ItemType Directory | Out-Null
        $modernDevFolder = Join-Path $platformArtifactPath "ModernDev\program files\Microsoft Dynamics NAV\*\AL Development Environment" -Resolve
        Copy-Item -Path (Join-Path $modernDevFolder 'System.app') -Destination $symbolsPath
        if ($cacheFolder -or !$vsixFile) {
            # Only unpack the artifact vsix file if we are populating a cache folder - or no vsixFile was specified
            Expand-7zipArchive -Path (Join-Path $modernDevFolder 'ALLanguage.vsix') -DestinationPath $compilerPath
        }
        $serviceTierFolder = Join-Path $platformArtifactPath "ServiceTier\program files\Microsoft Dynamics NAV\*\Service" -Resolve
        Copy-Item -Path $serviceTierFolder -Filter '*.dll' -Destination $dllsPath -Recurse
        Remove-Item -Path (Join-Path $dllsPath 'Service\Management') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $dllsPath 'Service\WindowsServiceInstaller') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $dllsPath 'Service\SideServices') -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path (Join-Path $dllsPath 'OpenXML') -ItemType Directory | Out-Null
        Copy-Item -Path (Join-Path $dllsPath 'Service\DocumentFormat.OpenXml.dll') -Destination (Join-Path $dllsPath 'OpenXML') -Force -ErrorAction SilentlyContinue
        $mockAssembliesFolder = Join-Path $platformArtifactPath "Test Assemblies\Mock Assemblies" -Resolve
        Copy-Item -Path $mockAssembliesFolder -Filter '*.dll' -Destination $dllsPath -Recurse
        $extensionsFolder = Join-Path $appArtifactPath 'Extensions'
        if (Test-Path $extensionsFolder -PathType Container) {
            Copy-Item -Path (Join-Path $extensionsFolder '*.app') -Destination $symbolsPath
            'Microsoft_Tests-TestLibraries*.app','Microsoft_Performance Toolkit Samples*.app','Microsoft_Performance Toolkit Tests*.app','Microsoft_System Application Test Library*.app','Microsoft_TestRunner-Internal*.app' | ForEach-Object {
                Get-ChildItem -Path (Join-Path $platformArtifactPath 'Applications') -Filter $_ -Recurse | ForEach-Object { Copy-Item -Path $_.FullName -Destination $symbolsPath  }
            }
        }
        else {
            Get-ChildItem -Path (Join-Path $platformArtifactPath 'Applications') -Filter '*.app' -Recurse | ForEach-Object { Copy-Item -Path $_.FullName -Destination $symbolsPath }
        }
    }

    $containerCompilerPath = Join-Path $compilerFolder 'compiler'
    if ($vsixFile) {
        # If a vsix file was specified unpack directly to compilerfolder
        Write-Host "Using $vsixFile"
        $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "alc.zip"
        Download-File -sourceUrl $vsixFile -destinationFile $tempZip
        Expand-7zipArchive -Path $tempZip -DestinationPath $containerCompilerPath
        Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
    }

    # If a cacheFolder was specified, the cache folder has been populated
    if ($cacheFolder) {
        Write-Host "Copying DLLs from cache"
        Copy-Item -Path $dllsPath -Filter '*.dll' -Destination $compilerFolder -Recurse -Force
        Write-Host "Copying symbols from cache"
        Copy-Item -Path $symbolsPath -Filter '*.app' -Destination $compilerFolder -Recurse -Force
        # If a vsix file was specified, the compiler folder has been populated
        if (!$vsixFile) {
            Write-Host "Copying compiler from cache"
            Copy-Item -Path $compilerPath -Destination $compilerFolder -Recurse -Force
        }
    }

    # If a packagesFolder was specified, copy symbols from CompilerFolder
    if ($packagesFolder) {
        Write-Host "Copying symbols to packagesFolder"
        New-Item -Path $packagesFolder -ItemType Directory -Force | Out-Null
        Copy-Item -Path $symbolsPath -Filter '*.app' -Destination $packagesFolder -Force -Recurse
    }

    if ($isLinux) {
        $alcExePath = Join-Path $containerCompilerPath 'extension/bin/linux/alc'
        # Set execute permissions on alc
        & /usr/bin/env sudo pwsh -command "& chmod +x $alcExePath"
    }
    $compilerFolder
}
catch {
    TrackException -telemetryScope $telemetryScope -errorRecord $_
    throw
}
finally {
    TrackTrace -telemetryScope $telemetryScope
}
}
Export-ModuleMember -Function New-BcCompilerFolder
