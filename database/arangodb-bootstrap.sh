#!/bin/bash
# ==============================================================================
# ArangoDB - Bootstrap Script
# ==============================================================================
# This script installs and configures ArangoDB Community Edition from the
# official ArangoDB repository on Ubuntu/Debian.
#
# Features:
#   - Installs latest ArangoDB 3.12 from official download.arangodb.com repo
#   - Reliably sets root password (with fallback methods)
#   - Enables remote web UI access (binds to 0.0.0.0)
#   - Opens firewall ports for HTTP API/Web UI (8529)
#
# Usage:
#   sudo ./arangodb-bootstrap.sh
#
# After installation:
#   - Web UI:  http://<server-ip>:8529
#   - Shell:   arangosh
#   - Default port: 8529
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/arangodb-config.json"

ARANGO_VERSION="312"       # Repository version slug (e.g., 312 for 3.12.x)
ARANGO_PORT=8529
ARANGO_ROOT_PASSWORD=""
ARANGO_BIND="0.0.0.0"     # Bind to all interfaces for remote web UI access

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq > /dev/null 2>&1; then
            ARANGO_ROOT_PASSWORD=$(jq -r '.arango_root_password // ""' "$CONFIG_FILE")
            ARANGO_BIND=$(jq -r '.arango_bind // "0.0.0.0"' "$CONFIG_FILE")
            echo "Loaded configuration from $CONFIG_FILE"
        else
            echo "Warning: jq not installed. Cannot read config file."
            echo "Install with: sudo apt install jq"
        fi
    else
        echo "Warning: Config file not found: $CONFIG_FILE"
        echo "Using default values."
    fi
}

load_config

# ==============================================================================
# ARGUMENT PARSING (overrides config file)
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            load_config
            shift 2
            ;;
        --arango-root-password)
            ARANGO_ROOT_PASSWORD="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script installs and configures ArangoDB Community Edition with:"
            echo "  - Latest ArangoDB 3.12 from official repository"
            echo "  - Root password authentication"
            echo "  - Remote web UI access"
            echo ""
            echo "Options:"
            echo "  --config <file>                  Path to config file (default: arangodb-config.json)"
            echo "  --arango-root-password <pass>     Override ArangoDB root password from config"
            echo "  --help, -h                        Show this help message"
            echo ""
            echo "Configuration is read from arangodb-config.json. Command-line args override."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# ==============================================================================
# PREFLIGHT CHECKS
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)."
    exit 1
fi

# Prompt for password if not set
if [[ -z "$ARANGO_ROOT_PASSWORD" ]]; then
    read -s -p "Enter ArangoDB root password: " ARANGO_ROOT_PASSWORD
    echo ""
    if [[ -z "$ARANGO_ROOT_PASSWORD" ]]; then
        echo "Error: Password cannot be empty."
        exit 1
    fi
fi

echo "=============================================="
echo "ArangoDB - Bootstrap"
echo "=============================================="
echo ""

# ==============================================================================
# INSTALL ARANGODB
# ==============================================================================
install_arangodb() {
    echo "Installing ArangoDB from official repository..."

    export DEBIAN_FRONTEND=noninteractive

    # 1. Install prerequisites
    apt-get update -qq || true
    apt-get install -y curl gnupg2 apt-transport-https jq

    # 2. Add ArangoDB GPG key (modern signed-by method)
    echo "Adding ArangoDB GPG key..."
    curl -fsSL "https://download.arangodb.com/arangodb${ARANGO_VERSION}/DEBIAN/Release.key" | \
        gpg --dearmor -o /usr/share/keyrings/arangodb-archive-keyring.gpg
    chmod 644 /usr/share/keyrings/arangodb-archive-keyring.gpg

    # 3. Add ArangoDB repository
    echo "Adding ArangoDB repository..."
    echo "deb [signed-by=/usr/share/keyrings/arangodb-archive-keyring.gpg] https://download.arangodb.com/arangodb${ARANGO_VERSION}/DEBIAN/ /" | \
        tee /etc/apt/sources.list.d/arangodb.list

    # 4. Pre-seed debconf so the installer doesn't prompt interactively
    #    NOTE: This may not take effect on all distros/versions — the
    #    set_root_password step below handles that case.
    echo "Pre-configuring ArangoDB root password..."
    echo "arangodb3 arangodb3/password password $ARANGO_ROOT_PASSWORD" | debconf-set-selections
    echo "arangodb3 arangodb3/password_again password $ARANGO_ROOT_PASSWORD" | debconf-set-selections
    echo "arangodb3 arangodb3/upgrade boolean true" | debconf-set-selections
    echo "arangodb3 arangodb3/storage_engine select auto" | debconf-set-selections
    echo "arangodb3 arangodb3/backup boolean false" | debconf-set-selections

    # 5. Install ArangoDB (fully non-interactive, auto-accept all prompts)
    apt-get update -qq || true
    apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        arangodb3

    echo "ArangoDB installed successfully."
}

