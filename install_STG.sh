#!/bin/bash

# SMTP-to-Gotify Installer Script
# Installs or uninstalls the SMTP-to-Gotify application across multiple distributions.
# Usage: curl -sSL https://raw.githubusercontent.com/NeoMetra/STG/main/install_STG.sh | bash
# Uninstall: curl -sSL https://raw.githubusercontent.com/NeoMetra/STG/main/install_STG.sh | bash -s -- --uninstall

# Configuration Variables (easily changeable)
MAIN_GO_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/main.go"
SERVICE_FILE_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/smtp-to-gotify.service"
DEFAULT_INSTALL_DIR="/opt/smtp-to-gotify"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/smtp-to-gotify.service"
FREEBSD_RC_SCRIPT="/usr/local/etc/rc.d/smtp-to-gotify"
TEMP_DIR="/tmp/smtp-to-gotify-install-$(date +%s)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to log messages with timestamp
log() {
    echo -e "${2}[$(date '+%H:%M:%S')] $1${NC}"
}

# Function to log errors and exit
error_exit() {
    log "ERROR: $1" "${RED}"
    if [ -n "$2" ]; then
        log "Advice: $2" "${YELLOW}"
    fi
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

# Function to log headers for visual structure
header() {
    echo -e "${CYAN}=== $1 ===${NC}"
}

# Function to check command status and handle errors
check_status() {
    if [ $? -ne 0 ]; then
        error_exit "$1" "$2"
    fi
}

# Function to rollback changes on failure
rollback() {
    info "Rolling back changes due to failure..."
    [ -d "$INSTALL_DIR" ] && { info "Removing $INSTALL_DIR..."; rm -rf "$INSTALL_DIR" 2>/dev/null || info "Warning: Could not remove $INSTALL_DIR."; }
    [ -f "$SYSTEMD_SERVICE_FILE" ] && { info "Removing $SYSTEMD_SERVICE_FILE..."; rm -f "$SYSTEMD_SERVICE_FILE" 2>/dev/null || info "Warning: Could not remove $SYSTEMD_SERVICE_FILE."; systemctl daemon-reload 2>/dev/null || info "Warning: Could not reload systemd."; }
    [ -f "$FREEBSD_RC_SCRIPT" ] && { info "Removing $FREEBSD_RC_SCRIPT..."; rm -f "$FREEBSD_RC_SCRIPT" 2>/dev/null || info "Warning: Could not remove $FREEBSD_RC_SCRIPT."; }
    [ -d "$TEMP_DIR" ] && { info "Removing temporary files..."; rm -rf "$TEMP_DIR" 2>/dev/null || info "Warning: Could not remove $TEMP_DIR."; }
    error_exit "Installation failed. Changes rolled back where possible." "Review error messages above for details."
}

# Function to check root privileges
check_root() {
    header "Privilege Check"
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script requires root privileges." "Run with 'sudo' or as root user."
    fi
    success "Root privileges confirmed."
}

# Function to perform pre-flight checks
check_preflight() {
    header "System Checks"
    info "Checking internet connectivity..."
    ping -c 1 -W 2 google.com >/dev/null 2>&1 || { error_exit "No internet connection detected." "Ensure your system is online and retry."; }
    success "Internet connection confirmed."

    info "Checking disk space..."
    local space=$(df -k / | tail -1 | awk '{print $4}')
    [ "$space" -lt 524288 ] && { error_exit "Insufficient disk space (less than 500MB on /)." "Free up space or choose a different install location."; }
    success "Disk space sufficient."

    info "Checking for required tools (curl)..."
    command -v curl >/dev/null 2>&1 || { error_exit "curl is not installed." "Install curl using your package manager and retry."; }
    success "Required tools present."
}

# Function to prompt user for input with default option
prompt_user() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    local input
    if [ -n "$default" ]; then
        read -p "$prompt (default: $default) [or 'cancel' to exit]: " input
        [ "$input" = "cancel" ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
        [ -z "$input" ] && input="$default"
    else
        read -p "$prompt [or 'cancel' to exit]: " input
        [ "$input" = "cancel" ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
        while [ -z "$input" ]; do
            info "Input cannot be empty."
            read -p "$prompt [or 'cancel' to exit]: " input
            [ "$input" = "cancel" ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
        done
    fi
    eval "$var_name='$input'"
}

# Function to prompt for yes/no response
prompt_yes_no() {
    local prompt="$1"
    local response
    read -p "$prompt (y/n) [or 'cancel' to exit]: " response
    while true; do
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            cancel) error_exit "Installation cancelled by user." "Run the script again to restart." ;;
            *) info "Please enter 'y' or 'n'."; read -p "$prompt (y/n) [or 'cancel' to exit]: " response ;;
        esac
    done
}

# Function to select distribution
select_distribution() {
    header "Distribution Selection"
    info "Which distribution are you installing on?"
    echo "1. Debian"
    echo "2. Ubuntu"
    echo "3. TrueNAS Scale"
    echo "4. pfSense (FreeBSD)"
    local choice
    read -p "Enter number (1-4) [or 'cancel' to exit]: " choice
    while true; do
        case "$choice" in
            1) DISTRO="Debian"; DISTRO_TYPE="linux"; return 0 ;;
            2) DISTRO="Ubuntu"; DISTRO_TYPE="linux"; return 0 ;;
            3) DISTRO="TrueNAS Scale"; DISTRO_TYPE="linux"; return 0 ;;
            4) DISTRO="pfSense"; DISTRO_TYPE="freebsd"; return 0 ;;
            cancel) error_exit "Installation cancelled by user." "Run the script again to restart." ;;
            *) info "Invalid choice. Enter a number between 1 and 4."; read -p "Enter number (1-4) [or 'cancel' to exit]: " choice ;;
        esac
    done
}

