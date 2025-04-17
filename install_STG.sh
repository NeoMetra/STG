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

# Colors for output (used in non-dialog mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if dialog is available, otherwise fallback to basic prompts
DIALOG_AVAILABLE=0
command -v dialog >/dev/null 2>&1 && DIALOG_AVAILABLE=1

# Function to log messages with timestamp (used in non-dialog mode or for logs)
log() {
    echo -e "${2}[$(date '+%H:%M:%S')] $1${NC}"
}

# Function to log errors and exit
error_exit() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Error" --msgbox "ERROR: $1\n\nAdvice: ${2:-No additional advice available.}" 10 60
    else
        log "ERROR: $1" "${RED}"
        [ -n "$2" ] && log "Advice: $2" "${YELLOW}"
    fi
    exit 1
}

# Function to log success (non-dialog mode)
success() {
    log "SUCCESS: $1" "${GREEN}"
}

# Function to log info (non-dialog mode)
info() {
    log "INFO: $1" "${YELLOW}"
}

# Function to display messages using dialog or fallback to log
show_info() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Information" --msgbox "$1" 8 50
    else
        info "$1"
    fi
}

# Function to check command status and handle errors
check_status() {
    if [ $? -ne 0 ]; then
        error_exit "$1" "$2"
    fi
}

# Function to rollback changes on failure
rollback() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Rollback" --msgbox "Installation failed. Rolling back changes..." 8 50
    else
        info "Rolling back changes due to failure..."
    fi
    [ -d "$INSTALL_DIR" ] && { rm -rf "$INSTALL_DIR" 2>/dev/null || show_info "Warning: Could not remove $INSTALL_DIR."; }
    [ -f "$SYSTEMD_SERVICE_FILE" ] && { rm -f "$SYSTEMD_SERVICE_FILE" 2>/dev/null || show_info "Warning: Could not remove $SYSTEMD_SERVICE_FILE."; systemctl daemon-reload 2>/dev/null || show_info "Warning: Could not reload systemd."; }
    [ -f "$FREEBSD_RC_SCRIPT" ] && { rm -f "$FREEBSD_RC_SCRIPT" 2>/dev/null || show_info "Warning: Could not remove $FREEBSD_RC_SCRIPT."; }
    [ -d "$TEMP_DIR" ] && { rm -rf "$TEMP_DIR" 2>/dev/null || show_info "Warning: Could not remove $TEMP_DIR."; }
    error_exit "Installation failed. Changes rolled back where possible." "Review error messages for details."
}

# Function to check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script requires root privileges." "Run with 'sudo' or as root user."
    fi
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Privilege Check" --msgbox "Root privileges confirmed." 6 40
    else
        success "Root privileges confirmed."
    fi
}

# Function to perform pre-flight checks
check_preflight() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "System Checks" --infobox "Checking system requirements..." 3 40
    else
        info "Checking system requirements..."
    fi
    sleep 1

    ping -c 1 -W 2 google.com >/dev/null 2>&1 || { error_exit "No internet connection detected." "Ensure your system is online and retry."; }
    local space=$(df -k / | tail -1 | awk '{print $4}')
    [ "$space" -lt 524288 ] && { error_exit "Insufficient disk space (less than 500MB on /)." "Free up space or choose a different install location."; }
    command -v curl >/dev/null 2>&1 || { error_exit "curl is not installed." "Install curl using your package manager and retry."; }

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "System Checks" --msgbox "System checks passed:\n- Internet connection confirmed.\n- Sufficient disk space.\n- Required tools present." 8 50
    else
        success "System checks passed."
    fi
}

# Function to prompt user for input with dialog or fallback
prompt_user() {
    local title="$1"
    local prompt="$2"
    local var_name="$3"
    local default="$4"
    local input
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        exec 3>&1
        input=$(dialog --title "$title" --inputbox "$prompt" 8 50 "$default" 2>&1 1>&3)
        local status=$?
        exec 3>&-
        [ $status -eq 1 ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
        [ -z "$input" ] && input="$default"
    else
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
    fi
    eval "$var_name='$input'"
}

# Function to prompt for yes/no response with dialog or fallback
prompt_yes_no() {
    local title="$1"
    local prompt="$2"
    local response
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "$title" --yesno "$prompt" 7 50
        response=$?
        [ $response -eq 1 ] && return 1
        [ $response -eq 255 ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
        return 0
    else
        read -p "$prompt (y/n) [or 'cancel' to exit]: " response
        while true; do
            case "$response" in
                [Yy]*) return 0 ;;
                [Nn]*) return 1 ;;
                cancel) error_exit "Installation cancelled by user." "Run the script again to restart." ;;
                *) info "Please enter 'y' or 'n'."; read -p "$prompt (y/n) [or 'cancel' to exit]: " response ;;
            esac
        done
    fi
}

