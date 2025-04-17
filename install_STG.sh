#!/bin/bash

# Install script for SMTP to Gotify Forwarder
# URL: https://raw.githubusercontent.com/NeoMetra/STG/main/install_STG.sh

# Colors for UI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging and error handling
LOG_FILE="/var/log/stg_install.log"
exec 1>>"$LOG_FILE"
exec 2>&1

# Function to display messages
msg() {
    echo -e "${2}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function for error handling
error_exit() {
    msg "ERROR: $1" "${RED}"
    exit 1
}

# Function to check if script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Use sudo or switch to the root user."
    fi
}

# Function to display a header
display_header() {
    clear
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN} SMTP to Gotify Forwarder Installer${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo ""
}

# Function to install dependencies for Go compilation on Debian 12
install_dependencies() {
    msg "Installing dependencies..." "${YELLOW}"
    apt update || error_exit "Failed to update package lists."
    apt install -y golang git curl || error_exit "Failed to install dependencies."
    msg "Dependencies installed successfully." "${GREEN}"
}

# Function to download and compile the Go application
compile_go_app() {
    msg "Downloading source code..." "${YELLOW}"
    mkdir -p /tmp/stg_build || error_exit "Failed to create temporary build directory."
    curl -sSL "https://raw.githubusercontent.com/NeoMetra/STG/main/main.go" -o /tmp/stg_build/main.go || error_exit "Failed to download source code."
    
    msg "Compiling Go application..." "${YELLOW}"
    cd /tmp/stg_build || error_exit "Failed to change to build directory."
    go build -o smtp-to-gotify main.go || error_exit "Failed to compile Go application."
    msg "Compilation successful." "${GREEN}"
}

# Function to install the binary
install_binary() {
    msg "Installing binary..." "${YELLOW}"
    mkdir -p /opt/smtp-to-gotify || error_exit "Failed to create installation directory."
    cp /tmp/stg_build/smtp-to-gotify /opt/smtp-to-gotify/ || error_exit "Failed to copy binary to installation directory."
    chmod 755 /opt/smtp-to-gotify/smtp-to-gotify || error_exit "Failed to set permissions on binary."
    msg "Binary installed successfully." "${GREEN}"
}

# Function to set up the systemd service
setup_service() {
    msg "Setting up systemd service..." "${YELLOW}"
    cat > /etc/systemd/system/smtp-to-gotify.service << EOF
[Unit]
Description=SMTP to Gotify Forwarder
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/smtp-to-gotify
ExecStart=/opt/smtp-to-gotify/smtp-to-gotify
Restart=always
RestartSec=10
SyslogIdentifier=smtp-to-gotify
Environment=RUN_AS_SERVICE=true
StandardOutput=journal
Standard.RangeError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    systemctl enable smtp-to-gotify.service || error_exit "Failed to enable systemd service."
    msg "Systemd service set up successfully." "${GREEN}"
}

# Function to clean up temporary files
cleanup() {
    msg "Cleaning up temporary files..." "${YELLOW}"
    rm -rf /tmp/stg_build || error_exit "Failed to clean up temporary files."
    msg "Cleanup completed." "${GREEN}"
}

# Main installation process
main() {
    display_header
    check_root

    msg "Starting installation process..." "${YELLOW}"
    echo "Log file: $LOG_FILE"
    echo ""

    install_dependencies
    compile_go_app
    install_binary
    setup_service
    cleanup

    msg "Installation completed successfully!" "${GREEN}"
    echo -e "${YELLOW}To start the service, run:${NC}"
    echo -e "  systemctl start smtp-to-gotify"
    echo -e "${YELLOW}To check the status of the service, run:${NC}"
    echo -e "  systemctl status smtp-to-gotify"
    echo ""
    echo -e "${GREEN}===========================================${NC}"
}

# Trap errors and display a message
trap 'error_exit "An unexpected error occurred on line $LINENO. Check $LOG_FILE for details."' ERR

# Run the main function
main
