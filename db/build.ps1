<#
.SYNOPSIS
  Builds the Reporting Studio database from scratch and runs the test suite.

.EXAMPLE
  $env:PGPASSWORD = '<postgres superuser password>'
  .\db\build.ps1 -Reset          # drop + rebuild + test
  .\db\build.ps1 -TestOnly       # just re-run tests

.NOTES
  * Superuser password is read from $env:PGPASSWORD only - never stored.
  * Passwords for the 7 application roles are generated once into db\.env
    (git-ignored) and reused on later builds. The backend reads the same file.
#>
param(
    [switch]$Reset,
    [switch]$TestOnly,
    [string]$DbName    = 'reporting_studio',
    [string]$PgHost    = 'localhost',
    [int]   $Port      = 5432,
    [string]$SuperUser = 'postgres'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

if (-not $env:PGPASSWORD) { throw 'Set $env:PGPASSWORD to the postgres superuser password first.' }

$psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
if (-not $psql) { $psql = 'C:\Program Files\PostgreSQL\16\bin\psql.exe' }
if (-not (Test-Path $psql)) { throw "psql not found. Add PostgreSQL bin to PATH." }

function Invoke-Psql([string]$db, [string[]]$extra) {
    # psql writes NOTICEs to stderr; Windows PowerShell would treat them as errors.
    # Success/failure is decided by the exit code instead.
    $ErrorActionPreference = 'Continue'
    & $psql -h $PgHost -p $Port -U $SuperUser -d $db -X -q -v ON_ERROR_STOP=1 @extra
    if ($LASTEXITCODE -ne 0) { throw "psql failed ($($extra -join ' '))" }
}

if (-not $TestOnly -and -not $Reset) {
    # Scripts 01-06 create objects, they don't migrate them; refuse to half-run.
    $exists = & $psql -h $PgHost -p $Port -U $SuperUser -d postgres -X -Atc "SELECT 1 FROM pg_database WHERE datname = '$DbName'"
    if ($exists -eq '1') { throw "Database '$DbName' already exists. Use -Reset to rebuild it (drops all data) or -TestOnly." }
}

if (-not $TestOnly) {
    # --- role passwords: create db\.env once, then reuse -------------------
    $roles   = 'iam_app','erp_app','aml_app','lending_app','erp_ro','aml_ro','lending_ro'
    $envFile = Join-Path $here '.env'
    $vals = @{}
    if (Test-Path $envFile) {
        Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } |
            ForEach-Object { $vals[$Matches[1]] = $Matches[2] }
    }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    foreach ($r in $roles) {
        $key = ($r.ToUpper() + '_PASSWORD')
        if (-not $vals[$key]) {
            $bytes = New-Object byte[] 18; $rng.GetBytes($bytes)
            $vals[$key] = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
        }
    }
    $vals['DB_HOST'] = $PgHost; $vals['DB_PORT'] = "$Port"; $vals['DB_NAME'] = $DbName
    ($vals.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) |
        Set-Content -Path $envFile -Encoding ascii

    # --- 00: roles + database (outside a transaction) ----------------------
    Write-Host "== 00 roles and database ($DbName, reset=$($Reset.IsPresent))"
    $vars = @('-v', "db_name=$DbName", '-v', "reset=$($Reset.IsPresent.ToString().ToLower())")
    foreach ($r in $roles) { $vars += @('-v', "pw_$r=$($vals[$r.ToUpper() + '_PASSWORD'])") }
    Invoke-Psql 'postgres' ($vars + @('-f', (Join-Path $here '00_roles_and_database.sql')))

    # --- 01..06: each file is all-or-nothing (-1 = single transaction) -----
    foreach ($f in '01_schemas.sql','02_iam_tables.sql','03_iam_functions.sql',
                   '04_product_pipeline.sql','05_domain_tables.sql','06_seed.sql') {
        Write-Host "== $f"
        Invoke-Psql $DbName @('-1', '-f', (Join-Path $here $f))
    }
}

Write-Host "== tests"
Invoke-Psql $DbName @('-f', (Join-Path $here 'tests\test_all.sql'))
