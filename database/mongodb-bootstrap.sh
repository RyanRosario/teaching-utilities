#!/bin/bash

# Percona Server for MongoDB Bootstrap Script
# This script installs and configures Percona Server for MongoDB 8.0 on Ubuntu with:
#   - RBAC (Role-Based Access Control) enabled
#   - X.509 certificate authentication (passwordless, like PostgreSQL peer auth)
#   - Audit logging (Percona's free Enterprise-equivalent feature)
#
# For user provisioning and database permissions, run mongodb-populate.sh separately.

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/mongodb-config.json"

# Default values
MONGO_ADMIN_USER="mongoadmin"
MONGO_ADMIN_PASS=""

# Certificate configuration
CERT_DIR="/etc/mongodb/ssl"
CA_CERT="$CERT_DIR/ca.pem"
CA_KEY="$CERT_DIR/ca-key.pem"
SERVER_CERT="$CERT_DIR/server.pem"
CLIENT_CERT_DIR="/etc/mongodb/client-certs"

# Audit log configuration
AUDIT_LOG_PATH="/var/log/mongodb/audit.json"

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Check if jq is available
        if command -v jq > /dev/null 2>&1; then
            MONGO_ADMIN_USER=$(jq -r '.mongo_admin_user // "mongoadmin"' "$CONFIG_FILE")
            MONGO_ADMIN_PASS=$(jq -r '.mongo_admin_pass // ""' "$CONFIG_FILE")
            echo "Loaded configuration from $CONFIG_FILE"
        else
            echo "Warning: jq not installed. Cannot read config file."
            echo "Install with: sudo apt install jq"
        fi
    else
        echo "Warning: Config file not found: $CONFIG_FILE"
        echo "Using default values. Create mongodb-config.json to configure."
    fi
}

# Load config first (can be overridden by command-line args)
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
        --mongo-admin-pass)
            MONGO_ADMIN_PASS="$2"
            shift 2
            ;;
        --reset-admin-password)
            RESET_ADMIN_PASSWORD=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script installs and configures Percona Server for MongoDB with:"
            echo "  - Percona Server for MongoDB 8.0 (free Enterprise features)"
            echo "  - X.509 certificate authentication (passwordless local access)"
            echo "  - Audit logging to $AUDIT_LOG_PATH"
            echo "  - 100-day log retention"
            echo ""
            echo "Options:"
            echo "  --config <file>              Path to config file (default: mongodb-config.json)"
            echo "  --mongo-admin-pass <pass>    Override MongoDB admin password from config"
            echo "  --reset-admin-password       Reset admin password (disables auth temporarily)"
            echo "  --help, -h                   Show this help message"
            echo ""
            echo "Configuration is read from mongodb-config.json. Command-line args override."
            echo "After running this script, run mongodb-populate.sh to provision users."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

if [[ -z "$MONGO_ADMIN_PASS" ]]; then
    echo "MongoDB admin password not set in config file or command-line args."
    read -s -p "Enter MongoDB admin password: " MONGO_ADMIN_PASS
    echo ""
    if [[ -z "$MONGO_ADMIN_PASS" ]]; then
        echo "Error: Password cannot be empty."
        exit 1
    fi
fi

if [[ "$MONGO_ADMIN_PASS" =~ [^a-zA-Z0-9_.-] ]]; then
    echo "Warning: Admin password contains special characters."
    echo "This is OK (we use CLI flags, not URI), but may cause issues"
    echo "with other tools that embed credentials in MongoDB URIs."
fi

