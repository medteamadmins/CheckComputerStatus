# =====================================================================
# TMTCheckConfig.ps1
# Runs as: Logged-in USER | Polls registry, shows progress UI
# =====================================================================

$RegBase    = "HKLM:\SOFTWARE\TMT"
$TotalSteps = 5

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----- Registry Helper -----
function Get-Reg([string]$Name) {
    try { return (Get-ItemProperty -Path $RegBase -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

# =====================================================================
# EARLY EXIT — New registry key (silent)
# =====================================================================
if ((Get-Reg "ConfigComplete") -eq 1) {
    Write-Host "ConfigComplete registry key found — already done. Exiting silently."
    return
}

# =====================================================================
# EARLY EXIT — Old txt flags (production compat — NO prompts)
# =====================================================================
$OldFlags = @(
    "C:\ProgramData\TMT\MasterScriptDone1.0.txt",
    "C:\ProgramData\TMT\Done1.0.txt",
    "C:\Users\$ENV:USERNAME\AppData\MasterScriptDone1.0.txt",
    "C:\Users\$ENV:USERNAME\AppData\Done1.0.txt"
)
foreach ($f in $OldFlags) {
    if (Test-Path $f -PathType Leaf) {
        Write-Host "Legacy flag found: $f — exiting silently (no prompt)."
        return
    }
}

# =====================================================================
# BUILD PROGRESS FORM
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "***COMPUTER CONFIGURATION***THE MEDICAL TEAM, INC."
$form.Size            = New-Object System.Drawing.Size(500, 185)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.ControlBox      = $false
$form.TopMost         = $true

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.AutoSize  = $true
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::DodgerBlue
$lblTitle.Location  = New-Object System.Drawing.Point(14, 12)
$lblTitle.Text      = "**PLEASE WAIT — DON'T turn off or restart your computer.**"

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.AutoSize  = $false
$lblSub.Size      = New-Object System.Drawing.Size(458, 20)
$lblSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblSub.Location  = New-Object System.Drawing.Point(16, 40)
$lblSub.Text      = "Configuring your computer."

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location              = New-Object System.Drawing.Point(14, 70)
$bar.Size                  = New-Object System.Drawing.Size(458, 22)
$bar.Style                 = "Marquee"
$bar.MarqueeAnimationSpeed = 30
$bar.Minimum               = 0
$bar.Maximum               = 100
$bar.Value                 = 0

$lblPct = New-Object System.Windows.Forms.Label
$lblPct.AutoSize  = $true
$lblPct.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblPct.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblPct.Location  = New-Object System.Drawing.Point(16, 100)
$lblPct.Text      = "Starting…"

$form.Controls.AddRange(@($lblTitle, $lblSub, $bar, $lblPct))

# =====================================================================
# POLLING TIMER
# =====================================================================
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000   # every 5 seconds

$timer.Add_Tick({

    $done       = Get-Reg "ConfigComplete"
    $step       = Get-Reg "ConfigStep"
    $stepLabel  = Get-Reg "ConfigStepLabel"
    $appsReady  = Get-Reg "AppsInstalled"

    # --- Update progress bar and labels ---
    if ($step -is [int] -and $step -gt 0) {

        # Switch to determinate once config has started
        if ($bar.Style -ne 'Continuous') {
            $bar.Style                 = 'Continuous'
            $bar.MarqueeAnimationSpeed = 0
        }

        $pct        = [int][math]::Round(($step / $TotalSteps) * 100)
        $bar.Value  = [Math]::Min($pct, 100)
        $lblPct.Text = "$pct% complete"

        # Step 4 — waiting on apps needs a special message
        if ($step -eq 4 -and $appsReady -ne 1) {
            $lblSub.Text = "Step 4/$TotalSteps Waiting for applications to finish installing…"
        } elseif ($stepLabel) {
            $lblSub.Text = $stepLabel
        }

    } else {
        # Config script hasn't written its first step yet — keep marquee
        if ($bar.Style -ne 'Marquee') {
            $bar.Style                 = 'Marquee'
            $bar.MarqueeAnimationSpeed = 30
        }
        $lblSub.Text  = "Waiting for configuration to begin…"
        $lblPct.Text  = "Starting…"
    }

    [System.Windows.Forms.Application]::DoEvents()

  # --- All done ---
    if ($done -eq 1) {
        $timer.Stop()
        $bar.Value    = 100
        $lblSub.Text  = "Configuration complete!"
        $lblPct.Text  = "100% complete"
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 800
        $form.Hide()

        $result = [System.Windows.Forms.MessageBox]::Show(
            "Device configuration is complete.`n`nClick YES to restart now, or NO to restart automatically in 5 minutes.",
            "Reboot Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            shutdown.exe /r /t 0 /c "TMT configuration complete. Restarting now."
        } else {
            shutdown.exe /r /t 300 /c "TMT configuration complete. Restarting in 5 minutes."
        }

        $form.Close()
    }
})

$form.Add_Shown({ $timer.Start() })
[void]$form.ShowDialog()