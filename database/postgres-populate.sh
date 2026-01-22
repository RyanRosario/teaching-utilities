#!/bin/bash

# Exit on any error
set -e

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." 
   exit 1
fi

INPUT_FILE=$1

# Validations
if [[ -z "$INPUT_FILE" ]]; then
    echo "Usage: $0 <path_to_user_csv>"
    echo "This script populates Postgres users/DBs based on the CSV and enables peer auth."
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' not found."
    exit 1
fi

echo "Starting PostgreSQL population from $INPUT_FILE..."

# 0. Setup Admin Database (Central Registry)
ADMIN_DB="admin"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$ADMIN_DB'" | grep -q 1; then
    sudo -u postgres createdb "$ADMIN_DB"
    echo "Created database '$ADMIN_DB'."
    
    # Revoke public access (restrict to admins/superusers implies regular users can't connect)
    # By default, owner (postgres) and superusers have access.
    # We revoke connect from PUBLIC to ensure only authorized users access it.
    sudo -u postgres psql -d "$ADMIN_DB" -c "REVOKE CONNECT ON DATABASE \"$ADMIN_DB\" FROM PUBLIC;"
    echo "Restricted access to '$ADMIN_DB'."

    # Create 'students' table
    sudo -u postgres psql -d "$ADMIN_DB" -c "
    CREATE TABLE students (
        student_id SERIAL PRIMARY KEY,
        student_name VARCHAR(255) NOT NULL,
        username VARCHAR(100) NOT NULL UNIQUE,
        hashed_university_id VARCHAR(255) NOT NULL UNIQUE,
        email_address VARCHAR(255) NOT NULL UNIQUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );"
    echo "Created 'students' table in '$ADMIN_DB'."
else
    echo "Database '$ADMIN_DB' already exists."
fi

# 1. Provide Postgres Roles and Databases
while IFS=, read -r username name password uid email || [ -n "$username" ]; do
    
    # Sanitize inputs
    username=$(echo "$username" | tr -d '\r' | xargs)
    name=$(echo "$name" | tr -d '\r' | xargs)
    uid=$(echo "$uid" | tr -d '\r' | xargs)
    email=$(echo "$email" | tr -d '\r' | xargs)
    
    # Skip empty/header
    if [[ -z "$username" || "$username" == "username" ]]; then
        continue
    fi

    echo "Processing '$username'..."

    # 1A. Populate Student Registry
    # compute hash of UID (using sha256)
    hashed_uid=$(echo -n "$uid" | sha256sum | awk '{print $1}')
    
    # Insert ignore (ON CONFLICT DO NOTHING) to handle re-runs without error
    sudo -u postgres psql -d "$ADMIN_DB" -c "
    INSERT INTO students (student_name, username, hashed_university_id, email_address)
    VALUES ('$name', '$username', '$hashed_uid', '$email')
    ON CONFLICT (username) DO UPDATE 
    SET student_name = EXCLUDED.student_name, 
        hashed_university_id = EXCLUDED.hashed_university_id,
        email_address = EXCLUDED.email_address;
    " >/dev/null

    # 1B. Create Roles/DBs
    # Check if unix user exists (prerequisite for peer auth if they want to log in)

    if ! id "$username" &>/dev/null; then
        echo "Warning: Unix user '$username' does not exist. Skipping Postgres setup for this user."
        continue
    fi

    echo "Provisioning PostgreSQL for '$username'..."
    
    # Create Postgres User (Superuser)
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
            sudo -u postgres createuser --superuser "$username"
            echo "Created Postgres superuser '$username'."
    else
            echo "Postgres user '$username' already exists."
    fi

    # Create Database
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$username'" | grep -q 1; then
            sudo -u postgres createdb -O "$username" "$username"
            echo "Created database '$username'."
    else
            echo "Database '$username' already exists."
    fi
    
    # Grant privileges explicitly (redundant for owner/superuser but safe)
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$username\" TO \"$username\";" >/dev/null

done < "$INPUT_FILE"

# 2. Configure Peer Authentication in pg_hba.conf
PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n 1)

if [[ -n "$PG_VERSION" ]]; then
    HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    echo "Configuring Peer Authentication in $HBA_FILE..."
    
    # Ensure "local all all peer" is at the top of the file
    if ! grep -q "^local\s*all\s*all\s*peer" "$HBA_FILE"; then
         # Insert at the top to take precedence over default rules
         echo "local   all             all                                     peer" | cat - "$HBA_FILE" | sudo tee "$HBA_FILE.tmp" > /dev/null
         sudo mv "$HBA_FILE.tmp" "$HBA_FILE"
         # Fix permissions and ownership
         sudo chown postgres:postgres "$HBA_FILE"
         sudo chmod 640 "$HBA_FILE"
         
         # Reload configuration
         sudo systemctl reload postgresql
         echo "Peer authentication enabled and PostgreSQL reloaded."
    else
         echo "Peer authentication already configured."
    fi
else
    echo "Error: Could not detect PostgreSQL version. Peer auth config skipped."
fi

echo "PostgreSQL population complete."
