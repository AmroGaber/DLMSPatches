<#
.SYNOPSIS
    Downloads the latest offline security/critical patches for:
      - Windows Server 2019
      - Windows Server 2022
      - Windows Server 2025
      - .NET Framework 4.x
      - .NET 8

.DESCRIPTION
    Run this ONE script on an Internet-connected Windows machine.

    It creates this structure in the SAME folder where the script is executed:

      Latest patches\
        Install-LatestPatches.ps1
        common patchs\
        windows 2019\
        windows 2022\
        windows 2025\

    "common patchs" contains shared packages such as the latest .NET 8 Hosting Bundle.

    Each Windows Server folder contains:
      - Latest non-preview Windows cumulative security update
      - Latest .NET Framework cumulative security/quality update applicable to that OS
      - .NET Framework offline installer where useful
      - Manifest CSV containing hashes and update details

    The generated Install-LatestPatches.ps1 is copied with the downloaded files
    to the disconnected/dark-site server. It detects the server version and
    installs only the matching updates plus the common updates.

.NOTES
    Microsoft Update Catalog does not expose a supported public REST API.
    This script uses the MSCatalogLTS PowerShell module to query and download
    Microsoft Update Catalog packages.

    Run PowerShell as Administrator.

#>

[CmdletBinding()]
param(
    [switch]$ForceRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$ExecutionFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ExecutionFolder) {
    $ExecutionFolder = (Get-Location).Path
}

$Root = Join-Path $ExecutionFolder 'Latest patches'

$CommonFolder = Join-Path $Root 'common patchs'
$Win2019Folder = Join-Path $Root 'windows 2019'
$Win2022Folder = Join-Path $Root 'windows 2022'
$Win2025Folder = Join-Path $Root 'windows 2025'

$AllFolders = @(
    $Root,
    $CommonFolder,
    $Win2019Folder,
    $Win2022Folder,
    $Win2025Folder
)

$SummaryRows = [System.Collections.Generic.List[object]]::new()
$Failures = [System.Collections.Generic.List[object]]::new()

foreach ($Folder in $AllFolders) {
    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
}

function Write-Step {
    param([string]$Text)
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Ensure-MSCatalogLTS {
    if (-not (Get-Module -ListAvailable -Name MSCatalogLTS)) {
        Write-Step 'Installing MSCatalogLTS module'

        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        }

        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        catch {}

        Install-Module MSCatalogLTS -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module MSCatalogLTS -Force
}

function Get-DateSafe {
    param($Value)

    if ($Value -is [datetime]) {
        return $Value
    }

    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$d)) {
        return $d
    }

    return [datetime]::MinValue
}

function Get-KBNumber {
    param([string]$Title)

    if ($Title -match '\b(KB\d{6,8})\b') {
        return $Matches[1]
    }

    return ''
}

function Get-LatestCatalogItem {
    param(
        [Parameter(Mandatory)]
        [string]$Search,

        [Parameter(Mandatory)]
        [scriptblock]$Filter,

        [Parameter(Mandatory)]
        [string]$Description
    )

    Write-Host "Searching Microsoft Update Catalog: $Description"

    $Results = @(Get-MSCatalogUpdate -Search $Search -AllPages)

    $Matches = @(
        $Results |
        Where-Object { & $Filter $_ } |
        Sort-Object @{ Expression = { Get-DateSafe $_.LastUpdated }; Descending = $true }
    )

    if (-not $Matches) {
        throw "No applicable update found for: $Description"
    }

    $Selected = $Matches[0]

    Write-Host "Selected:" -ForegroundColor Green
    Write-Host "  $($Selected.Title)"
    Write-Host "  Date: $($Selected.LastUpdated)"

    return $Selected
}

