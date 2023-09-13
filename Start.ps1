# Allow PS script
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force

# Define the path to the text file
$filePath = "C:\ProgramData\TMT\Done.txt"

# Create the TMT folder if it doesn't exist
$TMTFolder = "C:\ProgramData\TMT"
if (-not (Test-Path -Path $TMTFolder -PathType Container)) {
    New-Item -Path $TMTFolder -ItemType Directory
}

# Check if the text file exists
if (Test-Path -Path $filePath -PathType Leaf) {
    Write-Host "Done.txt file exists. Script will exit."
    # You can add additional actions here if needed
} else {
    Write-Host "Done.txt file does not exist."

    # Download the MasterScript.ps1 file from GitHub
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/MasterScript/main/MasterScript.ps1" -OutFile "$TMTFolder\MasterScript.ps1"

    # Define the path to the MasterScript.ps1
    $scriptPath = "c:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe -noexit -command & '$TMTFolder\MasterScript.ps1'"

    # Modify the RunOnce registry key to run the script
    $registryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    $registryName = "RunTMTScript"

    if (-not (Test-Path -Path $registryPath)) {
        New-Item -Path $registryPath -Force
    }

    Set-ItemProperty -Path $registryPath -Name $registryName -Value $scriptPath

    Write-Host "Registry key modified to run MasterScript.ps1 on next boot."

    # Prompt the user to reboot the computer
    # $a = new-object -comobject wscript.shell
    # $b = $a.popup("Please press OK to reboot the computer and complete the setup", 0, "Please Press OK", 0x0)
    # if ($b -eq 1) {
        # Reboot the computer
        # Restart-Computer -Force
    # }
	
# Define the scheduled task action to display a reboot prompt
$action = New-ScheduledTaskAction -Execute 'shutdown' -Argument '/r /f /t 0'

# Define the trigger to run the task in 2 minutes
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)

# Create the scheduled task
Register-ScheduledTask -TaskName "RebootPromptTask" -Action $action -Trigger $trigger -User "NT AUTHORITY\SYSTEM" -Force

# Start the scheduled task
Start-ScheduledTask -TaskName "RebootPromptTask"

# Define the message box as a form and set it to be always on top
$msgBox = New-Object -TypeName System.Windows.Forms.MessageBox
$msgBox.TopMost = $true

# Prompt the user to reboot
$confirmation = $msgBox.Show("The system will reboot in 2 minutes. Do you want to restart now?", "Reboot Confirmation", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)

# Check user's choice
if ($confirmation -eq [System.Windows.Forms.DialogResult]::OK) {
    # Initiate the reboot immediately
    Restart-Computer -Force
}
	
}

# End of the script
