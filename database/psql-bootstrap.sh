#!/bin/bash

# Exit on any error
set -e

# Parse arguments
PURGE_DATA=false
if [[ "$1" == "--purge-data" ]]; then
    PURGE_DATA=true
fi

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
sudo apt-get update
sudo apt-get install -y postgresql-common
# This script is provided by postgresql-common to easily add the repo
if [ -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh ]; then
    sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
else
    # Fallback manual method if the helper script isn't there (older ubuntu)
    sudo apt-get install -y curl ca-certificates
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
fi

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

# 6. Configure Client Authentication (pg_hba.conf) (Internet Access Step 2)
echo "Configuring $HBA_FILE..."
# Allow access from anywhere (0.0.0.0/0) using SCRAM-SHA-256 (modern default)
# We insert this line before other host rules to ensure it's evaluated, or at the end.
# Postgres reads top-down. The default usually handles local/host. We append to end for generic remote access.
echo "host    all             all             0.0.0.0/0               scram-sha-256" | sudo tee -a "$HBA_FILE"

# 7. Open Firewall (Optional but recommended if UFW is active)
if command -v ufw > /dev/null; then
    echo "Allowing port 5432 through UFW..."
    sudo ufw allow 5432/tcp
fi

# 8. Restart PostgreSQL to apply changes
sudo systemctl restart postgresql

# 9. Install Google Cloud Ops Agent (for GCE Logging)
echo "Installing Google Cloud Ops Agent..."
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install


echo "-----------------------------------------------------"
echo "PostgreSQL $PG_VERSION Installation & Configuration Complete"
echo "pgaudit is installed and enabled."
echo "Google Cloud Ops Agent is installed."
echo "Server is listening on *"
echo "-----------------------------------------------------"