# ==============================================================================
# INSTALLATION (Percona Server for MongoDB)
# ==============================================================================
install_mongodb() {
    echo "Starting Percona Server for MongoDB installation..."

    # 1. Update system and install prerequisites
    echo "Installing prerequisites..."
    sudo apt update || true
    sudo apt install -y gnupg curl openssl wget lsb-release

    # 2. Install Percona Release tool
    echo "Installing Percona release configuration tool..."
    wget -q https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb -O /tmp/percona-release.deb
    sudo dpkg -i /tmp/percona-release.deb
    rm -f /tmp/percona-release.deb

    # 3. Enable Percona Server for MongoDB 8.0 repository
    echo "Enabling Percona Server for MongoDB 8.0 repository..."
    sudo percona-release enable psmdb-80 release

    # 4. Update package cache
    sudo apt update || true

    # 5. Install Percona Server for MongoDB (includes mongosh)
    echo "Installing Percona Server for MongoDB..."
    sudo apt install -y percona-server-mongodb percona-mongodb-mongosh

    # 7. Start and enable MongoDB service (initially without auth for setup)
    echo "Starting MongoDB service..."
    sudo systemctl start mongod
    sudo systemctl enable mongod

    # 8. Verify installation
    echo "Verifying Percona Server for MongoDB installation..."
    if mongod --version > /dev/null 2>&1; then
        MONGO_VERSION=$(mongod --version | head -n 1)
        echo "Percona Server for MongoDB installed: $MONGO_VERSION"
    else
        echo "Error: Could not verify MongoDB installation."
        exit 1
    fi
    
    if mongosh --version > /dev/null 2>&1; then
        MONGOSH_VERSION=$(mongosh --version | head -n 1)
        echo "mongosh client installed: $MONGOSH_VERSION"
    else
        echo "Warning: mongosh client not found."
    fi
}

# ==============================================================================
# X.509 CERTIFICATE GENERATION (Server/CA only)
# ==============================================================================
generate_server_certificates() {
    echo "Generating X.509 certificates for TLS..."
    
    # Create certificate directories
    # CERT_DIR needs 755 so clients can read the CA cert for verification
    # Sensitive files (keys, server cert) are protected individually
    sudo mkdir -p "$CERT_DIR"
    sudo mkdir -p "$CLIENT_CERT_DIR"
    sudo chown mongod:mongod "$CERT_DIR"
    sudo chmod 755 "$CERT_DIR"
    sudo chmod 755 "$CLIENT_CERT_DIR"
    
    # Generate CA certificate (if not exists)
    if [[ ! -f "$CA_CERT" ]]; then
        echo "Generating Certificate Authority (CA)..."
        sudo openssl genrsa -out "$CA_KEY" 4096
        sudo openssl req -new -x509 -days 3650 -key "$CA_KEY" -out "$CA_CERT" \
            -subj "/C=US/ST=California/L=Los Angeles/O=UCLA/OU=MSBA/CN=MongoDB-CA"
        sudo chown mongod:mongod "$CA_KEY" "$CA_CERT"
        sudo chmod 600 "$CA_KEY"
        sudo chmod 644 "$CA_CERT"
    fi
    
    # Generate server certificate (if not exists)
    if [[ ! -f "$SERVER_CERT" ]]; then
        echo "Generating server certificate..."
        HOSTNAME=$(hostname -f)
        sudo openssl genrsa -out "$CERT_DIR/server-key.pem" 4096
        sudo openssl req -new -key "$CERT_DIR/server-key.pem" -out "$CERT_DIR/server.csr" \
            -subj "/C=US/ST=California/L=Los Angeles/O=UCLA/OU=MSBA/CN=$HOSTNAME"
        
        # Create extension file for server
        cat << EOF | sudo tee "$CERT_DIR/server-ext.cnf"
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$HOSTNAME,DNS:localhost,IP:127.0.0.1
EOF
        
        sudo openssl x509 -req -days 3650 -in "$CERT_DIR/server.csr" \
            -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
            -out "$CERT_DIR/server-cert.pem" -extfile "$CERT_DIR/server-ext.cnf"
        
        # Combine key and cert for MongoDB
        sudo cat "$CERT_DIR/server-key.pem" "$CERT_DIR/server-cert.pem" | sudo tee "$SERVER_CERT" > /dev/null
        sudo chmod 600 "$SERVER_CERT"
        sudo chown mongod:mongod "$SERVER_CERT"
        
        # Cleanup
        sudo rm -f "$CERT_DIR/server.csr" "$CERT_DIR/server-ext.cnf"
    fi
    
    echo "Server certificates generated."
}