function Save-CatalogUpdateToFolder {
    param(
        [Parameter(Mandatory)]$Update,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Category
    )

    $Before = @(
        Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    )

    Save-MSCatalogUpdate `
        -Update $Update `
        -Destination $Folder `
        -DownloadAll

    $After = @(
        Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue
    )

    $Downloaded = @(
        $After |
        Where-Object { $_.FullName -notin $Before }
    )

    if (-not $Downloaded) {
        $Downloaded = @(
            $After |
            Where-Object Extension -in '.msu','.cab','.exe'
        )
    }

    $ManifestRows = foreach ($File in $Downloaded) {
        $Signature = Get-AuthenticodeSignature -LiteralPath $File.FullName

        [pscustomobject]@{
            Category       = $Category
            KB             = Get-KBNumber $Update.Title
            Title          = $Update.Title
            CatalogDate    = [string]$Update.LastUpdated
            FileName       = $File.Name
            SHA256         = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
            Signature      = [string]$Signature.Status
            Source         = 'Microsoft Update Catalog'
        }
    }

    return $ManifestRows
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$File
    )

    if ((Test-Path -LiteralPath $File) -and -not $ForceRefresh) {
        Write-Host "Already downloaded: $(Split-Path $File -Leaf)"
        return
    }

    Write-Host "Downloading: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing
}

function Get-LatestDotNet8HostingBundle {

    Write-Step 'Finding latest .NET 8 Hosting Bundle'

    # Microsoft maintains this aka.ms alias to the current .NET 8 Windows
    # Hosting Bundle. Using the alias avoids depending on the internal JSON
    # shape of releases.json, which has changed over time.
    return [pscustomobject]@{
        Version = 'Latest'
        Date    = ''
        Url     = 'https://aka.ms/dotnetcore-8-0-windowshosting'
        SHA512  = ''
    }
}

# ---------------------------------------------------------------------------
# Generated DARK-SITE installation script
# ---------------------------------------------------------------------------

function Create-OfflineInstaller {

$OfflineInstaller = @'
<#
.SYNOPSIS
    Installs the downloaded offline patch bundle on Windows Server
    2019, 2022 or 2025.

.DESCRIPTION
    Copy the COMPLETE "Latest patches" folder to the dark-site server,
    open PowerShell as Administrator, and run:

        .\Install-LatestPatches.ps1

    The script automatically detects the Windows Server version and
    installs updates only from the corresponding OS folder plus
    "common patchs".

.PARAMETER NoReboot
    Prevents automatic reboot after installation.

.PARAMETER SkipDotNet8
    Skips installation of the .NET 8 Hosting Bundle.

#>

[CmdletBinding()]
param(
    [switch]$NoReboot,
    [switch]$SkipDotNet8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFolder = Join-Path $Root 'Logs'

if (-not (Test-Path -LiteralPath $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

$Log = Join-Path $LogFolder (
    'OfflinePatch-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)
)

Start-Transcript -Path $Log -Force | Out-Null

$RebootRequired = $false

function Invoke-MSU {
    param([string]$File)

    Write-Host ""
    Write-Host "Installing MSU:" -ForegroundColor Cyan
    Write-Host "  $(Split-Path $File -Leaf)"

    $Process = Start-Process `
        -FilePath "$env:SystemRoot\System32\wusa.exe" `
        -ArgumentList @(
            "`"$File`"",
            '/quiet',
            '/norestart'
        ) `
        -Wait `
        -PassThru

    switch ($Process.ExitCode) {
        0 {
            Write-Host 'Success.' -ForegroundColor Green
        }

        3010 {
            Write-Host 'Success - reboot required.' -ForegroundColor Yellow
            $script:RebootRequired = $true
        }

        2359302 {
            Write-Host 'Already installed / not applicable.' -ForegroundColor Yellow
        }

        default {
            Write-Warning "WUSA exit code: $($Process.ExitCode)"
        }
    }
}

