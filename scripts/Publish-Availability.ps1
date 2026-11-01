#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Publish')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [string]$ResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [string]$AppName,
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [string]$ExpectedAppPrivateIp,
    [Parameter(Mandatory, ParameterSetName = 'Package')]
    [switch]$PackageOnly,
    [Parameter(Mandatory, ParameterSetName = 'Package')]
    [string]$PackagePath
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\logicapp'
$entries = @('host.json', 'parameters.json', 'availability/workflow.json')
foreach ($entry in $entries) {
    $file = Join-Path $source $entry.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required package file missing: $entry" }
    [void](Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -ErrorAction Stop)
}
$temporaryPackage = $PSCmdlet.ParameterSetName -eq 'Publish'
if ($temporaryPackage) {
    $PackagePath = Join-Path ([IO.Path]::GetTempPath()) ("availability-$([guid]::NewGuid().ToString('N')).zip")
} else {
    $PackagePath = [IO.Path]::GetFullPath($PackagePath)
}
if (Test-Path -LiteralPath $PackagePath) { throw 'Package already exists; choose a new path' }

$archive = $null
$client = $null
$handler = $null
$token = $null
$packageComplete = $false
try {
    $archive = [IO.Compression.ZipFile]::Open($PackagePath, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($entry in $entries) {
        $file = Join-Path $source $entry.Replace('/', '\')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file, $entry)
    }
    $archive.Dispose()
    $archive = $null
    $packageComplete = $true
    if ($PackageOnly) {
        Write-Output "Package created: $PackagePath"
        return
    }

    $expected = [Net.IPAddress]::Parse($ExpectedAppPrivateIp)
    $ip = $expected.GetAddressBytes()
    if ($expected.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        -not ($ip[0] -eq 10 -or ($ip[0] -eq 172 -and $ip[1] -ge 16 -and $ip[1] -le 31) -or
              ($ip[0] -eq 192 -and $ip[1] -eq 168))) {
        throw 'ExpectedAppPrivateIp must be an actual private IPv4 endpoint address'
    }
    $appJson = az webapp show --resource-group $ResourceGroup --name $AppName --query "{enabledHostNames:enabledHostNames,publicNetworkAccess:publicNetworkAccess}" --output json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the selected app from the current Azure CLI context' }
    $app = $appJson | ConvertFrom-Json
    if ($app.publicNetworkAccess -ne 'Disabled') { throw 'Selected app must have public network access disabled' }
    $scmNames = @($app.enabledHostNames | Where-Object {
        $_ -match '^[a-zA-Z0-9-]+\.scm(?:\.[a-zA-Z0-9-]+)?\.azurewebsites\.net$'
    })
    if ($scmNames.Count -ne 1) { throw 'Expected one native WS1 SCM hostname in Azure public cloud' }
    $scmHost = $scmNames[0]
    $addresses = @([Net.Dns]::GetHostAddresses($scmHost))
    if ($addresses.Count -eq 0 -or @($addresses | Where-Object { -not $_.Equals($expected) }).Count -gt 0) {
        throw 'SCM DNS does not resolve exclusively to the expected app Private Endpoint address'
    }

    $token = az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'Cannot obtain Entra ARM token' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $content = [Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($PackagePath))
    $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/zip')
    $response = $null
    try {
        $response = $client.PostAsync("https://$scmHost/api/zipdeploy?isAsync=true", $content).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 202) {
            throw "Private SCM ZIP upload returned HTTP $([int]$response.StatusCode); deployment not verified"
        }
        $location = $response.Headers.Location
        if ($null -eq $location) { throw 'SCM did not return a deployment status URL' }
        $pollUri = [Uri]::new([Uri]"https://$scmHost/", $location)
        if ($pollUri.Scheme -ne 'https' -or $pollUri.Host -ne $scmHost -or $pollUri.Port -ne 443 -or
            $pollUri.UserInfo -or $pollUri.AbsolutePath -notlike '/api/deployments/*') {
            throw 'Unexpected status URL; bearer token will not be sent'
        }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $content.Dispose()
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalMinutes -lt 5) {
        $statusResponse = $null
        try {
            $statusResponse = $client.GetAsync($pollUri).GetAwaiter().GetResult()
            if (-not $statusResponse.IsSuccessStatusCode) {
                throw "SCM status query returned HTTP $([int]$statusResponse.StatusCode)"
            }
            $deployment = $statusResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            if ($deployment.status -eq 3) { throw 'SCM reports a failed deployment; inspect private deployment logs' }
            if ($deployment.status -eq 4 -and $deployment.complete -eq $true) {
                Write-Output "PASS: private Entra ZIP deployment completed; id=$($deployment.id)"
                return
            }
        } finally {
            if ($null -ne $statusResponse) { $statusResponse.Dispose() }
        }
        Start-Sleep -Seconds 10
    }
    throw 'Deployment not confirmed within the bounded wait; inspect the existing deployment before retrying'
} finally {
    if ($null -ne $archive) { $archive.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $handler) { $handler.Dispose() }
    $token = $null
    if (($temporaryPackage -or -not $packageComplete) -and (Test-Path -LiteralPath $PackagePath)) {
        Remove-Item -LiteralPath $PackagePath
    }
}
