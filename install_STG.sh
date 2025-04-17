#!/bin/bash

# SMTP-to-Gotify Installer Script
# This script installs or uninstalls the SMTP-to-Gotify application across multiple distributions.
# Run with --uninstall to remove the application.

# URLs for source files (easily changeable)
MAIN_GO_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/main.go"
SERVICE_FILE_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/smtp-to-gotify.service"

# Default installation paths
DEFAULT_INSTALL_DIR="/opt/smtp-to-gotify"
BINARY_PATH=""
SERVICE_FILE="/etc/systemd/system/smtp-to-gotify.service"
RC_SCRIPT="/usr/local/etc/rc.d/smtp-to-gotify"
TEMP_DIR="/tmp/smtp-to-gotify-install"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Spinner for long-running tasks
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ -d "/proc/$pid" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Function to log messages with timestamp
log() {
    echo -e "${2}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
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

# Function to log headers
header() {
    echo -e "${CYAN}===== $1 =====${NC}"
}

# Function to check if a command executed successfully
check_status() {
    if [ $? -ne 0 ]; then
        error_exit "$1" "$2"
    fi
}

# Function to rollback changes if installation fails
rollback() {
    info "Rolling back changes due to installation failure..."
    if [ -d "$INSTALL_DIR" ]; then
        info "Removing installation directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR" 2>/dev/null || info "Warning: Failed to remove $INSTALL_DIR, manual cleanup may be needed."
    fi
    if [ -f "$SERVICE_FILE" ]; then
        info "Removing systemd service file: $SERVICE_FILE"
        rm -f "$SERVICE_FILE" 2>/dev/null || info "Warning: Failed to remove $SERVICE_FILE, manual cleanup may be needed."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload 2>/dev/null || info "Warning: Failed to reload systemd, manual cleanup may be needed."
        fi
    fi
    if [ -f "$RC_SCRIPT" ]; then
        info "Removing rc.d script: $RC_SCRIPT"
        rm -f "$RC_SCRIPT" 2>/dev/null || info "Warning: Failed to remove $RC_SCRIPT, manual cleanup may be needed."
    fi
    if [ -d "$TEMP_DIR" ]; then
        info "Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR" 2>/dev/null || info "Warning: Failed to remove $TEMP_DIR, manual cleanup may be needed."
    fi
    error_exit "Installation failed. Changes have been rolled back where possible." "Check previous error messages for details."
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root (use sudo)." "Run with sudo or as root user."
    fi
    success "Root privilege check passed."
}

# Function to check pre-flight conditions
check_preflight() {
    header "Pre-Flight Checks"
    info "Checking for internet connectivity..."
    if ! ping -c 1 -W 2 google.com >/dev/null 2>&1; then
        error_exit "No internet connectivity detected." "Ensure your system is connected to the internet and try again."
    fi
    success "Internet connectivity confirmed."

    info "Checking for required tools..."
    local required_tools=("curl" "tar")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error_exit "$tool is not installed." "Install $tool using your package manager and try again."
        fi
    done
    success "Required tools are installed."

    info "Checking available disk space..."
    local install_dir_space=$(df -k / | tail -1 | awk '{print $4}')
    if [ "$install_dir_space" -lt 524288 ]; then # 500MB in KB
        error_exit "Insufficient disk space on / (less than 500MB available)." "Free up disk space or choose a different installation directory."
    fi
    success "Sufficient disk space available."
}

# Function to prompt user and validate input
prompt_user() {
    local prompt="$1"
    local var_name="$2"
    local default_value="$3"
    local input
    if [ -n "$default_value" ]; then
        read -p "$prompt (default: $default_value) [Enter to accept, 'cancel' to exit]: " input
        if [ "$input" = "cancel" ]; then
            error_exit "Installation cancelled by user." "Run the script again if you wish to install."
        fi
        if [ -z "$input" ]; then
            input="$default_value"
        fi
    else
        read -p "$prompt [Enter value, 'cancel' to exit]: " input
        if [ "$input" = "cancel" ]; then
            error_exit "Installation cancelled by user." "Run the script again if you wish to install."
        fi
        while [ -z "$input" ]; do
            info "Input cannot be empty."
            read -p "$prompt [Enter value, 'cancel' to exit]: " input
            if [ "$input" = "cancel" ]; then
                error_exit "Installation cancelled by user." "Run the script again if you wish to install."
            fi
        done
    fi
    eval "$var_name='$input'"
}

# Function to prompt for yes/no and return 0 for yes, 1 for no
prompt_yes_no() {
    local prompt="$1"
    local response
    read -p "$prompt (y/n) [Enter 'cancel' to exit]: " response
    while true; do
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            cancel) error_exit "Installation cancelled by user." "Run the script again if you wish to install." ;;
            *) info "Please answer y or n, or type 'cancel' to exit."; read -p "$prompt (y/n) [Enter 'cancel' to exit]: " response ;;
        esac
    done
}