function Invoke-CAB {
    param([string]$File)

    Write-Host ""
    Write-Host "Installing CAB:" -ForegroundColor Cyan
    Write-Host "  $(Split-Path $File -Leaf)"

    $Process = Start-Process `
        -FilePath "$env:SystemRoot\System32\dism.exe" `
        -ArgumentList @(
            '/Online',
            '/Add-Package',
            "/PackagePath:`"$File`"",
            '/NoRestart'
        ) `
        -Wait `
        -PassThru

    if ($Process.ExitCode -eq 3010) {
        $script:RebootRequired = $true
    }
    elseif ($Process.ExitCode -ne 0) {
        Write-Warning "DISM exit code: $($Process.ExitCode)"
    }
}

function Invoke-EXE {
    param(
        [string]$File,
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "Installing EXE:" -ForegroundColor Cyan
    Write-Host "  $(Split-Path $File -Leaf)"

    $Process = Start-Process `
        -FilePath $File `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru

    if ($Process.ExitCode -eq 3010) {
        $script:RebootRequired = $true
    }
    elseif ($Process.ExitCode -notin 0,1638) {
        Write-Warning "Installer exit code: $($Process.ExitCode)"
    }
}

function Install-PackageFolder {
    param([string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder)) {
        return
    }

    # Install CAB/MSU files alphabetically.
    # This is important when Server 2025 uses checkpoint cumulative updates.
    $Packages = @(
        Get-ChildItem -LiteralPath $Folder -File |
        Where-Object Extension -in '.msu','.cab' |
        Sort-Object Name
    )

    foreach ($Package in $Packages) {

        if ($Package.Extension -eq '.msu') {
            Invoke-MSU $Package.FullName
        }
        elseif ($Package.Extension -eq '.cab') {
            Invoke-CAB $Package.FullName
        }
    }
}

try {

    # -----------------------------------------------------------------------
    # Detect Windows Server version
    # -----------------------------------------------------------------------

    $OS = Get-CimInstance Win32_OperatingSystem

    if ($OS.ProductType -eq 1) {
        throw 'This script is intended for Windows Server, not Windows client.'
    }

    $Build = [int]$OS.BuildNumber

    switch ($Build) {

        17763 {
            $ServerVersion = 'Windows Server 2019'
            $OSFolder = Join-Path $Root 'windows 2019'
        }

        20348 {
            $ServerVersion = 'Windows Server 2022'
            $OSFolder = Join-Path $Root 'windows 2022'
        }

        26100 {
            $ServerVersion = 'Windows Server 2025'
            $OSFolder = Join-Path $Root 'windows 2025'
        }

        default {
            throw "Unsupported Windows Server build: $Build"
        }
    }

    Write-Host ""
    Write-Host "Detected $ServerVersion" -ForegroundColor Green
    Write-Host "Build: $Build"
    Write-Host ""

    # -----------------------------------------------------------------------
    # Verify downloaded hashes
    # -----------------------------------------------------------------------

    $Manifest = Join-Path $OSFolder 'Manifest.csv'

    if (Test-Path -LiteralPath $Manifest) {

        Write-Host 'Verifying OS-specific file hashes...' -ForegroundColor Cyan

        foreach ($Entry in Import-Csv -LiteralPath $Manifest) {

            $File = Join-Path $OSFolder $Entry.FileName

            if (-not (Test-Path -LiteralPath $File)) {
                throw "Missing file: $File"
            }

            $Hash = (
                Get-FileHash `
                    -LiteralPath $File `
                    -Algorithm SHA256
            ).Hash

            if ($Hash -ne $Entry.SHA256) {
                throw "HASH VALIDATION FAILED: $File"
            }
        }

        Write-Host 'OS-specific hashes verified.' -ForegroundColor Green
    }

    $CommonManifest = Join-Path $Root 'common patchs\Manifest.csv'

    if (Test-Path -LiteralPath $CommonManifest) {

        Write-Host 'Verifying common patch hashes...' -ForegroundColor Cyan

        foreach ($Entry in Import-Csv -LiteralPath $CommonManifest) {

            $File = Join-Path (Join-Path $Root 'common patchs') $Entry.FileName

            if (-not (Test-Path -LiteralPath $File)) {
                throw "Missing file: $File"
            }

            $Hash = (
                Get-FileHash `
                    -LiteralPath $File `
                    -Algorithm SHA256
            ).Hash

            if ($Hash -ne $Entry.SHA256) {
                throw "HASH VALIDATION FAILED: $File"
            }
        }

        Write-Host 'Common hashes verified.' -ForegroundColor Green
    }

    # -----------------------------------------------------------------------
    # Install OS-specific packages
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host 'Installing Windows and .NET Framework updates...' -ForegroundColor Cyan

    Install-PackageFolder $OSFolder

    # -----------------------------------------------------------------------
    # Install .NET Framework offline base installer if present
    # -----------------------------------------------------------------------

    $FrameworkInstaller = @(
        Get-ChildItem `
            -LiteralPath $OSFolder `
            -File `
            -Filter 'NDP*.exe' `
            -ErrorAction SilentlyContinue
    )

    foreach ($Installer in $FrameworkInstaller) {

        Invoke-EXE `
            -File $Installer.FullName `
            -Arguments @(
                '/q',
                '/norestart'
            )
    }

    # -----------------------------------------------------------------------
    # Install latest .NET 8 Hosting Bundle
    # -----------------------------------------------------------------------

    if (-not $SkipDotNet8) {

        $CommonFolder = Join-Path $Root 'common patchs'

        $DotNet8 = @(
            Get-ChildItem `
                -LiteralPath $CommonFolder `
                -File `
                -Filter 'dotnet-hosting-*-win.exe' `
                -ErrorAction SilentlyContinue
        )

        foreach ($Installer in $DotNet8) {

            Invoke-EXE `
                -File $Installer.FullName `
                -Arguments @(
                    '/install',
                    '/quiet',
                    '/norestart'
                )
        }
    }

    # -----------------------------------------------------------------------
    # Display installed .NET versions
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host '.NET Framework:' -ForegroundColor Cyan

    $NetFx = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
        -ErrorAction SilentlyContinue

    if ($NetFx) {
        Write-Host "Version : $($NetFx.Version)"
        Write-Host "Release : $($NetFx.Release)"
    }

    Write-Host ""
    Write-Host '.NET runtimes:' -ForegroundColor Cyan

    if (Get-Command dotnet.exe -ErrorAction SilentlyContinue) {
        dotnet --list-runtimes
    }
    else {
        Write-Host 'dotnet.exe not currently in PATH.'
    }

    Write-Host ""
    Write-Host 'Offline patch installation completed.' -ForegroundColor Green

    Stop-Transcript | Out-Null

    if ($RebootRequired) {

        Write-Warning 'A reboot is required.'

        if (-not $NoReboot) {

            Write-Host 'Server will reboot in 60 seconds.'
            Write-Host 'Run shutdown /a to cancel.'

            shutdown.exe /r /t 60 /c `
                'Offline Windows/.NET patch installation completed.'
        }
    }
}
catch {

    Write-Error $_

    try {
        Stop-Transcript | Out-Null
    }
    catch {}

    exit 1
}
'@

    $InstallerFile = Join-Path $Root 'Install-LatestPatches.ps1'

    Set-Content `
        -LiteralPath $InstallerFile `
        -Value $OfflineInstaller `
        -Encoding UTF8

    Write-Host "Created offline installer:"
    Write-Host "  $InstallerFile" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Internet-side downloader starts here
# ---------------------------------------------------------------------------

Ensure-MSCatalogLTS

Write-Step 'Creating offline installer script'
Create-OfflineInstaller

# ---------------------------------------------------------------------------
# Download latest .NET 8 to COMMON PATCHS
# ---------------------------------------------------------------------------

Write-Step 'Downloading latest .NET 8 to common patchs'

try {

    $DotNet8 = Get-LatestDotNet8HostingBundle

    # Download through Microsoft's stable alias. Invoke-WebRequest follows
    # the redirect to the current Microsoft-hosted servicing package.
    $TemporaryDotNet8File = Join-Path $CommonFolder 'dotnet-hosting-8-latest-win.exe'

    Download-File `
        -Url $DotNet8.Url `
        -File $TemporaryDotNet8File

    if (-not (Test-Path -LiteralPath $TemporaryDotNet8File)) {
        throw "Download did not create the expected file: $TemporaryDotNet8File"
    }

    # Validate that the downloaded executable is Microsoft-signed BEFORE use.
    $DotNetSignature = Get-AuthenticodeSignature -LiteralPath $TemporaryDotNet8File

    if ($DotNetSignature.Status -ne 'Valid') {
        throw "The downloaded .NET 8 Hosting Bundle does not have a valid Authenticode signature. Status: $($DotNetSignature.Status)"
    }

    $SignerSubject = ''
    if ($DotNetSignature.SignerCertificate) {
        $SignerSubject = [string]$DotNetSignature.SignerCertificate.Subject
    }

    if ($SignerSubject -notmatch 'Microsoft') {
        throw "The .NET 8 installer signature is valid but the signer is not recognized as Microsoft: $SignerSubject"
    }

    # Determine the actual version from the signed EXE itself. This is more
    # resilient than depending on Microsoft's release-metadata JSON schema.
    $VersionInfo = (Get-Item -LiteralPath $TemporaryDotNet8File).VersionInfo
    $DetectedVersion = [string]$VersionInfo.ProductVersion

    if (-not $DetectedVersion) {
        $DetectedVersion = [string]$VersionInfo.FileVersion
    }

    if ($DetectedVersion) {
        # ProductVersion can contain informational suffixes. Extract 8.0.x.
        if ($DetectedVersion -match '(8\.0\.\d+)') {
            $DetectedVersion = $Matches[1]
        }
    }

    if (-not $DetectedVersion) {
        $DetectedVersion = '8.0-latest'
    }

    $FinalDotNet8File = Join-Path `
        $CommonFolder `
        ("dotnet-hosting-{0}-win.exe" -f $DetectedVersion)

    if ($FinalDotNet8File -ne $TemporaryDotNet8File) {
        if (Test-Path -LiteralPath $FinalDotNet8File) {
            Remove-Item -LiteralPath $FinalDotNet8File -Force
        }
        Move-Item -LiteralPath $TemporaryDotNet8File -Destination $FinalDotNet8File -Force
    }

    $DotNetSHA256 = (
        Get-FileHash `
            -LiteralPath $FinalDotNet8File `
            -Algorithm SHA256
    ).Hash

    [pscustomobject]@{
        Category   = '.NET 8 Hosting Bundle'
        Version    = $DetectedVersion
        Date       = (Get-Date).ToString('yyyy-MM-dd')
        FileName   = Split-Path $FinalDotNet8File -Leaf
        SHA256     = $DotNetSHA256
        Signature  = [string]$DotNetSignature.Status
        Signer     = $SignerSubject
        Source     = $DotNet8.Url
    } |
    Export-Csv `
        -LiteralPath (Join-Path $CommonFolder 'Manifest.csv') `
        -NoTypeInformation `
        -Encoding UTF8

    $SummaryRows.Add(
        [pscustomobject]@{
            Scope       = 'Common'
            Server      = '2019 / 2022 / 2025'
            Category    = '.NET 8 Hosting Bundle'
            KB          = ''
            Version     = $DetectedVersion
            ReleaseDate = ''
            FileName    = Split-Path $FinalDotNet8File -Leaf
            SHA256      = $DotNetSHA256
            Status      = 'Downloaded and Microsoft signature validated'
        }
    )

    Write-Host "Downloaded .NET 8 Hosting Bundle version: $DetectedVersion" -ForegroundColor Green
}
catch {

    $Message = $_.Exception.Message

    Write-Warning '.NET 8 Hosting Bundle download failed.'
    Write-Warning $Message
    Write-Warning 'Continuing with Windows and .NET Framework downloads.'

    $Failures.Add(
        [pscustomobject]@{
            Scope     = 'Common'
            Component = '.NET 8 Hosting Bundle'
            Error     = $Message
        }
    )

    $SummaryRows.Add(
        [pscustomobject]@{
            Scope       = 'Common'
            Server      = '2019 / 2022 / 2025'
            Category    = '.NET 8 Hosting Bundle'
            KB          = ''
            Version     = ''
            ReleaseDate = ''
            FileName    = ''
            SHA256      = ''
            Status      = "FAILED: $Message"
        }
    )
}

