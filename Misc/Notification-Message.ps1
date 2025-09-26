# Modern Notification Window Script
# Usage: Set the variables and run the script

param(
    [string]$MessageContent = "This is a sample notification message from {Company}. You can include <b>bold text</b>, <i>italic text</i>, and other formatting.",
    [string]$FormTitle = "{Company}",
    [string]$HeaderText = "Message from {Company}"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Create the form
$form = New-Object System.Windows.Forms.Form
$form.Text = $FormTitle
$form.Size = New-Object System.Drawing.Size(450, 300)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

# Modern color scheme
$primaryColor = [System.Drawing.Color]::FromArgb(45, 45, 48)      # Dark gray
$accentColor = [System.Drawing.Color]::FromArgb(0, 122, 204)      # Blue
$textColor = [System.Drawing.Color]::FromArgb(241, 241, 241)      # Light gray
$buttonColor = [System.Drawing.Color]::FromArgb(62, 62, 66)       # Medium gray

$form.BackColor = $primaryColor

# Create header panel
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Size = New-Object System.Drawing.Size(450, 60)
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.BackColor = $accentColor

# Header text (configurable)
$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = $HeaderText
$headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$headerLabel.ForeColor = [System.Drawing.Color]::White
$headerLabel.Location = New-Object System.Drawing.Point(20, 18)
$headerLabel.Size = New-Object System.Drawing.Size(400, 25)
$headerLabel.TextAlign = "MiddleLeft"

$headerPanel.Controls.Add($headerLabel)

# Header title (hidden but kept for future use)
# $headerLabel is now used above for the main header text
# This section kept for reference/future logo integration

# Create rich text box for message content
$richTextBox = New-Object System.Windows.Forms.RichTextBox
$richTextBox.Location = New-Object System.Drawing.Point(20, 80)
$richTextBox.Size = New-Object System.Drawing.Size(390, 140)
$richTextBox.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
$richTextBox.ForeColor = $textColor
$richTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$richTextBox.BorderStyle = "None"
$richTextBox.ReadOnly = $true
$richTextBox.ScrollBars = "Vertical"

# Function to parse simple HTML-like tags and apply formatting
function Set-RichTextContent {
    param($rtb, $content)
    
    $rtb.Clear()
    $rtb.Text = $content
    
    # Remove HTML tags but apply formatting
    $content = $content -replace '<b>', '' -replace '</b>', ''
    $content = $content -replace '<i>', '' -replace '</i>', ''
    $content = $content -replace '<u>', '' -replace '</u>', ''
    
    $rtb.Text = $content
    
    # Apply bold formatting
    $originalContent = $MessageContent
    $boldPattern = '<b>(.*?)</b>'
    $matches = [regex]::Matches($originalContent, $boldPattern)
    foreach ($match in $matches) {
        $text = $match.Groups[1].Value
        $start = $rtb.Text.IndexOf($text)
        if ($start -ge 0) {
            $rtb.Select($start, $text.Length)
            $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Bold)
        }
    }
    
    # Apply italic formatting
    $italicPattern = '<i>(.*?)</i>'
    $matches = [regex]::Matches($originalContent, $italicPattern)
    foreach ($match in $matches) {
        $text = $match.Groups[1].Value
        $start = $rtb.Text.IndexOf($text)
        if ($start -ge 0) {
            $rtb.Select($start, $text.Length)
            $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Italic)
        }
    }
    
    # Reset selection
    $rtb.Select(0, 0)
}

# Set the message content
Set-RichTextContent -rtb $richTextBox -content $MessageContent

# Create OK button
$okButton = New-Object System.Windows.Forms.Button
$okButton.Location = New-Object System.Drawing.Point(330, 235)
$okButton.Size = New-Object System.Drawing.Size(80, 30)
$okButton.Text = "OK"
$okButton.BackColor = $buttonColor
$okButton.ForeColor = $textColor
$okButton.FlatStyle = "Flat"
$okButton.FlatAppearance.BorderSize = 0
$okButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

# Hover effects for button
$okButton.Add_MouseEnter({
    $this.BackColor = $accentColor
})

$okButton.Add_MouseLeave({
    $this.BackColor = $buttonColor
})

# Button click event
$okButton.Add_Click({
    $form.Close()
})

# Add controls to form
$form.Controls.Add($headerPanel)
$form.Controls.Add($richTextBox)
$form.Controls.Add($okButton)

# Show the form
$form.Add_Shown({
    $form.Activate()
})

# Play system notification sound
[System.Media.SystemSounds]::Asterisk.Play()

# Show the dialog
[void]$form.ShowDialog()

# Cleanup
$form.Dispose()