# ==============================================================================
# SET ROOT PASSWORD (robust, with fallback)
# ==============================================================================
# debconf pre-seeding is unreliable across distros. This function ensures the
# root password is correctly set after installation by trying multiple methods.
set_root_password() {
    echo "Setting root password..."

    local api_url="http://127.0.0.1:${ARANGO_PORT}/_api/version"

    # Method 1: Password already works (debconf succeeded)
    if curl -sf "$api_url" -u "root:${ARANGO_ROOT_PASSWORD}" > /dev/null 2>&1; then
        echo "Root password is already set correctly."
        return
    fi

    # Method 2: Empty password (debconf was ignored) — update via API
    if curl -sf "$api_url" -u "root:" > /dev/null 2>&1; then
        echo "ArangoDB has empty root password. Setting password via API..."
        curl -sf -X PATCH "http://127.0.0.1:${ARANGO_PORT}/_api/user/root" \
            -u "root:" \
            -H "Content-Type: application/json" \
            -d "{\"passwd\": \"${ARANGO_ROOT_PASSWORD}\"}" > /dev/null

        # Verify
        if curl -sf "$api_url" -u "root:${ARANGO_ROOT_PASSWORD}" > /dev/null 2>&1; then
            echo "Root password set successfully."
            return
        fi
    fi

    # Method 3: Temporarily disable authentication, set password, re-enable
    echo "Fallback: Temporarily disabling authentication to set root password..."
    local config_file="/etc/arangodb3/arangod.conf"

    # Disable authentication
    if grep -q "^authentication = " "$config_file" 2>/dev/null; then
        sed -i 's/^authentication = .*/authentication = false/' "$config_file"
    else
        sed -i '/^\[server\]/a authentication = false' "$config_file"
    fi

    systemctl restart arangodb3
    sleep 3

    # Wait for ArangoDB to come up
    local attempt=0
    while [[ $attempt -lt 15 ]]; do
        if curl -sf "$api_url" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        ((attempt++))
    done

    # Set password via API (no auth required now)
    curl -sf -X PATCH "http://127.0.0.1:${ARANGO_PORT}/_api/user/root" \
        -H "Content-Type: application/json" \
        -d "{\"passwd\": \"${ARANGO_ROOT_PASSWORD}\"}" > /dev/null

    # Re-enable authentication
    sed -i 's/^authentication = false/authentication = true/' "$config_file"
    systemctl restart arangodb3
    sleep 3

    # Wait and verify
    attempt=0
    while [[ $attempt -lt 15 ]]; do
        if curl -sf "$api_url" -u "root:${ARANGO_ROOT_PASSWORD}" > /dev/null 2>&1; then
            echo "Root password set successfully (via auth-disable fallback)."
            return
        fi
        sleep 1
        ((attempt++))
    done

    echo "ERROR: Could not set root password. Check /var/log/arangodb3/ for details."
    exit 1
}

# ==============================================================================
# CONFIGURE ARANGODB
# ==============================================================================
configure_arangodb() {
    echo "Configuring ArangoDB..."

    local config_file="/etc/arangodb3/arangod.conf"

    # Backup original config
    if [[ ! -f "${config_file}.bak" ]]; then
        cp "$config_file" "${config_file}.bak"
    fi

    # --- Bind address (enable remote access for web UI) ---
    # Replace the endpoint to bind to all interfaces
    if grep -q "^endpoint = " "$config_file"; then
        sed -i "s|^endpoint = .*|endpoint = tcp://${ARANGO_BIND}:${ARANGO_PORT}|" "$config_file"
    else
        # Add endpoint under [server] section if not present
        sed -i "/^\[server\]/a endpoint = tcp://${ARANGO_BIND}:${ARANGO_PORT}" "$config_file"
    fi

    echo "ArangoDB configuration updated."
}

# ==============================================================================
# START ARANGODB SERVICE
# ==============================================================================
start_arangodb() {
    echo "Starting ArangoDB service..."

    systemctl enable arangodb3
    systemctl restart arangodb3

    # Wait for ArangoDB to start
    echo "Waiting for ArangoDB to start..."
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s "http://127.0.0.1:${ARANGO_PORT}/_api/version" > /dev/null 2>&1; then
            echo "ArangoDB is running!"
            return
        fi
        sleep 2
        ((attempt++))
        echo "  Waiting... ($attempt/$max_attempts)"
    done

    echo "Warning: ArangoDB may not have started. Check: systemctl status arangodb3"
}

# ==============================================================================
# CONFIGURE FIREWALL
# ==============================================================================
configure_firewall() {
    if command -v ufw > /dev/null 2>&1; then
        if [[ "$ARANGO_BIND" == "0.0.0.0" ]]; then
            echo "Allowing port $ARANGO_PORT through UFW..."
            ufw allow $ARANGO_PORT/tcp comment "ArangoDB HTTP/Web UI"
        else
            echo "ArangoDB bound to localhost only — no firewall changes needed."
        fi
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    install_arangodb
    echo ""

    configure_arangodb
    echo ""

    configure_firewall
    echo ""

    start_arangodb
    echo ""

    set_root_password
    echo ""

    # Get ArangoDB version
    ARANGO_INSTALLED_VERSION=$(arangod --version 2>/dev/null | head -n 1 || echo "unknown")

    echo "=============================================="
    echo "ArangoDB Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  - $ARANGO_INSTALLED_VERSION"
    echo "  - Port: $ARANGO_PORT"
    echo "  - Bind: $ARANGO_BIND"
    echo "  - Authentication: root password enabled"
    echo ""
    echo "Access:"
    echo "  Web UI:  http://<server-ip>:$ARANGO_PORT"
    echo "  Shell:   arangosh --server.endpoint tcp://127.0.0.1:$ARANGO_PORT"
    echo ""
    echo "Commands:"
    echo "  Status:  sudo systemctl status arangodb3"
    echo "  Stop:    sudo systemctl stop arangodb3"
    echo "  Start:   sudo systemctl start arangodb3"
    echo "  Logs:    sudo journalctl -u arangodb3 -f"
    echo ""
    echo "Config:    /etc/arangodb3/arangod.conf"
    echo "=============================================="
}

main "$@"
