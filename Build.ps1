param(
    [Parameter(Mandatory = $false)][string] $Configuration = "Release",
    [Parameter(Mandatory = $false)][string] $OutputPath = "",
    [Parameter(Mandatory = $false)][switch] $SkipTests,
    [Parameter(Mandatory = $false)][bool]   $CreatePackages = $true,
    [Parameter(Mandatory = $false)][switch] $DisableCodeCoverage
)

$ErrorActionPreference = "Stop"

$solutionPath = Split-Path $MyInvocation.MyCommand.Definition
$sdkFile = Join-Path $solutionPath "global.json"

$dotnetVersion = (Get-Content $sdkFile | Out-String | ConvertFrom-Json).sdk.version

if ($OutputPath -eq "") {
    $OutputPath = Join-Path "$(Convert-Path "$PSScriptRoot")" "artifacts"
}

$installDotNetSdk = $false;

if (($null -eq (Get-Command "dotnet.exe" -ErrorAction SilentlyContinue)) -and ($null -eq (Get-Command "dotnet" -ErrorAction SilentlyContinue))) {
    Write-Host "The .NET Core SDK is not installed."
    $installDotNetSdk = $true
}
else {
    Try {
        $installedDotNetVersion = (dotnet --version 2>&1 | Out-String).Trim()
    }
    Catch {
        $installedDotNetVersion = "?"
    }

    if ($installedDotNetVersion -ne $dotnetVersion) {
        Write-Host "The required version of the .NET Core SDK is not installed. Expected $dotnetVersion."
        $installDotNetSdk = $true
    }
}

if ($installDotNetSdk -eq $true) {
    $env:DOTNET_INSTALL_DIR = Join-Path "$(Convert-Path "$PSScriptRoot")" ".dotnetcli"
    $sdkPath = Join-Path $env:DOTNET_INSTALL_DIR "sdk\$dotnetVersion"

    if (!(Test-Path $sdkPath)) {
        if (!(Test-Path $env:DOTNET_INSTALL_DIR)) {
            mkdir $env:DOTNET_INSTALL_DIR | Out-Null
        }
        $installScript = Join-Path $env:DOTNET_INSTALL_DIR "install.ps1"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor "Tls12"
        Invoke-WebRequest "https://dot.net/v1/dotnet-install.ps1" -OutFile $installScript -UseBasicParsing
        & $installScript -Version "$dotnetVersion" -InstallDir "$env:DOTNET_INSTALL_DIR" -NoPath
    }

    $env:PATH = "$env:DOTNET_INSTALL_DIR;$env:PATH"
    $dotnet = Join-Path "$env:DOTNET_INSTALL_DIR" "dotnet.exe"
}
else {
    $dotnet = "dotnet"
}

function DotNetBuild {
    param([string]$Project, [string]$Configuration, [string]$Framework)
    & $dotnet build $Project --output (Join-Path $OutputPath $Framework) --framework $Framework --configuration $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE"
    }
}

function DotNetTest {
    param([string]$Project)
    if ($DisableCodeCoverage -eq $true) {
        & $dotnet test $Project --output $OutputPath
    }
    else {

        if ($installDotNetSdk -eq $true) {
            $dotnetPath = $dotnet
        }
        else {
            $dotnetPath = (Get-Command "dotnet.exe").Source
        }

        $nugetPath = Join-Path $env:USERPROFILE ".nuget\packages"
        $propsFile = Join-Path $solutionPath "Directory.Build.props"

        $openCoverVersion = (Select-Xml -Path $propsFile -XPath "//PackageReference[@Include='OpenCover']/@Version").Node.'#text'
        $openCoverPath = Join-Path $nugetPath "OpenCover\$openCoverVersion\tools\OpenCover.Console.exe"

        $reportGeneratorVersion = (Select-Xml -Path $propsFile -XPath "//PackageReference[@Include='ReportGenerator']/@Version").Node.'#text'
        $reportGeneratorPath = Join-Path $nugetPath "ReportGenerator\$reportGeneratorVersion\tools\netcoreapp2.0\ReportGenerator.dll"

        $coverageOutput = Join-Path $OutputPath "code-coverage.xml"
        $reportOutput = Join-Path $OutputPath "coverage"

        & $openCoverPath `
            `"-target:$dotnetPath`" `
            `"-targetargs:test $Project --output $OutputPath`" `
            `"-output:$coverageOutput`" `
            `"-excludebyattribute:*.ExcludeFromCodeCoverage*`" `
            `"-hideskipped:All`" `
            -mergebyhash `
            -mergeoutput `
            -oldstyle `
            `"-register:user`" `
            -returntargetcode `
            -skipautoprops `
            `"-filter:+[JustEat.StatsD]* -[*Test*]*`"

        if ($LASTEXITCODE -eq 0) {
            & $dotnet `
                $reportGeneratorPath `
                `"-reports:$coverageOutput`" `
                `"-targetdir:$reportOutput`" `
                -reporttypes:HTML`;Cobertura `
                -verbosity:Warning
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet test failed with exit code $LASTEXITCODE"
    }
}

function DotNetPack {
    param([string]$Project, [string]$Configuration)
    & $dotnet pack $Project --output $OutputPath --configuration $Configuration --include-symbols --include-source
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet pack failed with exit code $LASTEXITCODE"
    }
}

$projects = @(
    (Join-Path $solutionPath "src\JustEat.StatsD\JustEat.StatsD.csproj")
)

$testProjects = @(
    (Join-Path $solutionPath "tests\JustEat.StatsD.Tests\JustEat.StatsD.Tests.csproj")
)

$packageProjects = @(
    (Join-Path $solutionPath "src\JustEat.StatsD\JustEat.StatsD.csproj")
)

Write-Host "Building $($projects.Count) projects..." -ForegroundColor Green
ForEach ($project in $projects) {
    DotNetBuild $project $Configuration "netstandard2.0"
    DotNetBuild $project $Configuration "net451"
}

if ($SkipTests -eq $false) {
    Write-Host "Testing $($testProjects.Count) project(s)..." -ForegroundColor Green
    ForEach ($project in $testProjects) {
        DotNetTest $project
    }
}

if ($CreatePackages -eq $true) {
    Write-Host "Creating $($packageProjects.Count) package(s)..." -ForegroundColor Green
    ForEach ($project in $packageProjects) {
        DotNetPack $project $Configuration
    }
}
