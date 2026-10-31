# Read-only integrity comparison. Does not copy, move, delete or modify either file.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Original,
  [Parameter(Mandatory=$true)][string]$Copy
)
$ErrorActionPreference = 'Stop'
try {
  $left = (Resolve-Path -LiteralPath $Original -ErrorAction Stop).ProviderPath
  $right = (Resolve-Path -LiteralPath $Copy -ErrorAction Stop).ProviderPath
  if ($left -eq $right) {
    Write-Error 'Original and Copy resolve to the same path; use distinct files.'
    exit 2
  }
  $a = Get-Item -LiteralPath $left
  $b = Get-Item -LiteralPath $right
  if ($a.PSIsContainer -or $b.PSIsContainer) {
    Write-Error 'Both paths must be regular files.'
    exit 2
  }
  $hashA = (Get-FileHash -LiteralPath $left -Algorithm SHA256).Hash
  $hashB = (Get-FileHash -LiteralPath $right -Algorithm SHA256).Hash
  Write-Host ('Original: {0}' -f $left)
  Write-Host ('    Size: {0} bytes; SHA-256: {1}' -f $a.Length, $hashA)
  Write-Host ('Copy:     {0}' -f $right)
  Write-Host ('    Size: {0} bytes; SHA-256: {1}' -f $b.Length, $hashB)
  if ($a.Length -ne $b.Length -or $hashA -ne $hashB) {
    Write-Host 'FAIL: sizes or hashes differ.' -ForegroundColor Red
    exit 1
  }
  Write-Host 'PASS: matching size and SHA-256.' -ForegroundColor Green
  exit 0
} catch {
  Write-Error $_
  exit 2
}
