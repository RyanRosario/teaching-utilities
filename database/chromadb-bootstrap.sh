#!/bin/bash
# ==============================================================================
# ChromaDB - Bootstrap Script
# ==============================================================================
# This script installs and configures ChromaDB as a system service.
#
# Features:
#   - Installs ChromaDB (pre-1.0 with native token authentication)
#   - Runs as a systemd service under a dedicated 'chroma' user
#   - Persistent data storage at /var/lib/chromadb
#   - Token-based authentication for all API access
#   - Binds to 0.0.0.0 for remote access (web UI at port 8000)
#
# Usage:
#   sudo ./chromadb-bootstrap.sh
#
# After installation:
#   - API:   http://<server-ip>:8000
#   - Docs:  http://<server-ip>:8000/docs
#   - Shell: python3 -c "import chromadb; ..."
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/chromadb-config.json"

CHROMA_VERSION="0.6.3"        # Pre-1.0 for native token auth support
CHROMA_PORT=8000
CHROMA_HOST="0.0.0.0"
CHROMA_DATA_DIR="/var/lib/chromadb"
CHROMA_SERVER_TOKEN=""         # Will be generated if empty

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq > /dev/null 2>&1; then
            CHROMA_SERVER_TOKEN=$(jq -r '.chroma_server_token // ""' "$CONFIG_FILE")
            CHROMA_HOST=$(jq -r '.chroma_host // "0.0.0.0"' "$CONFIG_FILE")
            CHROMA_PORT=$(jq -r '.chroma_port // 8000' "$CONFIG_FILE")
            CHROMA_VERSION=$(jq -r '.chroma_version // "0.6.3"' "$CONFIG_FILE")
            echo "Loaded configuration from $CONFIG_FILE"
        else
            echo "Warning: jq not installed. Cannot read config file."
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
        --token)
            CHROMA_SERVER_TOKEN="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script installs and configures ChromaDB with:"
            echo "  - ChromaDB ${CHROMA_VERSION} with native token authentication"
            echo "  - Persistent storage at ${CHROMA_DATA_DIR}"
            echo "  - Systemd service for automatic startup"
            echo ""
            echo "Options:"
            echo "  --config <file>     Path to config file (default: chromadb-config.json)"
            echo "  --token <token>     Override server authentication token"
            echo "  --help, -h          Show this help message"
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

# Generate server token if not set
if [[ -z "$CHROMA_SERVER_TOKEN" ]]; then
    CHROMA_SERVER_TOKEN=$(openssl rand -hex 32)
    echo "Generated server authentication token."
fi

echo "=============================================="
echo "ChromaDB - Bootstrap"
echo "=============================================="
echo ""

# ==============================================================================
# INSTALL DEPENDENCIES
# ==============================================================================
install_dependencies() {
    echo "Installing system dependencies..."

    apt-get update -qq || true
    apt-get install -y python3 python3-pip python3-venv jq curl

    echo "System dependencies installed."
}

# ==============================================================================
# CREATE CHROMA USER AND DIRECTORIES
# ==============================================================================
setup_chroma_user() {
    echo "Setting up chroma system user..."

    # Create dedicated system user
    if ! id "chroma" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin chroma
        echo "Created system user: chroma"
    else
        echo "System user 'chroma' already exists."
    fi

    # Create data directory
    mkdir -p "$CHROMA_DATA_DIR"
    chown chroma:chroma "$CHROMA_DATA_DIR"
    chmod 750 "$CHROMA_DATA_DIR"

    # Create log directory
    mkdir -p /var/log/chromadb
    chown chroma:chroma /var/log/chromadb

    echo "Directories configured."
}

# ==============================================================================
# INSTALL CHROMADB IN VIRTUALENV
# ==============================================================================
install_chromadb() {
    echo "Installing ChromaDB ${CHROMA_VERSION} in /opt/chromadb..."

    # Create virtualenv
    mkdir -p /opt/chromadb
    python3 -m venv /opt/chromadb/venv

    # Install ChromaDB
    /opt/chromadb/venv/bin/pip install --upgrade pip
    /opt/chromadb/venv/bin/pip install "chromadb==${CHROMA_VERSION}"

    chown -R chroma:chroma /opt/chromadb

    echo "ChromaDB installed: $(/opt/chromadb/venv/bin/pip show chromadb | grep Version)"
}

