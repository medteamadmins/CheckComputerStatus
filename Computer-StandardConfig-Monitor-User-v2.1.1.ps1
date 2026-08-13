#requires -Version 5.1
<#
.SYNOPSIS
    User-facing monitor for THE MEDICAL TEAM standard computer configuration.

.DESCRIPTION
    Deploy this script from Microsoft Intune in the logged-on user context. The
    Intune invocation copies the UI host to the user's LocalAppData folder,
    launches it in a separate STA Windows PowerShell process, and exits promptly.

    The UI reads the configuration state from the explicit 64-bit registry view:

        HKLM\SOFTWARE\TMT\Standard

    It never writes to HKLM and does not require local administrator rights.

.NOTES
    Script version : 2.1.1
    PowerShell     : Windows PowerShell 5.1 or later
    Deployment     : Intune, Run using logged-on credentials = Yes
#>

[CmdletBinding()]
param(
    [switch]$UiHost
)

# Preserve both possible forms of the Intune payload. The normal case provides
# a temporary .ps1 path; some wrappers provide only a ScriptBlock. The monitor
# can install its persistent user copy from either representation.
$script:InitialInvocation = $MyInvocation
$script:InitialScriptPath = $null
$script:InitialCommandPath = $null
$script:InitialScriptText = $null

try {
    $pathVariable = Get-Variable -Name PSCommandPath -ValueOnly -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace([string]$pathVariable)) {
        $script:InitialScriptPath = [string]$pathVariable
    }
}
catch {
    # The ScriptBlock fallback below remains available.
}

try {
    if ([string]::IsNullOrWhiteSpace($script:InitialScriptPath) -and
        -not [string]::IsNullOrWhiteSpace([string]$script:InitialInvocation.PSCommandPath)) {
        $script:InitialScriptPath = [string]$script:InitialInvocation.PSCommandPath
    }
}
catch {
    # Not every host exposes PSCommandPath through InvocationInfo.
}

try {
    $commandPath = [string]$script:InitialInvocation.MyCommand.Path
    if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
        $script:InitialCommandPath = $commandPath
    }
}
catch {
    # ScriptBlock-backed commands do not necessarily expose a Path property.
}

try {
    $initialScriptBlock = $script:InitialInvocation.MyCommand.ScriptBlock
    if ($null -ne $initialScriptBlock -and $null -ne $initialScriptBlock.Ast) {
        $script:InitialScriptText = [string]$initialScriptBlock.Ast.Extent.Text
    }
}
catch {
    # A physical source file can still be copied when available.
}

if ([string]::IsNullOrWhiteSpace($script:InitialScriptText)) {
    try {
        $commandDefinition = [string]$script:InitialInvocation.MyCommand.Definition
        if (-not [string]::IsNullOrWhiteSpace($commandDefinition) -and
            $commandDefinition.Contains('function Start-DetachedUiHost')) {
            $script:InitialScriptText = $commandDefinition
        }
    }
    catch {
        # Installation reports a precise error if neither source is usable.
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RegistrySubKey = 'SOFTWARE\TMT\Standard'
$script:SystemRoot = Join-Path $env:ProgramData 'TMT'
$script:LocalRoot = Join-Path $env:LOCALAPPDATA 'TMT'
$script:InstalledMonitor = Join-Path $script:LocalRoot 'Computer-StandardConfig-Monitor-User.ps1'
$script:SystemLogPath = Join-Path $script:SystemRoot 'Logs\StandardConfig.log'
$script:MonitorLogPath = Join-Path $script:LocalRoot 'Monitor.log'
$script:MonitorVersion = '2.1.1'
$script:ExpectedConfigVersion = '2.1.1'
$script:ExpectedSchemaVersion = 4
$script:ExpectedTotalSteps = 5
$script:ExpectedOutlookAppUserModelId = 'Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookForWindows'
$script:ExpectedTeamsAppUserModelId = 'MSTeams_8wekyb3d8bbwe!MSTeams'
$script:ExpectedWindowsDebloatVersion = '5.5.14'
$script:ExpectedWindowsDebloatCommit = '1d2eddcf4d2983b5ee0ce1a61b238f4e45f4db3f'
$script:ExpectedWindowsDebloatSha256 = '69B3B3DB1E1ED9D74ECF53D619145D4C6990641435B77BDF39C89C924A1A6E97'
$script:ExpectedWindowsDebloatScriptPath = Join-Path $script:SystemRoot 'Downloads\RemoveBloat.ps1'
$script:ExpectedWindowsDebloatLogPath = 'C:\ProgramData\Debloat\Debloat.log'
$script:ExpectedWindowsDebloatSourceUrl = "https://raw.githubusercontent.com/andrew-s-taylor/public/$script:ExpectedWindowsDebloatCommit/De-Bloat/RemoveBloat.ps1"
$script:CompletionMarkerPath = Join-Path $script:LocalRoot 'LastCompletedRunId.txt'
$script:RunValueName = 'TMTStandardConfigMonitor'
$script:MonitorMaximumHours = 26
$script:PollIntervalMilliseconds = 3000
$script:MonitorStarted = Get-Date
$script:TerminalHandled = $false

# -----------------------------------------------------------------------------
# Registry and conversion helpers
# -----------------------------------------------------------------------------
function Write-MonitorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path -LiteralPath $script:LocalRoot -PathType Container)) {
            New-Item -Path $script:LocalRoot -ItemType Directory -Force | Out-Null
        }

        $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('o')), $Level, $Message
        Add-Content -LiteralPath $script:MonitorLogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never block the user notification flow.
    }
}


