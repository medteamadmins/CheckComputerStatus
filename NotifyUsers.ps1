# Define the list of expected members in the Administrators group
$expectedMembers = @("Administrator", "MiPCSAdmin")

# Get the members of the Administrators group
$administratorsGroup = [ADSI]"WinNT://./Administrators,group"
$members = $administratorsGroup.Invoke("Members") | ForEach-Object {
    $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
}

# Check if the members match the expected list
$additionalMembers = $members | Where-Object { $_ -notin $expectedMembers }

# Display the appropriate notification
if ($additionalMembers.Count -eq 0) {
    # There are no additional members
    [System.Windows.Forms.MessageBox]::Show("The computer is ready to use", "Computer Status", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
} else {
    # There are additional members
    [System.Windows.Forms.MessageBox]::Show("Please DO NOT USE this computer at this moment.

We are setting up this computer. It will restart as we complete", "Configuration is in Progress", "OK", [System.Windows.Forms.MessageBoxIcon]::Stop)

# Restart computer in 40 minutes
shutdown.exe /r -t 2400
}