# ---------------------------------------------------------------------------
# Per-OS definitions
# ---------------------------------------------------------------------------

$Servers = @(

    [pscustomobject]@{
        Year = 2019
        Folder = $Win2019Folder

        LcuSearch =
            'Cumulative Update for Windows Server 2019 for x64-based Systems'

        LcuRegex =
            'Cumulative Update for Windows Server 2019 for x64-based Systems'

        NetFxSearch =
            'Cumulative Update for .NET Framework Windows Server 2019 x64'

        NetFxRegex =
            'Cumulative Update for \.NET Framework.*Windows Server 2019.*x64'

        FrameworkVersion = '4.8'

        FrameworkUrl =
            'https://go.microsoft.com/fwlink/?linkid=2088631'

        FrameworkFile =
            'NDP48-x86-x64-AllOS-ENU.exe'
    },

    [pscustomobject]@{
        Year = 2022
        Folder = $Win2022Folder

        LcuSearch =
            'Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems'

        LcuRegex =
            'Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems'

        NetFxSearch =
            'Cumulative Update for .NET Framework Microsoft server operating system version 21H2 x64'

        NetFxRegex =
            'Cumulative Update for \.NET Framework.*Microsoft server operating system version 21H2.*x64'

        FrameworkVersion = '4.8.1'

        FrameworkUrl =
            'https://go.microsoft.com/fwlink/?linkid=2203305'

        FrameworkFile =
            'NDP481-x86-x64-AllOS-ENU.exe'
    },

    [pscustomobject]@{
        Year = 2025
        Folder = $Win2025Folder

        LcuSearch =
            'Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems'

        LcuRegex =
            'Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems'

        NetFxSearch =
            'Cumulative Update for .NET Framework Microsoft server operating system version 24H2 x64'

        NetFxRegex =
            'Cumulative Update for \.NET Framework.*Microsoft server operating system version 24H2.*x64'

        FrameworkVersion = '4.8.1'

        FrameworkUrl =
            'https://go.microsoft.com/fwlink/?linkid=2203305'

        FrameworkFile =
            'NDP481-x86-x64-AllOS-ENU.exe'
    }
)

