#!/bin/bash

# Install Script for SMTP-to-Gotify Forwarder
# This script can install or uninstall the SMTP-to-Gotify program across multiple distributions.
# Run with: curl -sSL <url-to-script> | bash
# Uninstall with: bash install-smtp-to-gotify.sh --uninstall

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_INSTALL_DIR="/opt/smtp-to-gotify"
DEFAULT_USER="smtp-gotify"
BINARY_NAME="smtp-to-gotify"
SERVICE_NAME="smtp-to-gotify"
GO_VERSION="1.21.3" # Suitable Go version for compilation
TEMP_DIR="/tmp/smtp-to-gotify-install"
ROLLBACK_LOG="$TEMP_DIR/rollback.log"
SRC_FILE="$TEMP_DIR/main.go"
SERVICE_FILE="$TEMP_DIR/$SERVICE_NAME.service"
# GitHub HTTP link for source code (replace <github-http-link> with actual URL before using)
SRC_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/main.go" # Replace with actual GitHub raw link to main.go

# Function to log messages
log() {
    echo -e "${2}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function to log and track rollback steps
log_rollback() {
    echo "$1" >> "$ROLLBACK_LOG"
}

# Function to prompt user with a default value, ensuring reliable input
prompt() {
    local prompt_text="$1"
    local default_value="$2"
    local response
    # Ensure terminal is in a state to read input
    stty raw 2>/dev/null || true
    echo -n "$prompt_text [$default_value]: "
    read -r response
    stty cooked 2>/dev/null || true
    if [ -z "$response" ]; then
        echo "$default_value"
    else
        echo "$response"
    fi
}

# Function to prompt for yes/no with a default value
prompt_yes_no() {
    local prompt_text="$1"
    local default_value="$2"
    local response
    stty raw 2>/dev/null || true
    echo -n "$prompt_text (y/n) [$default_value]: "
    read -r response
    stty cooked 2>/dev/null || true
    if [ -z "$response" ]; then
        echo "$default_value"
    else
        echo "$response"
    fi
}

# Function to prompt for distribution selection using numbers
prompt_distro() {
    local distro
    log "Select the distribution to install on:" "${YELLOW}"
    echo "1. PFSense (FreeBSD-based)"
    echo "2. TrueNAS Scale (Debian-based)"
    echo "3. Debian"
    echo "4. Ubuntu"
    while true; do
        stty raw 2>/dev/null || true
        echo -n "Enter number (1-4): "
        read -r distro_num
        stty cooked 2>/dev/null || true
        case "$distro_num" in
            1)
                distro="pfsense"
                break
                ;;
            2)
                distro="truenas-scale"
                break
                ;;
            3)
                distro="debian"
                break
                ;;
            4)
                distro="ubuntu"
                break
                ;;
            *)
                log "Invalid selection. Please enter a number between 1 and 4." "${RED}"
                ;;
        esac
    done
    echo "$distro"
}

# Function to check if a command exists
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Function to perform rollback if a step fails
rollback() {
    log "Installation failed. Performing rollback..." "${RED}"
    if [ -f "$ROLLBACK_LOG" ]; then
        log "Executing rollback steps..." "${YELLOW}"
        while IFS= read -r cmd; do
            if [ -n "$cmd" ]; then
                log "Rollback: $cmd" "${YELLOW}"
                eval "$cmd" || log "Warning: Rollback step failed: $cmd" "${YELLOW}"
            fi
        done < "$ROLLBACK_LOG"
    else
        log "No rollback log found. Manual cleanup may be required." "${RED}"
    fi
    log "Rollback complete. Exiting." "${RED}"
    exit 1
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "This script must be run as root. Use sudo or switch to root user." "${RED}"
        exit 1
    fi
}

# Function to detect distribution if not provided
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="$ID"
        if [[ "$DISTRO" == "debian" ]] && grep -q "TrueNAS" /etc/os-release; then
            DISTRO="truenas-scale"
        fi
    elif [ -f /etc/pfsense-release ]; then
        DISTRO="pfsense"
    else
        DISTRO="unknown"
    fi
    echo "$DISTRO"
}