function Test-PowerShellScriptSyntax {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "Installed monitor script failed syntax validation: $messages"
    }
}

function Install-CurrentScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DestinationPath)

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)
    $candidatePaths = @(
        $script:InitialScriptPath,
        $script:InitialCommandPath
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | Select-Object -Unique

    foreach ($candidatePath in $candidatePaths) {
        try {
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                continue
            }

            $sourceFullPath = [IO.Path]::GetFullPath([string]$candidatePath)
            if ($sourceFullPath -ine $destinationFullPath) {
                Copy-Item -LiteralPath $sourceFullPath -Destination $destinationFullPath -Force
            }

            if (Test-Path -LiteralPath $destinationFullPath -PathType Leaf) {
                Write-MonitorLog -Message "Installed persistent monitor script from '$sourceFullPath'."
                return
            }
        }
        catch {
            Write-MonitorLog -Level WARN -Message "Unable to install the monitor from candidate path '$candidatePath': $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:InitialScriptText)) {
        $utf8WithoutBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [IO.File]::WriteAllText(
            $destinationFullPath,
            $script:InitialScriptText,
            $utf8WithoutBom
        )

        if (-not (Test-Path -LiteralPath $destinationFullPath -PathType Leaf) -or
            (Get-Item -LiteralPath $destinationFullPath).Length -le 0) {
            throw "The monitor ScriptBlock was captured, but '$destinationFullPath' was not written successfully."
        }

        Write-MonitorLog -Message 'Installed persistent monitor script from the captured Intune ScriptBlock because no physical source path was available.'
        return
    }

    throw "Unable to install the persistent monitor at '$destinationFullPath'. The host supplied neither a readable script path nor recoverable ScriptBlock text."
}

function Get-RegistryView {
    if ([Environment]::Is64BitOperatingSystem) {
        return [Microsoft.Win32.RegistryView]::Registry64
    }

    return [Microsoft.Win32.RegistryView]::Registry32
}

function Get-StateSnapshot {
    [CmdletBinding()]
    param()

    $result = @{}
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $stateKey = $baseKey.OpenSubKey($script:RegistrySubKey, $false)
        if ($null -eq $stateKey) {
            return $result
        }

        try {
            foreach ($name in $stateKey.GetValueNames()) {
                $result[$name] = $stateKey.GetValue(
                    $name,
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
            }
        }
        finally {
            $stateKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }

    return $result
}

function Get-SnapshotValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($Snapshot.ContainsKey($Name) -and $null -ne $Snapshot[$Name]) {
        return $Snapshot[$Name]
    }

    return $Default
}

function Get-SnapshotInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Default = 0
    )

    $value = Get-SnapshotValue -Snapshot $Snapshot -Name $Name -Default $Default
    $parsed = 0
    if ([int]::TryParse([string]$value, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function ConvertTo-DateTimeOffset {
    [CmdletBinding()]
    param($Value)

    $result = [DateTimeOffset]::MinValue
    if ($null -ne $Value -and
        [DateTimeOffset]::TryParse([string]$Value, [ref]$result)) {
        return $result
    }

    return $null
}

function Get-NativeWindowsPowerShellPath {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')
    }

    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Test-IsInteractiveUserSession {
    try {
        return [Environment]::UserInteractive -and
            ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0)
    }
    catch {
        return $false
    }
}

function Set-UserRunRegistration {
    [CmdletBinding()]
    param()

    $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $commandLine = "`"$powerShellPath`" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:InstalledMonitor`" -UiHost"

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        (Get-RegistryView)
    )

    try {
        $runKey = $baseKey.CreateSubKey(
            'Software\Microsoft\Windows\CurrentVersion\Run',
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        )
        if ($null -eq $runKey) {
            throw 'Unable to open the current user Run registry key.'
        }

        try {
            $runKey.SetValue(
                $script:RunValueName,
                $commandLine,
                [Microsoft.Win32.RegistryValueKind]::String
            )
        }
        finally {
            $runKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Remove-UserRunRegistration {
    [CmdletBinding()]
    param()

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::CurrentUser,
            (Get-RegistryView)
        )

        try {
            $runKey = $baseKey.OpenSubKey(
                'Software\Microsoft\Windows\CurrentVersion\Run',
                $true
            )
            if ($null -ne $runKey) {
                try {
                    $runKey.DeleteValue($script:RunValueName, $false)
                }
                finally {
                    $runKey.Dispose()
                }
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }
    catch {
        Write-MonitorLog -Level WARN -Message "Unable to remove user Run registration: $($_.Exception.Message)"
    }
}

function Get-CompletionIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Snapshot)

    $runId = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'RunId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        return $runId
    }

    return [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigVersion' -Default 'UnknownRun')
}

function Get-CompletionMarker {
    [CmdletBinding()]
    param()

    try {
        if (Test-Path -LiteralPath $script:CompletionMarkerPath -PathType Leaf) {
            return ([string](Get-Content -LiteralPath $script:CompletionMarkerPath -Raw -ErrorAction Stop)).Trim()
        }
    }
    catch {
        Write-Verbose "Unable to read completion marker: $($_.Exception.Message)"
    }

    return ''
}

function Set-CompletionMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)

    if (-not (Test-Path -LiteralPath $script:LocalRoot -PathType Container)) {
        New-Item -Path $script:LocalRoot -ItemType Directory -Force | Out-Null
    }

    Set-Content `
        -LiteralPath $script:CompletionMarkerPath `
        -Value $Identity `
        -Encoding ASCII `
        -Force
}

