#!/bin/bash

# SMTP-to-Gotify Installer Script
# This script installs, uninstalls, and validates the SMTP-to-Gotify application.
# Run with --uninstall to remove the application.

# URLs for source files (easily changeable)
MAIN_GO_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/main.go"
SERVICE_FILE_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/smtp-to-gotify.service"

# Default installation paths
INSTALL_DIR="/opt/smtp-to-gotify"
BINARY_PATH="${INSTALL_DIR}/smtp-to-gotify"
SERVICE_FILE="/etc/systemd/system/smtp-to-gotify.service"
RC_SCRIPT="/usr/local/etc/rc.d/smtp-to-gotify"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo -e "${2}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function to log errors and exit
error_exit() {
    log "ERROR: $1" "${RED}"
    exit 1
}

# Function to log success
success() {
    log "SUCCESS: $1" "${GREEN}"
}

# Function to log info
info() {
    log "INFO: $1" "${YELLOW}"
}

# Function to check if command executed successfully
check_status() {
    if [ $? -ne 0 ]; then
        error_exit "$1"
    fi
}

# Function to rollback changes if installation fails
rollback() {
    info "Rolling back changes due to installation failure..."
    if [ -d "$INSTALL_DIR" ]; then
        info "Removing installation directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR" || info "Failed to remove $INSTALL_DIR, manual cleanup may be needed."
    fi
    if [ -f "$SERVICE_FILE" ]; then
        info "Removing service file: $SERVICE_FILE"
        rm -f "$SERVICE_FILE" || info "Failed to remove $SERVICE_FILE, manual cleanup may be needed."
        systemctl daemon-reload || info "Failed to reload systemd, manual cleanup may be needed."
    fi
    if [ -f "$RC_SCRIPT" ]; then
        info "Removing rc.d script: $RC_SCRIPT"
        rm -f "$RC_SCRIPT" || info "Failed to remove $RC_SCRIPT, manual cleanup may be needed."
    fi
    error_exit "Installation failed. Changes have been rolled back."
}

# Function to detect package manager and install dependencies
install_dependencies() {
    info "Installing dependencies for $DISTRO..."
    case $DISTRO in
        "Debian" | "Ubuntu" | "TrueNAS Scale")
            PKG_MANAGER="apt"
            UPDATE_CMD="apt update"
            INSTALL_CMD="apt install -y golang git curl"
            ;;
        "pfSense")
            PKG_MANAGER="pkg"
            UPDATE_CMD="pkg update"
            INSTALL_CMD="pkg install -y go git curl"
            ;;
        *)
            error_exit "Unsupported distribution for dependency installation."
            ;;
    esac

    info "Updating package lists..."
    $UPDATE_CMD
    check_status "Failed to update package lists."

    info "Installing dependencies (Go, Git, Curl)..."
    $INSTALL_CMD
    check_status "Failed to install dependencies."
    success "Dependencies installed successfully."
}

# Function to compile the Go program
compile_program() {
    info "Downloading source code from $MAIN_GO_URL..."
    mkdir -p "$INSTALL_DIR/src"
    check_status "Failed to create source directory $INSTALL_DIR/src."

    curl -sSL "$MAIN_GO_URL" -o "$INSTALL_DIR/src/main.go"
    check_status "Failed to download source code from $MAIN_GO_URL."

    info "Compiling SMTP-to-Gotify binary..."
    cd "$INSTALL_DIR/src"
    go build -o "$BINARY_PATH" main.go
    check_status "Failed to compile SMTP-to-Gotify binary."

    chmod +x "$BINARY_PATH"
    check_status "Failed to set executable permissions on $BINARY_PATH."
    success "Binary compiled and installed at $BINARY_PATH."
}

# Function to set up the systemd service for Linux
setup_systemd_service() {
    info "Downloading service file from $SERVICE_FILE_URL..."
    curl -sSL "$SERVICE_FILE_URL" -o "$SERVICE_FILE"
    check_status "Failed to download service file from $SERVICE_FILE_URL."

    info "Replacing user placeholder in service file with $SERVICE_USER..."
    sed -i "s/%USER%/$SERVICE_USER/g" "$SERVICE_FILE"
    check_status "Failed to configure service file with user $SERVICE_USER."

    info "Reloading systemd daemon..."
    systemctl daemon-reload
    check_status "Failed to reload systemd daemon."

    info "Enabling SMTP-to-Gotify service to start on boot..."
    systemctl enable smtp-to-gotify
    check_status "Failed to enable SMTP-to-Gotify service."

    success "Systemd service setup completed at $SERVICE_FILE."
}

