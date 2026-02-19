#!/bin/bash

# PostgreSQL Bootstrap Script
# This script installs and configures PostgreSQL with pgaudit, remote access, and log retention.
# For password reset app components (Node.js, Nginx, Certbot), run password-reset.sh separately.

set -e

# Parse arguments
PURGE_DATA=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data)
            PURGE_DATA=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script installs and configures PostgreSQL with:"
            echo "  - Latest PostgreSQL from PGDG repository"
            echo "  - pgaudit extension for audit logging"
            echo "  - Remote access configuration"
            echo "  - 100-day log retention"
            echo ""
            echo "Options:"
            echo "  --purge-data     Remove all PostgreSQL data directories during reinstall"
            echo "  --help, -h       Show this help message"
            echo ""
            echo "For password reset app (Node.js, Nginx, Certbot), run password-reset.sh separately."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

echo "Starting PostgreSQL installation and configuration..."

# 0. Clean Reinstall Logic
if dpkg -l | grep -qw postgresql; then
    echo "Existing PostgreSQL installation detected. Removing..."

    # Preconfigure debconf to avoid interactive prompt "Remove PostgreSQL directories when package is purged?"
    if [ "$PURGE_DATA" = true ]; then
        echo "postgresql-common postgresql-common/obsolete-major boolean true" | sudo debconf-set-selections
    else
        echo "postgresql-common postgresql-common/obsolete-major boolean false" | sudo debconf-set-selections
    fi

    sudo systemctl stop postgresql || true
    
    # Run purge non-interactively
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y postgresql*
    sudo apt-get autoremove -y

    # Only manually remove data directories if explicitly requested
    if [ "$PURGE_DATA" = true ]; then
        echo "Purging data directories as requested..."
        sudo rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql
    else
        echo "Preserving /var/lib/postgresql and config directories (pass --purge-data to remove)."
    fi

    echo "PostgreSQL removed (reinstalling fresh)..."
fi

# 1. Update system and add PostgreSQL Global Development Group (PGDG) repository
# This ensures we get the true "LATEST" version, not just what's in the Ubuntu repo.

# Clean up any existing PGDG repository configurations to prevent Signed-By conflicts
echo "Cleaning up any existing PGDG repository configurations..."
sudo rm -f /etc/apt/sources.list.d/pgdg.list
sudo rm -f /etc/apt/sources.list.d/apt.postgresql.org.sources
sudo rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
sudo rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
# Clean up any .old files that cause warnings
sudo find /etc/apt/sources.list.d/ -name "*.old*" -delete 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y postgresql-common gnupg curl ca-certificates

# Add PGDG repository with properly formatted GPG key
echo "Adding PostgreSQL PGDG repository..."
sudo install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor --yes -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

# 2. Install Latest PostgreSQL
sudo apt-get update
# 'postgresql' metapackage always points to the latest supported version in the repo
sudo apt-get install -y postgresql postgresql-contrib git finger
sudo apt-get install -y libpq-dev

# 3. Dynamic Version Detection
# We need to know the version to find the config files and install the right pgaudit plugin
PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n 1)
echo "Detected Latest PostgreSQL Version: $PG_VERSION"

# 4. Install pgaudit extension
# Package format is typically postgresql-XX-pgaudit
sudo apt-get install -y "postgresql-$PG_VERSION-pgaudit"

# 5. Configure PostgreSQL (postgresql.conf)
CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

echo "Configuring $CONF_FILE..."

# Enable pgaudit in shared_preload_libraries
# We use sed to look for the default commented out line or an existing line.
# If it's a fresh install, it usually looks like: #shared_preload_libraries = ''
if grep -q "^shared_preload_libraries" "$CONF_FILE"; then
    # Helper: If it's already set, we append pgaudit (simplistic approach, assumes valid config)
    # Ideally, you'd check if pgaudit is already there.
    if ! grep -q "pgaudit" "$CONF_FILE"; then
         sudo sed -i "s/^shared_preload_libraries = '/shared_preload_libraries = 'pgaudit, /" "$CONF_FILE"
    fi
else
    # If it is commented out or missing (commented out usually has #)
    # We uncomment if present, or append if not.
    if grep -q "#shared_preload_libraries" "$CONF_FILE"; then
         sudo sed -i "s/#shared_preload_libraries = ''/shared_preload_libraries = 'pgaudit'/" "$CONF_FILE"
    else
         echo "shared_preload_libraries = 'pgaudit'" | sudo tee -a "$CONF_FILE"
    fi
fi

# Configure pgaudit settings
# Appending to the end of the file is safe because usually last config wins or it merges
cat <<EOF | sudo tee -a "$CONF_FILE"