# Function to select distribution
select_distribution() {
    header "Distribution Selection"
    info "Select the distribution to install on:"
    echo "1. Debian"
    echo "2. Ubuntu"
    echo "3. TrueNAS Scale"
    echo "4. pfSense (FreeBSD)"
    local choice
    read -p "Enter the number of your distribution (1-4) [Enter 'cancel' to exit]: " choice
    while true; do
        case $choice in
            1) DISTRO="Debian"; return 0 ;;
            2) DISTRO="Ubuntu"; return 0 ;;
            3) DISTRO="TrueNAS Scale"; return 0 ;;
            4) DISTRO="pfSense"; return 0 ;;
            cancel) error_exit "Installation cancelled by user." "Run the script again if you wish to install." ;;
            *) info "Invalid choice. Please select a number between 1 and 4."; read -p "Enter the number (1-4) [Enter 'cancel' to exit]: " choice ;;
        esac
    done
}

# Function to install dependencies based on distribution with retry
install_dependencies() {
    header "Dependency Installation"
    info "Installing dependencies for $DISTRO..."
    local PKG_MANAGER UPDATE_CMD INSTALL_CMD
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
            error_exit "Unsupported distribution for dependency installation." "Select a supported distribution."
            ;;
    esac

    info "Updating package lists..."
    if ! $UPDATE_CMD; then
        error_exit "Failed to update package lists." "Check your package manager configuration and internet connection."
    fi
    success "Package lists updated."

    info "Installing dependencies (Go, Git, Curl)..."
    if ! $INSTALL_CMD; then
        error_exit "Failed to install dependencies." "Ensure your package manager repositories are accessible and try again."
    fi
    success "Dependencies installed successfully."
}

# Function to download with retry
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_count=0
    info "Downloading from $url..."
    while [ $retry_count -lt $max_retries ]; do
        if curl -sSL "$url" -o "$output"; then
            success "Download successful: $output"
            return 0
        fi
        retry_count=$((retry_count + 1))
        info "Download attempt $retry_count/$max_retries failed. Retrying in 5 seconds..."
        sleep 5
    done
    error_exit "Failed to download from $url after $max_retries attempts." "Check your internet connection or the URL availability."
}

# Function to compile the Go program
compile_program() {
    header "Compilation"
    info "Creating source directory: $INSTALL_DIR/src..."
    mkdir -p "$INSTALL_DIR/src" || { error_exit "Failed to create source directory $INSTALL_DIR/src." "Check write permissions on $INSTALL_DIR."; }
    success "Source directory created."

    mkdir -p "$TEMP_DIR" || { error_exit "Failed to create temporary directory $TEMP_DIR." "Check write permissions on /tmp."; }
    local temp_source="$TEMP_DIR/main.go"
    download_with_retry "$MAIN_GO_URL" "$temp_source"
    cp "$temp_source" "$INSTALL_DIR/src/main.go" || { error_exit "Failed to copy source code to $INSTALL_DIR/src." "Check write permissions."; }
    success "Source code copied to installation directory."

    info "Compiling SMTP-to-Gotify binary (this may take a while)..."
    cd "$INSTALL_DIR/src" || { error_exit "Failed to change directory to $INSTALL_DIR/src." "Check directory existence."; }
    if ! go build -o "$BINARY_PATH" main.go; then
        error_exit "Failed to compile SMTP-to-Gotify binary." "Ensure Go is installed correctly (run 'go version') and dependencies are met."
    fi
    success "Binary compiled at $BINARY_PATH."

    info "Setting executable permissions on binary..."
    if ! chmod +x "$BINARY_PATH"; then
        error_exit "Failed to set executable permissions on $BINARY_PATH." "Check write permissions on the directory."
    fi
    success "Binary permissions set."
}

# Function to set up systemd service for Linux
setup_systemd_service() {
    header "Systemd Service Setup"
    info "Downloading systemd service file from $SERVICE_FILE_URL..."
    local temp_service="$TEMP_DIR/smtp-to-gotify.service"
    download_with_retry "$SERVICE_FILE_URL" "$temp_service"
    cp "$temp_service" "$SERVICE_FILE" || { error_exit "Failed to copy service file to $SERVICE_FILE." "Check write permissions."; }
    success "Service file downloaded to $SERVICE_FILE."

    info "Configuring service file with user $SERVICE_USER..."
    if ! sed -i "s/%USER%/$SERVICE_USER/g" "$SERVICE_FILE"; then
        error_exit "Failed to configure service file with user $SERVICE_USER." "Check write permissions on $SERVICE_FILE."
    fi
    success "Service file configured."

    info "Reloading systemd daemon..."
    if ! systemctl daemon-reload; then
        error_exit "Failed to reload systemd daemon." "Check systemd installation."
    fi
    success "Systemd daemon reloaded."

    info "Enabling SMTP-to-Gotify service to start on boot..."
    if ! systemctl enable smtp-to-gotify; then
        error_exit "Failed to enable SMTP-to-Gotify service." "Check systemd configuration."
    fi
    success "Service enabled to start on boot."
}

