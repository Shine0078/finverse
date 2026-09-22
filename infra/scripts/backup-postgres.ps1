param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^age1[0-9a-z]+$')]
  [string]$AgeRecipient,
  [string]$Destination = (Join-Path $PSScriptRoot '..\backups'),
  [ValidateRange(1, 3650)]
  [int]$RetentionDays = 35,
  [string]$AgeBinary = 'age'
)

$ErrorActionPreference = 'Stop'
$runningOnWindows = ($env:OS -eq 'Windows_NT') -or [bool]$IsWindows
$ageCommand = Get-Command $AgeBinary -ErrorAction SilentlyContinue
if (-not $ageCommand) { throw "The $AgeBinary binary is required for encrypted backups." }
$resolvedDestination = [System.IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Force -Path $resolvedDestination | Out-Null

if ($runningOnWindows) {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls $resolvedDestination /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not restrict backup directory ACLs.' }
} elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
  & chmod 700 $resolvedDestination
  if ($LASTEXITCODE -ne 0) { throw 'Could not restrict backup directory permissions.' }
}

$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
$archive = Join-Path $resolvedDestination "finverse-$stamp.dump.age"
$plainArchive = Join-Path $resolvedDestination ".finverse-$stamp.dump"
$temporaryArchive = Join-Path $resolvedDestination ".finverse-$stamp.dump.age"
$encryptionSucceeded = $false

try {
  & pg_dump --dbname=$DatabaseUrl --format=custom --compress=9 --file=$plainArchive
  if ($LASTEXITCODE -ne 0) { throw "pg_dump failed with exit code $LASTEXITCODE" }
  if (-not $runningOnWindows -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
    & chmod 600 $plainArchive
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary backup dump.' }
  }

  & $ageCommand.Source --encrypt --recipient $AgeRecipient --output $temporaryArchive $plainArchive
  if ($LASTEXITCODE -ne 0) { throw "age encryption failed with exit code $LASTEXITCODE" }
  $encryptionSucceeded = $true
} finally {
  Remove-Item -LiteralPath $plainArchive -Force -ErrorAction SilentlyContinue
  if (-not $encryptionSucceeded) {
    Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue
  }
}
try {
  Move-Item -LiteralPath $temporaryArchive -Destination $archive -Force
} catch {
  Remove-Item -LiteralPath $temporaryArchive, $archive -Force -ErrorAction SilentlyContinue
  throw
}

if ($runningOnWindows) {
  & icacls $archive /inheritance:r /grant:r "${identity}:F" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw 'Could not restrict backup archive ACLs; archive removed.'
  }
} elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
  & chmod 600 $archive
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw 'Could not restrict backup archive permissions; archive removed.'
  }
}

$archiveStream = [System.IO.File]::OpenRead($archive)
try {
  $headerBytes = New-Object byte[] 24
  $readCount = $archiveStream.Read($headerBytes, 0, $headerBytes.Length)
  if ($readCount -eq 0) { throw 'Backup archive is empty.' }
  $ageHeader = [System.Text.Encoding]::ASCII.GetString($headerBytes, 0, $readCount)
} finally { $archiveStream.Dispose() }
if (-not $ageHeader.StartsWith('age-encryption.org/v1')) {
  Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  throw 'Backup archive does not have a valid age encryption header.'
}

$cutoff = (Get-Date).AddDays(-$RetentionDays)
Get-ChildItem -LiteralPath $resolvedDestination -Filter 'finverse-*.dump.age' -File |
  Where-Object LastWriteTime -lt $cutoff |
  Remove-Item -Force

Write-Output $archive
