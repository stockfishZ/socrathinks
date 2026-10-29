<#
.SYNOPSIS
    Syncs a live lesson artifact or content into an Obsidian vault and optionally launches Obsidian.

.DESCRIPTION
    Integrates Antigravity's teaching workflow with an Obsidian knowledge base.
    Ensures the target vault folder, .obsidian directory, and Lessons folder are properly initialized.
    Pre-registers the vault in %APPDATA%\obsidian\obsidian.json so Obsidian loads without onboarding dialogs.
    Can write raw content or mirror a markdown file, and can launch/focus Obsidian via obsidian:// URI protocol.

.PARAMETER Topic
    The slug, title, or filename of the lesson note.

.PARAMETER Content
    Optional raw markdown content to write or append.

.PARAMETER ContentFile
    Optional path to a markdown file (e.g. Antigravity artifact) to copy/sync from.

.PARAMETER VaultPath
    The root path to the Obsidian vault. Defaults to $env:OBSIDIAN_VAULT_PATH or ~/Documents/ObsidianVault.

.PARAMETER Open
    Switch to launch or focus Obsidian directly to the active lesson note.

.PARAMETER Append
    Switch to append content rather than overwrite.

.EXAMPLE
    .\sync-obsidian-lesson.ps1 -Topic "Nyquist_Shannon" -ContentFile "C:\path\to\lesson.md" -Open
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Topic,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$Content,

    [Parameter(Mandatory = $false)]
    [string]$ContentFile,

    [Parameter(Mandatory = $false)]
    [string]$VaultPath = $(
        if ($env:OBSIDIAN_VAULT_PATH) {
            $env:OBSIDIAN_VAULT_PATH
        } else {
            $docs = [Environment]::GetFolderPath('MyDocuments')
            if ([string]::IsNullOrWhiteSpace($docs)) {
                $docs = Join-Path $HOME "Documents"
            }
            Join-Path $docs "ObsidianVault"
        }
    ),

    [Parameter(Mandatory = $false)]
    [switch]$Open,

    [Parameter(Mandatory = $false)]
    [switch]$Append
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# 1. Resolve and normalize vault path
$resolvedVaultPath = [System.IO.Path]::GetFullPath($VaultPath)
$dotObsidian = Join-Path $resolvedVaultPath ".obsidian"
$lessonsDir = Join-Path $resolvedVaultPath "Lessons"
$circuitsDir = Join-Path (Join-Path $lessonsDir "assets") "circuits"

# Ensure directories exist
if (-not (Test-Path -LiteralPath $resolvedVaultPath)) {
    New-Item -ItemType Directory -Path $resolvedVaultPath -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $dotObsidian)) {
    New-Item -ItemType Directory -Path $dotObsidian -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $lessonsDir)) {
    New-Item -ItemType Directory -Path $lessonsDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $circuitsDir)) {
    New-Item -ItemType Directory -Path $circuitsDir -Force | Out-Null
}

# Optional default app.json in .obsidian to configure basic editor settings
$appJsonPath = Join-Path $dotObsidian "app.json"
if (-not (Test-Path -LiteralPath $appJsonPath)) {
    $defaultAppJson = @{
        showLineNumber = $true
        livePreview    = $true
    } | ConvertTo-Json
    Set-Content -LiteralPath $appJsonPath -Value $defaultAppJson -Encoding UTF8
}

# 2. Register Vault in Obsidian config
if ($IsWindows -or $env:OS -like "*Windows*") {
    $obsidianAppData = Join-Path $env:APPDATA "obsidian"
} elseif ($IsMacOS) {
    $obsidianAppData = Join-Path $HOME "Library/Application Support/obsidian"
} else {
    $obsidianAppData = Join-Path $HOME ".config/obsidian"
}
$obsidianConfigFile = Join-Path $obsidianAppData "obsidian.json"

if (-not (Test-Path -LiteralPath $obsidianAppData)) {
    New-Item -ItemType Directory -Path $obsidianAppData -Force | Out-Null
}

$vaultRegistered = $false
$existingConfig = $null