foreach ($Server in $Servers) {

    Write-Step "Processing Windows Server $($Server.Year)"

    try {

        $Manifest = [System.Collections.Generic.List[object]]::new()

    # -----------------------------------------------------------------------
    # Windows cumulative security update
    # -----------------------------------------------------------------------

    $LCU = Get-LatestCatalogItem `
        -Search $Server.LcuSearch `
        -Description "Windows Server $($Server.Year) latest security cumulative update" `
        -Filter {

            param($Update)

            $Update.Title -match $Server.LcuRegex -and
            $Update.Title -notmatch 'Preview' -and
            $Update.Title -notmatch 'Dynamic Update' -and
            $Update.Title -notmatch '\.NET Framework' -and
            [string]$Update.Classification -match 'Security'
        }

    foreach (
        $Row in Save-CatalogUpdateToFolder `
            -Update $LCU `
            -Folder $Server.Folder `
            -Category 'Windows cumulative security update'
    ) {
        $Manifest.Add($Row)
    }

    # -----------------------------------------------------------------------
    # .NET Framework cumulative update
    # -----------------------------------------------------------------------

    $NetFxCU = Get-LatestCatalogItem `
        -Search $Server.NetFxSearch `
        -Description "Windows Server $($Server.Year) latest .NET Framework cumulative update" `
        -Filter {

            param($Update)

            $Update.Title -match $Server.NetFxRegex -and
            $Update.Title -notmatch 'Preview' -and
            $Update.Title -notmatch 'arm64' -and
            [string]$Update.Classification -match 'Security'
        }

    foreach (
        $Row in Save-CatalogUpdateToFolder `
            -Update $NetFxCU `
            -Folder $Server.Folder `
            -Category '.NET Framework cumulative update'
    ) {
        $Manifest.Add($Row)
    }

    # -----------------------------------------------------------------------
    # .NET Framework offline base installer
    # -----------------------------------------------------------------------

    $FrameworkFile = Join-Path `
        $Server.Folder `
        $Server.FrameworkFile

    Download-File `
        -Url $Server.FrameworkUrl `
        -File $FrameworkFile

    $Signature = Get-AuthenticodeSignature `
        -LiteralPath $FrameworkFile

    $Manifest.Add(
        [pscustomobject]@{
            Category       = ".NET Framework $($Server.FrameworkVersion) offline installer"
            KB             = ''
            Title          = ".NET Framework $($Server.FrameworkVersion) Offline Installer"
            CatalogDate    = ''
            FileName       = Split-Path $FrameworkFile -Leaf
            SHA256         = (
                Get-FileHash `
                    -LiteralPath $FrameworkFile `
                    -Algorithm SHA256
            ).Hash
            Signature      = [string]$Signature.Status
            Source         = 'Microsoft official .NET Framework download'
        }
    )

    $Manifest |
    Export-Csv `
        -LiteralPath (Join-Path $Server.Folder 'Manifest.csv') `
        -NoTypeInformation `
        -Encoding UTF8


        foreach ($Row in $Manifest) {
            $SummaryRows.Add(
                [pscustomobject]@{
                    Scope       = "Windows Server $($Server.Year)"
                    Server      = [string]$Server.Year
                    Category    = $Row.Category
                    KB          = $Row.KB
                    Version     = if ($Row.Category -like '.NET Framework*') { $Server.FrameworkVersion } else { '' }
                    ReleaseDate = $Row.CatalogDate
                    FileName    = $Row.FileName
                    SHA256      = $Row.SHA256
                    Status      = 'Downloaded'
                }
            )
        }

    }
    catch {

        $Message = $_.Exception.Message

        Write-Warning "Windows Server $($Server.Year) download section failed."
        Write-Warning $Message
        Write-Warning 'Continuing with the next Windows Server version.'

        $Failures.Add(
            [pscustomobject]@{
                Scope     = "Windows Server $($Server.Year)"
                Component = 'Windows/.NET Framework downloads'
                Error     = $Message
            }
        )

        $SummaryRows.Add(
            [pscustomobject]@{
                Scope       = "Windows Server $($Server.Year)"
                Server      = [string]$Server.Year
                Category    = 'Download section'
                KB          = ''
                Version     = ''
                ReleaseDate = ''
                FileName    = ''
                SHA256      = ''
                Status      = "FAILED: $Message"
            }
        )
    }
}


