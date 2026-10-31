# 邻跃 LINYUE DEV13D2E19-C
# Create one NEW 32 MiB unimportant fixture under the user's TEMP directory.
# No overwriting, no deletion, no application data access, no admin privileges.
$ErrorActionPreference = 'Stop'
$folder = Join-Path ([System.IO.Path]::GetTempPath()) 'LinYue_E19C_TestData'
[System.IO.Directory]::CreateDirectory($folder) | Out-Null
$path = Join-Path $folder ('E19C_32MiB_' + [guid]::NewGuid().ToString('N') + '.bin')
$stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$buffer = New-Object byte[] (1024 * 1024)
try {
    for ($i = 0; $i -lt 32; $i++) {
        $rng.GetBytes($buffer)
        $stream.Write($buffer, 0, $buffer.Length)
    }
    $stream.Flush()
} finally {
    $stream.Dispose()
    $rng.Dispose()
}
Write-Host 'Test file:' $path
Write-Host 'Size:' ([System.IO.FileInfo]$path).Length 'bytes'
Get-FileHash -LiteralPath $path -Algorithm SHA256 | Format-List Path,Hash
Write-Host 'This script did not delete or overwrite any file. Keep the path for SHA256 comparison.'