function Get-CurrentBootTimeUtc {
    [CmdletBinding()]
    param()

    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return ([DateTime]$operatingSystem.LastBootUpTime).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Test-EffectiveRestartRequired {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Snapshot)

    if ((Get-SnapshotInt -Snapshot $Snapshot -Name 'RestartRequired') -ne 1) {
        return $false
    }

    $currentBootUtc = Get-CurrentBootTimeUtc
    if ($null -eq $currentBootUtc) {
        return $true
    }

    $bootAtCompletion = ConvertTo-DateTimeOffset (
        Get-SnapshotValue -Snapshot $Snapshot -Name 'BootTimeAtCompletionUtc'
    )
    if ($null -ne $bootAtCompletion -and
        $currentBootUtc -gt $bootAtCompletion.UtcDateTime.AddSeconds(30)) {
        return $false
    }

    $completedTime = ConvertTo-DateTimeOffset (
        Get-SnapshotValue -Snapshot $Snapshot -Name 'CompletedTimeUtc'
    )
    if ($null -ne $completedTime -and
        $currentBootUtc -gt $completedTime.UtcDateTime.AddSeconds(30)) {
        return $false
    }

    return $true
}


function Get-PendingComputerName {
    [CmdletBinding()]
    param()

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $computerNameKey = $baseKey.OpenSubKey(
            'SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName',
            $false
        )
        if ($null -eq $computerNameKey) {
            return ''
        }

        try {
            return [string]$computerNameKey.GetValue('ComputerName', '')
        }
        finally {
            $computerNameKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Get-ShortcutDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ShortcutPath)

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $null
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        try {
            return [pscustomobject]@{
                TargetPath = [Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath)
                Arguments = [string]$shortcut.Arguments
                IconLocation = [Environment]::ExpandEnvironmentVariables([string]$shortcut.IconLocation)
            }
        }
        finally {
            if ($null -ne $shortcut) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Test-EquivalentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or
        [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $leftPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Left.Trim().Trim('"'))
        ).TrimEnd('\')
        $rightPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Right.Trim().Trim('"'))
        ).TrimEnd('\')
        return ($leftPath -ieq $rightPath)
    }
    catch {
        $leftFallback = $Left.Trim().Trim('"').TrimEnd('\')
        $rightFallback = $Right.Trim().Trim('"').TrimEnd('\')
        return ($leftFallback -ieq $rightFallback)
    }
}

function Test-CompletionContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Snapshot)

    $issues = New-Object System.Collections.Generic.List[string]
    $configVersion = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigVersion' -Default '')
    $schemaVersion = Get-SnapshotInt -Snapshot $Snapshot -Name 'SchemaVersion'
    $state = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigState' -Default '')
    $complete = Get-SnapshotInt -Snapshot $Snapshot -Name 'ConfigComplete'
    $failed = Get-SnapshotInt -Snapshot $Snapshot -Name 'ConfigFailed'
    $step = Get-SnapshotInt -Snapshot $Snapshot -Name 'ConfigStep'
    $totalSteps = Get-SnapshotInt -Snapshot $Snapshot -Name 'TotalSteps'
    $progress = Get-SnapshotInt -Snapshot $Snapshot -Name 'ProgressPercent' -Default -1
    $runId = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'RunId' -Default '')
    $workerResult = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'WorkerLastResult' -Default '')
    $configError = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigError' -Default '')

    if ($configVersion -ne $script:ExpectedConfigVersion) {
        $issues.Add("ConfigVersion is '$configVersion'; expected '$script:ExpectedConfigVersion'") | Out-Null
    }
    if ($schemaVersion -ne $script:ExpectedSchemaVersion) {
        $issues.Add("SchemaVersion is '$schemaVersion'; expected '$script:ExpectedSchemaVersion'") | Out-Null
    }
    if ($complete -ne 1) {
        $issues.Add('ConfigComplete is not 1') | Out-Null
    }
    if ($failed -ne 0) {
        $issues.Add('ConfigFailed is not 0') | Out-Null
    }
    if ($state -ne 'Completed') {
        $issues.Add("ConfigState is '$state'; expected 'Completed'") | Out-Null
    }
    if ($step -ne $script:ExpectedTotalSteps) {
        $issues.Add("ConfigStep is '$step'; expected '$script:ExpectedTotalSteps'") | Out-Null
    }
    if ($totalSteps -ne $script:ExpectedTotalSteps) {
        $issues.Add("TotalSteps is '$totalSteps'; expected '$script:ExpectedTotalSteps'") | Out-Null
    }
    if ($progress -ne 100) {
        $issues.Add("ProgressPercent is '$progress'; expected '100'") | Out-Null
    }
    if ($workerResult -ne 'Completed') {
        $issues.Add("WorkerLastResult is '$workerResult'; expected 'Completed'") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($configError)) {
        $issues.Add("ConfigError is not empty: $configError") | Out-Null
    }

    $parsedRunId = [Guid]::Empty
    if (-not [Guid]::TryParse($runId, [ref]$parsedRunId)) {
        $issues.Add("RunId is not a valid GUID: '$runId'") | Out-Null
    }

    foreach ($timestampName in @('CompletedTimeUtc', 'FinalVerificationUtc')) {
        $timestamp = ConvertTo-DateTimeOffset (
            Get-SnapshotValue -Snapshot $Snapshot -Name $timestampName
        )
        if ($null -eq $timestamp) {
            $issues.Add("$timestampName is missing or invalid") | Out-Null
        }
    }

    $allowedStatuses = @('Succeeded', 'SucceededWithWarnings')
    for ($number = 1; $number -le $script:ExpectedTotalSteps; $number++) {
        $statusName = 'Step{0:D2}Status' -f $number
        $status = [string](Get-SnapshotValue -Snapshot $Snapshot -Name $statusName -Default '')
        if ($status -notin $allowedStatuses) {
            $issues.Add("$statusName is '$status'") | Out-Null
        }
    }

    $appsInstalled = Get-SnapshotInt -Snapshot $Snapshot -Name 'AppsInstalled'
    $appsReady = Get-SnapshotInt -Snapshot $Snapshot -Name 'AppsReady'
    $appsTotal = Get-SnapshotInt -Snapshot $Snapshot -Name 'AppsTotal'
    if ($appsInstalled -ne 1 -or $appsTotal -ne 4 -or $appsReady -ne $appsTotal) {
        $issues.Add("Application readiness is inconsistent: Installed=$appsInstalled, Ready=$appsReady, Total=$appsTotal") | Out-Null
    }

    $chromePath = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ChromeExecutable' -Default '')
    $adobePath = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'AdobeExecutable' -Default '')
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'Google Chrome'; Path = $chromePath },
        [pscustomobject]@{ Name = 'Adobe Acrobat'; Path = $adobePath }
    )) {
        if ([string]::IsNullOrWhiteSpace($entry.Path) -or
            -not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
            $issues.Add("$($entry.Name) executable is unavailable at '$($entry.Path)'") | Out-Null
        }
    }


    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($publicDesktop)) {
        $publicDesktop = 'C:\Users\Public\Desktop'
    }

    $outlookIcon = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'OutlookExecutable' -Default '')
    $teamsIcon = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'TeamsExecutable' -Default '')
    if ([string]::IsNullOrWhiteSpace($outlookIcon)) {
        $issues.Add('OutlookExecutable was not published by the SYSTEM worker') | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($teamsIcon)) {
        $issues.Add('TeamsExecutable was not published by the SYSTEM worker') | Out-Null
    }
    $explorerTarget = Join-Path $env:SystemRoot 'explorer.exe'
    $outlookArguments = "shell:AppsFolder\$script:ExpectedOutlookAppUserModelId"
    $teamsArguments = "shell:AppsFolder\$script:ExpectedTeamsAppUserModelId"

    $shortcutDefinitions = @(
        [pscustomobject]@{
            Name = 'Google Chrome'
            FileName = 'Google Chrome.lnk'
            TargetPath = $chromePath
            Arguments = ''
            IconPath = ''
        },
        [pscustomobject]@{
            Name = 'Adobe Acrobat'
            FileName = 'Adobe Acrobat.lnk'
            TargetPath = $adobePath
            Arguments = ''
            IconPath = ''
        },
        [pscustomobject]@{
            Name = 'Outlook'
            FileName = 'Outlook.lnk'
            TargetPath = $explorerTarget
            Arguments = $outlookArguments
            IconPath = $outlookIcon
        },
        [pscustomobject]@{
            Name = 'MS Teams'
            FileName = 'MS Teams.lnk'
            TargetPath = $explorerTarget
            Arguments = $teamsArguments
            IconPath = $teamsIcon
        }
    )
    foreach ($definition in $shortcutDefinitions) {
        $shortcutPath = Join-Path $publicDesktop $definition.FileName
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
            $issues.Add("Required shortcut is missing: $shortcutPath") | Out-Null
            continue
        }

        try {
            $actualShortcut = Get-ShortcutDefinition -ShortcutPath $shortcutPath
            if ($null -eq $actualShortcut) {
                throw 'The shortcut could not be read.'
            }

            if (-not (Test-EquivalentPath `
                -Left ([string]$actualShortcut.TargetPath) `
                -Right ([string]$definition.TargetPath))) {
                $issues.Add(
                    "Shortcut target mismatch for $($definition.Name): '$($actualShortcut.TargetPath)'"
                ) | Out-Null
            }

            $actualArguments = ([string]$actualShortcut.Arguments).Trim()
            $expectedArguments = ([string]$definition.Arguments).Trim()
            if ($actualArguments -cne $expectedArguments) {
                $issues.Add(
                    "Shortcut arguments mismatch for $($definition.Name): '$($actualShortcut.Arguments)'"
                ) | Out-Null
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$definition.IconPath)) {
                $actualIconLocation = [string]$actualShortcut.IconLocation
                $actualIconPath = ($actualIconLocation -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
                if (-not (Test-EquivalentPath `
                    -Left $actualIconPath `
                    -Right ([string]$definition.IconPath))) {
                    $issues.Add(
                        "Shortcut icon mismatch for $($definition.Name): '$actualIconLocation'"
                    ) | Out-Null
                }
            }
        }
        catch {
            $issues.Add("Unable to verify shortcut '$shortcutPath': $($_.Exception.Message)") | Out-Null
        }
    }

    $desiredName = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'DesiredComputerName' -Default '')
    $currentName = [string]$env:COMPUTERNAME
    $pendingName = ''
    try {
        $pendingName = Get-PendingComputerName
    }
    catch {
        $issues.Add("Unable to read the pending computer name: $($_.Exception.Message)") | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($desiredName)) {
        $issues.Add('DesiredComputerName is empty') | Out-Null
    }
    elseif ($currentName -ine $desiredName -and $pendingName -ine $desiredName) {
        $issues.Add("Computer name is neither applied nor pending. Current='$currentName'; Pending='$pendingName'; Expected='$desiredName'") | Out-Null
    }

    $debloatVersion = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'WindowsDebloatVersion' -Default '')
    $debloatCommit = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'WindowsDebloatCommit' -Default '')
    $debloatStateHash = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'WindowsDebloatSha256' -Default '')
    $debloatSourceUrl = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'WindowsDebloatSourceUrl' -Default '')
    $debloatLog = [string](Get-SnapshotValue `
        -Snapshot $Snapshot `
        -Name 'WindowsDebloatLog' `
        -Default $script:ExpectedWindowsDebloatLogPath)

    if ($debloatVersion -ne $script:ExpectedWindowsDebloatVersion) {
        $issues.Add("Windows debloat version is '$debloatVersion'; expected '$script:ExpectedWindowsDebloatVersion'") | Out-Null
    }
    if ($debloatCommit -ne $script:ExpectedWindowsDebloatCommit) {
        $issues.Add("Windows debloat commit is '$debloatCommit'; expected '$script:ExpectedWindowsDebloatCommit'") | Out-Null
    }
    if ($debloatStateHash -ine $script:ExpectedWindowsDebloatSha256) {
        $issues.Add("Windows debloat state SHA256 is '$debloatStateHash'; expected '$script:ExpectedWindowsDebloatSha256'") | Out-Null
    }
    if ($debloatSourceUrl -ne $script:ExpectedWindowsDebloatSourceUrl) {
        $issues.Add("Windows debloat source URL is '$debloatSourceUrl'; expected the pinned commit URL") | Out-Null
    }
    if (-not (Test-EquivalentPath `
        -Left $debloatLog `
        -Right $script:ExpectedWindowsDebloatLogPath)) {
        $issues.Add("Windows debloat log path is '$debloatLog'; expected '$script:ExpectedWindowsDebloatLogPath'") | Out-Null
    }

    if (-not (Test-Path -LiteralPath $script:ExpectedWindowsDebloatScriptPath -PathType Leaf)) {
        $issues.Add("Pinned Windows debloat script is missing: $script:ExpectedWindowsDebloatScriptPath") | Out-Null
    }
    else {
        try {
            $actualDebloatHash = (Get-FileHash `
                -LiteralPath $script:ExpectedWindowsDebloatScriptPath `
                -Algorithm SHA256 `
                -ErrorAction Stop).Hash.ToUpperInvariant()
            if ($actualDebloatHash -ne $script:ExpectedWindowsDebloatSha256) {
                $issues.Add("Pinned Windows debloat script SHA256 is '$actualDebloatHash'; expected '$script:ExpectedWindowsDebloatSha256'") | Out-Null
            }
        }
        catch {
            $issues.Add("Unable to hash the pinned Windows debloat script: $($_.Exception.Message)") | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $debloatLog -PathType Leaf)) {
        $issues.Add("Windows debloat log is missing: $debloatLog") | Out-Null
    }
    else {
        try {
            $completionLine = Get-Content `
                -LiteralPath $debloatLog `
                -Tail 200 `
                -ErrorAction Stop | Where-Object { $_ -match '^\s*Completed\s*$' } | Select-Object -Last 1
            if ($null -eq $completionLine) {
                $issues.Add("Windows debloat log lacks its terminal completion marker: $debloatLog") | Out-Null
            }
        }
        catch {
            $issues.Add("Unable to verify Windows debloat log '$debloatLog': $($_.Exception.Message)") | Out-Null
        }
    }

    $finalVerification = [string](Get-SnapshotValue `
        -Snapshot $Snapshot `
        -Name 'FinalVerificationResult' `
        -Default '')
    if ($finalVerification -ne 'Passed') {
        $issues.Add("FinalVerificationResult is '$finalVerification'; expected 'Passed'") | Out-Null
    }

    return [pscustomobject]@{
        Valid = ($issues.Count -eq 0)
        Message = ($issues -join '; ')
        RestartRequired = (Test-EffectiveRestartRequired -Snapshot $Snapshot)
    }
}