# ==============================================================================
# CONFIGURE SYSTEMD SERVICE
# ==============================================================================
configure_systemd() {
    echo "Configuring ChromaDB systemd service..."

    cat > /etc/systemd/system/chromadb.service <<EOF
[Unit]
Description=ChromaDB Vector Database
After=network.target
Wants=network-online.target

[Service]
Type=exec
User=chroma
Group=chroma
WorkingDirectory=${CHROMA_DATA_DIR}

# Token authentication
Environment="CHROMA_SERVER_AUTHN_CREDENTIALS=${CHROMA_SERVER_TOKEN}"
Environment="CHROMA_SERVER_AUTHN_PROVIDER=chromadb.auth.token_authn.TokenAuthenticationServerProvider"
Environment="CHROMA_AUTH_TOKEN_TRANSPORT_HEADER=Authorization"
Environment="ANONYMIZED_TELEMETRY=FALSE"
Environment="IS_PERSISTENT=TRUE"
Environment="PERSIST_DIRECTORY=${CHROMA_DATA_DIR}"

ExecStart=/opt/chromadb/venv/bin/chroma run \
    --host ${CHROMA_HOST} \
    --port ${CHROMA_PORT} \
    --path ${CHROMA_DATA_DIR}

Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${CHROMA_DATA_DIR} /var/log/chromadb
ProtectHome=yes

StandardOutput=journal
StandardError=journal
SyslogIdentifier=chromadb

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo "Systemd service configured."
}

# ==============================================================================
# STORE SERVER TOKEN
# ==============================================================================
store_server_token() {
    echo "Storing server token..."

    # Store token in a secure root-only file for the populate script
    echo "$CHROMA_SERVER_TOKEN" > /etc/chromadb-server-token
    chmod 600 /etc/chromadb-server-token

    # Also store in config for reference
    mkdir -p /etc/chromadb
    cat > /etc/chromadb/server.json <<EOF
{
    "host": "${CHROMA_HOST}",
    "port": ${CHROMA_PORT},
    "data_dir": "${CHROMA_DATA_DIR}",
    "version": "${CHROMA_VERSION}"
}
EOF
    chmod 644 /etc/chromadb/server.json

    echo "Server token stored at /etc/chromadb-server-token"
}

# ==============================================================================
# INSTALL CLIENT SYSTEM-WIDE
# ==============================================================================
install_client() {
    echo "Installing chromadb-client system-wide for students..."

    # Install the lightweight client package system-wide
    pip3 install --break-system-packages "chromadb-client>=${CHROMA_VERSION}" 2>/dev/null || \
    pip3 install "chromadb-client>=${CHROMA_VERSION}" 2>/dev/null || \
    echo "Warning: Could not install chromadb-client system-wide. Students may need to install it themselves."

    echo "Client library installed."
}

# ==============================================================================
# START SERVICE
# ==============================================================================
start_chromadb() {
    echo "Starting ChromaDB service..."

    systemctl enable chromadb
    systemctl restart chromadb

    # Wait for ChromaDB to start
    echo "Waiting for ChromaDB to start..."
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf "http://127.0.0.1:${CHROMA_PORT}/api/v1/heartbeat" \
            -H "Authorization: Bearer ${CHROMA_SERVER_TOKEN}" > /dev/null 2>&1; then
            echo "ChromaDB is running!"
            return
        fi
        # Also try without /api/v1 prefix (version-dependent)
        if curl -sf "http://127.0.0.1:${CHROMA_PORT}/api/v2/heartbeat" \
            -H "Authorization: Bearer ${CHROMA_SERVER_TOKEN}" > /dev/null 2>&1; then
            echo "ChromaDB is running!"
            return
        fi
        sleep 2
        ((attempt++))
        echo "  Waiting... ($attempt/$max_attempts)"
    done

    echo "Warning: ChromaDB may not have started. Check: journalctl -u chromadb -f"
}

# ==============================================================================
# CONFIGURE FIREWALL
# ==============================================================================
configure_firewall() {
    if command -v ufw > /dev/null 2>&1; then
        if [[ "$CHROMA_HOST" == "0.0.0.0" ]]; then
            echo "Allowing port $CHROMA_PORT through UFW..."
            ufw allow $CHROMA_PORT/tcp comment "ChromaDB API"
        fi
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    install_dependencies
    echo ""

    setup_chroma_user
    echo ""

    install_chromadb
    echo ""

    configure_systemd
    echo ""

    store_server_token
    echo ""

    install_client
    echo ""

    configure_firewall
    echo ""

    start_chromadb
    echo ""

    echo "=============================================="
    echo "ChromaDB Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  - Version: ChromaDB ${CHROMA_VERSION}"
    echo "  - Port: $CHROMA_PORT"
    echo "  - Bind: $CHROMA_HOST"
    echo "  - Data: $CHROMA_DATA_DIR"
    echo "  - Auth: Token-based (Bearer token)"
    echo ""
    echo "Access:"
    echo "  API:   http://<server-ip>:$CHROMA_PORT"
    echo "  Docs:  http://<server-ip>:$CHROMA_PORT/docs"
    echo ""
    echo "Commands:"
    echo "  Status:  sudo systemctl status chromadb"
    echo "  Stop:    sudo systemctl stop chromadb"
    echo "  Start:   sudo systemctl start chromadb"
    echo "  Logs:    sudo journalctl -u chromadb -f"
    echo ""
    echo "Server token stored at: /etc/chromadb-server-token"
    echo "=============================================="
}

main "$@"
