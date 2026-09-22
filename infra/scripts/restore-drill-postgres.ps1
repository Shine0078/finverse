param(
  [Parameter(Mandatory = $true)]
  [string]$Archive,
  [Parameter(Mandatory = $true)]
  [string]$RestoreDatabaseUrl,
  [Parameter(Mandatory = $true)]
  [string]$AgeIdentity,
  [string]$AgeBinary = 'age'
)

$ErrorActionPreference = 'Stop'
$runningOnWindows = ($env:OS -eq 'Windows_NT') -or [bool]$IsWindows
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$identityPath = (Resolve-Path -LiteralPath $AgeIdentity).Path
$ageCommand = Get-Command $AgeBinary -ErrorAction SilentlyContinue
if (-not $ageCommand) { throw "The $AgeBinary binary is required to decrypt backups." }
if ($archivePath -notmatch '\.age$') { throw 'Only age-encrypted backup archives are accepted.' }
$databaseName = ([Uri]$RestoreDatabaseUrl).AbsolutePath.Trim('/')

if ($databaseName -notmatch '_restore_test$') {
  throw 'RestoreDatabaseUrl database name must end in _restore_test; refusing to overwrite any other database.'
}

$restoreDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "finverse-restore-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $restoreDirectory | Out-Null
$plainArchive = Join-Path $restoreDirectory 'restore.dump'
try {
  if ($runningOnWindows) {
    $restoreIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $restoreDirectory /inheritance:r /grant:r "${restoreIdentity}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary restore dump ACL.' }
  } elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
    & chmod 700 $restoreDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary restore dump permissions.' }
  }

  & $ageCommand.Source --decrypt --identity $identityPath --output $plainArchive $archivePath
  if ($LASTEXITCODE -ne 0) { throw "age decryption failed with exit code $LASTEXITCODE" }

  & pg_restore --exit-on-error --dbname=$RestoreDatabaseUrl --clean --if-exists --no-owner $plainArchive
  if ($LASTEXITCODE -ne 0) { throw "pg_restore failed with exit code $LASTEXITCODE" }
} finally {
  Remove-Item -LiteralPath $restoreDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

& psql $RestoreDatabaseUrl --no-psqlrc --tuples-only --command='SELECT count(*) FROM schema_migrations;'
if ($LASTEXITCODE -ne 0) { throw 'Restored database validation query failed.' }

Write-Output "Restore drill completed in $databaseName"