# -----------------------------------------------------------------------------
# Intune launcher mode
# -----------------------------------------------------------------------------
function Start-DetachedUiHost {
    [CmdletBinding()]
    param()

    $snapshot = Get-StateSnapshot
    if ((Get-SnapshotInt -Snapshot $snapshot -Name 'ConfigComplete') -eq 1) {
        $completionIdentity = Get-CompletionIdentity -Snapshot $snapshot
        if ((Get-CompletionMarker) -eq $completionIdentity) {
            Remove-UserRunRegistration
            Write-Output 'Completion for this configuration run was already shown to the current user.'
            return
        }
    }

    if (-not (Test-Path -LiteralPath $script:LocalRoot -PathType Container)) {
        New-Item -Path $script:LocalRoot -ItemType Directory -Force | Out-Null
    }

    Install-CurrentScript -DestinationPath $script:InstalledMonitor
    Test-PowerShellScriptSyntax -Path $script:InstalledMonitor

    Set-UserRunRegistration

    if (-not (Test-IsInteractiveUserSession)) {
        Write-Output 'The monitor was installed for the next interactive user logon.'
        return
    }

    $powerShellPath = Get-NativeWindowsPowerShellPath
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:InstalledMonitor`" -UiHost"

    Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden | Out-Null

    Write-Output 'The user-facing configuration monitor was launched.'
}
if (-not $UiHost) {
    try {
        Start-DetachedUiHost
        exit 0
    }
    catch {
        Write-MonitorLog -Level ERROR -Message "Launcher failed: $($_.Exception.Message)"
        Write-Error "Unable to launch the configuration monitor: $($_.Exception.Message)"
        exit 1
    }
}

# -----------------------------------------------------------------------------
# UI host prerequisites and duplicate-instance protection
# -----------------------------------------------------------------------------
if (-not (Test-IsInteractiveUserSession)) {
    exit 0
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    Install-CurrentScript -DestinationPath $script:InstalledMonitor
    Test-PowerShellScriptSyntax -Path $script:InstalledMonitor

    $powerShellPath = Get-NativeWindowsPowerShellPath
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:InstalledMonitor`" -UiHost"
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    exit 0
}