# ==============================================================================
# SYSTEM-WIDE MONGOSH ALIAS (via /etc/profile.d)
# ==============================================================================
setup_system_mongosh_alias() {
    echo "Setting up system-wide mongosh alias..."
    
    # Create a system-wide profile script that dynamically sets up the alias
    # This runs for every user at login, checking if they have a certificate
    sudo tee /etc/profile.d/mongosh.sh > /dev/null << 'PROFILE_EOF'
#!/bin/bash
# Percona Server for MongoDB - Passwordless Authentication
# This script automatically configures mongosh for users with X.509 certificates

# Certificate paths
_MONGO_CLIENT_CERT_DIR="/etc/mongodb/client-certs"
_MONGO_CA_CERT="/etc/mongodb/ssl/ca.pem"
_MONGO_USER_CERT="$_MONGO_CLIENT_CERT_DIR/$USER/mongodb.pem"
# User's default database (matches PostgreSQL pattern - same as username)
_MONGO_USER_DB="$USER"

# If user has a certificate, set up the alias with their default database
# Use connection URI to specify both default DB and authSource separately
if [[ -f "$_MONGO_USER_CERT" && -f "$_MONGO_CA_CERT" ]]; then
    alias mongosh="mongosh 'mongodb://127.0.0.1:27017/${_MONGO_USER_DB}?authSource=\$external' --tls --tlsCertificateKeyFile ${_MONGO_USER_CERT} --tlsCAFile ${_MONGO_CA_CERT} --authenticationMechanism MONGODB-X509"
fi

# Cleanup variables
unset _MONGO_CLIENT_CERT_DIR _MONGO_CA_CERT _MONGO_USER_CERT _MONGO_USER_DB
PROFILE_EOF
    
    sudo chmod 644 /etc/profile.d/mongosh.sh
    echo "System-wide mongosh alias configured in /etc/profile.d/mongosh.sh"
}