# Function to set up the rc.d script for FreeBSD/pfSense
setup_rcd_script() {
    info "Creating rc.d script for FreeBSD/pfSense at $RC_SCRIPT..."
    cat > "$RC_SCRIPT" << 'EOF'
#!/bin/sh

# PROVIDE: smtp_to_gotify
# REQUIRE: LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="smtp_to_gotify"
rcvar="smtp_to_gotify_enable"
load_rc_config $name

: ${smtp_to_gotify_enable="NO"}
: ${smtp_to_gotify_user="%USER%"}
: ${smtp_to_gotify_binary="/opt/smtp-to-gotify/smtp-to-gotify"}
: ${smtp_to_gotify_workdir="/opt/smtp-to-gotify"}
: ${smtp_to_gotify_env="RUN_AS_SERVICE=true"}

pidfile="/var/run/${name}.pid"
command="/usr/sbin/daemon"
command_args="-p ${pidfile} -u ${smtp_to_gotify_user} ${smtp_to_gotify_env} ${smtp_to_gotify_binary}"

start_precmd="smtp_to_gotify_prestart"
stop_postcmd="smtp_to_gotify_poststop"

smtp_to_gotify_prestart()
{
    if [ ! -x "${smtp_to_gotify_binary}" ]; then
        err 1 "Binary not found: ${smtp_to_gotify_binary}"
    fi
    return 0
}

smtp_to_gotify_poststop()
{
    rm -f "${pidfile}"
    return 0
}

run_rc_command "$1"
EOF
    check_status "Failed to create rc.d script at $RC_SCRIPT."

    info "Replacing user placeholder in rc.d script with $SERVICE_USER..."
    sed -i '' "s/%USER%/$SERVICE_USER/g" "$RC_SCRIPT"
    check_status "Failed to configure rc.d script with user $SERVICE_USER."

    info "Setting executable permissions on rc.d script..."
    chmod +x "$RC_SCRIPT"
    check_status "Failed to set executable permissions on $RC_SCRIPT."

    info "Enabling SMTP-to-Gotify service to start on boot..."
    sysrc smtp_to_gotify_enable="YES"
    check_status "Failed to enable SMTP-to-Gotify service in rc.conf."

    success "FreeBSD rc.d script setup completed at $RC_SCRIPT."
}

# Function to uninstall the application
uninstall() {
    info "Uninstalling SMTP-to-Gotify..."

    if [ "$DISTRO" != "pfSense" ]; then
        info "Stopping SMTP-to-Gotify service..."
        systemctl stop smtp-to-gotify 2>/dev/null || info "Service was not running or not installed."

        info "Disabling SMTP-to-Gotify service..."
        systemctl disable smtp-to-gotify 2>/dev/null || info "Service was not enabled or not installed."

        info "Removing service file: $SERVICE_FILE..."
        rm -f "$SERVICE_FILE" 2>/dev/null || info "Service file not found or already removed."
        systemctl daemon-reload 2>/dev/null || info "Failed to reload systemd, manual cleanup may be needed."
    else
        info "Stopping SMTP-to-Gotify service on FreeBSD..."
        service smtp_to_gotify stop 2>/dev/null || info "Service was not running or not installed."

        info "Disabling SMTP-to-Gotify service in rc.conf..."
        sysrc -x smtp_to_gotify_enable 2>/dev/null || info "Service was not enabled or not installed."

        info "Removing rc.d script: $RC_SCRIPT..."
        rm -f "$RC_SCRIPT" 2>/dev/null || info "rc.d script not found or already removed."
    fi

    info "Removing installation directory: $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR" 2>/dev/null || info "Failed to remove $INSTALL_DIR, manual cleanup may be needed."

    success "SMTP-to-Gotify has been uninstalled successfully."
    exit 0
}