$mutex = $null
$lockTaken = $false

try {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $currentIdentity.User.Value
    $mutexName = "Local\TMT.StandardConfig.Monitor.$userSid"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)

    try {
        $lockTaken = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $lockTaken = $true
    }

    if (-not $lockTaken) {
        exit 0
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # -------------------------------------------------------------------------
    # UI helpers
    # -------------------------------------------------------------------------
    function Set-ProgressBarMode {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][System.Windows.Forms.ProgressBar]$ProgressBar,
            [Parameter(Mandatory)][ValidateSet('Marquee', 'Continuous')][string]$Mode
        )

        if ([string]$ProgressBar.Style -eq $Mode) {
            return
        }

        if ($Mode -eq 'Marquee') {
            $ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $ProgressBar.MarqueeAnimationSpeed = 30
        }
        else {
            $ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $ProgressBar.MarqueeAnimationSpeed = 0
        }
    }

    function Show-FailureDialog {
        [CmdletBinding()]
        param(
            [string]$Message,
            [string]$State
        )

        if ([string]::IsNullOrWhiteSpace($Message)) {
            $Message = 'The configuration worker reported an unspecified error.'
        }

        $dialogText = @"
The computer configuration could not be completed.

State: $State
Error: $Message

Technical log:
$script:SystemLogPath

Please contact the IT Service Desk and include the error shown above.
"@

        [System.Windows.Forms.MessageBox]::Show(
            $dialogText,
            'Computer Configuration Failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }

    function Request-Restart {
        [CmdletBinding()]
        param([ValidateSet(0, 300)][int]$DelaySeconds)

        $comment = if ($DelaySeconds -eq 0) {
            'Restarting now to complete THE MEDICAL TEAM computer configuration.'
        }
        else {
            'Restarting in 5 minutes to complete THE MEDICAL TEAM computer configuration.'
        }

        try {
            $arguments = "/r /t $DelaySeconds /c `"$comment`""
            $process = Start-Process `
                -FilePath (Join-Path $env:WINDIR 'System32\shutdown.exe') `
                -ArgumentList $arguments `
                -PassThru `
                -Wait

            if ($process.ExitCode -ne 0) {
                throw "shutdown.exe returned exit code $($process.ExitCode)."
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Windows could not schedule the restart automatically.`r`n`r`n$($_.Exception.Message)`r`n`r`nPlease save your work and restart the computer manually.",
                'Restart Required',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }

    function Show-CompletionDialog {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][hashtable]$Snapshot,
            [Parameter(Mandatory)][bool]$RestartRequired
        )

        $warnings = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigWarnings' -Default '')
        $warningText = ''

        if (-not [string]::IsNullOrWhiteSpace($warnings)) {
            if ($warnings.Length -gt 1200) {
                $warnings = $warnings.Substring(0, 1200) + '...'
            }
            $warningText = "`r`n`r`nNon-blocking notes:`r`n$warnings"
        }

        if (-not $RestartRequired) {
            [System.Windows.Forms.MessageBox]::Show(
                "The computer setup is complete.$warningText",
                'Computer Setup Complete',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            "The computer setup is complete.$warningText`r`n`r`nA restart is required to finish applying the changes.`r`n`r`nSelect Yes to restart now.`r`nSelect No to restart automatically in 5 minutes.",
            'Computer Setup Complete - Restart Required',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Request-Restart -DelaySeconds 0
        }
        else {
            Request-Restart -DelaySeconds 300
        }
    }

    function Format-ElapsedTime {
        [CmdletBinding()]
        param([Parameter(Mandatory)][TimeSpan]$Elapsed)

        if ($Elapsed.TotalHours -ge 1) {
            return ('{0}h {1}m {2}s' -f [int]$Elapsed.TotalHours, $Elapsed.Minutes, $Elapsed.Seconds)
        }

        return ('{0}m {1}s' -f [int]$Elapsed.TotalMinutes, $Elapsed.Seconds)
    }

    # -------------------------------------------------------------------------
    # Build form
    # -------------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'THE MEDICAL TEAM - Computer Setup'
    $form.ClientSize = New-Object System.Drawing.Size(640, 315)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.ControlBox = $true
    $form.ShowInTaskbar = $true
    $form.TopMost = $false

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.AutoSize = $false
    $lblTitle.Size = New-Object System.Drawing.Size(606, 30)
    $lblTitle.Location = New-Object System.Drawing.Point(16, 14)
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $lblTitle.Text = 'Preparing this computer for work'

    $lblStep = New-Object System.Windows.Forms.Label
    $lblStep.AutoSize = $false
    $lblStep.Size = New-Object System.Drawing.Size(606, 24)
    $lblStep.Location = New-Object System.Drawing.Point(16, 52)
    $lblStep.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblStep.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $lblStep.Text = 'Waiting for configuration to start'

    $lblDetail = New-Object System.Windows.Forms.Label
    $lblDetail.AutoSize = $false
    $lblDetail.Size = New-Object System.Drawing.Size(606, 42)
    $lblDetail.Location = New-Object System.Drawing.Point(16, 78)
    $lblDetail.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(75, 75, 75)
    $lblDetail.Text = 'The SYSTEM configuration worker has not published a status yet.'

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(16, 128)
    $bar.Size = New-Object System.Drawing.Size(606, 24)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value = 0
    $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $bar.MarqueeAnimationSpeed = 30

    $lblPercent = New-Object System.Windows.Forms.Label
    $lblPercent.AutoSize = $false
    $lblPercent.Size = New-Object System.Drawing.Size(200, 20)
    $lblPercent.Location = New-Object System.Drawing.Point(16, 160)
    $lblPercent.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblPercent.ForeColor = [System.Drawing.Color]::FromArgb(75, 75, 75)
    $lblPercent.Text = 'Starting'

    $lblApps = New-Object System.Windows.Forms.Label
    $lblApps.AutoSize = $false
    $lblApps.Size = New-Object System.Drawing.Size(606, 22)
    $lblApps.Location = New-Object System.Drawing.Point(16, 187)
    $lblApps.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblApps.ForeColor = [System.Drawing.Color]::FromArgb(75, 75, 75)
    $lblApps.Text = ''

    $lblTiming = New-Object System.Windows.Forms.Label
    $lblTiming.AutoSize = $false
    $lblTiming.Size = New-Object System.Drawing.Size(606, 22)
    $lblTiming.Location = New-Object System.Drawing.Point(16, 214)
    $lblTiming.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblTiming.ForeColor = [System.Drawing.Color]::FromArgb(115, 115, 115)
    $lblTiming.Text = 'Elapsed: 0m 0s'

    $lblNotice = New-Object System.Windows.Forms.Label
    $lblNotice.AutoSize = $false
    $lblNotice.Size = New-Object System.Drawing.Size(606, 42)
    $lblNotice.Location = New-Object System.Drawing.Point(16, 245)
    $lblNotice.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblNotice.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $lblNotice.Text = 'Please keep the computer powered on and connected to the internet. You may minimize this window. Closing it while setup is active will minimize it and will not stop the configuration.'

    $form.Controls.AddRange(@(
        $lblTitle,
        $lblStep,
        $lblDetail,
        $bar,
        $lblPercent,
        $lblApps,
        $lblTiming,
        $lblNotice
    ))

    # -------------------------------------------------------------------------
    # State-to-UI rendering
    # -------------------------------------------------------------------------
    function Update-MonitorForm {
        [CmdletBinding()]
        param([Parameter(Mandatory)][hashtable]$Snapshot)

        if ($script:TerminalHandled) {
            return
        }

        $state = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigState' -Default '')
        $complete = Get-SnapshotInt -Snapshot $Snapshot -Name 'ConfigComplete'
        $failed = Get-SnapshotInt -Snapshot $Snapshot -Name 'ConfigFailed'
        $step = Get-SnapshotInt -Snapshot $Snapshot -Name 'ConfigStep'
        $totalSteps = Get-SnapshotInt -Snapshot $Snapshot -Name 'TotalSteps' -Default 5
        $percent = Get-SnapshotInt -Snapshot $Snapshot -Name 'ProgressPercent' -Default -1
        $stepLabel = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigStepLabel' -Default '')
        $stepDetail = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigStepDetail' -Default '')
        $appsReady = Get-SnapshotInt -Snapshot $Snapshot -Name 'AppsReady'
        $appsTotal = Get-SnapshotInt -Snapshot $Snapshot -Name 'AppsTotal'
        $appsMissing = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'AppsMissing' -Default '')
        $lastUpdated = ConvertTo-DateTimeOffset (Get-SnapshotValue -Snapshot $Snapshot -Name 'LastUpdatedUtc')
        $startTime = ConvertTo-DateTimeOffset (Get-SnapshotValue -Snapshot $Snapshot -Name 'ScriptStartTimeUtc')
        $errorMessage = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigError' -Default '')
        $warnings = [string](Get-SnapshotValue -Snapshot $Snapshot -Name 'ConfigWarnings' -Default '')

        if ($failed -eq 1) {
            $script:TerminalHandled = $true
            $timer.Stop()
            Write-MonitorLog -Level ERROR -Message "SYSTEM configuration failed. State='$state'; Error='$errorMessage'"
            Remove-UserRunRegistration
            $form.Hide()
            Show-FailureDialog -Message $errorMessage -State $state
            $form.Close()
            return
        }

        if ($complete -eq 1) {
            $verification = Test-CompletionContract -Snapshot $Snapshot
            $script:TerminalHandled = $true
            $timer.Stop()

            if (-not $verification.Valid) {
                Write-MonitorLog -Level ERROR -Message "Completion contract verification failed: $($verification.Message)"
                Remove-UserRunRegistration
                $form.Hide()
                Show-FailureDialog `
                    -Message "Completion verification failed: $($verification.Message)" `
                    -State 'CompletionVerificationFailed'
                $form.Close()
                return
            }

            Set-ProgressBarMode -ProgressBar $bar -Mode Continuous
            $bar.Value = 100
            $lblStep.Text = 'Configuration completed and verified'
            $lblDetail.Text = 'All required configuration postconditions passed.'
            $lblPercent.Text = '100% complete'
            $lblApps.Text = ''
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 600
            $form.Hide()

            Write-MonitorLog -Message 'Configuration completed and the independent user-context verification contract passed.'
            Remove-UserRunRegistration
            $completionIdentity = Get-CompletionIdentity -Snapshot $Snapshot
            try {
                Set-CompletionMarker -Identity $completionIdentity
            }
            catch {
                # Notification tracking is non-critical; do not suppress the
                # completion or restart dialog if LocalAppData is unavailable.
            }

            Show-CompletionDialog `
                -Snapshot $Snapshot `
                -RestartRequired ([bool]$verification.RestartRequired)
            $form.Close()
            return
        }

        if ($Snapshot.Count -eq 0 -or [string]::IsNullOrWhiteSpace($state)) {
            Set-ProgressBarMode -ProgressBar $bar -Mode Marquee
            $lblStep.Text = 'Waiting for the SYSTEM configuration worker'
            $lblDetail.Text = 'The configuration policy may still be downloading or waiting for its first device check-in.'
            $lblPercent.Text = 'Waiting to start'
            $lblApps.Text = ''
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($stepLabel)) {
                $lblStep.Text = $stepLabel
            }
            elseif ($step -gt 0) {
                $lblStep.Text = "Step $step/$totalSteps"
            }

            if (-not [string]::IsNullOrWhiteSpace($stepDetail)) {
                $lblDetail.Text = $stepDetail
            }

            if ($percent -lt 0 -and $step -gt 0 -and $totalSteps -gt 0) {
                $percent = [int][Math]::Floor(($step / $totalSteps) * 100)
            }

            if ($percent -ge 0) {
                Set-ProgressBarMode -ProgressBar $bar -Mode Continuous
                $percent = [Math]::Max(0, [Math]::Min(100, $percent))
                $bar.Value = $percent
                $lblPercent.Text = "$percent% complete"
            }
            else {
                Set-ProgressBarMode -ProgressBar $bar -Mode Marquee
                $lblPercent.Text = 'Working'
            }

            if ($appsTotal -gt 0 -and ($step -ge 4 -or $state -eq 'WaitingForApps')) {
                $appsText = "Required apps: $appsReady/$appsTotal ready"
                if (-not [string]::IsNullOrWhiteSpace($appsMissing) -and $appsMissing -ne 'None') {
                    $appsText += " | Waiting for: $appsMissing"
                }
                else {
                    $appsText += ' | All required apps are ready'
                }
                $lblApps.Text = $appsText
            }
            else {
                $lblApps.Text = ''
            }
        }

        $elapsed = if ($null -ne $startTime) {
            [DateTimeOffset]::UtcNow - $startTime.ToUniversalTime()
        }
        else {
            (Get-Date) - $script:MonitorStarted
        }

        $timingText = "Elapsed: $(Format-ElapsedTime -Elapsed $elapsed)"
        if ($null -ne $lastUpdated) {
            $timingText += " | Last update: $($lastUpdated.LocalDateTime.ToString('g'))"
        }
        $lblTiming.Text = $timingText

        $lblNotice.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
        if ($state -eq 'RetryPending') {
            $lblNotice.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblNotice.Text = 'A configuration attempt failed, but the SYSTEM worker is scheduled to retry automatically. Closing this window while setup is active will minimize it and will not stop the retry.'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($warnings)) {
            $lblNotice.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblNotice.Text = 'The configuration has recorded one or more non-blocking warnings. Details will be shown when setup completes.'
        }
        elseif ($null -ne $lastUpdated -and
            (([DateTimeOffset]::UtcNow - $lastUpdated.ToUniversalTime()).TotalMinutes -ge 20)) {
            $lblNotice.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblNotice.Text = 'No status update has been received for at least 20 minutes. A long-running cleanup may still be active; the SYSTEM worker will report a failure if it cannot continue.'
        }
        else {
            $lblNotice.Text = 'Please keep the computer powered on and connected to the internet. You may minimize this window. Closing it while setup is active will minimize it and will not stop the configuration.'
        }

        if (((Get-Date) - $script:MonitorStarted).TotalHours -ge $script:MonitorMaximumHours) {
            $script:TerminalHandled = $true
            $timer.Stop()
            Write-MonitorLog -Level WARN -Message "Monitor UI reached its $script:MonitorMaximumHours hour local lifetime and closed without a terminal state."
            Remove-UserRunRegistration
            $form.Hide()
            [System.Windows.Forms.MessageBox]::Show(
                "This progress window has been open for more than $script:MonitorMaximumHours hours and will now close.`r`n`r`nThe SYSTEM configuration worker, if still active, is not stopped by closing this window.`r`n`r`nLog: $script:SystemLogPath",
                'Configuration Monitor Closed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $form.Close()
        }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $script:PollIntervalMilliseconds
    $timer.Add_Tick({
        try {
            $snapshot = Get-StateSnapshot
            Update-MonitorForm -Snapshot $snapshot
        }
        catch {
            $lblNotice.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblNotice.Text = "Unable to read the latest configuration status: $($_.Exception.Message)"
        }
    })

    $form.Add_Shown({
        try {
            Update-MonitorForm -Snapshot (Get-StateSnapshot)
        }
        catch {
            $lblNotice.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblNotice.Text = "Unable to read the initial configuration status: $($_.Exception.Message)"
        }
        if (-not $script:TerminalHandled) {
            $timer.Start()
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        if (-not $script:TerminalHandled -and
            $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $eventArgs.Cancel = $true
            $sender.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        }
    })

    [void]$form.ShowDialog()
}
catch {
    $message = $_.Exception.Message
    Write-MonitorLog -Level ERROR -Message "UI host failed: $message"

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "The computer setup monitor could not continue.`r`n`r`n$message`r`n`r`nMonitor log: $script:MonitorLogPath`r`nSystem log: $script:SystemLogPath",
            'Computer Setup Monitor Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        # The local monitor log remains available if Windows Forms is unavailable.
    }
}
finally {
    if ($lockTaken) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
            # The process is exiting; no additional user-facing action is needed.
        }
    }

    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
