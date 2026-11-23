# Requires PowerShell 7 for its bundled .NET cryptography APIs.
param(
    [Parameter(Mandatory)][string[]]$ServerName,
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'PrivateNAS')
)
$ErrorActionPreference = 'Stop'
$folder = $OutputDirectory
$certPath = Join-Path $folder 'server-cert.pem'
$keyPath = Join-Path $folder 'server-key.pem'
if ((Test-Path $certPath) -or (Test-Path $keyPath)) { throw 'A TLS identity already exists.' }
$rsa = [Security.Cryptography.RSA]::Create(3072)
try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=PrivateNAS', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    foreach ($name in $ServerName) {
        $address = $null
        if ([Net.IPAddress]::TryParse($name, [ref]$address)) { $san.AddIpAddress($address) }
        else { $san.AddDnsName($name) }
    }
    $request.CertificateExtensions.Add($san.Build())
    $usages = [Security.Cryptography.OidCollection]::new()
    [void]$usages.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
    $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(365))
    try {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [IO.File]::WriteAllText($keyPath, $rsa.ExportPkcs8PrivateKeyPem())
        try { [IO.File]::WriteAllText($certPath, $cert.ExportCertificatePem()) }
        catch { Remove-Item -LiteralPath $keyPath; throw }
        Write-Output ('SHA-256: ' + $cert.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256))
    } finally { $cert.Dispose() }
} finally { $rsa.Dispose() }