# Function to select distribution with dialog or fallback
select_distribution() {
    local choice
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        exec 3>&1
        choice=$(dialog --title "Distribution Selection" --menu "Select your distribution:" 10 50 4 \
            1 "Debian" \
            2 "Ubuntu" \
            3 "TrueNAS Scale" \
            4 "pfSense (FreeBSD)" 2>&1 1>&3)
        local status=$?
        exec 3>&-
        [ $status -eq 1 ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
    else
        header "Distribution Selection"
        info "Which distribution are you installing on?"
        echo "1. Debian"
        echo "2. Ubuntu"
        echo "3. TrueNAS Scale"
        echo "4. pfSense (FreeBSD)"
        read -p "Enter number (1-4) [or 'cancel' to exit]: " choice
        while true; do
            [ "$choice" = "cancel" ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
            case "$choice" in
                1|2|3|4) break ;;
                *) info "Invalid choice. Enter a number between 1 and 4."; read -p "Enter number (1-4) [or 'cancel' to exit]: " choice ;;
            esac
        done
    fi
    case "$choice" in
        1) DISTRO="Debian"; DISTRO_TYPE="linux" ;;
        2) DISTRO="Ubuntu"; DISTRO_TYPE="linux" ;;
        3) DISTRO="TrueNAS Scale"; DISTRO_TYPE="linux" ;;
        4) DISTRO="pfSense"; DISTRO_TYPE="freebsd" ;;
    esac
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Distribution Selection" --msgbox "Selected distribution: $DISTRO" 6 40
    else
        success "Selected: $DISTRO."
    fi
}

# Function to download files with retry logic
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry=0
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Downloading" --infobox "Downloading from $url..." 3 50
    else
        info "Downloading from $url..."
    fi
    while [ $retry -lt $max_retries ]; do
        if curl -sSL -o "$output" "$url"; then
            if [ $DIALOG_AVAILABLE -eq 1 ]; then
                dialog --title "Downloading" --msgbox "Download successful: $output" 6 50
            else
                success "Downloaded $output."
            fi
            return 0
        fi
        retry=$((retry + 1))
        if [ $DIALOG_AVAILABLE -eq 1 ]; then
            dialog --title "Downloading" --infobox "Attempt $retry/$max_retries failed. Retrying..." 3 50
        else
            info "Attempt $retry/$max_retries failed. Retrying in 3 seconds..."
        fi
        sleep 3
    done
    error_exit "Failed to download $url after $max_retries attempts." "Check your internet connection or URL availability."
}

# Function to install dependencies
install_dependencies() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Installing Dependencies" --infobox "Setting up dependencies for $DISTRO..." 3 50
    else
        header "Installing Dependencies"
        info "Setting up dependencies for $DISTRO..."
    fi
    local update_cmd install_cmd
    if [ "$DISTRO_TYPE" = "linux" ]; then
        update_cmd="apt update"
        install_cmd="apt install -y golang git curl"
    else
        update_cmd="pkg update"
        install_cmd="pkg install -y go git curl"
    fi

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Installing Dependencies" --infobox "Updating package lists..." 3 50
    else
        info "Updating package lists..."
    fi
    $update_cmd
    check_status "Failed to update package lists." "Check your package manager configuration or internet connection."

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Installing Dependencies" --infobox "Installing Go, Git, and Curl..." 3 50
    else
        info "Installing Go, Git, and Curl..."
    fi
    sleep 1
    $install_cmd
    check_status "Failed to install dependencies." "Ensure your package repositories are accessible and retry."
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Installing Dependencies" --msgbox "Dependencies installed successfully." 6 50
    else
        success "Dependencies installed."
    fi
}

# Function to compile the program
compile_program() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Compiling Application" --infobox "Preparing source code and compiling..." 3 50
    else
        header "Compiling Application"
        info "Preparing source code and compiling..."
    fi
    sleep 1

    info "Creating temporary directory for build..."
    mkdir -p "$TEMP_DIR" || { error_exit "Failed to create temporary directory $TEMP_DIR." "Check write permissions on /tmp."; }
    local temp_source="$TEMP_DIR/main.go"
    download_with_retry "$MAIN_GO_URL" "$temp_source"

    info "Creating installation directory structure..."
    mkdir -p "$INSTALL_DIR/src" || { error_exit "Failed to create $INSTALL_DIR/src." "Check write permissions."; }
    cp "$temp_source" "$INSTALL_DIR/src/main.go" || { error_exit "Failed to copy source code." "Check write permissions."; }

    info "Compiling binary (this may take a moment)..."
    cd "$INSTALL_DIR/src" || { error_exit "Failed to access $INSTALL_DIR/src." "Check directory permissions."; }
    go build -o "$BINARY_PATH" main.go
    check_status "Failed to compile SMTP-to-Gotify binary." "Ensure Go is installed correctly (run 'go version')."
    chmod +x "$BINARY_PATH"
    check_status "Failed to set executable permissions on $BINARY_PATH." "Check write permissions."
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Compiling Application" --msgbox "Binary compiled at $BINARY_PATH." 6 50
    else
        success "Binary compiled at $BINARY_PATH."
    fi
}

