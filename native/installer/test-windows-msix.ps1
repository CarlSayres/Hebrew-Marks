param(
    [Parameter(Mandatory)][string]$SourceDir
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) {
    throw 'The MSIX installation test is intended for disposable GitHub-hosted runners.'
}

$testId = [guid]::NewGuid().ToString('N')
$packageName = "HebrewMarks.CI.$testId"
$publisher = "CN=$packageName"
$testDir = Join-Path $env:RUNNER_TEMP $packageName
$sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$sdk = Get-ChildItem -LiteralPath $sdkBin -Directory |
    Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64' } |
    Where-Object { (Test-Path (Join-Path $_ 'makeappx.exe')) -and (Test-Path (Join-Path $_ 'signtool.exe')) } |
    Select-Object -First 1
if (-not $sdk) { throw 'Could not find the Windows SDK signing and packaging tools.' }

# Launch by package identity, as the Start menu does.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MsixTestActivation
{
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            uint options, out uint processId);
    }

    public static uint Launch(string appId, string arguments)
    {
        var clsid = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
        var manager = (IApplicationActivationManager)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));
        try
        {
            uint processId;
            Marshal.ThrowExceptionForHR(manager.ActivateApplication(appId, arguments, 0, out processId));
            return processId;
        }
        finally { Marshal.ReleaseComObject(manager); }
    }
}
'@

$package = & (Join-Path $PSScriptRoot 'build-windows-msix.ps1') -SourceDir $SourceDir -OutputDir $testDir `
    -MakeAppxPath (Join-Path $sdk 'makeappx.exe') -PackageName $packageName -Publisher $publisher -PublisherDisplayName 'Hebrew Marks CI'

$cert = $null
try {
    # Trust only this job's short-lived certificate, and sign only the private test copy.
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $publisher `
        -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(1)
    $publicCert = Join-Path $testDir 'test.cer'
    Export-Certificate -Cert $cert -FilePath $publicCert | Out-Null
    Import-Certificate -FilePath $publicCert -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
    & (Join-Path $sdk 'signtool.exe') sign /s My /sha1 $cert.Thumbprint /fd SHA256 $package
    if ($LASTEXITCODE -ne 0) { throw 'Signing the MSIX test copy failed.' }

    Add-AppxPackage -Path $package
    $installed = Get-AppxPackage -Name $packageName
    if (-not $installed) { throw 'The installed Hebrew Marks package could not be found.' }
    $expectedExe = Join-Path $installed.InstallLocation 'Hebrew Marks.exe'
    $originalExe = Join-Path $SourceDir 'Hebrew Marks.exe'
    if ((Get-FileHash -LiteralPath $expectedExe).Hash -ne (Get-FileHash -LiteralPath $originalExe).Hash) {
        throw 'The installed executable differs from the portable build.'
    }

    $previews = Join-Path $testDir 'previews'
    $appProcessId = [MsixTestActivation]::Launch("$($installed.PackageFamilyName)!HebrewMarks", "--render `"$previews`"")
    $app = Get-Process -Id $appProcessId -ErrorAction SilentlyContinue
    if ($app -and -not $app.WaitForExit(20000)) { throw 'Timed out waiting for the installed app to render.' }
    foreach ($name in @('niqqud.png', 'teamim.png')) {
        if ((Get-Item -LiteralPath (Join-Path $previews $name)).Length -lt 100) { throw "Missing preview: $name" }
    }
    Write-Host 'PASS MSIX installation, executable integrity, activation and rendering'
} finally {
    try {
        Get-AppxPackage -Name $packageName | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName }
    } finally {
        if ($cert) {
            Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey
        }
    }
}
if (Get-AppxPackage -Name $packageName) { throw 'MSIX package still present after uninstall.' }
Write-Host 'PASS MSIX uninstallation'