# ---------------------------------------------------------------------------
# Summary report
# ---------------------------------------------------------------------------

Write-Step 'Creating summary report'

$SummaryCsv = Join-Path $Root 'Patch-Summary.csv'
$SummaryTxt = Join-Path $Root 'Patch-Summary.txt'

$SummaryRows |
    Sort-Object Scope, Category, FileName |
    Export-Csv `
        -LiteralPath $SummaryCsv `
        -NoTypeInformation `
        -Encoding UTF8

$Report = [System.Collections.Generic.List[string]]::new()

$Report.Add('LATEST PATCHES - DOWNLOAD SUMMARY')
$Report.Add('=================================')
$Report.Add('')
$Report.Add("Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
$Report.Add("Computer  : $env:COMPUTERNAME")
$Report.Add("Root      : $Root")
$Report.Add('')

foreach ($Group in ($SummaryRows | Group-Object Scope)) {

    $Report.Add($Group.Name)
    $Report.Add(('-' * $Group.Name.Length))

    foreach ($Item in $Group.Group) {

        $Report.Add("Category     : $($Item.Category)")

        if ($Item.KB) {
            $Report.Add("KB           : $($Item.KB)")
        }

        if ($Item.Version) {
            $Report.Add("Version      : $($Item.Version)")
        }

        if ($Item.ReleaseDate) {
            $Report.Add("Release date : $($Item.ReleaseDate)")
        }

        if ($Item.FileName) {
            $Report.Add("File         : $($Item.FileName)")
        }

        if ($Item.SHA256) {
            $Report.Add("SHA256       : $($Item.SHA256)")
        }

        $Report.Add("Status       : $($Item.Status)")
        $Report.Add('')
    }
}

if ($Failures.Count -gt 0) {

    $FailureCsv = Join-Path $Root 'Patch-Failures.csv'

    $Failures |
        Export-Csv `
            -LiteralPath $FailureCsv `
            -NoTypeInformation `
            -Encoding UTF8

    $Report.Add('DOWNLOAD FAILURES')
    $Report.Add('-----------------')

    foreach ($Failure in $Failures) {
        $Report.Add("Scope     : $($Failure.Scope)")
        $Report.Add("Component : $($Failure.Component)")
        $Report.Add("Error     : $($Failure.Error)")
        $Report.Add('')
    }
}

