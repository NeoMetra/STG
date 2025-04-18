#!/bin/sh

# Installation script for smtp-to-gotify on pfSense (FreeBSD)
# This script downloads the source code, installs the Go compiler, compiles the binary,
# sets up directories, and configures a service to run at boot.
# It also supports uninstalling the program and undoing all changes with the --uninstall argument.
# Enhanced with colored UI and confirmation prompts for user interaction using tput for portability.

# Define variables
BINARY_NAME="smtp-to-gotify"
INSTALL_DIR="/opt/smtp-to-gotify"
SOURCE_DIR="/tmp/smtp-to-gotify-src"
MAIN_GO_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/main.go"
MAIN_GO_FILE="${SOURCE_DIR}/main.go"
BINARY_DEST="${INSTALL_DIR}/${BINARY_NAME}"
SERVICE_SCRIPT="/usr/local/etc/rc.d/smtp_to_gotify"
CONFIG_DIR="${INSTALL_DIR}"
LOG_DIR="${INSTALL_DIR}"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
RC_CONF_FILE="/etc/rc.conf.local"
GO_PKG="go121"
GO_CMD="go121"

# Check if tput is available and terminal supports colors
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    NC=$(tput sgr0)
    SUPPORT_COLORS=true
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
    SUPPORT_COLORS=false
fi

CHECKMARK="${GREEN}✓${NC}"

# Function to display usage
usage() {
    echo "${YELLOW}Usage: $0 [--uninstall]${NC}"
    echo "  --uninstall: Remove smtp-to-gotify and undo all installation changes."
    exit 1
}

# Function to prompt for confirmation
confirm() {
    local prompt="$1"
    local response
    echo "${YELLOW}${prompt} (y/N): ${NC}"
    read response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            echo "${RED}Operation cancelled by user.${NC}"
            exit 1
            ;;
    esac
}

