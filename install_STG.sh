#!/bin/sh
# Installation script for smtp-to-gotify on pfSense (FreeBSD) or Debian 12 (SystemD)
# This script allows the user to select the target OS, downloads the appropriate source code,
# installs the Go compiler, compiles the binary, sets up directories, and configures a service.
# It also supports uninstalling the program with the --uninstall argument.
# Enhanced with colored UI and confirmation prompts for user interaction using tput for portability.
# Supports non-interactive mode with --no-confirm for automated installations.

# Define common variables
BINARY_NAME="smtp-to-gotify"
INSTALL_DIR="/opt/smtp-to-gotify"
SOURCE_DIR="/tmp/smtp-to-gotify-src"
BINARY_DEST="${INSTALL_DIR}/${BINARY_NAME}"
CONFIG_DIR="${INSTALL_DIR}"
LOG_DIR="${INSTALL_DIR}"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
PFSENSE_MAIN_GO_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/main.go"
DEBIAN_MAIN_GO_URL="https://raw.githubusercontent.com/NeoMetra/STG/main/sc_debian.go"
MAIN_GO_FILE="${SOURCE_DIR}/main.go"
GO_VERSION="go"

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
    echo "${YELLOW}Usage: $0 [--uninstall] [--no-confirm]${NC}"
    echo "  --uninstall: Remove smtp-to-gotify and undo all installation changes."
    echo "  --no-confirm: Skip confirmation prompts for automated installations."
    exit 1
}

# Function to prompt for confirmation
confirm() {
    local prompt="$1"
    local response
    if [ "$NO_CONFIRM" = true ] || ! [ -t 0 ]; then
        echo "${YELLOW}${prompt} (y/N): Automatically confirmed.${NC}"
        return 0
    fi
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

# Function to select OS
select_os() {
    if [ "$NO_CONFIRM" = true ] || ! [ -t 0 ]; then
        echo "${RED}Error: OS selection cannot be automated. Please run interactively or specify OS manually.${NC}"
        exit 1
    fi
    echo "${YELLOW}Select the operating system to install smtp-to-gotify on:${NC}"
    echo "  1. pfSense (FreeBSD)"
    echo "  2. Debian 12 (SystemD)"
    echo "${YELLOW}Enter the number of your choice (1-2): ${NC}"
    read os_choice
    case "$os_choice" in
        1)
            OS_TYPE="pfsense"
            echo "${GREEN}Selected pfSense (FreeBSD).${NC}"
            ;;
        2)
            OS_TYPE="debian"
            echo "${GREEN}Selected Debian 12 (SystemD).${NC}"
            ;;
        *)
            echo "${RED}Invalid choice. Please select 1 or 2.${NC}"
            exit 1
            ;;
    esac
}