# Function to set up rc.d script for FreeBSD/pfSense
setup_rcd_script() {
    header "FreeBSD rc.d Script Setup"
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
    if [ $? -ne 0 ]; then
        error_exit "Failed to create rc.d script at $RC_SCRIPT." "Check write permissions on $RC_SCRIPT directory."
    fi
    success "rc.d script created."

    info "Configuring rc.d script with user $SERVICE_USER..."
    if ! sed -i '' "s/%USER%/$SERVICE_USER/g" "$RC_SCRIPT"; then
        error_exit "Failed to configure rc.d script with user $SERVICE_USER." "Check write permissions on $RC_SCRIPT."
    fi
    success "rc.d script configured."

    info "Setting executable permissions on rc.d script..."
    if ! chmod +x "$RC_SCRIPT"; then
        error_exit "Failed to set executable permissions on $RC_SCRIPT." "Check write permissions."
    fi
    success "rc.d script permissions set."

    info "Enabling SMTP-to-Gotify service to start on boot..."
    if ! command -v sysrc >/dev/null 2>&1; then
        error_exit "sysrc command not found on FreeBSD." "Manually enable the service by adding smtp_to_gotify_enable=\"YES\" to /etc/rc.conf."
    fi
    if ! sysrc smtp_to_gotify_enable="YES"; then
        error_exit "Failed to enable SMTP-to-Gotify service in rc.conf." "Manually enable the service in /etc/rc.conf."
    fi
    success "Service enabled to start on boot."
}

# Function to uninstall the application
uninstall() {
    header "Uninstalling SMTP-to-Gotify"
    select_distribution
    success "Selected distribution: $DISTRO for uninstallation."

    if [ "$DISTRO" != "pfSense" ]; then
        info "Stopping SMTP-to-Gotify service..."
        systemctl stop smtp-to-gotify 2>/dev/null && success "Service stopped." || info "Service was not running or not installed."

        info "Disabling SMTP-to-Gotify service..."
        systemctl disable smtp-to-gotify 2>/dev/null && success "Service disabled." || info "Service was not enabled or not installed."

        info "Removing systemd service file: $SERVICE_FILE..."
        rm -f "$SERVICE_FILE" 2>/dev/null && success "Service file removed." || info "Service file not found or already removed."
        systemctl daemon-reload 2>/dev/null && success "Systemd daemon reloaded." || info "Failed to reload systemd, manual cleanup may be needed."
    else
        info "Stopping SMTP-to-Gotify service on FreeBSD..."
        service smtp_to_gotify stop 2>/dev/null && success "Service stopped." || info "Service was not running or not installed."

        info "Disabling SMTP-to-Gotify service in rc.conf..."
        if command -v sysrc >/dev/null 2>&1; then
            sysrc -x smtp_to_gotify_enable 2>/dev/null && success "Service disabled." || info "Service was not enabled or not installed."
        else
            info "sysrc not found, manual cleanup of /etc/rc.conf may be needed."
        fi

        info "Removing rc.d script: $RC_SCRIPT..."
        rm -f "$RC_SCRIPT" 2>/dev/null && success "rc.d script removed." || info "rc.d script not found or already removed."
    fi

    info "Removing installation directory (if it exists)..."
    if prompt_yes_no "Do you want to remove the installation directory and all its contents (including configuration and logs)?"; then
        if [ -d "$DEFAULT_INSTALL_DIR" ]; then
            INSTALL_DIR="$DEFAULT_INSTALL_DIR"
        else
            prompt_user "Enter the installation directory to remove" "INSTALL_DIR"
        fi
        if [ -d "$INSTALL_DIR" ]; then
            rm -rf "$INSTALL_DIR" 2>/dev/null && success "Installation directory $INSTALL_DIR removed." || info "Failed to remove $INSTALL_DIR, manual cleanup may be needed."
        else
            info "Directory $INSTALL_DIR does not exist, no removal needed."
        fi
    else
        info "Installation directory not removed as per user request."
    fi

    success "SMTP-to-Gotify has been uninstalled successfully."
    exit 0
}

