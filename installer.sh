#!/bin/bash

# Check if the script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

# Install the script
install() {
    local SCRIPT_NAME="$1"
    local SCRIPT_URL="https://raw.githubusercontent.com/snaeim/wg-scripts/refs/heads/main/$SCRIPT_NAME.sh"
    local SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
    local SCRIPT_DB_PATH="/var/lib/$SCRIPT_NAME"
    
    # Download the script
    if curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"; then
        echo "Downloaded $SCRIPT_NAME successfully."
    else
        echo "Failed to download $SCRIPT_NAME."
        exit 1
    fi
    # Make it executable
    chmod +x "$SCRIPT_PATH" 
    # Create the directory for the script database
    if [ -d "$SCRIPT_DB_PATH" ]; then
        echo "Directory $SCRIPT_DB_PATH already exists."
    else
        mkdir -p "$SCRIPT_DB_PATH"
        chmod 755 "$SCRIPT_DB_PATH"
    fi

    return 0
}

install_cronjob() {
    local SCRIPT_NAME="$1"
    local SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
    if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH"; then
        echo "Cron job already exists for $SCRIPT_NAME"
    else
        # Add the new cron job
        (crontab -l 2>/dev/null; echo "* * * * * $SCRIPT_PATH update >/dev/null 2>&1") | crontab -
        echo "Cron job added: $CRON_SCHEDULE"
    fi
    
    return 0
}

install "wgctl"
install "wgstat"
install_cronjob "wgstat"
exit 0