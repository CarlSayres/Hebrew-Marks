[CmdletBinding(DefaultParameterSetName = 'LocalTest')]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$MakeAppxPath,
    [Parameter(Mandatory, ParameterSetName = 'Publisher')][string]$PackageName,
    [Parameter(Mandatory, ParameterSetName = 'Publisher')][string]$Publisher,
    [Parameter(Mandatory, ParameterSetName = 'Publisher')][string]$PublisherDisplayName
)

$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $SourceDir).Path
$exe = Join-Path $sourcePath 'Hebrew Marks.exe'
$files = @('Hebrew Marks.exe', 'README.md', 'THIRD_PARTY.md', 'JUCE-LICENSE.md', 'JUCE.spdx.json')
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourcePath $file) -PathType Leaf)) {
        throw "Missing package file: $file"
    }
}

if (-not $MakeAppxPath) {
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $MakeAppxPath = Get-ChildItem -LiteralPath $sdkBin -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64\makeappx.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if (-not $MakeAppxPath -or -not (Test-Path -LiteralPath $MakeAppxPath -PathType Leaf)) {
    throw 'MakeAppx.exe is required. Install the Windows SDK or supply -MakeAppxPath.'
}

$version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
if ($version -notmatch '^(\d+\.\d+\.\d+)(?:\.\d+)?$') { throw "Invalid application version: $version" }
$version = $Matches[1]
[xml]$manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.xml')
$manifest.Package.Identity.Version = "$version.0"

if ($PSCmdlet.ParameterSetName -eq 'Publisher') {
    if ($Publisher -match '2\.25\.311729368913984317654407730594956997722') {
        throw 'The unsigned test publisher marker is reserved for local test builds.'
    }
    $manifest.Package.Identity.Name = $PackageName
    $manifest.Package.Identity.Publisher = $Publisher
    $manifest.Package.Properties.PublisherDisplayName = $PublisherDisplayName
    $suffix = 'unsigned'
} else {
    # Windows 11 uses this OID to isolate unsigned installs from signed packages.
    $manifest.Package.Identity.Publisher += ', OID.2.25.311729368913984317654407730594956997722=1'
    $suffix = 'local-test'
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDir).Path
$package = Join-Path $outputPath "HebrewMarks-$version-x64-$suffix.msix"
$stage = Join-Path $outputPath ("msix-stage-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null

try {
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $sourcePath $file) -Destination $stage }
    $manifest.Save((Join-Path $stage 'AppxManifest.xml'))

    # Draw the same simple alef-with-mark icon at each manifest size.
    Add-Type -AssemblyName System.Drawing
    $assets = Join-Path $stage 'Assets'
    New-Item -ItemType Directory -Path $assets | Out-Null
    $logos = [ordered]@{ 'StoreLogo.png' = 50; 'Square44x44Logo.png' = 44; 'Square150x150Logo.png' = 150 }
    $format = [Drawing.StringFormat]::new()
    try {
        $format.Alignment = $format.LineAlignment = [Drawing.StringAlignment]::Center
        $format.FormatFlags = [Drawing.StringFormatFlags]::DirectionRightToLeft
        foreach ($logo in $logos.GetEnumerator()) {
            $size = $logo.Value
            $bitmap = [Drawing.Bitmap]::new($size, $size)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $font = [Drawing.Font]::new('Arial', $size * 0.72, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
            try {
                $graphics.Clear([Drawing.Color]::FromArgb(21, 45, 61))
                $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
                $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $letterBox = [Drawing.RectangleF]::new(0, 0, $size, $size * 0.84)
                $graphics.DrawString([string][char]0x05d0, $font, [Drawing.Brushes]::White, $letterBox, $format)
                $dot = [Drawing.RectangleF]::new($size * 0.46, $size * 0.80, $size * 0.08, $size * 0.08)
                $graphics.FillEllipse([Drawing.Brushes]::PaleTurquoise, $dot)
                $bitmap.Save((Join-Path $assets $logo.Key), [Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $font.Dispose()
                $graphics.Dispose()
                $bitmap.Dispose()
            }
        }
    } finally {
        $format.Dispose()
    }

    $packArgs = @('pack', '/d', $stage, '/p', $package, '/o')
    & $MakeAppxPath @packArgs | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $package -PathType Leaf)) {
        throw "MakeAppx packaging failed ($LASTEXITCODE)."
    }
    $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($package))" | Set-Content -LiteralPath "$package.sha256.txt" -Encoding utf8
    Write-Output $package
} finally {
    $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
    if ((Split-Path -Parent $resolvedStage) -eq $outputPath -and (Split-Path -Leaf $resolvedStage) -match '^msix-stage-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