# Main installation process
main_install() {
    header "Welcome to SMTP-to-Gotify Installation"
    info "This script will guide you through installing SMTP-to-Gotify, a tool to forward SMTP emails to Gotify notifications."
    info "You can cancel at any time by typing 'cancel' at prompts."
    echo ""

    # Check if running as root
    check_root

    # Perform pre-flight checks
    check_preflight

    # Check if already installed
    if [ -f "$SERVICE_FILE" ] || [ -f "$RC_SCRIPT" ] || [ -d "$DEFAULT_INSTALL_DIR" ]; then
        if prompt_yes_no "SMTP-to-Gotify appears to be installed. Do you want to proceed with reinstallation (existing files may be overwritten)?"; then
            info "Proceeding with reinstallation."
        else
            error_exit "Installation aborted by user." "Run the script again if you wish to install."
        fi
    fi

    # Prompt for distribution
    select_distribution
    success "Selected distribution: $DISTRO"

    # Prompt for installation directory with validation
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
                rm -rf "$INSTALL_DIR" 2>/dev/null # Clean up test directory
            else
                info "Directory $INSTALL_DIR is not writable or cannot be created."
            fi
        done
    fi
    BINARY_PATH="${INSTALL_DIR}/smtp-to-gotify"
    success "Installation directory set to: $INSTALL_DIR"

    # Prompt for service user
    prompt_user "Enter the user to run the SMTP-to-Gotify service" "SERVICE_USER" "smtp-gotify"
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        info "Creating user $SERVICE_USER..."
        if [ "$DISTRO" != "pfSense" ]; then
            useradd -m -s /bin/false "$SERVICE_USER" || { error_exit "Failed to create user $SERVICE_USER." "Check user creation permissions."; }
        else
            if ! command -v pw >/dev/null 2>&1; then
                error_exit "pw command not found on FreeBSD. Cannot create user $SERVICE_USER." "Install pw or use an existing user."
            fi
            pw useradd -n "$SERVICE_USER" -s /sbin/nologin -m || { error_exit "Failed to create user $SERVICE_USER." "Check user creation permissions."; }
        fi
        success "User $SERVICE_USER created."
    else
        success "User $SERVICE_USER already exists."
    fi
    success "Service will run as user: $SERVICE_USER"

    # Summary of choices before proceeding
    header "Installation Summary"
    info "Distribution: $DISTRO"
    info "Installation Directory: $INSTALL_DIR"
    info "Service User: $SERVICE_USER"
    if ! prompt_yes_no "Are these settings correct? Proceed with installation?"; then
        error_exit "Installation aborted by user." "Run the script again to restart with different settings."
    fi

    # Create installation directory and set permissions
    header "Directory Setup"
    info "Creating installation directory: $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR" || { error_exit "Failed to create installation directory $INSTALL_DIR." "Check write permissions on parent directory."; }
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" || { error_exit "Failed to set ownership of $INSTALL_DIR to $SERVICE_USER." "Check user permissions."; }
    success "Installation directory created and permissions set."

    # Install dependencies
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
    header "Service Start"
    if prompt_yes_no "Do you want to start the SMTP-to-Gotify service now?"; then
        if [ "$DISTRO" != "pfSense" ]; then
            info "Starting SMTP-to-Gotify service..."
            systemctl start smtp-to-gotify || { error_exit "Failed to start SMTP-to-Gotify service." "Check systemd logs with 'journalctl -u smtp-to-gotify'."; }
            success "SMTP-to-Gotify service started successfully."
        else
            info "Starting SMTP-to-Gotify service on FreeBSD..."
            service smtp_to_gotify start || { error_exit "Failed to start SMTP-to-Gotify service." "Check service logs or configuration."; }
            success "SMTP-to-Gotify service started successfully."
        fi
    else
        if [ "$DISTRO" != "pfSense" ]; then
            info "Service not started. You can start it later with 'systemctl start smtp-to-gotify'."
        else
            info "Service not started. You can start it later with 'service smtp_to_gotify start'."
        fi
    fi

    # Final summary
    header "Installation Complete"
    success "SMTP-to-Gotify installation completed successfully!"
    echo ""
    info "Key Information:"
    info "  - Configuration files are located at: $INSTALL_DIR/config.yaml"
    info "  - Run '$BINARY_PATH config' to configure settings interactively."
    if [ "$DISTRO" != "pfSense" ]; then
        info "  - Use 'systemctl status smtp-to-gotify' to check service status."
        info "  - Use 'systemctl start smtp-to-gotify' to start the service if not started."
        info "  - Use 'systemctl stop smtp-to-gotify' to stop the service."
    else
        info "  - Use 'service smtp_to_gotify status' to check service status."
        info "  - Use 'service smtp_to_gotify start' to start the service if not started."
        info "  - Use 'service smtp_to_gotify stop' to stop the service."
    fi
    info "  - To uninstall, run this script with '--uninstall' argument."
    echo ""
    success "Thank you for installing SMTP-to-Gotify!"
}

# Check for uninstall argument
if [ "$1" = "--uninstall" ]; then
    uninstall
fi

# Run main installation
main_install
