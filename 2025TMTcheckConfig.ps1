# Paths
$filePath       = "C:\Users\$($ENV:USERNAME)\AppData\Done1.0.txt"
$AppsAreInstalled = "C:\ProgramData\TMT\AppsAreInstalled1.0.txt"
$TMTFolder      = "C:\ProgramData\TMT"

# Assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework

# ---------- UI helpers ----------
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-ProgressForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Installing Applications"
    $form.Size = New-Object System.Drawing.Size(420,150)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false        # prevents closing mid-install
    $form.TopMost = $true

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 11,[System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(12,10)
    $title.Text = "Please wait…"

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.AutoSize = $true
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $subtitle.Location = New-Object System.Drawing.Point(14,35)
    $subtitle.Text = "Preparing installation"

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(12,65)
    $bar.Size = New-Object System.Drawing.Size(380,22)
    $bar.Style = 'Marquee'                # Indeterminate until we detect something
    $bar.MarqueeAnimationSpeed = 30
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value   = 0

    $form.Controls.AddRange(@($title,$subtitle,$bar))
    return [pscustomobject]@{
        Form    = $form
        Title   = $title
        Subtitle= $subtitle
        Bar     = $bar
    }
}

# ---------- Ensure TMT folder ----------
if (-not (Test-Path -Path $TMTFolder -PathType Container)) {
    New-Item -Path $TMTFolder -ItemType Directory | Out-Null
}

# ---------- Early exit if done flag ----------
if (Test-Path -Path $filePath -PathType Leaf) {
    Write-Host "Done1.0.txt exists. Script will exit."
    return
}

Write-Host "Done1.0.txt not found."

# ---------- Download and set RunOnce ----------
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/MasterScript/main/2025TMTconfigScript.ps1" -OutFile "$TMTFolder\2025TMTconfigScript.ps1"

# Properly quoted RunOnce command; requires admin rights
$psExe      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$scriptCmd  = "& '$TMTFolder\2025TMTconfigScript.ps1'"
$scriptPath = "`"$psExe`" -ExecutionPolicy Bypass -WindowStyle Minimized -NoExit -Command $scriptCmd"

$registryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$registryName = "RunTMTScript"

if (-not (Test-Path -Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}
Set-ItemProperty -Path $registryPath -Name $registryName -Value $scriptPath
Write-Host "Registry set to run configuration script on next boot."

# If AppsAreInstalled marker already exists, we don't need to prompt or show progress
if (Test-Path $AppsAreInstalled) { return }

# ---------- User prompt ----------
[void][System.Windows.Forms.MessageBox]::Show(
    "Press OK to continue installing apps.",
    "Installation Status",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
)

# ---------- Build UI ----------
$ui = New-ProgressForm
$form = $ui.Form
$label = $ui.Title
$sub  = $ui.Subtitle
$progressBar = $ui.Bar

# Shortcuts we expect
$shortcutNames = @(
    "Adobe Acrobat.lnk",
    "Google Chrome.lnk"
)

# Derived paths
$publicDesktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonDesktopDirectory)

# ---------- Timer to poll installation status ----------
$checkTimer = New-Object System.Windows.Forms.Timer
$checkTimer.Interval = 5000   # 5 seconds

$checkTimer.Add_Tick({
    # Detect installed shortcuts
    $installed = @()
    foreach ($name in $shortcutNames) {
        $path = Join-Path $publicDesktopPath $name
        if (Test-Path $path -PathType Leaf) { $installed += $name }
    }

    $count = $installed.Count
    $total = $shortcutNames.Count

    if ($count -eq 0) {
        $label.Text = "Installing applications…"
        $sub.Text   = "This may take several minutes."
        if ($progressBar.Style -ne 'Marquee') { $progressBar.Style = 'Marquee'; $progressBar.MarqueeAnimationSpeed = 30 }
    }
    else {
        # Switch to determinate and show % based on count (0/50/100 for two apps)
        if ($progressBar.Style -ne 'Continuous') { $progressBar.Style = 'Continuous'; $progressBar.MarqueeAnimationSpeed = 0 }
        $percent = [int][math]::Round(($count / $total) * 100,0)
        $progressBar.Value = [Math]::Min($percent, 100)

        # Friendly status text
        $statusBits = @()
        if ($installed -contains "Google Chrome.lnk") { $statusBits += "Chrome detected" }
        if ($installed -contains "Adobe Acrobat.lnk") { $statusBits += "Acrobat detected" }
        if ($statusBits.Count -gt 0) {
            $label.Text = "Finalizing installation…"
            $sub.Text   = ($statusBits -join " · ") + "  ($percent`%)"
        }
    }

    # All found → mark, stop, close, prompt reboot
    if ($count -eq $total) {
        try { New-Item -Path $AppsAreInstalled -ItemType File -Force | Out-Null } catch {}
        $checkTimer.Stop()
        $form.Hide()

        $result = [System.Windows.Forms.MessageBox]::Show(
            "Applications are installed. You must reboot your computer. Press OK to reboot.",
            "Reboot Required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            Restart-Computer -Force
        }
        $form.Close()
    }
})

# Start timer when form is shown
$form.Add_Shown({ $checkTimer.Start() })

# Show modal dialog to keep script alive while UI runs
[void]$form.ShowDialog()