# Check for arguments
UNINSTALL=false
NO_CONFIRM=false
for arg in "$@"; do
    if [ "$arg" = "--uninstall" ]; then
        UNINSTALL=true
    elif [ "$arg" = "--no-confirm" ]; then
        NO_CONFIRM=true
    elif [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
    fi
done

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "${RED}Error: This script must be run as root. Use 'su' or 'sudo'.${NC}"
    exit 1
fi

# Uninstall function for pfSense
uninstall_pfsense() {
    echo "${YELLOW}=== Uninstalling smtp-to-gotify on pfSense ===${NC}"
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
    SERVICE_SCRIPT="/usr/local/etc/rc.d/smtp_to_gotify"
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
    RC_CONF_FILE="/etc/rc.conf.local"
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

# Uninstall function for Debian
uninstall_debian() {
    echo "${YELLOW}=== Uninstalling smtp-to-gotify on Debian ===${NC}"
    confirm "Are you sure you want to uninstall smtp-to-gotify and remove all associated files?"
    echo "${GREEN}Confirmation received. Proceeding with uninstallation...${NC}"
    # Stop the service if running
    echo "${YELLOW}Stopping smtp-to-gotify service...${NC}"
    if systemctl is-active --quiet smtp-to-gotify; then
        systemctl stop smtp-to-gotify
        if [ $? -eq 0 ]; then
            echo "${GREEN}Service stopped successfully. ${CHECKMARK}${NC}"
        else
            echo "${RED}Warning: Failed to stop service. Continuing with uninstall.${NC}"
        fi
    else
        echo "${GREEN}Service smtp-to-gotify is not running. ${CHECKMARK}${NC}"
    fi
    # Disable the service
    echo "${YELLOW}Disabling smtp-to-gotify service...${NC}"
    systemctl disable smtp-to-gotify
    if [ $? -eq 0 ]; then
        echo "${GREEN}Service disabled successfully. ${CHECKMARK}${NC}"
    else
        echo "${RED}Warning: Failed to disable service. Continuing with uninstall.${NC}"
    fi
    # Remove service file
    SERVICE_FILE="/etc/systemd/system/smtp-to-gotify.service"
    echo "${YELLOW}Removing service file: ${SERVICE_FILE}...${NC}"
    if [ -f "${SERVICE_FILE}" ]; then
        rm -f "${SERVICE_FILE}"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Service file removed. ${CHECKMARK}${NC}"
        else
            echo "${RED}Error: Failed to remove service file ${SERVICE_FILE}${NC}"
        fi
    else
        echo "${GREEN}Service file ${SERVICE_FILE} not found. ${CHECKMARK}${NC}"
    fi
    # Reload systemd daemon
    echo "${YELLOW}Reloading systemd daemon...${NC}"
    systemctl daemon-reload
    if [ $? -eq 0 ]; then
        echo "${GREEN}Systemd daemon reloaded. ${CHECKMARK}${NC}"
    else
        echo "${RED}Warning: Failed to reload systemd daemon.${NC}"
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
    echo "${GREEN}Uninstallation complete! smtp-to-gotify has been removed. ${CHECKMARK}${NC}"
    exit 0
}

# Execute uninstall if requested
if [ "$UNINSTALL" = true ]; then
    select_os
    if [ "$OS_TYPE" = "pfsense" ]; then
        uninstall_pfsense
    else
        uninstall_debian
    fi
fi

# Install procedure (if not uninstalling)
echo "${YELLOW}=== Installing smtp-to-gotify ===${NC}"
select_os
confirm "Are you sure you want to install smtp-to-gotify on $OS_TYPE?"
echo "${GREEN}Confirmation received. Proceeding with installation...${NC}"

# Installation for pfSense (FreeBSD)
install_pfsense() {
    # Install Go compiler package
    echo "${YELLOW}Installing Go compiler package (go121)...${NC}"
    pkg install -y go121
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to install Go compiler package (go121). Please ensure pkg is configured and internet access is available.${NC}"
        exit 1
    else
        echo "${GREEN}Go compiler installed successfully. ${CHECKMARK}${NC}"
    fi
    GO_CMD="go121"
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
    echo "${YELLOW}Downloading source code from ${PFSENSE_MAIN_GO_URL}...${NC}"
    fetch -o "${MAIN_GO_FILE}" "${PFSENSE_MAIN_GO_URL}"
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to download source code from ${PFSENSE_MAIN_GO_URL}. Please check internet connectivity.${NC}"
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
    # Create config and log directories
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
    # Set ownership to root
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
    SERVICE_SCRIPT="/usr/local/etc/rc.d/smtp_to_gotify"
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
    RC_CONF_FILE="/etc/rc.conf.local"
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
}

# Installation for Debian 12 (SystemD)
install_debian() {
    # Update package lists
    echo "${YELLOW}Updating package lists...${NC}"
    apt update
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to update package lists. Please check internet connectivity.${NC}"
        exit 1
    fi
    # Install basic tools if not already present
    echo "${YELLOW}Installing necessary tools (wget, tar)...${NC}"
    apt install -y wget tar
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to install necessary tools. Please ensure apt is configured and internet access is available.${NC}"
        exit 1
    fi
    # Check if Go is installed and its version
    echo "${YELLOW}Checking for existing Go installation...${NC}"
    GO_INSTALLED=false
    GO_VERSION_OK=false
    if command -v go >/dev/null 2>&1; then
        GO_INSTALLED=true
        GO_VERSION_STR=$(go version | awk '{print $3}' | sed 's/go//')
        echo "${YELLOW}Found Go version: ${GO_VERSION_STR}${NC}"
        # Compare version (need at least Go 1.21 for log/slog and slices)
        GO_MAJOR=$(echo "${GO_VERSION_STR}" | cut -d. -f1)
        GO_MINOR=$(echo "${GO_VERSION_STR}" | cut -d. -f2)
        if [ "${GO_MAJOR}" -gt 1 ] || { [ "${GO_MAJOR}" -eq 1 ] && [ "${GO_MINOR}" -ge 21 ]; }; then
            GO_VERSION_OK=true
            echo "${GREEN}Go version ${GO_VERSION_STR} is sufficient (>= 1.21). ${CHECKMARK}${NC}"
        else
            echo "${RED}Go version ${GO_VERSION_STR} is too old (< 1.21). A newer version will be installed.${NC}"
        fi
    else
        echo "${YELLOW}Go is not installed. A newer version will be installed.${NC}"
    fi
    # Install or update Go if necessary
    if [ "${GO_INSTALLED}" = false ] || [ "${GO_VERSION_OK}" = false ]; then
        echo "${YELLOW}Downloading and installing Go 1.22 (or latest)...${NC}"
        GO_TARBALL="go1.22.5.linux-amd64.tar.gz"
        GO_URL="https://golang.org/dl/${GO_TARBALL}"
        wget -O /tmp/${GO_TARBALL} "${GO_URL}"
        if [ $? -ne 0 ]; then
            echo "${RED}Error: Failed to download Go from ${GO_URL}. Please check internet connectivity.${NC}"
            exit 1
        fi
        # Remove old Go if it exists
        if [ -d "/usr/local/go" ]; then
            echo "${YELLOW}Removing old Go installation at /usr/local/go...${NC}"
            rm -rf /usr/local/go
        fi
        # Extract and install Go
        echo "${YELLOW}Extracting and installing Go to /usr/local...${NC}"
        tar -C /usr/local -xzf /tmp/${GO_TARBALL}
        if [ $? -ne 0 ]; then
            echo "${RED}Error: Failed to extract Go tarball.${NC}"
            exit 1
        fi
        # Set up environment variables for Go
        echo "${YELLOW}Setting up Go environment variables...${NC}"
        if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" /etc/profile; then
            echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/profile
        fi
        if ! grep -q "export GOPATH=\$HOME/go" /etc/profile; then
            echo "export GOPATH=\$HOME/go" >> /etc/profile
        fi
        if ! grep -q "export PATH=\$PATH:\$GOPATH/bin" /etc/profile; then
            echo "export PATH=\$PATH:\$GOPATH/bin" >> /etc/profile
        fi
        # Apply environment changes for the current session
        export PATH=$PATH:/usr/local/go/bin
        export GOPATH=$HOME/go
        export PATH=$PATH:$GOPATH/bin
        # Clean up tarball
        rm -f /tmp/${GO_TARBALL}
        echo "${GREEN}Go 1.22 installed successfully at /usr/local/go. ${CHECKMARK}${NC}"
    fi
    GO_CMD="/usr/local/go/bin/go"
    if [ ! -x "${GO_CMD}" ]; then
        GO_CMD="go"
    fi
    # Verify Go version again
    echo "${YELLOW}Verifying Go version...${NC}"
    ${GO_CMD} version
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Go compiler is not working correctly. Please check installation.${NC}"
        exit 1
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
    echo "${YELLOW}Downloading source code from ${DEBIAN_MAIN_GO_URL}...${NC}"
    wget -O "${MAIN_GO_FILE}" "${DEBIAN_MAIN_GO_URL}"
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to download source code from ${DEBIAN_MAIN_GO_URL}. Please check internet connectivity.${NC}"
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
    # Create config and log directories
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
    # Set ownership to root
    echo "${YELLOW}Setting ownership for binary...${NC}"
    chown root:root "${BINARY_DEST}"
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to set ownership on binary${NC}"
        exit 1
    else
        echo "${GREEN}Binary ownership set. ${CHECKMARK}${NC}"
    fi
    # Set permissions for config and log directories
    echo "${YELLOW}Setting permissions and ownership for config and log directories...${NC}"
    chmod 750 "${CONFIG_DIR}" "${LOG_DIR}"
    chown root:root "${CONFIG_DIR}" "${LOG_DIR}"
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to set permissions/ownership on config or log directories${NC}"
        exit 1
    else
        echo "${GREEN}Directory permissions and ownership set. ${CHECKMARK}${NC}"
    fi
    # Create the systemd service file for Debian
    SERVICE_FILE="/etc/systemd/system/smtp-to-gotify.service"
    echo "${YELLOW}Creating systemd service file at ${SERVICE_FILE}...${NC}"
    cat > "${SERVICE_FILE}" << 'EOF'
[Unit]
Description=SMTP to Gotify Forwarder
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/smtp-to-gotify
Environment=RUN_AS_SERVICE=true
ExecStart=/opt/smtp-to-gotify/smtp-to-gotify start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    # Set permissions for the service file
    echo "${YELLOW}Setting permissions for service file...${NC}"
    chmod 644 "${SERVICE_FILE}"
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to set permissions on service file${NC}"
        exit 1
    else
        echo "${GREEN}Service file permissions set. ${CHECKMARK}${NC}"
    fi
    # Reload systemd daemon and enable the service
    echo "${YELLOW}Reloading systemd daemon and enabling service...${NC}"
    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo "${RED}Error: Failed to reload systemd daemon${NC}"
        exit 1
    fi
    systemctl enable smtp-to-gotify
    if [ $? -eq 0 ]; then
        echo "${GREEN}Service enabled successfully. ${CHECKMARK}${NC}"
    else
        echo "${RED}Warning: Failed to enable service. You may need to enable it manually.${NC}"
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
        chown root:root "${CONFIG_FILE}"
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
    echo "The systemd service file has been created at ${SERVICE_FILE} and enabled."
    echo "A placeholder config file has been created at ${CONFIG_FILE}. Please edit it with your settings."
    echo "To start the service now, run:"
    echo "  ${GREEN}systemctl start smtp-to-gotify${NC}"
    echo "The service will start automatically on boot."
    echo "To uninstall, run this script with the --uninstall argument:"
    echo "  ${GREEN}$0 --uninstall${NC}"
    exit 0
}
# Execute the appropriate installation based on OS type
if [ "$OS_TYPE" = "pfsense" ]; then
    install_pfsense
else
    install_debian
fi
