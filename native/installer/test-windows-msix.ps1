param(
    [Parameter(Mandatory)][string]$SourceDir
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) {
    throw 'The MSIX installation test is intended for disposable GitHub-hosted runners.'
}

$packageName = 'HebrewMarks.LocalTest'
if (Get-AppxPackage -Name $packageName) { throw 'The local MSIX test package is already installed.' }
$testDir = Join-Path $env:RUNNER_TEMP ("msix-test-" + [guid]::NewGuid().ToString('N'))

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

    public static uint Launch(string appId)
    {
        var clsid = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
        var manager = (IApplicationActivationManager)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));
        try
        {
            uint processId;
            Marshal.ThrowExceptionForHR(manager.ActivateApplication(appId, null, 0, out processId));
            return processId;
        }
        finally { Marshal.ReleaseComObject(manager); }
    }
}
'@

$package = & (Join-Path $PSScriptRoot 'build-windows-msix.ps1') -SourceDir $SourceDir -OutputDir $testDir
$publicCert = [IO.Path]::ChangeExtension($package, '.cer')
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicCert)

$app = $null
try {
    # Trust only this job's short-lived public certificate on the disposable runner.
    Import-Certificate -FilePath $publicCert -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null

    Add-AppxPackage -Path $package
    $installed = Get-AppxPackage -Name $packageName
    if (-not $installed) { throw 'The installed Hebrew Marks package could not be found.' }
    $expectedExe = Join-Path $installed.InstallLocation 'Hebrew Marks.exe'
    $originalExe = Join-Path $SourceDir 'Hebrew Marks.exe'
    if ((Get-FileHash -LiteralPath $expectedExe).Hash -ne (Get-FileHash -LiteralPath $originalExe).Hash) {
        throw 'The installed executable differs from the portable build.'
    }

    $appProcessId = [MsixTestActivation]::Launch("$($installed.PackageFamilyName)!HebrewMarks")
    $launchedProcess = Get-Process -Id $appProcessId
    if ($launchedProcess.Path -ne $expectedExe) { throw 'Activation did not start the installed executable.' }
    $app = $launchedProcess
    if (-not $app.WaitForInputIdle(15000) -or $app.HasExited) {
        throw 'The installed app did not reach its Windows message loop.'
    }
    Write-Host 'PASS MSIX installation, executable integrity and normal activation'
} finally {
    try {
        if ($app -and -not $app.HasExited) {
            if (-not $app.CloseMainWindow() -or -not $app.WaitForExit(3000)) {
                # This is the exact process started from the private test package.
                $app.Kill()
                if (-not $app.WaitForExit(5000)) { throw 'The MSIX fixture did not exit.' }
            }
        }
    } finally {
        try {
            Get-AppxPackage -Name $packageName | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName }
        } finally {
            Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
            $cert.Dispose()
        }
    }
}
if (Get-AppxPackage -Name $packageName) { throw 'MSIX package still present after uninstall.' }
Write-Host 'PASS MSIX uninstallation'
