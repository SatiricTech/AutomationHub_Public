#!/bin/bash

# Script to rename your Mac via Terminal
# This sets the ComputerName, LocalHostName, and HostName

#KB INFO#
########################################################
# Upload this script to a location on the mac you can get to (the hidden ninjaRMM/programfiles folder is a good place if using NinjaRMM
# The background terminal as root loads to that location /Applications/ninjaRMM/programfiles/ )
# This script commonly needs permissions added use chmod below to fix that.
# chmod +x Rename_macOS_Device.sh
# Run the script with sudo ./Rename_macOS_Device.sh
########################################################

NEW_NAME="<Your Desired Name Here>"
NEW_HOSTNAME="<Your Desired Hostname Here>"

echo "Renaming Mac to: $NEW_NAME"
echo "Setting hostname to: $NEW_HOSTNAME"

# Set the computer name (as it appears in Finder and System Preferences)
sudo scutil --set ComputerName "$NEW_NAME"

# Set the local hostname (used for Bonjour)
sudo scutil --set LocalHostName "$NEW_HOSTNAME"

# Set the hostname (used for network identification)
sudo scutil --set HostName "$NEW_HOSTNAME"

echo ""
echo "Mac has been renamed successfully!"
echo "Computer Name: $NEW_NAME"
echo "Local Hostname: $NEW_HOSTNAME"
echo "Hostname: $NEW_HOSTNAME"
echo ""
echo "Note: You may need to restart for all changes to take effect."