# Function to install Go based on distribution
install_go() {
    local distro="$1"
    log "Installing Go..." "${YELLOW}"
    case "$distro" in
        "pfsense")
            if ! check_cmd go; then
                log "Installing Go on PFSense (FreeBSD)..." "${YELLOW}"
                pkg install -y go || {
                    log "Failed to install Go on PFSense." "${RED}"
                    return 1
                }
                log_rollback "pkg delete -y go"
            else
                log "Go already installed on PFSense." "${GREEN}"
            fi
            ;;
        "truenas-scale" | "debian" | "ubuntu")
            if ! check_cmd go; then
                log "Installing Go on $distro..." "${YELLOW}"
                apt update || {
                    log "Failed to update package lists." "${RED}"
                    return 1
                }
                apt install -y golang || {
                    log "Failed to install Go using apt. Falling back to manual installation..." "${YELLOW}"
                    local go_tar="go${GO_VERSION}.linux-amd64.tar.gz"
                    wget -O "$TEMP_DIR/$go_tar" "https://golang.org/dl/$go_tar" || {
                        log "Failed to download Go." "${RED}"
                        return 1
                    }
                    tar -C /usr/local -xzf "$TEMP_DIR/$go_tar" || {
                        log "Failed to extract Go." "${RED}"
                        return 1
                    }
                    echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/profile
                    export PATH=$PATH:/usr/local/go/bin
                    log_rollback "rm -rf /usr/local/go"
                    log_rollback "sed -i '/export PATH=\$PATH:\/usr\/local\/go\/bin/d' /etc/profile"
                }
                log_rollback "apt remove -y golang"
            else
                log "Go already installed on $distro." "${GREEN}"
            fi
            ;;
        *)
            log "Unsupported distribution for Go installation: $distro" "${RED}"
            return 1
            ;;
    esac
    go version || {
        log "Go installation verification failed." "${RED}"
        return 1
    }
    log "Go installed successfully." "${GREEN}"
    return 0
}

# Function to create user if not exists
create_user() {
    local user="$1"
    if id "$user" >/dev/null 2>&1; then
        log "User $user already exists." "${GREEN}"
    else
        log "Creating user $user..." "${YELLOW}"
        useradd -m -s /bin/bash "$user" || {
            log "Failed to create user $user." "${RED}"
            return 1
        }
        log_rollback "userdel -r $user"
        log "User $user created." "${GREEN}"
    fi
    return 0
}

# Function to fetch source code from GitHub link
fetch_source() {
    local src_url="$1"
    local src_file="$2"
    log "Fetching source code from $src_url..." "${YELLOW}"
    wget -O "$src_file" "$src_url" || {
        log "Failed to fetch source code from $src_url." "${RED}"
        return 1
    }
    log_rollback "rm -f $src_file"
    log "Source code fetched successfully." "${GREEN}"
    return 0
}

# Function to compile the program
compile_program() {
    local src_file="$1"
    log "Compiling SMTP-to-Gotify..." "${YELLOW}"
    go build -o "$BINARY_NAME" "$src_file" || {
        log "Failed to compile SMTP-to-Gotify." "${RED}"
        return 1
    }
    log "Compilation successful." "${GREEN}"
    log_rollback "rm -f $BINARY_NAME"
    return 0
}

# Function to install the binary and setup directories
install_binary() {
    local install_dir="$1"
    local user="$2"
    log "Installing binary to $install_dir..." "${YELLOW}"
    mkdir -p "$install_dir" || {
        log "Failed to create installation directory $install_dir." "${RED}"
        return 1
    }
    cp "$BINARY_NAME" "$install_dir/" || {
        log "Failed to copy binary to $install_dir." "${RED}"
        return 1
    }
    chown "$user:$user" "$install_dir/$BINARY_NAME" || {
        log "Failed to set ownership of binary." "${RED}"
        return 1
    }
    chmod 755 "$install_dir/$BINARY_NAME" || {
        log "Failed to set permissions on binary." "${RED}"
        return 1
    }
    log_rollback "rm -rf $install_dir"
    log "Binary installed to $install_dir." "${GREEN}"
    return 0
}

# Function to setup service based on distribution
setup_service() {
    local distro="$1"
    local install_dir="$2"
    local user="$3"
    log "Setting up service for $distro..." "${YELLOW}"
    case "$distro" in
        "pfsense")
            local rc_script="/usr/local/etc/rc.d/$SERVICE_NAME"
            cat <<EOF > "$rc_script"
#!/bin/sh
# PROVIDE: $SERVICE_NAME
# REQUIRE: networking
# KEYWORD: shutdown