# Function to download files with retry logic
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry=0
    info "Downloading from $url..."
    while [ $retry -lt $max_retries ]; do
        if curl -sSL -o "$output" "$url"; then
            success "Downloaded $output."
            return 0
        fi
        retry=$((retry + 1))
        info "Attempt $retry/$max_retries failed. Retrying in 3 seconds..."
        sleep 3
    done
    error_exit "Failed to download $url after $max_retries attempts." "Check your internet connection or URL availability."
}

# Function to install dependencies
install_dependencies() {
    header "Installing Dependencies"
    local update_cmd install_cmd
    if [ "$DISTRO_TYPE" = "linux" ]; then
        update_cmd="apt update"
        install_cmd="apt install -y golang git curl"
    else
        update_cmd="pkg update"
        install_cmd="pkg install -y go git curl"
    fi

    info "Updating package lists..."
    $update_cmd
    check_status "Failed to update package lists." "Check your package manager configuration or internet connection."

    info "Installing Go, Git, and Curl..."
    $install_cmd
    check_status "Failed to install dependencies." "Ensure your package repositories are accessible and retry."
    success "Dependencies installed."
}

# Function to compile the program
compile_program() {
    header "Compiling Application"
    info "Creating temporary directory for build..."
    mkdir -p "$TEMP_DIR" || { error_exit "Failed to create temporary directory $TEMP_DIR." "Check write permissions on /tmp."; }
    local temp_source="$TEMP_DIR/main.go"
    download_with_retry "$MAIN_GO_URL" "$temp_source"

    info "Creating installation directory structure..."
    mkdir -p "$INSTALL_DIR/src" || { error_exit "Failed to create $INSTALL_DIR/src." "Check write permissions."; }
    cp "$temp_source" "$INSTALL_DIR/src/main.go" || { error_exit "Failed to copy source code." "Check write permissions."; }
    success "Source code prepared at $INSTALL_DIR/src."

    info "Compiling binary (this may take a moment)..."
    cd "$INSTALL_DIR/src" || { error_exit "Failed to access $INSTALL_DIR/src." "Check directory permissions."; }
    go build -o "$BINARY_PATH" main.go
    check_status "Failed to compile SMTP-to-Gotify binary." "Ensure Go is installed correctly (run 'go version')."
    chmod +x "$BINARY_PATH"
    check_status "Failed to set executable permissions on $BINARY_PATH." "Check write permissions."
    success "Binary compiled at $BINARY_PATH."
}

# Function to set up systemd service for Linux
setup_systemd_service() {
    header "Setting Up Systemd Service"
    local temp_service="$TEMP_DIR/smtp-to-gotify.service"
    download_with_retry "$SERVICE_FILE_URL" "$temp_service"
    cp "$temp_service" "$SYSTEMD_SERVICE_FILE" || { error_exit "Failed to copy service file to $SYSTEMD_SERVICE_FILE." "Check write permissions."; }

    info "Configuring service with user $SERVICE_USER..."
    sed -i "s/%USER%/$SERVICE_USER/g" "$SYSTEMD_SERVICE_FILE"
    check_status "Failed to configure service file." "Check write permissions on $SYSTEMD_SERVICE_FILE."

    info "Reloading systemd configuration..."
    systemctl daemon-reload
    check_status "Failed to reload systemd configuration." "Check systemd installation."

    info "Enabling service to start on boot..."
    systemctl enable smtp-to-gotify
    check_status "Failed to enable service." "Check systemd configuration."
    success "Systemd service configured and enabled."
}

