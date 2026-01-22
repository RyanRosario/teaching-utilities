#!/bin/bash

# Exit on any error
set -e

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." 
   exit 1
fi

# Parse arguments
ADMIN_FILE=""
ROSTER_FILE=""

# Simple argument parsing loop - simplistic guess based on content or order?
# create-users.sh uses order: [ADMIN] [ROSTER]. Let's stick to that convention.
# But since we might run this independently, let's just grab them.
# If $1 is a file, check if it looks like admin or roster?
# Or just assume $1=Admin, $2=Roster as per 'create-users.sh' interface expectation.

for arg in "$@"; do
    if [[ -z "$ADMIN_FILE" && ! "$arg" == --* ]]; then
        ADMIN_FILE="$arg"
    elif [[ -z "$ROSTER_FILE" && ! "$arg" == --* ]]; then
        ROSTER_FILE="$arg"
    fi
done

if [[ -z "$ADMIN_FILE" && -z "$ROSTER_FILE" ]]; then
    echo "Usage: $0 <path_to_admin_csv> [path_to_roster_csv]"
    echo "This script populates Postgres users/DBs based on the CSVs and enables peer auth."
    exit 1
fi
if [[ -n "$ADMIN_FILE" && ! -f "$ADMIN_FILE" ]]; then
     echo "Error: Admin File '$ADMIN_FILE' not found."
     exit 1
fi
if [[ -n "$ROSTER_FILE" && ! -f "$ROSTER_FILE" ]]; then
     echo "Error: Roster File '$ROSTER_FILE' not found."
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
# Function to process Admin Postgres
process_admins_postgres() {
    local input=$1
    echo "Processing Admin Postgres: $input"
    
    while IFS=, read -r username name password uid email || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        # Skip empty/header
        if [[ -z "$username" || "$username" == "username" ]]; then continue; fi

        if ! id "$username" &>/dev/null; then
            echo "Warning: Unix user '$username' does not exist. Skipping Admin Postgres setup."
            continue
        fi

        echo "Provisioning Admin Postgres user '$username'..."
        # Create Superuser
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
                sudo -u postgres createuser --superuser "$username"
                echo "Created Postgres superuser '$username'."
        fi
        # Create Database
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$username'" | grep -q 1; then
                sudo -u postgres createdb -O "$username" "$username"
                echo "Created database '$username'."
        fi
        # Grant All
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$username\" TO \"$username\";" >/dev/null
    done < "$input"
}

# Function to process Student Roster Postgres
process_roster_postgres() {
    local input=$1
    echo "Processing Roster Postgres: $input"
    
    sanitize() {
        echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]//g' | cut -c1-8
    }

    declare -a PROVISIONED_USERS=()
    
    is_available() {
         local u=$1
         # Check if exists on system
         if ! id "$u" &>/dev/null; then return 1; fi # Not a system user
         
         # Check if we already claimed it for a previous student in this run
         for p in "${PROVISIONED_USERS[@]}"; do
             [[ "$p" == "$u" ]] && return 1 # Already claimed
         done
         return 0 # Available/Exists/Unclaimed
    }

    while IFS=, read -r c1 c2 c3 c4 c5 c6 c7 rest || [ -n "$c1" ]; do
        # 1. Skip rows not matching UID pattern
        if ! [[ "$c1" =~ ^[0-9]{3}-[0-9]{3}-[0-9]{3}$ ]]; then continue; fi
        
        # 2. Parse Data
        raw_uid="$c1"
        last_name_raw=$(echo "$c2" | tr -d '"' | xargs)
        first_names_raw=$(echo "$c3" | tr -d '"' | xargs)
        name="$first_names_raw $last_name_raw"
        email=$(echo "$c4" | xargs)

        # Override Check
        override=""
        possible_c7=$(echo "$c7" | tr -d '\r' | xargs)
        possible_c6=$(echo "$c6" | tr -d '\r' | xargs)
        if [[ -n "$possible_c7" ]] && [[ "$possible_c7" =~ ^[a-z0-9_]+$ ]]; then
             override="$possible_c7"
        elif [[ -n "$possible_c6" ]] && [[ "$possible_c6" =~ ^[a-z0-9_]+$ ]]; then
             override="$possible_c6"
        fi

        target_username=""
        
        # 1. Try Override
        if [[ -n "$override" ]]; then
             if is_available "$override"; then
                  target_username="$override"
             fi
        fi

        # 2. Try Standard Generation candidates if no override matched yet
        if [[ -z "$target_username" ]]; then
             f=$(sanitize "$first_names_raw")
             l=$(sanitize "$last_name_raw")
             
             # Candidate 1: FirstInit + Last
             c1="${f:0:1}${l}"; c1=${c1:0:8}
             if is_available "$c1"; then target_username="$c1"; fi
             
             # Candidate 2: Firstname (Fallback 1)
             if [[ -z "$target_username" ]] && is_available "$f"; then target_username="$f"; fi
             
             # Candidate 3: Lastname (Fallback 2)
             if [[ -z "$target_username" ]] && is_available "$l"; then target_username="$l"; fi
        fi

        if [[ -z "$target_username" ]]; then
             echo "Warning: No matching/available system user found for '$name' (Candidates explored). Skipping Postgres."
             continue
        fi

        username="$target_username"
        PROVISIONED_USERS+=("$username")
        
        echo "Provisioning Postgres for '$username' ($name)..."
        
        # A. Create Role (Login)
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
               sudo -u postgres psql -c "CREATE ROLE \"$username\" WITH LOGIN;" >/dev/null
               echo "Created Postgres role '$username'."
        fi

        # B. Create Schema
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
               sudo -u postgres psql -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
               # Secure it:
               sudo -u postgres psql -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
               echo "Created Postgres schema '$username'."
        fi

        # C. Insert into admin.students
        hashed_uid=$(echo -n "$raw_uid" | sha256sum | awk '{print $1}')
        
        sudo -u postgres psql -d "$ADMIN_DB" -c "
        INSERT INTO students (student_name, username, hashed_university_id, email_address)
        VALUES ('$name', '$username', '$hashed_uid', '$email')
        ON CONFLICT (username) DO UPDATE 
        SET student_name = EXCLUDED.student_name, 
            hashed_university_id = EXCLUDED.hashed_university_id,
            email_address = EXCLUDED.email_address;
        " >/dev/null

    done < "$input"
}

# Main Execution
if [[ -n "$ADMIN_FILE" ]]; then
    process_admins_postgres "$ADMIN_FILE"
fi
if [[ -n "$ROSTER_FILE" ]]; then
    process_roster_postgres "$ROSTER_FILE"
fi

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
