# =====================================================================
# Prueba tecnica Instacredit - Variante Windows / Azure SQL Database
# run_all.ps1
#
# Ejecuta la solucion completa en el orden esperado, dos veces donde se
# prueba idempotencia (incremental, extractor e integracion API).
#
# Uso local:
#   .\run_all.ps1
#   .\run_all.ps1 -Server "localhost,1433" -User sa -Password 'Clave'
#
# Uso Azure SQL Database (la base debe existir):
#   .\run_all.ps1 -Azure -Server "mi-servidor.database.windows.net" `
#       -Database "dw.DatosPrueba" -SrcDatabase DatosPrueba -User sqladmin -Password 'Clave'
#
# Los valores faltantes se toman de python\.env o de variables de entorno.
# =====================================================================
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Server,
    [int]$Port = 0,
    [string]$Database,
    [string]$SrcDatabase,
    [string]$User,
    [string]$Password,
    [string]$Driver,
    [string]$DataDir,
    [string]$InputJson,
    [switch]$Azure,
    [switch]$SkipDbCreate
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Read-DotEnv {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith("#")) { continue }
        $equals = $text.IndexOf("=")
        if ($equals -lt 1) { continue }
        $key = $text.Substring(0, $equals).Trim()
        $value = $text.Substring($equals + 1).Trim()
        if ($value.Length -ge 2 -and (
            ($value.StartsWith("'") -and $value.EndsWith("'")) -or
            ($value.StartsWith('"') -and $value.EndsWith('"')))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $map[$key] = $value
    }
    return $map
}

$EnvMap = Read-DotEnv (Join-Path $Root "python\.env")

function Get-Setting {
    param([string]$Name, [string]$Default = "")
    if ($EnvMap.ContainsKey($Name) -and $EnvMap[$Name]) { return [string]$EnvMap[$Name] }
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return [string]$value }
    return $Default
}

if (-not $Server)   { $Server   = Get-Setting "DB_SERVER" "localhost" }
if ($Port -le 0)    { $Port     = [int](Get-Setting "DB_PORT" "1433") }
if (-not $Database)    { $Database    = Get-Setting "DB_NAME" "dw.DatosPrueba" }
if (-not $SrcDatabase) { $SrcDatabase = Get-Setting "SRC_DB_NAME" "DatosPrueba" }
if (-not $User)     { $User     = Get-Setting "DB_USER" "sa" }
if (-not $Password) { $Password = Get-Setting "DB_PASSWORD" "" }
if (-not $Driver)   { $Driver   = Get-Setting "DB_DRIVER" "ODBC Driver 18 for SQL Server" }
if (-not $DataDir)  { $DataDir  = Get-Setting "DATA_DIR" "Instacredit\Paquete_datos_prueba_tecnica" }
if (-not $InputJson) {
    $InputJson = Get-Setting "INPUT_JSON_PATH" "Instacredit\Paquete_datos_prueba_tecnica\api_pagos_externos.json"
}
if (-not $Password) { throw "Falta DB_PASSWORD. Configure python\.env o use -Password." }

$env:DB_SERVER    = $Server
$env:DB_PORT      = [string]$Port
$env:DB_NAME      = $Database
$env:SRC_DB_NAME  = $SrcDatabase
$env:DB_USER      = $User
$env:DB_PASSWORD  = $Password
$env:DB_DRIVER    = $Driver
$env:DATA_DIR     = $DataDir
$env:INPUT_JSON_PATH = $InputJson

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "No se encontro sqlcmd en PATH. Instale sqlcmd o SSMS."
}

$ServerSpec = $Server
if ($Server -notmatch '[,\\]') { $ServerSpec = "$Server,$Port" }

$TrustCert = (Get-Setting "DB_TRUST_CERT" "no").ToLowerInvariant()
$SqlArgsBase = @(
    "-S", $ServerSpec,
    "-U", $User,
    "-P", $Password,
    "-b",
    "-f", "65001"
)
if ($TrustCert -in @("1", "true", "yes", "y", "si", "sí")) { $SqlArgsBase += "-C" }

function Invoke-SqlFile {
    param([string]$File, [string]$DatabaseName)
    $path = Join-Path $Root $File
    if (-not (Test-Path -LiteralPath $path)) { throw "No existe el script $File" }
    Write-Host "`n==> sqlcmd -d $DatabaseName -i $File" -ForegroundColor Cyan
    $sqlArgs = $SqlArgsBase + @("-d", $DatabaseName, "-i", $path)
    & sqlcmd @sqlArgs
    if ($LASTEXITCODE -ne 0) { throw "Fallo $File (exit $LASTEXITCODE)." }
}

$Python = Join-Path $Root "python\.venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $Python)) { $Python = "python" }

function Invoke-PythonScript {
    param([string]$Script, [string[]]$Arguments = @())
    $path = Join-Path $Root "python\$Script"
    if (-not (Test-Path -LiteralPath $path)) { throw "No existe python\$Script" }
    Write-Host "`n==> python $Script $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Python $path @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Fallo python/$Script (exit $LASTEXITCODE)." }
}

Write-Host "Raiz: $Root"
Write-Host "Servidor: $ServerSpec | Origen: $SrcDatabase | DW: $Database | Azure: $($Azure.IsPresent)"

if ($Azure) {
    Write-Host "Azure SQL Database: se omite 00_crear_base_datos.sql (la base debe existir)." -ForegroundColor Yellow
} elseif (-not $SkipDbCreate) {
    Invoke-SqlFile "sql\00_crear_base_datos.sql" "master"
}

Invoke-SqlFile "sql\00_cargar_origen.sql" $SrcDatabase
Invoke-PythonScript "load_src.py" @("--data-dir", $DataDir)

Invoke-SqlFile "sql\01_dw_ddl.sql" $Database
Invoke-SqlFile "sql\02_carga_inicial.sql" $Database

Invoke-SqlFile "sql\03_carga_incremental.sql" $Database
Invoke-SqlFile "sql\03_carga_incremental.sql" $Database

Invoke-PythonScript "extractor_pagos.py"
Invoke-PythonScript "extractor_pagos.py"

Invoke-SqlFile "sql\06_integrar_pagos_externos.sql" $Database
Invoke-SqlFile "sql\06_integrar_pagos_externos.sql" $Database

Invoke-SqlFile "sql\04_consultas.sql" $Database
Invoke-SqlFile "sql\05_validaciones.sql" $Database

Write-Host "`nProceso completado. Revise el resumen de 05_validaciones.sql." -ForegroundColor Green