# Function to set up rc.d script for FreeBSD
setup_freebsd_rc_script() {
    header "Setting Up FreeBSD Service"
    info "Creating rc.d script at $FREEBSD_RC_SCRIPT..."
    cat > "$FREEBSD_RC_SCRIPT" << 'EOF'
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
: ${smtp_to_gotify_env="RUN_AS_SERVICE=true"}

pidfile="/var/run/${name}.pid"
command="/usr/sbin/daemon"
command_args="-p ${pidfile} -u ${smtp_to_gotify_user} ${smtp_to_gotify_env} ${smtp_to_gotify_binary}"

start_precmd="smtp_to_gotify_prestart"
stop_postcmd="smtp_to_gotify_poststop"

smtp_to_gotify_prestart()
{
    [ ! -x "${smtp_to_gotify_binary}" ] && err 1 "Binary not found: ${smtp_to_gotify_binary}"
    return 0
}

smtp_to_gotify_poststop()
{
    rm -f "${pidfile}"
    return 0
}

run_rc_command "$1"
EOF
    check_status "Failed to create rc.d script at $FREEBSD_RC_SCRIPT." "Check write permissions."

    info "Configuring rc.d script with user $SERVICE_USER..."
    sed -i '' "s/%USER%/$SERVICE_USER/g" "$FREEBSD_RC_SCRIPT"
    check_status "Failed to configure rc.d script." "Check write permissions on $FREEBSD_RC_SCRIPT."

    info "Setting executable permissions..."
    chmod +x "$FREEBSD_RC_SCRIPT"
    check_status "Failed to set executable permissions." "Check write permissions."

    info "Enabling service to start on boot..."
    command -v sysrc >/dev/null 2>&1 || { error_exit "sysrc command not found." "Manually add 'smtp_to_gotify_enable=\"YES\"' to /etc/rc.conf."; }
    sysrc smtp_to_gotify_enable="YES"
    check_status "Failed to enable service in rc.conf." "Manually enable in /etc/rc.conf."
    success "FreeBSD service configured and enabled."
}

# Function to uninstall the application
uninstall() {
    header "Uninstalling SMTP-to-Gotify"
    select_distribution
    success "Selected distribution: $DISTRO."

    if [ "$DISTRO_TYPE" = "linux" ]; then
        info "Stopping service..."
        systemctl stop smtp-to-gotify 2>/dev/null && success "Service stopped." || info "Service was not running."
        info "Disabling service..."
        systemctl disable smtp-to-gotify 2>/dev/null && success "Service disabled." || info "Service was not enabled."
        info "Removing service file..."
        rm -f "$SYSTEMD_SERVICE_FILE" 2>/dev/null && success "Service file removed." || info "Service file not found."
        systemctl daemon-reload 2>/dev/null || info "Warning: Could not reload systemd."
    else
        info "Stopping service..."
        service smtp_to_gotify stop 2>/dev/null && success "Service stopped." || info "Service was not running."
        info "Disabling service..."
        command -v sysrc >/dev/null 2>&1 && sysrc -x smtp_to_gotify_enable 2>/dev/null && success "Service disabled." || info "Service was not enabled or sysrc not found."
        info "Removing rc.d script..."
        rm -f "$FREEBSD_RC_SCRIPT" 2>/dev/null && success "Script removed." || info "Script not found."
    fi

    if prompt_yes_no "Remove installation directory and all contents (including configs and logs)?"; then
        local install_dir="$DEFAULT_INSTALL_DIR"
        [ ! -d "$install_dir" ] && prompt_user "Enter installation directory to remove" "install_dir"
        [ -d "$install_dir" ] && { rm -rf "$install_dir" && success "Removed $install_dir." || info "Warning: Could not remove $install_dir."; } || info "Directory $install_dir not found."
    else
        info "Installation directory not removed."
    fi

    success "SMTP-to-Gotify uninstalled successfully."
    exit 0
}