# Function to set up systemd service for Linux
setup_systemd_service() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Setting Up Systemd Service" --infobox "Configuring systemd service..." 3 50
    else
        header "Setting Up Systemd Service"
        info "Configuring systemd service..."
    fi
    sleep 1

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
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Setting Up Systemd Service" --msgbox "Systemd service configured and enabled." 6 50
    else
        success "Systemd service configured and enabled."
    fi
}

# Function to set up rc.d script for FreeBSD
setup_freebsd_rc_script() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Setting Up FreeBSD Service" --infobox "Configuring FreeBSD rc.d script..." 3 50
    else
        header "Setting Up FreeBSD Service"
        info "Configuring FreeBSD rc.d script..."
    fi
    sleep 1

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
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Setting Up FreeBSD Service" --msgbox "FreeBSD service configured and enabled." 6 50
    else
        success "FreeBSD service configured and enabled."
    fi
}

# Function to uninstall the application
uninstall() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Uninstalling SMTP-to-Gotify" --infobox "Gathering uninstallation information..." 3 50
    else
        header "Uninstalling SMTP-to-Gotify"
    fi
    sleep 1
    select_distribution

    if [ "$DISTRO_TYPE" = "linux" ]; then
        if [ $DIALOG_AVAILABLE -eq 1 ]; then
            dialog --title "Uninstalling" --infobox "Stopping and disabling systemd service..." 3 50
        else
            info "Stopping and disabling systemd service..."
        fi
        systemctl stop smtp-to-gotify 2>/dev/null
        systemctl disable smtp-to-gotify 2>/dev/null
        rm -f "$SYSTEMD_SERVICE_FILE" 2>/dev/null
        systemctl daemon-reload 2>/dev/null
    else
        if [ $DIALOG_AVAILABLE -eq 1 ]; then
            dialog --title "Uninstalling" --infobox "Stopping and disabling FreeBSD service..." 3 50
        else
            info "Stopping and disabling FreeBSD service..."
        fi
        service smtp_to_gotify stop 2>/dev/null
        command -v sysrc >/dev/null 2>&1 && sysrc -x smtp_to_gotify_enable 2>/dev/null
        rm -f "$FREEBSD_RC_SCRIPT" 2>/dev/null
    fi

    if prompt_yes_no "Remove Directory" "Remove installation directory and all contents (including configs and logs)?"; then
        local install_dir="$DEFAULT_INSTALL_DIR"
        if [ ! -d "$install_dir" ]; then
            prompt_user "Installation Directory" "Enter installation directory to remove:" "install_dir"
        fi
        [ -d "$install_dir" ] && { rm -rf "$install_dir" && show_info "Removed $install_dir." || show_info "Warning: Could not remove $install_dir."; } || show_info "Directory $install_dir not found."
    else
        show_info "Installation directory not removed."
    fi

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Uninstall Complete" --msgbox "SMTP-to-Gotify uninstalled successfully." 6 50
    else
        success "SMTP-to-Gotify uninstalled successfully."
    fi
    exit 0
}

