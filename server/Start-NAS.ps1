param([string]$NodePath = (Get-Command node -CommandType Application).Source)
$ErrorActionPreference = 'Stop'
if (!$NodePath) { throw 'Specify the path to node.exe with -NodePath.' }
& $NodePath (Join-Path $PSScriptRoot 'nas.mjs') --tls
exit $LASTEXITCODE
