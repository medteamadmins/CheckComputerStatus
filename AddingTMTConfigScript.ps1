# Define the path to the text file
$filePath = "C:\Users\$($ENV:USERNAME)\AppData\Done1.0.txt"
$AppsAreInstalled = "C:\ProgramData\TMT\AppsAreInstalled1.0.txt"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

#------PROGRESS BAR------

# Create a form
$form = New-Object Windows.Forms.Form
$form.Text = "Apps are Installing"
$form.Size = New-Object Drawing.Size(300, 100)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $False
$form.MinimizeBox = $False

# Create a progress bar
$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Location = New-Object Drawing.Point(10, 30)
$progressBar.Width = 360

# Create a label
$label = New-Object Windows.Forms.Label
$label.Text = ""
$label.Location = New-Object Drawing.Point(10, 10)

# Add controls to the form
$form.Controls.Add($label)
$form.Controls.Add($progressBar)

# Function to update the progress bar
function Update-ProgressBar {
    if ($progressBar.Value -lt $progressBar.Maximum) {
        $progressBar.Value++    }
    else {
        $timer.Stop()
        $form.Close()
    }
}

#----- END PROGRESS BAR-------


# Create the TMT folder if it doesn't exist
$TMTFolder = "C:\ProgramData\TMT"
if (-not (Test-Path -Path $TMTFolder -PathType Container)) {
    New-Item -Path $TMTFolder -ItemType Directory
}

# Check if the text file exists
if (Test-Path -Path $filePath -PathType Leaf) {
    Write-Host "Done1.0.txt file exists. Script will exit."
    # You can add additional actions here if needed
} else {
    Write-Host "Done1.0.txt file does not exist."

    # Download the MasterScript.ps1 file from GitHub
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/MasterScript/main/TMTconfigurationScript.ps1" -OutFile "$TMTFolder\TMTconfigurationScript.ps1"

    # Define the path to the MasterScript.ps1
    $scriptPath = "c:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -WindowStyle Minimized -noexit -command & '$TMTFolder\TMTconfigurationScript.ps1'"

    # Modify the RunOnce registry key to run the script
    $registryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    $registryName = "RunTMTScript"

    if (-not (Test-Path -Path $registryPath)) {
        New-Item -Path $registryPath -Force
    }

    Set-ItemProperty -Path $registryPath -Name $registryName -Value $scriptPath

    Write-Host "Registry key modified to run MasterScript.ps1 on next boot."
	
	
	# Test-path if C:\ProgramData\TMT\AppsAreInstalled1.0.txt was created.
	If (Test-path $AppsAreInstalled){
		# Script Will Exit.
	} Else {
	
	# Display the notification
	$Prompt = [System.Windows.Forms.MessageBox]::Show("Press OK to Continue installing Apps.", "Installation Status", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)

	# Display Progress BAR------
	$form.Show()
	
#------------------------- NEW FUNCTION.

	# Define the names of the software shortcuts you want to check for
	$shortcutNames = @("Adobe Acrobat.lnk", "Google Chrome.lnk")

	while ($true) {
		# Set the path to the Public Desktop folder
		$publicDesktopPath = [System.IO.Path]::Combine([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonDesktopDirectory))

		# Initialize an array to store the results
		$installedShortcuts = @()

		# Check if the specified software shortcuts exist in the Public Desktop folder
		foreach ($shortcutName in $shortcutNames) {
			$shortcutPath = [System.IO.Path]::Combine($publicDesktopPath, $shortcutName)
	
			if (Test-Path $shortcutPath -PathType Leaf) {
				$installedShortcuts += $shortcutName
			}
		}
			
		# Check if both Adobe Acrobat Reader and Google Chrome shortcuts are present
		if ($installedShortcuts.Count -eq 2) {
			New-Item -Path "C:\ProgramData\TMT\AppsAreInstalled1.0.txt" # DO NOT delete this line.
			#Close the form.
			$form.Close()
			# Display a message box
			$result = [System.Windows.Forms.MessageBox]::Show("Application are installed. You must reboot your computer. Press OK to reboot.", "Reboot Confirmation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)

			# Check the user's choice
			if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
				
				# Reboot the computer
				Restart-Computer -Force
			} else {
            # User canceled, do nothing
			}
        
			break  # Exit the loop after triggering the reboot
		}

		# Wait for 60 seconds before checking again if either Adobe or Chrome is not installed
		Update-ProgressBar
		Start-Sleep -Seconds 60
		}
# ---------------------- END NEW FUNCTION.
	}
}

# End of the script