# ==============================================================================
# MONGODB ADMIN SETUP & CONFIGURATION
# ==============================================================================
setup_mongo_admin() {
    echo "Setting up MongoDB admin user..."

    # Build connection args — use TLS if certs exist (re-run), plain if not (fresh install)
    local mongosh_args="--quiet"
    if [[ -f "$CA_CERT" ]]; then
        mongosh_args="$mongosh_args --tls --tlsCAFile $CA_CERT"
    fi

    # Create admin user with password auth
    # NOTE: use db.getSiblingDB(), NOT 'use admin' (which doesn't work in --eval)
    /usr/bin/mongosh $mongosh_args --eval "
        const adminDb = db.getSiblingDB('admin');
        try {
            adminDb.createUser({
                user: '$MONGO_ADMIN_USER',
                pwd: $(printf '%s' "$MONGO_ADMIN_PASS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
                roles: [
                    { role: 'userAdminAnyDatabase', db: 'admin' },
                    { role: 'readWriteAnyDatabase', db: 'admin' },
                    { role: 'dbAdminAnyDatabase', db: 'admin' },
                    { role: 'clusterAdmin', db: 'admin' }
                ]
            });
            print('Admin user created successfully.');
        } catch(e) {
            if (e.codeName === 'DuplicateKey' || e.code === 11000) {
                print('Admin user already exists, continuing...');
            } else {
                print('ERROR creating admin user: ' + e.message);
                throw e;
            }
        }
    "
    
    # Generate server certificates
    generate_server_certificates
    
    # Create audit log directory
    echo "Setting up audit logging..."
    sudo mkdir -p "$(dirname $AUDIT_LOG_PATH)"
    sudo touch "$AUDIT_LOG_PATH"
    sudo chown mongod:mongod "$AUDIT_LOG_PATH"
    
    # Configure MongoDB for TLS, X.509, and Audit Logging
    MONGOD_CONF="/etc/mongod.conf"
    
    echo "Configuring Percona Server for MongoDB..."
    
    # Backup original config
    sudo cp "$MONGOD_CONF" "$MONGOD_CONF.bak"
    
    # Update mongod.conf with full Percona configuration
    sudo tee "$MONGOD_CONF" > /dev/null << EOF
# Percona Server for MongoDB configuration file

storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0
  tls:
    mode: requireTLS
    certificateKeyFile: $SERVER_CERT
    CAFile: $CA_CERT
    allowConnectionsWithoutCertificates: true

security:
  authorization: enabled

# Percona Audit Logging (Enterprise-equivalent feature, free in Percona)
auditLog:
  destination: file
  format: JSON
  path: $AUDIT_LOG_PATH

# Query profiling (additional monitoring)
operationProfiling:
  mode: slowOp
  slowOpThresholdMs: 100

setParameter:
  authenticationMechanisms: MONGODB-X509,SCRAM-SHA-256
EOF
    
    # Restart MongoDB to apply configuration
    echo "Restarting Percona Server for MongoDB with TLS and audit logging..."
    sudo systemctl restart mongod
    sleep 3
    
    # Verify MongoDB is running
    if ! sudo systemctl is-active --quiet mongod; then
        echo "Error: MongoDB failed to start. Check /var/log/mongodb/mongod.log"
        sudo journalctl -u mongod -n 20
        exit 1
    fi
    
    echo "Percona Server for MongoDB configured with TLS, X.509, and audit logging."
    
    # Open firewall if UFW is active
    if command -v ufw > /dev/null; then
        echo "Allowing port 27017 through UFW..."
        sudo ufw allow 27017/tcp
    fi
}

# ==============================================================================
# AUDIT LOG ROTATION SETUP
# ==============================================================================
setup_audit_log_rotation() {
    echo "Setting up audit log rotation..."
    
    sudo tee /etc/logrotate.d/mongodb-audit > /dev/null << EOF
$AUDIT_LOG_PATH {
    daily
    rotate 100
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su mongod mongod
}
EOF
    
    echo "Audit log rotation configured (100 days retention)."
}

# ==============================================================================
# RESET ADMIN PASSWORD (recovers from lost/broken admin auth)
# ==============================================================================
reset_admin_password() {
    echo "Resetting MongoDB admin password..."
    local MONGOD_CONF="/etc/mongod.conf"

    # 1. Temporarily disable authorization
    echo "Temporarily disabling authorization..."
    sudo sed -i 's/authorization: enabled/authorization: disabled/' "$MONGOD_CONF"
    sudo systemctl restart mongod
    sleep 3

    # 2. Create or reset admin user
    local mongosh_args="--quiet"
    if [[ -f "$CA_CERT" ]]; then
        mongosh_args="$mongosh_args --tls --tlsCAFile $CA_CERT"
    fi

    /usr/bin/mongosh $mongosh_args --eval "
        const adminDb = db.getSiblingDB('admin');
        const pwd = $(printf '%s' "$MONGO_ADMIN_PASS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))');
        try {
            adminDb.dropUser('$MONGO_ADMIN_USER');
            print('Dropped existing admin user.');
        } catch(e) {
            print('No existing admin user to drop.');
        }
        adminDb.createUser({
            user: '$MONGO_ADMIN_USER',
            pwd: pwd,
            roles: [
                { role: 'userAdminAnyDatabase', db: 'admin' },
                { role: 'readWriteAnyDatabase', db: 'admin' },
                { role: 'dbAdminAnyDatabase', db: 'admin' },
                { role: 'clusterAdmin', db: 'admin' }
            ]
        });
        print('Admin user created successfully.');
    "

    # 3. Re-enable authorization
    echo "Re-enabling authorization..."
    sudo sed -i 's/authorization: disabled/authorization: enabled/' "$MONGOD_CONF"
    sudo systemctl restart mongod
    sleep 3

    # 4. Verify
    if /usr/bin/mongosh --quiet --host 127.0.0.1 --port 27017 \
        --tls --tlsCAFile "$CA_CERT" \
        --username "$MONGO_ADMIN_USER" \
        --password "$MONGO_ADMIN_PASS" \
        --authenticationDatabase admin \
        --eval "print('Auth OK')" 2>/dev/null | grep -q "Auth OK"; then
        echo "Admin password reset and verified successfully!"
    else
        echo "ERROR: Password reset may have failed. Check mongod logs."
        exit 1
    fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

echo "=============================================="
echo "Percona Server for MongoDB Bootstrap"
echo "=============================================="

if [[ "$RESET_ADMIN_PASSWORD" == true ]]; then
    reset_admin_password
    exit 0
fi

install_mongodb
setup_mongo_admin
setup_audit_log_rotation
setup_system_mongosh_alias

echo ""
echo "=============================================="
echo "Percona Server for MongoDB Installation Complete"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  - Percona Server for MongoDB 8.0"
echo "  - TLS/X.509 authentication enabled"
echo "  - Remote access enabled (listening on all interfaces)"
echo "  - Audit logging: $AUDIT_LOG_PATH"
echo "  - Log retention: 100 days"
echo ""
echo "Admin Access:"
echo "  mongosh --tls --tlsCAFile $CA_CERT \\"
echo "    -u $MONGO_ADMIN_USER -p <password> --authenticationDatabase admin"
echo ""
echo "Next Steps:"
echo "  Run mongodb-populate.sh to provision user accounts and databases."
echo ""
echo "View Audit Log:"
echo "  sudo tail -f $AUDIT_LOG_PATH | jq ."
echo "=============================================="