# Main installation process
main_install() {
    header "SMTP-to-Gotify Installation"
    info "This script installs SMTP-to-Gotify, forwarding SMTP emails to Gotify notifications."
    info "Type 'cancel' at any prompt to exit."
    echo ""

    check_root
    check_preflight

    if [ -f "$SYSTEMD_SERVICE_FILE" ] || [ -f "$FREEBSD_RC_SCRIPT" ] || [ -d "$DEFAULT_INSTALL_DIR" ]; then
        if prompt_yes_no "SMTP-to-Gotify seems to be installed. Proceed with reinstallation (files may be overwritten)?"; then
            info "Proceeding with reinstallation."
        else
            error_exit "Installation aborted." "Run the script again if needed."
        fi
    fi

    select_distribution
    success "Selected: $DISTRO."

    if prompt_yes_no "Use default installation directory ($DEFAULT_INSTALL_DIR)?"; then
        INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    else
        local valid_dir=false
        while [ "$valid_dir" = false ]; do
            prompt_user "Enter custom installation directory" "INSTALL_DIR"
            if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
                valid_dir=true
            elif mkdir -p "$INSTALL_DIR" 2>/dev/null && [ -w "$INSTALL_DIR" ]; then
                valid_dir=true
                rm -rf "$INSTALL_DIR" 2>/dev/null
            else
                info "Directory $INSTALL_DIR is not writable or cannot be created."
            fi
        done
    fi
    BINARY_PATH="${INSTALL_DIR}/smtp-to-gotify"
    success "Installation directory: $INSTALL_DIR."

    prompt_user "Enter user to run the service" "SERVICE_USER" "smtp-gotify"
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        info "Creating user $SERVICE_USER..."
        if [ "$DISTRO_TYPE" = "linux" ]; then
            useradd -m -s /bin/false "$SERVICE_USER"
        else
            command -v pw >/dev/null 2>&1 || { error_exit "pw command not found on FreeBSD." "Create user manually or use an existing one."; }
            pw useradd -n "$SERVICE_USER" -s /sbin/nologin -m
        fi
        check_status "Failed to create user $SERVICE_USER." "Check user creation permissions."
        success "User $SERVICE_USER created."
    else
        success "User $SERVICE_USER exists."
    fi

    header "Confirm Settings"
    info "Distribution: $DISTRO"
    info "Install Directory: $INSTALL_DIR"
    info "Service User: $SERVICE_USER"
    if ! prompt_yes_no "Proceed with these settings?"; then
        error_exit "Installation aborted." "Run the script again with different settings."
    fi

    header "Directory Setup"
    info "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR" || { error_exit "Failed to create $INSTALL_DIR." "Check write permissions."; }
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" || { error_exit "Failed to set ownership of $INSTALL_DIR." "Check user permissions."; }
    success "Directory created and permissions set."

    install_dependencies || rollback
    compile_program || rollback

    if [ "$DISTRO_TYPE" = "linux" ]; then
        setup_systemd_service || rollback
    else
        setup_freebsd_rc_script || rollback
    fi

    header "Service Start"
    if prompt_yes_no "Start the SMTP-to-Gotify service now?"; then
        if [ "$DISTRO_TYPE" = "linux" ]; then
            info "Starting service..."
            systemctl start smtp-to-gotify
            check_status "Failed to start service." "Check logs with 'journalctl -u smtp-to-gotify'."
            success "Service started."
        else
            info "Starting service..."
            service smtp_to_gotify start
            check_status "Failed to start service." "Check service configuration."
            success "Service started."
        fi
    else
        info "Service not started. Start it later manually."
    fi

    header "Installation Complete"
    success "SMTP-to-Gotify installed successfully!"
    info "Configuration: $INSTALL_DIR/config.yaml"
    info "Interactive Config: $BINARY_PATH config"
    if [ "$DISTRO_TYPE" = "linux" ]; then
        info "Service Status: systemctl status smtp-to-gotify"
        info "Start Service: systemctl start smtp-to-gotify"
        info "Stop Service: systemctl stop smtp-to-gotify"
    else
        info "Service Status: service smtp_to_gotify status"
        info "Start Service: service smtp_to_gotify start"
        info "Stop Service: service smtp_to_gotify stop"
    fi
    info "Uninstall: Run this script with '--uninstall'."
}

# Check for uninstall argument
[ "$1" = "--uninstall" ] && uninstall

# Run main installation
main_install