$Report.Add('NOTES')
$Report.Add('-----')
$Report.Add('* Preview updates are excluded.')
$Report.Add('* A failure in one component no longer stops the other server downloads.')
$Report.Add('* Windows cumulative updates already contain previous cumulative monthly security fixes.')
$Report.Add('* Review failed components before transferring this bundle to the dark site.')

$Report |
    Set-Content `
        -LiteralPath $SummaryTxt `
        -Encoding UTF8

Write-Host "Summary: $SummaryTxt" -ForegroundColor Green
Write-Host "CSV    : $SummaryCsv" -ForegroundColor Green

# ---------------------------------------------------------------------------
# README
# ---------------------------------------------------------------------------

$ReadMe = @"
LATEST PATCHES OFFLINE BUNDLE
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')

Folder layout:

Latest patches
|
+-- Install-LatestPatches.ps1
|
+-- common patchs
|   +-- Latest .NET 8 Hosting Bundle
|   +-- Manifest.csv
|
+-- windows 2019
|   +-- Latest Windows Server 2019 cumulative security update
|   +-- Latest .NET Framework cumulative update
|   +-- .NET Framework 4.8 offline installer
|   +-- Manifest.csv
|
+-- windows 2022
|   +-- Latest Windows Server 2022 cumulative security update
|   +-- Latest .NET Framework cumulative update
|   +-- .NET Framework 4.8.1 offline installer
|   +-- Manifest.csv
|
+-- windows 2025
    +-- Latest Windows Server 2025 cumulative security update
    +-- Latest .NET Framework cumulative update
    +-- .NET Framework 4.8.1 offline installer
    +-- Manifest.csv