if (Test-Path -LiteralPath $obsidianConfigFile) {
    try {
        $rawConfig = Get-Content -LiteralPath $obsidianConfigFile -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($rawConfig)) {
            $existingConfig = $rawConfig | ConvertFrom-Json
            if ($existingConfig.vaults) {
                foreach ($prop in $existingConfig.vaults.PSObject.Properties) {
                    if ($prop.Value -and $prop.Value.path) {
                        $existingNorm = [System.IO.Path]::GetFullPath($prop.Value.path).TrimEnd('\', '/')
                        $targetNorm = $resolvedVaultPath.TrimEnd('\', '/')
                        if ($existingNorm -ieq $targetNorm) {
                            $vaultRegistered = $true
                            break
                        }
                    }
                }
            }
        }
    } catch {
        Write-Warning "Could not parse existing obsidian.json: $_"
    }
}

if (-not $vaultRegistered) {
    # Generate 16-hex character vault id
    $rand = New-Object System.Random
    $bytes = New-Object byte[] 8
    $rand.NextBytes($bytes)
    $vaultId = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $vaultEntry = [ordered]@{
        path = $resolvedVaultPath
        ts   = $nowMs
        open = $true
    }

    if ($existingConfig) {
        if (-not $existingConfig.vaults) {
            $existingConfig | Add-Member -MemberType NoteProperty -Name "vaults" -Value (New-Object PSObject)
        }
        $existingConfig.vaults | Add-Member -MemberType NoteProperty -Name $vaultId -Value (New-Object PSObject -Property $vaultEntry)
        $existingConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $obsidianConfigFile -Encoding UTF8
    } else {
        $newConfig = [ordered]@{
            vaults = [ordered]@{
                $vaultId = $vaultEntry
            }
        }
        $newConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $obsidianConfigFile -Encoding UTF8
    }
    Write-Host "Registered vault '$resolvedVaultPath' in $obsidianConfigFile"
}

# 3. Clean topic / note name
$cleanTopic = $Topic
if ($cleanTopic.EndsWith(".md", [System.StringComparison]::OrdinalIgnoreCase)) {
    $cleanTopic = $cleanTopic.Substring(0, $cleanTopic.Length - 3)
}
$invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
foreach ($ch in $invalidChars) {
    $cleanTopic = $cleanTopic.Replace($ch, [char]'_')
}
$cleanTopic = $cleanTopic.Trim()
if ([string]::IsNullOrWhiteSpace($cleanTopic)) {
    $cleanTopic = "Untitled_Lesson"
}

$noteFilePath = Join-Path $lessonsDir "$cleanTopic.md"

# 4. Resolve Content to Write / Append
$textToWrite = ""
if ($ContentFile) {
    $resolvedContentFile = [System.IO.Path]::GetFullPath($ContentFile)
    if (Test-Path -LiteralPath $resolvedContentFile) {
        $textToWrite = Get-Content -LiteralPath $resolvedContentFile -Raw -Encoding UTF8
    } else {
        Write-Warning "Specified ContentFile does not exist: $resolvedContentFile"
    }
}

if ($Content) {
    if (-not [string]::IsNullOrEmpty($textToWrite)) {
        $textToWrite = $textToWrite + "`r`n`r`n" + $Content
    } else {
        $textToWrite = $Content
    }
}

# Default starter template if file does not exist and no content provided
if ([string]::IsNullOrEmpty($textToWrite) -and -not (Test-Path -LiteralPath $noteFilePath)) {
    $textToWrite = "# $cleanTopic`r`n`r`n> Initialized on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
}

# Write / Append to note file
if (-not [string]::IsNullOrEmpty($textToWrite)) {
    if ($Append -and (Test-Path -LiteralPath $noteFilePath)) {
        Add-Content -LiteralPath $noteFilePath -Value "`r`n$textToWrite" -Encoding UTF8
        Write-Host "Appended content to $noteFilePath"
    } else {
        Set-Content -LiteralPath $noteFilePath -Value $textToWrite -Encoding UTF8
        Write-Host "Saved lesson note to $noteFilePath"
    }
}

# 5. Build Obsidian Protocol URI and Open if Requested
$vaultFolderName = [System.IO.Path]::GetFileName($resolvedVaultPath)
$escapedVault = [System.Uri]::EscapeDataString($vaultFolderName)
$escapedFile = [System.Uri]::EscapeDataString("Lessons/$cleanTopic")
$obsidianUri = "obsidian://open?vault=$escapedVault&file=$escapedFile"

if ($Open) {
    Write-Host "Opening Obsidian URI: $obsidianUri"
    $possibleExePaths = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Obsidian\Obsidian.exe"),
        (Join-Path $env:LOCALAPPDATA "Obsidian\Obsidian.exe"),
        "C:\Program Files\Obsidian\Obsidian.exe"
    )
    $foundExe = $possibleExePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    $launched = $false
    if ($foundExe) {
        try {
            Start-Process -FilePath $foundExe -ArgumentList "`"$obsidianUri`"" -ErrorAction Stop
            $launched = $true
            Write-Host "Launched Obsidian via executable: $foundExe"
        } catch {
            Write-Warning "Direct launch via $foundExe failed: $_"
        }
    }

    if (-not $launched) {
        try {
            Start-Process -FilePath "explorer.exe" -ArgumentList "`"$obsidianUri`"" -ErrorAction Stop
            $launched = $true
            Write-Host "Activated Obsidian via shell protocol: $obsidianUri"
        } catch {
            Write-Warning "Protocol activation via explorer failed: $_"
        }
    }
}

return [PSCustomObject]@{
    VaultPath = $resolvedVaultPath
    NotePath  = $noteFilePath
    Topic     = $cleanTopic
    Uri       = $obsidianUri
    Status    = "Success"
}
