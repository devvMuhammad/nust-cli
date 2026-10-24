# Installs nust on Windows. No admin needed. Works in Windows PowerShell 5.1 and PowerShell 7.
#
#   irm https://raw.githubusercontent.com/devvMuhammad/nust-cli/main/install.ps1 | iex
#
# Optional: $env:NUST_VERSION = 'v0.1.0' to pin a release, $env:NUST_INSTALL_DIR to pick the
# folder (default %LOCALAPPDATA%\Programs\nust), $env:NUST_BASE_URL to download from elsewhere.

$ErrorActionPreference = 'Stop'

function Install-Nust {
    # PowerShell 5.1 defaults to old TLS versions that GitHub rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # The progress bar makes downloads very slow on 5.1.
    $ProgressPreference = 'SilentlyContinue'

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'nust is only built for 64-bit Windows.' }

    $repo = 'devvMuhammad/nust-cli'
    $asset = 'nust-windows-x64.exe'
    if ($env:NUST_BASE_URL) {
        $base = $env:NUST_BASE_URL.TrimEnd('/')
    } elseif ($env:NUST_VERSION) {
        $base = "https://github.com/$repo/releases/download/v$($env:NUST_VERSION.TrimStart('v'))"
    } else {
        $base = "https://github.com/$repo/releases/latest/download"
    }
    $dir = if ($env:NUST_INSTALL_DIR) { $env:NUST_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\nust' }
    $target = Join-Path $dir 'nust.exe'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('nust-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null

    try {
        Write-Host 'Downloading nust for Windows x64...'
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile (Join-Path $work $asset)
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS')

        $want = $null
        foreach ($line in Get-Content (Join-Path $work 'SHA256SUMS')) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $asset) { $want = $parts[0].ToLowerInvariant(); break }
        }
        if (-not $want) { throw "SHA256SUMS has no entry for $asset." }
        $got = (Get-FileHash -Algorithm SHA256 (Join-Path $work $asset)).Hash.ToLowerInvariant()
        if ($got -ne $want) { throw 'The download is corrupted (checksum mismatch). Nothing was installed.' }

        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $stage = "$target.new"
        Copy-Item (Join-Path $work $asset) $stage -Force
        # A running nust.exe cannot be overwritten, but it can be renamed out of the way.
        try { Move-Item $stage $target -Force } catch {
            Remove-Item "$target.old" -Force -ErrorAction SilentlyContinue
            Move-Item $target "$target.old" -Force
            Move-Item $stage $target -Force
        }
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $version = (& $target version 2>$null | Out-String).Trim()
    Write-Host "Installed $version to $target"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @(if ($userPath) { $userPath -split ';' | Where-Object { $_ } })
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $dir) -join ';'), 'User')
        Write-Host "Added $dir to your PATH."
        Write-Host ''
        Write-Host 'Open a new terminal, then run: nust login'
    } else {
        Write-Host ''
        Write-Host 'Next: nust login'
    }
}

Install-Nust