HOW TO USE ON DARK-SITE SERVER
-------------------------------

1. Copy the COMPLETE "Latest patches" folder to the server.

2. Open PowerShell as Administrator.

3. Change directory to "Latest patches".

4. Run:

   Set-ExecutionPolicy Bypass -Scope Process -Force

   .\Install-LatestPatches.ps1


Optional:

   .\Install-LatestPatches.ps1 -NoReboot

   .\Install-LatestPatches.ps1 -SkipDotNet8


NOTES
-----

* The installer detects Server 2019, 2022 or 2025 automatically.

* Only the matching Windows folder is installed.

* Packages inside "common patchs" apply to all supported server versions.

* Preview updates are intentionally excluded.

* The latest monthly Windows cumulative update already contains previous
  cumulative Windows security fixes.

* .NET Framework cumulative updates are OS-specific.

* Modern .NET 8 servicing is handled separately from .NET Framework 4.x.

* Server 2019 uses .NET Framework 4.8.
  Server 2022 and Server 2025 use .NET Framework 4.8.1.

* SHA256 hashes are stored in Manifest.csv and validated before installation.
"@

Set-Content `
    -LiteralPath (Join-Path $Root 'README.txt') `
    -Value $ReadMe `
    -Encoding UTF8

Write-Step 'COMPLETED'

if ($Failures.Count -gt 0) {
    Write-Warning "$($Failures.Count) section(s) failed. Review Patch-Failures.csv and Patch-Summary.txt."
}
else {
    Write-Host 'All requested download sections completed successfully.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Offline patch bundle created at:' -ForegroundColor Green
Write-Host "  $Root"
Write-Host ''
Write-Host 'Folder structure:' -ForegroundColor Cyan
Write-Host '  Latest patches'
Write-Host '    Install-LatestPatches.ps1'
Write-Host '    Patch-Summary.txt'
Write-Host '    Patch-Summary.csv'
Write-Host '    Patch-Failures.csv (only when failures occur)'
Write-Host '    README.txt'
Write-Host '    common patchs'
Write-Host '    windows 2019'
Write-Host '    windows 2022'
Write-Host '    windows 2025'
Write-Host ''