# Main installation process
main_install() {
    info "Starting SMTP-to-Gotify installation..."

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root (use sudo)."
    fi

    # Prompt for distribution
    info "Select the distribution to install on:"
    echo "1. Debian"
    echo "2. Ubuntu"
    echo "3. TrueNAS Scale"
    echo "4. pfSense"
    read -p "Enter the number of your distribution (1-4): " DISTRO_CHOICE

    case $DISTRO_CHOICE in
        1) DISTRO="Debian" ;;
        2) DISTRO="Ubuntu" ;;
        3) DISTRO="TrueNAS Scale" ;;
        4) DISTRO="pfSense" ;;
        *) error_exit "Invalid distribution choice. Please select a number between 1 and 4." ;;
    esac
    success "Selected distribution: $DISTRO"

    # Prompt for installation directory
    read -p "Use default installation directory ($INSTALL_DIR)? (y/n): " USE_DEFAULT_DIR
    if [ "$USE_DEFAULT_DIR" != "y" ] && [ "$USE_DEFAULT_DIR" != "Y" ]; then
        read -p "Enter custom installation directory: " CUSTOM_DIR
        INSTALL_DIR="$CUSTOM_DIR"
        BINARY_PATH="${INSTALL_DIR}/smtp-to-gotify"
    fi
    success "Installation directory set to: $INSTALL_DIR"

    # Prompt for service user
    read -p "Enter the user to run the SMTP-to-Gotify service (default: smtp-gotify): " SERVICE_USER
    if [ -z "$SERVICE_USER" ]; then
        SERVICE_USER="smtp-gotify"
    fi
    id "$SERVICE_USER" >/dev/null 2>&1 || {
        info "Creating user $SERVICE_USER..."
        if [ "$DISTRO" != "pfSense" ]; then
            useradd -m -s /bin/false "$SERVICE_USER"
        else
            pw useradd -n "$SERVICE_USER" -s /sbin/nologin -m
        fi
        check_status "Failed to create user $SERVICE_USER."
    }
    success "Service will run as user: $SERVICE_USER"

    # Create installation directory and set permissions
    info "Creating installation directory: $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    check_status "Failed to create installation directory $INSTALL_DIR."
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    check_status "Failed to set ownership of $INSTALL_DIR to $SERVICE_USER."
    success "Installation directory created and permissions set."

    # Install dependencies based on distribution
    install_dependencies || rollback

    # Compile the program
    compile_program || rollback

    # Set up the service based on distribution
    if [ "$DISTRO" != "pfSense" ]; then
        setup_systemd_service || rollback
    else
        setup_rcd_script || rollback
    fi

    # Ask if user wants to start the service now
    read -p "Do you want to start the SMTP-to-Gotify service now? (y/n): " START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        if [ "$DISTRO" != "pfSense" ]; then
            info "Starting SMTP-to-Gotify service..."
            systemctl start smtp-to-gotify
            check_status "Failed to start SMTP-to-Gotify service."
            success "SMTP-to-Gotify service started successfully."
        else
            info "Starting SMTP-to-Gotify service on FreeBSD..."
            service smtp_to_gotify start
            check_status "Failed to start SMTP-to-Gotify service."
            success "SMTP-to-Gotify service started successfully."
        fi
    else
        if [ "$DISTRO" != "pfSense" ]; then
            info "Service not started. You can start it later with 'systemctl start smtp-to-gotify'."
        else
            info "Service not started. You can start it later with 'service smtp_to_gotify start'."
        fi
    fi

    success "SMTP-to-Gotify installation completed successfully!"
    info "Configuration files are located at: $INSTALL_DIR/config.yaml"
    info "Run '$BINARY_PATH config' to configure settings interactively."
    if [ "$DISTRO" != "pfSense" ]; then
        info "Use 'systemctl status smtp-to-gotify' to check service status."
    else
        info "Use 'service smtp_to_gotify status' to check service status."
    fi
}

# Check for uninstall argument
if [ "$1" = "--uninstall" ]; then
    # Prompt for distribution during uninstall to handle correct cleanup
    info "Select the distribution to uninstall from:"
    echo "1. Debian"
    echo "2. Ubuntu"
    echo "3. TrueNAS Scale"
    echo "4. pfSense"
    read -p "Enter the number of your distribution (1-4): " DISTRO_CHOICE

    case $DISTRO_CHOICE in
        1) DISTRO="Debian" ;;
        2) DISTRO="Ubuntu" ;;
        3) DISTRO="TrueNAS Scale" ;;
        4) DISTRO="pfSense" ;;
        *) error_exit "Invalid distribution choice. Please select a number between 1 and 4." ;;
    esac
    uninstall
fi

# Run main installation
main_install