# --- Automatic pgaudit configuration ---
pgaudit.log = 'all' 
pgaudit.log_catalog = on
pgaudit.log_level = log
# ---------------------------------------
EOF

# Enable listening on all interfaces (Internet Access Step 1)
# Default is usually 'localhost'. Change to '*'
if grep -q "#listen_addresses = 'localhost'" "$CONF_FILE"; then
    sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$CONF_FILE"
elif grep -q "listen_addresses = 'localhost'" "$CONF_FILE"; then
    sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" "$CONF_FILE"
else
    echo "listen_addresses = '*'" | sudo tee -a "$CONF_FILE"
fi

# 6. Configure Client Authentication (pg_hba.conf)
# - Local connections use peer auth (no password, OS login is trusted)
# - Remote connections use PAM auth (validates against Unix/system password)
echo "Configuring $HBA_FILE..."
# Allow access from anywhere using PAM authentication (uses Unix password)
echo "host    all             all             0.0.0.0/0               pam" | sudo tee -a "$HBA_FILE"

# 6.5 Configure PAM service for PostgreSQL
# This is required for PAM authentication to work with remote connections
echo "Configuring PAM service for PostgreSQL..."
cat <<EOF | sudo tee /etc/pam.d/postgresql
# PAM configuration for PostgreSQL
# Allows PostgreSQL to authenticate users against Unix passwords
@include common-auth
@include common-account
EOF
echo "PAM service configured for PostgreSQL."

# Add postgres user to shadow group so it can read /etc/shadow for PAM auth
if ! groups postgres | grep -q '\bshadow\b'; then
    sudo usermod -aG shadow postgres
    echo "Added postgres user to shadow group for PAM authentication."
else
    echo "Postgres user already in shadow group."
fi

# 7. Open Firewall (Optional but recommended if UFW is active)
if command -v ufw > /dev/null; then
    echo "Allowing port 5432 through UFW..."
    sudo ufw allow 5432/tcp
fi

# 8. Restart PostgreSQL to apply changes
sudo systemctl restart postgresql

# 9. Configure Log Retention (100 Days)
echo "Configuring log retention for 100 days..."

# 9.1 Configure journald for persistent storage and 100-day retention
sudo mkdir -p /var/log/journal
sudo mkdir -p /etc/systemd/journald.conf.d
cat <<EOF | sudo tee /etc/systemd/journald.conf.d/retention.conf
[Journal]
Storage=persistent
MaxRetentionSec=100d
MaxFileSec=1d
EOF
sudo systemctl restart systemd-journald
echo "Journald configured for 100-day retention."

# 9.2 Configure rsyslog logrotate (auth.log, syslog)
cat <<EOF | sudo tee /etc/logrotate.d/rsyslog-100days
/var/log/syslog
/var/log/auth.log
{
    rotate 100
    daily
    missingok
    notifempty
    delaycompress
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF
echo "Rsyslog (auth.log, syslog) configured for 100-day retention."

# 9.3 Configure PostgreSQL logging
sudo -u postgres psql -c "ALTER SYSTEM SET logging_collector = 'on';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_directory = 'log';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_filename = 'postgresql-%Y-%m-%d.log';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_rotation_age = '1d';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_rotation_size = '0';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_statement = 'all';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_connections = 'on';"
sudo -u postgres psql -c "ALTER SYSTEM SET log_disconnections = 'on';"

# Create PostgreSQL log directory
sudo mkdir -p /var/lib/postgresql/$PG_VERSION/main/log
sudo chown postgres:postgres /var/lib/postgresql/$PG_VERSION/main/log

# PostgreSQL logrotate
cat <<EOF | sudo tee /etc/logrotate.d/postgresql
/var/lib/postgresql/*/main/log/*.log {
    daily
    rotate 100
    missingok
    notifempty
    compress
    delaycompress
    su postgres postgres
}
EOF
echo "PostgreSQL logs configured for 100-day retention."

# Restart PostgreSQL to apply logging changes
sudo systemctl restart postgresql

echo "-----------------------------------------------------"
echo "PostgreSQL $PG_VERSION Installation & Configuration Complete"
echo ""
echo "Installed and configured:"
echo "  - PostgreSQL $PG_VERSION (listening on all interfaces)"
echo "  - pgaudit extension (audit logging enabled)"
echo "  - Remote access via PAM (Unix password authentication)"
echo "  - 100-day log retention"
echo ""
echo "For password reset app (Node.js, Nginx, Certbot), run:"
echo "  ./password-reset.sh"
echo "-----------------------------------------------------"