# Main installation process
main_install() {
    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Welcome to SMTP-to-Gotify Installation" --msgbox "This script installs SMTP-to-Gotify, a tool to forward SMTP emails to Gotify notifications.\n\nPress OK to continue or Cancel to exit." 10 60
        [ $? -eq 1 ] && { error_exit "Installation cancelled by user." "Run the script again to restart."; }
    else
        header "SMTP-to-Gotify Installation"
        info "This script installs SMTP-to-Gotify, forwarding SMTP emails to Gotify notifications."
        info "Type 'cancel' at any prompt to exit."
        echo ""
    fi

    check_root
    check_preflight

    if [ -f "$SYSTEMD_SERVICE_FILE" ] || [ -f "$FREEBSD_RC_SCRIPT" ] || [ -d "$DEFAULT_INSTALL_DIR" ]; then
        if prompt_yes_no "Reinstallation Check" "SMTP-to-Gotify seems to be installed. Proceed with reinstallation (files may be overwritten)?"; then
            show_info "Proceeding with reinstallation."
        else
            error_exit "Installation aborted." "Run the script again if needed."
        fi
    fi

    select_distribution

    if prompt_yes_no "Installation Directory" "Use default installation directory ($DEFAULT_INSTALL_DIR)?"; then
        INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    else
        local valid_dir=false
        while [ "$valid_dir" = false ]; do
            prompt_user "Installation Directory" "Enter custom installation directory:" "INSTALL_DIR"
            if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
                valid_dir=true
            elif mkdir -p "$INSTALL_DIR" 2>/dev/null && [ -w "$INSTALL_DIR" ]; then
                valid_dir=true
                rm -rf "$INSTALL_DIR" 2>/dev/null
            else
                show_info "Directory $INSTALL_DIR is not writable or cannot be created."
            fi
        done
    fi
    BINARY_PATH="${INSTALL_DIR}/smtp-to-gotify"

    prompt_user "Service User" "Enter user to run the service:" "SERVICE_USER" "smtp-gotify"
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        if [ $DIALOG_AVAILABLE -eq 1 ]; then
            dialog --title "Creating User" --infobox "Creating user $SERVICE_USER..." 3 50
        else
            info "Creating user $SERVICE_USER..."
        fi
        if [ "$DISTRO_TYPE" = "linux" ]; then
            useradd -m -s /bin/false "$SERVICE_USER"
        else
            command -v pw >/dev/null 2>&1 || { error_exit "pw command not found on FreeBSD." "Create user manually or use an existing one."; }
            pw useradd -n "$SERVICE_USER" -s /sbin/nologin -m
        fi
        check_status "Failed to create user $SERVICE_USER." "Check user creation permissions."
        show_info "User $SERVICE_USER created."
    else
        show_info "User $SERVICE_USER exists."
    fi

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Confirm Settings" --yesno "Distribution: $DISTRO\nInstall Directory: $INSTALL_DIR\nService User: $SERVICE_USER\n\nProceed with these settings?" 10 50
        [ $? -eq 1 ] && { error_exit "Installation aborted by user." "Run the script again with different settings."; }
    else
        header "Confirm Settings"
        info "Distribution: $DISTRO"
        info "Install Directory: $INSTALL_DIR"
        info "Service User: $SERVICE_USER"
        if ! prompt_yes_no "" "Proceed with these settings?"; then
            error_exit "Installation aborted." "Run the script again with different settings."
        fi
    fi

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Directory Setup" --infobox "Creating $INSTALL_DIR..." 3 50
    else
        header "Directory Setup"
        info "Creating $INSTALL_DIR..."
    fi
    sleep 1
    mkdir -p "$INSTALL_DIR" || { error_exit "Failed to create $INSTALL_DIR." "Check write permissions."; }
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" || { error_exit "Failed to set ownership of $INSTALL_DIR." "Check user permissions."; }
    show_info "Directory created and permissions set."

    install_dependencies || rollback
    compile_program || rollback

    if [ "$DISTRO_TYPE" = "linux" ]; then
        setup_systemd_service || rollback
    else
        setup_freebsd_rc_script || rollback
    fi

    if prompt_yes_no "Service Start" "Start the SMTP-to-Gotify service now?"; then
        if [ $DIALOG_AVAILABLE -eq 1 ]; then
            dialog --title "Starting Service" --infobox "Starting SMTP-to-Gotify service..." 3 50
        else
            info "Starting SMTP-to-Gotify service..."
        fi
        sleep 1
        if [ "$DISTRO_TYPE" = "linux" ]; then
            systemctl start smtp-to-gotify
            check_status "Failed to start service." "Check logs with 'journalctl -u smtp-to-gotify'."
            show_info "Service started successfully."
        else
            service smtp_to_gotify start
            check_status "Failed to start service." "Check service configuration."
            show_info "Service started successfully."
        fi
    else
        show_info "Service not started. Start it later manually."
    fi

    if [ $DIALOG_AVAILABLE -eq 1 ]; then
        dialog --title "Installation Complete" --msgbox "SMTP-to-Gotify installed successfully!\n\nConfiguration: $INSTALL_DIR/config.yaml\nInteractive Config: $BINARY_PATH config\nService Status: $([ "$DISTRO_TYPE" = "linux" ] && echo "systemctl status smtp-to-gotify" || echo "service smtp_to_gotify status")\nStart Service: $([ "$DISTRO_TYPE" = "linux" ] && echo "systemctl start smtp-to-gotify" || echo "service smtp_to_gotify start")\nStop Service: $([ "$DISTRO_TYPE" = "linux" ] && echo "systemctl stop smtp-to-gotify" || echo "service smtp_to_gotify stop")\n\nUninstall: Run this script with '--uninstall'." 15 60
    else
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
    fi
}

# Check for uninstall argument
[ "$1" = "--uninstall" ] && uninstall

# Run main installation
main_install
