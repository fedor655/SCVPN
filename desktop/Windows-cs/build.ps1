<#
    Сборка SCVPN: приложение и установщик, для одной или обеих архитектур.

    Заменяет прежние build.bat и build_installer.bat — их было двое, и версия
    приложения задавалась в них дважды.

        .\build.ps1                 # обе архитектуры, приложение и установщик
        .\build.ps1 -Arch arm64     # только arm64
        .\build.ps1 -NoInstaller    # только приложение

    Кросс-сборка работает: с arm64-машины собирается и x64 (и наоборот) —
    PyInstaller так не умел, а dotnet умеет. Если ReadyToRun для чужой
    архитектуры не заведётся, запусти с -NoR2R: потеряется только скорость
    холодного старта.
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64', 'both')]
    [string]$Arch = 'both',
    [switch]$NoInstaller,
    [switch]$NoR2R
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# --- версия: единственный источник — Directory.Build.props -----------------
[xml]$props = Get-Content 'Directory.Build.props'
$version = ($props.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
if (-not $version) { throw 'Не нашёл <Version> в Directory.Build.props' }
Write-Host "SCVPN $version" -ForegroundColor Cyan

$targets = if ($Arch -eq 'both') { @('x64', 'arm64') } else { @($Arch) }

# --- проверка Inno Setup ---------------------------------------------------
$iscc = $null
if (-not $NoInstaller) {
    foreach ($candidate in @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
        if (Test-Path $candidate) { $iscc = $candidate; break }
    }
    if (-not $iscc) {
        throw 'Не найден ISCC.exe. Нужен Inno Setup 6.3 или новее (идентификатор x64compatible появился именно в 6.3).'
    }
}

# --- сборка ----------------------------------------------------------------
foreach ($rid in $targets) {
    Write-Host "`n=== dotnet publish win-$rid ===" -ForegroundColor Cyan
    $out = "dist\$rid"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }

    $args = @(
        'publish', 'SCVPN\SCVPN.csproj',
        '-c', 'Release',
        '-r', "win-$rid",
        '--self-contained', 'true',
        '-o', $out
    )
    if (-not $NoR2R) { $args += '-p:PublishReadyToRun=true' }

    & dotnet @args
    if ($LASTEXITCODE -ne 0) { throw "Сборка win-$rid не удалась" }

    if (-not (Test-Path "$out\SCVPN.exe")) { throw "Нет $out\SCVPN.exe" }
    $size = [math]::Round((Get-ChildItem $out -Recurse | Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Host "  готово: $out ($size МБ)" -ForegroundColor Green
}

# --- установщик ------------------------------------------------------------
if (-not $NoInstaller) {
    foreach ($rid in $targets) {
        Write-Host "`n=== ISCC $rid ===" -ForegroundColor Cyan
        & $iscc "/DMyArch=$rid" "/DMyVersion=$version" 'setup\installer.iss'
        if ($LASTEXITCODE -ne 0) { throw "Установщик для $rid не собрался" }
    }
    Write-Host "`nУстановщики в dist_installer\" -ForegroundColor Green
    Get-ChildItem 'dist_installer\*.exe' | ForEach-Object {
        Write-Host ("  {0}  ({1:N1} МБ)" -f $_.Name, ($_.Length / 1MB))
    }
}