# Check for uninstall argument
UNINSTALL=false
for arg in "$@"; do
    if [ "$arg" = "--uninstall" ]; then
        UNINSTALL=true
        break
    elif [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
    fi
done

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "${RED}Error: This script must be run as root. Use 'su' or 'sudo'.${NC}"
    exit 1
fi

# Uninstall function
uninstall() {
    echo "${YELLOW}=== Uninstalling smtp-to-gotify ===${NC}"
    confirm "Are you sure you want to uninstall smtp-to-gotify and remove all associated files?"
    echo "${GREEN}Confirmation received. Proceeding with uninstallation...${NC}"

    # Stop the service if running
    echo "${YELLOW}Stopping smtp-to-gotify service...${NC}"
    if service smtp_to_gotify status >/dev/null 2>&1; then
        service smtp_to_gotify stop
        if [ $? -eq 0 ]; then
            echo "${GREEN}Service stopped successfully. ${CHECKMARK}${NC}"
        else
            echo "${RED}Warning: Failed to stop service. Continuing with uninstall.${NC}"
        fi
    else
        echo "${GREEN}Service smtp_to_gotify is not running. ${CHECKMARK}${NC}"
    fi

    # Remove service script
    echo "${YELLOW}Removing service script: ${SERVICE_SCRIPT}...${NC}"
    if [ -f "${SERVICE_SCRIPT}" ]; then
        rm -f "${SERVICE_SCRIPT}"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Service script removed. ${CHECKMARK}${NC}"
        else
            echo "${RED}Error: Failed to remove service script ${SERVICE_SCRIPT}${NC}"
        fi
    else
        echo "${GREEN}Service script ${SERVICE_SCRIPT} not found. ${CHECKMARK}${NC}"
    fi

    # Disable service in rc.conf.local or rc.conf
    echo "${YELLOW}Disabling service in configuration...${NC}"
    if [ -f "${RC_CONF_FILE}" ] && grep -q "smtp_to_gotify_enable=" "${RC_CONF_FILE}"; then
        sed -i '' 's/smtp_to_gotify_enable="YES"/smtp_to_gotify_enable="NO"/' "${RC_CONF_FILE}"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Service disabled in ${RC_CONF_FILE}. ${CHECKMARK}${NC}"
        else
            echo "${RED}Error: Failed to disable service in ${RC_CONF_FILE}${NC}"
        fi
    elif [ -f "/etc/rc.conf" ] && grep -q "smtp_to_gotify_enable=" "/etc/rc.conf"; then
        sed -i '' 's/smtp_to_gotify_enable="YES"/smtp_to_gotify_enable="NO"/' "/etc/rc.conf"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Service disabled in /etc/rc.conf. ${CHECKMARK}${NC}"
        else
            echo "${RED}Error: Failed to disable service in /etc/rc.conf${NC}"
        fi
    else
        echo "${GREEN}Service not enabled in rc.conf or rc.conf.local. ${CHECKMARK}${NC}"
    fi

    # Remove binary and directories
    echo "${YELLOW}Removing installation directory and contents: ${INSTALL_DIR}...${NC}"
    if [ -d "${INSTALL_DIR}" ]; then
        rm -rf "${INSTALL_DIR}"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Installation directory removed. ${CHECKMARK}${NC}"
        else
            echo "${RED}Error: Failed to remove directory ${INSTALL_DIR}${NC}"
        fi
    else
        echo "${GREEN}Installation directory ${INSTALL_DIR} not found. ${CHECKMARK}${NC}"
    fi

    # Remove pidfile if it exists
    PIDFILE="/var/run/smtp_to_gotify.pid"
    echo "${YELLOW}Removing pidfile if it exists: ${PIDFILE}...${NC}"
    if [ -f "${PIDFILE}" ]; then
        rm -f "${PIDFILE}"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Pidfile removed. ${CHECKMARK}${NC}"
        else
            echo "${RED}Error: Failed to remove pidfile ${PIDFILE}${NC}"
        fi
    else
        echo "${GREEN}Pidfile not found. ${CHECKMARK}${NC}"
    fi

    echo "${GREEN}Uninstallation complete! smtp-to-gotify has been removed. ${CHECKMARK}${NC}"
    exit 0
}

# Execute uninstall if requested
if [ "$UNINSTALL" = true ]; then
    uninstall
fi

# Install procedure (if not uninstalling)
echo "${YELLOW}=== Installing smtp-to-gotify ===${NC}"
confirm "Are you sure you want to install smtp-to-gotify?"
echo "${GREEN}Confirmation received. Proceeding with installation...${NC}"

# Install Go compiler package
echo "${YELLOW}Installing Go compiler package (${GO_PKG})...${NC}"
pkg install -y "${GO_PKG}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to install Go compiler package (${GO_PKG}). Please ensure pkg is configured and internet access is available.${NC}"
    exit 1
else
    echo "${GREEN}Go compiler installed successfully. ${CHECKMARK}${NC}"
fi

# Create source directory for downloading the source code
echo "${YELLOW}Creating temporary source directory: ${SOURCE_DIR}...${NC}"
mkdir -p "${SOURCE_DIR}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to create source directory ${SOURCE_DIR}${NC}"
    exit 1
else
    echo "${GREEN}Source directory created. ${CHECKMARK}${NC}"
fi

# Download the source code from the specified URL
echo "${YELLOW}Downloading source code from ${MAIN_GO_URL}...${NC}"
fetch -o "${MAIN_GO_FILE}" "${MAIN_GO_URL}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to download source code from ${MAIN_GO_URL}. Please check internet connectivity.${NC}"
    rm -rf "${SOURCE_DIR}"
    exit 1
else
    echo "${GREEN}Source code downloaded to ${MAIN_GO_FILE}. ${CHECKMARK}${NC}"
fi

# Initialize Go module in the source directory
echo "${YELLOW}Initializing Go module in ${SOURCE_DIR}...${NC}"
cd "${SOURCE_DIR}"
${GO_CMD} mod init smtp-to-gotify
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to initialize Go module. Please ensure ${GO_CMD} is installed correctly.${NC}"
    rm -rf "${SOURCE_DIR}"
    exit 1
else
    echo "${GREEN}Go module initialized successfully. ${CHECKMARK}${NC}"
fi

# Download necessary dependencies using go mod tidy
echo "${YELLOW}Downloading dependencies with ${GO_CMD} mod tidy...${NC}"
${GO_CMD} mod tidy
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to download dependencies with ${GO_CMD} mod tidy. Please check internet connectivity or source code requirements.${NC}"
    rm -rf "${SOURCE_DIR}"
    exit 1
else
    echo "${GREEN}Dependencies downloaded successfully. ${CHECKMARK}${NC}"
fi

# Compile the source code into a binary
echo "${YELLOW}Compiling source code to binary with ${GO_CMD} build...${NC}"
${GO_CMD} build -o "${BINARY_DEST}" "${MAIN_GO_FILE}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to compile source code. Please ensure ${GO_CMD} is installed correctly and dependencies are resolved.${NC}"
    rm -rf "${SOURCE_DIR}"
    exit 1
else
    echo "${GREEN}Binary compiled successfully to ${BINARY_DEST}. ${CHECKMARK}${NC}"
fi

# Clean up temporary source directory
echo "${YELLOW}Cleaning up temporary source directory...${NC}"
rm -rf "${SOURCE_DIR}"
if [ $? -eq 0 ]; then
    echo "${GREEN}Temporary source directory removed. ${CHECKMARK}${NC}"
else
    echo "${RED}Warning: Failed to clean up temporary source directory ${SOURCE_DIR}.${NC}"
fi

# Create installation directory
echo "${YELLOW}Creating installation directory: ${INSTALL_DIR}...${NC}"
mkdir -p "${INSTALL_DIR}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to create directory ${INSTALL_DIR}${NC}"
    exit 1
else
    echo "${GREEN}Installation directory created. ${CHECKMARK}${NC}"
fi

# Create config and log directories (if separate, but here they are under INSTALL_DIR)
echo "${YELLOW}Creating config and log directories...${NC}"
mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to create config or log directories${NC}"
    exit 1
else
    echo "${GREEN}Config and log directories created. ${CHECKMARK}${NC}"
fi

# Set permissions for the binary
echo "${YELLOW}Setting permissions for binary...${NC}"
chmod 750 "${BINARY_DEST}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to set permissions on binary${NC}"
    exit 1
else
    echo "${GREEN}Binary permissions set. ${CHECKMARK}${NC}"
fi

# Set ownership to root (or another user if needed)
echo "${YELLOW}Setting ownership for binary...${NC}"
chown root:wheel "${BINARY_DEST}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to set ownership on binary${NC}"
    exit 1
else
    echo "${GREEN}Binary ownership set. ${CHECKMARK}${NC}"
fi

# Set permissions for config and log directories
echo "${YELLOW}Setting permissions and ownership for config and log directories...${NC}"
chmod 750 "${CONFIG_DIR}" "${LOG_DIR}"
chown root:wheel "${CONFIG_DIR}" "${LOG_DIR}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to set permissions/ownership on config or log directories${NC}"
    exit 1
else
    echo "${GREEN}Directory permissions and ownership set. ${CHECKMARK}${NC}"
fi

# Create the service script for FreeBSD/pfSense
echo "${YELLOW}Creating service script at ${SERVICE_SCRIPT}...${NC}"
cat > "${SERVICE_SCRIPT}" << 'EOF'
#!/bin/sh

# PROVIDE: smtp_to_gotify
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="smtp_to_gotify"
rcvar="smtp_to_gotify_enable"
command="/opt/smtp-to-gotify/smtp-to-gotify"
pidfile="/var/run/${name}.pid"
required_files="/opt/smtp-to-gotify/config.yaml"
command_args="start"

start_cmd="${name}_start"
stop_cmd="${name}_stop"
status_cmd="${name}_status"

smtp_to_gotify_start()
{
    echo "Starting ${name}..."
    /usr/sbin/daemon -p ${pidfile} ${command} ${command_args}
    if [ $? -eq 0 ]; then
        echo "${name} started."
    else
        echo "Failed to start ${name}."
        return 1
    fi
}

smtp_to_gotify_stop()
{
    if [ -f "${pidfile}" ]; then
        pid=$(cat "${pidfile}")
        echo "Stopping ${name} (PID: ${pid})..."
        kill -TERM "${pid}"
        rm -f "${pidfile}"
        echo "${name} stopped."
    else
        echo "${name} is not running."
        return 1
    fi
}

smtp_to_gotify_status()
{
    if [ -f "${pidfile}" ]; then
        pid=$(cat "${pidfile}")
        if ps -p "${pid}" > /dev/null; then
            echo "${name} is running as PID ${pid}."
        else
            echo "${name} is not running, but pidfile exists."
            rm -f "${pidfile}"
            return 1
        fi
    else
        echo "${name} is not running."
        return 1
    fi
}

load_rc_config $name
: ${smtp_to_gotify_enable="NO"}

run_rc_command "$1"
EOF

# Set permissions for the service script
echo "${YELLOW}Setting permissions for service script...${NC}"
chmod 755 "${SERVICE_SCRIPT}"
if [ $? -ne 0 ]; then
    echo "${RED}Error: Failed to set permissions on service script${NC}"
    exit 1
else
    echo "${GREEN}Service script permissions set. ${CHECKMARK}${NC}"
fi

# Enable the service in rc.conf.local (or rc.conf if rc.conf.local doesn't exist)
if [ ! -f "${RC_CONF_FILE}" ]; then
    RC_CONF_FILE="/etc/rc.conf"
fi

echo "${YELLOW}Enabling ${BINARY_NAME} service in ${RC_CONF_FILE}...${NC}"
if grep -q "smtp_to_gotify_enable=" "${RC_CONF_FILE}"; then
    sed -i '' 's/smtp_to_gotify_enable="NO"/smtp_to_gotify_enable="YES"/' "${RC_CONF_FILE}"
else
    echo 'smtp_to_gotify_enable="YES"' >> "${RC_CONF_FILE}"
fi
if [ $? -eq 0 ]; then
    echo "${GREEN}Service enabled successfully. ${CHECKMARK}${NC}"
else
    echo "${RED}Warning: Failed to enable service in ${RC_CONF_FILE}. You may need to enable it manually.${NC}"
fi

# Check if config file exists; if not, create a placeholder
echo "${YELLOW}Creating placeholder config file if it doesn't exist...${NC}"
if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" << 'EOF'
smtp:
  addr: ":2525"
  domain: "localhost"
  smtp_username: "admin"
  smtp_password: "password"
  auth_required: true
gotify:
  gotify_host: "https://gotify.example.com"
  gotify_token: ""
EOF
    chmod 640 "${CONFIG_FILE}"
    chown root:wheel "${CONFIG_FILE}"
    if [ $? -eq 0 ]; then
        echo "${GREEN}Placeholder config file created at ${CONFIG_FILE}. ${CHECKMARK}${NC}"
    else
        echo "${RED}Error: Failed to create or set permissions for config file.${NC}"
    fi
else
    echo "${GREEN}Config file already exists at ${CONFIG_FILE}. ${CHECKMARK}${NC}"
fi

# Notify user of completion and next steps
echo "${GREEN}Installation complete! ${CHECKMARK}${NC}"
echo "The ${BINARY_NAME} binary has been installed to ${INSTALL_DIR}."
echo "The service script has been created at ${SERVICE_SCRIPT} and enabled in ${RC_CONF_FILE}."
echo "A placeholder config file has been created at ${CONFIG_FILE}. Please edit it with your settings."
echo "To start the service now, run:"
echo "  ${GREEN}service smtp_to_gotify start${NC}"
echo "The service will start automatically on boot."
echo "To uninstall, run this script with the --uninstall argument:"
echo "  ${GREEN}$0 --uninstall${NC}"

exit 0