. /etc/rc.subr

name="$SERVICE_NAME"
rcvar="${SERVICE_NAME}_enable"
command="$install_dir/$BINARY_NAME"
command_args="start"
pidfile="/var/run/\${name}.pid"
start_cmd="${SERVICE_NAME}_start"
stop_cmd="${SERVICE_NAME}_stop"

load_rc_config \$name

: \${${SERVICE_NAME}_enable:="NO"}

${SERVICE_NAME}_start() {
    /usr/sbin/daemon -p \${pidfile} \${command} \${command_args}
    echo "Starting \${name}."
}

${SERVICE_NAME}_stop() {
    if [ -f "\${pidfile}" ]; then
        kill -TERM \$(cat \${pidfile})
        echo "Stopping \${name}."
        rm -f \${pidfile}
    else
        echo "\${name} is not running."
    fi
}

run_rc_command "\$1"
EOF
            chmod +x "$rc_script" || {
                log "Failed to create RC script for PFSense." "${RED}"
                return 1
            }
            sysrc "${SERVICE_NAME}_enable=YES" || {
                log "Failed to enable service on boot for PFSense." "${RED}"
                return 1
            }
            log_rollback "rm -f $rc_script"
            log_rollback "sysrc -x ${SERVICE_NAME}_enable"
            log "Service setup complete for PFSense." "${GREEN}"
            ;;
        "truenas-scale" | "debian" | "ubuntu")
            local service_file="/etc/systemd/system/$SERVICE_NAME.service"
            cat <<EOF > "$service_file"
[Unit]
Description=SMTP to Gotify Forwarder
After=network.target

[Service]
Type=simple
User=$user
Group=$user
WorkingDirectory=$install_dir
ExecStart=$install_dir/$BINARY_NAME
# Recommendation 9: Refined restart policy and timeout settings
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=5
TimeoutStartSec=30
TimeoutStopSec=30
SyslogIdentifier=$SERVICE_NAME
Environment=RUN_AS_SERVICE=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || {
                log "Failed to reload SystemD daemon." "${RED}"
                return 1
            }
            log_rollback "rm -f $service_file"
            log_rollback "systemctl daemon-reload"
            log "Service setup complete for $distro." "${GREEN}"
            ;;
        *)
            log "Unsupported distribution for service setup: $distro" "${RED}"
            return 1
            ;;
    esac
    return 0
}

# Function to enable service on boot
enable_service() {
    local distro="$1"
    local enable_boot="$2"
    if [ "$enable_boot" != "y" ] && [ "$enable_boot" != "Y" ]; then
        log "Service will not be enabled on boot as per user choice." "${YELLOW}"
        return 0
    fi
    log "Enabling service on boot..." "${YELLOW}"
    case "$distro" in
        "pfsense")
            sysrc "${SERVICE_NAME}_enable=YES" || {
                log "Failed to enable service on boot for PFSense." "${RED}"
                return 1
            }
            log_rollback "sysrc -x ${SERVICE_NAME}_enable"
            ;;
        "truenas-scale" | "debian" | "ubuntu")
            systemctl enable "$SERVICE_NAME" || {
                log "Failed to enable service on boot for $distro." "${RED}"
                return 1
            }
            log_rollback "systemctl disable $SERVICE_NAME"
            ;;
        *)
            log "Unsupported distribution for enabling service: $distro" "${RED}"
            return 1
            ;;
    esac
    log "Service enabled on boot." "${GREEN}"
    return 0
}

# Function to start service
start_service() {
    local distro="$1"
    local start_now="$2"
    if [ "$start_now" != "y" ] && [ "$start_now" != "Y" ]; then
        log "Service will not be started now as per user choice." "${YELLOW}"
        return 0
    fi
    log "Starting service..." "${YELLOW}"
    case "$distro" in
        "pfsense")
            service "$SERVICE_NAME" start || {
                log "Failed to start service on PFSense." "${RED}"
                return 1
            }
            ;;
        "truenas-scale" | "debian" | "ubuntu")
            systemctl start "$SERVICE_NAME" || {
                log "Failed to start service on $distro." "${RED}"
                return 1
            }
            ;;
        *)
            log "Unsupported distribution for starting service: $distro" "${RED}"
            return 1
            ;;
    esac
    log "Service started successfully." "${GREEN}"
    return 0
}

