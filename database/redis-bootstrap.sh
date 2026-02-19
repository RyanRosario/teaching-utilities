#!/bin/bash
# ==============================================================================
# Redis - Bootstrap Script
# ==============================================================================
# This script installs and configures Redis from the official redis.io
# repository on Ubuntu/Debian.
#
# Features:
#   - Installs latest Redis from official packages.redis.io repository
#   - Configures password authentication
#   - Binds to localhost only (secure default)
#   - Enables persistence (RDB snapshots + AOF)
#   - Sets memory limit appropriate for teaching environment
#
# Usage:
#   sudo ./redis-bootstrap.sh
#
# After installation:
#   - CLI: redis-cli
#   - Default port: 6379
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/redis-config.json"

REDIS_PORT=6379
REDIS_PASSWORD=""
REDIS_MAXMEMORY="256mb"
REDIS_BIND="127.0.0.1 ::1"

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq > /dev/null 2>&1; then
            REDIS_PASSWORD=$(jq -r '.redis_password // ""' "$CONFIG_FILE")
            REDIS_MAXMEMORY=$(jq -r '.redis_maxmemory // "256mb"' "$CONFIG_FILE")
            REDIS_BIND=$(jq -r '.redis_bind // "127.0.0.1 ::1"' "$CONFIG_FILE")
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
        --redis-password)
            REDIS_PASSWORD="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script installs and configures Redis with:"
            echo "  - Latest Redis from official repository"
            echo "  - Optional password authentication"
            echo "  - RDB + AOF persistence"
            echo "  - Memory limit for teaching environment"
            echo ""
            echo "Options:"
            echo "  --config <file>           Path to config file (default: redis-config.json)"
            echo "  --redis-password <pass>   Override Redis password from config"
            echo "  --help, -h                Show this help message"
            echo ""
            echo "Configuration is read from redis-config.json. Command-line args override."
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

echo "=============================================="
echo "Redis - Bootstrap"
echo "=============================================="
echo ""

# ==============================================================================
# INSTALL REDIS
# ==============================================================================
install_redis() {
    echo "Installing Redis from official repository..."

    # 1. Install prerequisites
    apt-get update || true
    apt-get install -y lsb-release curl gpg

    # 2. Add Redis GPG key
    echo "Adding Redis GPG key..."
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg

    # 3. Add Redis repository
    echo "Adding Redis repository..."
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/redis.list

    # 4. Install Redis
    apt-get update || true
    apt-get install -y redis

    echo "Redis installed successfully."
}

# ==============================================================================
# CONFIGURE REDIS
# ==============================================================================
configure_redis() {
    echo "Configuring Redis..."

    local config_file="/etc/redis/redis.conf"

    # Backup original config
    if [[ ! -f "${config_file}.bak" ]]; then
        cp "$config_file" "${config_file}.bak"
    fi

    # --- Bind address ---
    sed -i "s/^bind .*/bind $REDIS_BIND/" "$config_file"

    # --- Password authentication ---
    if [[ -n "$REDIS_PASSWORD" ]]; then
        # Remove any existing requirepass lines
        sed -i '/^# *requirepass/d; /^requirepass/d' "$config_file"
        echo "requirepass $REDIS_PASSWORD" >> "$config_file"
        echo "Password authentication enabled."
    else
        echo "No password set. Redis will accept unauthenticated connections on localhost."
    fi

    # --- Memory limit ---
    sed -i '/^# *maxmemory /d; /^maxmemory /d' "$config_file"
    echo "maxmemory $REDIS_MAXMEMORY" >> "$config_file"

    # --- Eviction policy ---
    sed -i '/^# *maxmemory-policy/d; /^maxmemory-policy/d' "$config_file"
    echo "maxmemory-policy allkeys-lru" >> "$config_file"

    # --- Persistence: RDB snapshots (default) + AOF ---
    sed -i 's/^appendonly no/appendonly yes/' "$config_file"
    if ! grep -q "^appendonly yes" "$config_file"; then
        echo "appendonly yes" >> "$config_file"
    fi

    echo "Redis configuration updated."
}

# ==============================================================================
# START REDIS SERVICE
# ==============================================================================
start_redis() {
    echo "Starting Redis service..."

    systemctl enable redis-server
    systemctl restart redis-server

    # Wait for Redis to start
    echo "Waiting for Redis to start..."
    local max_attempts=15
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if redis-cli -p $REDIS_PORT ping 2>/dev/null | grep -q "PONG"; then
            echo "Redis is running!"
            return
        fi
        # Try with password if set
        if [[ -n "$REDIS_PASSWORD" ]]; then
            if redis-cli -p $REDIS_PORT -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null | grep -q "PONG"; then
                echo "Redis is running! (authenticated)"
                return
            fi
        fi
        sleep 1
        ((attempt++))
        echo "  Waiting... ($attempt/$max_attempts)"
    done

    echo "Warning: Redis may not have started. Check: systemctl status redis-server"
}

# ==============================================================================
# CONFIGURE FIREWALL
# ==============================================================================
configure_firewall() {
    if command -v ufw > /dev/null 2>&1; then
        # Only open firewall if binding to non-localhost
        if [[ "$REDIS_BIND" != "127.0.0.1"* ]]; then
            echo "Allowing port $REDIS_PORT through UFW..."
            ufw allow $REDIS_PORT/tcp comment "Redis"
        else
            echo "Redis bound to localhost only — no firewall changes needed."
        fi
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    install_redis
    echo ""

    configure_redis
    echo ""

    configure_firewall
    echo ""

    start_redis
    echo ""

    # Print Redis version
    REDIS_VERSION=$(redis-server --version 2>/dev/null | awk '{print $3}' | cut -d= -f2)

    echo "=============================================="
    echo "Redis Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  - Redis $REDIS_VERSION"
    echo "  - Port: $REDIS_PORT"
    echo "  - Bind: $REDIS_BIND"
    echo "  - Max Memory: $REDIS_MAXMEMORY"
    echo "  - Persistence: RDB + AOF"
    if [[ -n "$REDIS_PASSWORD" ]]; then
        echo "  - Authentication: password enabled"
    else
        echo "  - Authentication: none (localhost only)"
    fi
    echo ""
    echo "Commands:"
    echo "  CLI:      redis-cli"
    echo "  Status:   sudo systemctl status redis-server"
    echo "  Stop:     sudo systemctl stop redis-server"
    echo "  Start:    sudo systemctl start redis-server"
    echo "  Logs:     sudo journalctl -u redis-server -f"
    echo ""
    echo "Next Steps:"
    echo "  Run redis-populate.sh to provision user accounts."
    echo "=============================================="
}

main "$@"