# Function to uninstall the program
uninstall() {
    local distro="$1"
    local install_dir="$2"
    log "Uninstalling SMTP-to-Gotify..." "${YELLOW}"
    case "$distro" in
        "pfsense")
            service "$SERVICE_NAME" stop 2>/dev/null || log "Service already stopped or not running." "${YELLOW}"
            sysrc -x "${SERVICE_NAME}_enable" 2>/dev/null || log "Service not enabled on boot." "${YELLOW}"
            rm -f "/usr/local/etc/rc.d/$SERVICE_NAME" 2>/dev/null || log "RC script already removed." "${YELLOW}"
            ;;
        "truenas-scale" | "debian" | "ubuntu")
            systemctl stop "$SERVICE_NAME" 2>/dev/null || log "Service already stopped or not running." "${YELLOW}"
            systemctl disable "$SERVICE_NAME" 2>/dev/null || log "Service not enabled on boot." "${YELLOW}"
            rm -f "/etc/systemd/system/$SERVICE_NAME.service" 2>/dev/null || log "Service file already removed." "${YELLOW}"
            systemctl daemon-reload 2>/dev/null || log "SystemD reload not needed." "${YELLOW}"
            ;;
        *)
            log "Unsupported distribution for uninstall: $distro. Manual cleanup required." "${RED}"
            ;;
    esac
    rm -rf "$install_dir" 2>/dev/null || log "Installation directory already removed or not accessible." "${YELLOW}"
    log "Uninstallation complete. SMTP-to-Gotify has been removed." "${GREEN}"
    return 0
}

# Main script logic
if [ "$1" == "--uninstall" ]; then
    check_root
    log "Starting uninstallation of SMTP-to-Gotify..." "${YELLOW}"
    # Detect distribution for uninstall
    DISTRO=$(detect_distro)
    if [ "$DISTRO" == "unknown" ]; then
        log "Could not detect distribution. Please specify manually." "${RED}"
        DISTRO=$(prompt_distro)
    else
        log "Detected distribution: $DISTRO" "${GREEN}"
        confirm=$(prompt_yes_no "Is this correct?" "y")
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            DISTRO=$(prompt_distro)
        fi
    fi
    log "Proceeding with uninstall for $DISTRO..." "${GREEN}"
    # Ask for installation directory to uninstall
    INSTALL_DIR=$(prompt "Enter installation directory to uninstall from" "$DEFAULT_INSTALL_DIR")
    uninstall "$DISTRO" "$INSTALL_DIR"
    exit 0
fi

# Normal installation
check_root
log "Starting installation of SMTP-to-Gotify..." "${YELLOW}"

# Detect distribution or ask user
DISTRO=$(detect_distro)
if [ "$DISTRO" == "unknown" ]; then
    log "Could not detect distribution. Please specify manually." "${RED}"
    DISTRO=$(prompt_distro)
else
    log "Detected distribution: $DISTRO" "${GREEN}"
    confirm=$(prompt_yes_no "Is this correct?" "y")
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        DISTRO=$(prompt_distro)
    fi
fi

# Validate distribution
case "$DISTRO" in
    "pfsense" | "truenas-scale" | "debian" | "ubuntu")
        log "Proceeding with installation for $DISTRO..." "${GREEN}"
        ;;
    *)
        log "Unsupported distribution: $DISTRO. Supported: pfsense, truenas-scale, debian, ubuntu" "${RED}"
        exit 1
        ;;
esac

# Prompt for installation details
INSTALL_DIR=$(prompt "Enter installation directory" "$DEFAULT_INSTALL_DIR")
USER=$(prompt "Enter user to run the service as" "$DEFAULT_USER")
ENABLE_BOOT=$(prompt_yes_no "Enable service to start on boot?" "y")
START_NOW=$(prompt_yes_no "Start service after installation?" "y")

# Create temporary directory for installation
mkdir -p "$TEMP_DIR" || {
    log "Failed to create temporary directory $TEMP_DIR." "${RED}"
    exit 1
}
log_rollback "rm -rf $TEMP_DIR"

# Fetch source code from GitHub link
fetch_source "$SRC_URL" "$SRC_FILE" || rollback

# Perform installation
install "$DISTRO" "$INSTALL_DIR" "$USER" "$ENABLE_BOOT" "$START_NOW"
log_rollback "bash $0 --uninstall"

# Clean up temporary directory
rm -rf "$TEMP_DIR"

exit 0
