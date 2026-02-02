#!/bin/bash

# Exit on any error
set -e

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." 
   exit 1
fi

# Parse arguments
#
# Input File Types:
#   ADMIN_FILE      - Full CSV with columns: username,name,password,uid,email
#   ROSTER_FILE     - Student roster CSV (UCLA format with UID, name, email, etc.)
#   ADMIN_USERS_FILE   - Simple text file with one admin username per line
#   STUDENT_USERS_FILE - Simple text file with one student username per line
#
ADMIN_FILE=""
ROSTER_FILE=""
ADMIN_USERS_FILE=""
STUDENT_USERS_FILE=""

for arg in "$@"; do
    if [[ "$arg" == "--add-admin" ]]; then
        MODE="interactive_admin"
        NEXT_IS_INTERACTIVE_USER=true
    elif [[ "$arg" == "--add-student" ]]; then
        MODE="interactive_student"
        NEXT_IS_INTERACTIVE_USER=true
    elif [[ "$arg" == "--admin" ]]; then
        NEXT_IS_ADMIN=true
    elif [[ "$arg" == "--roster" ]]; then
        NEXT_IS_ROSTER=true
    elif [[ "$arg" == "--admin-users" ]]; then
        NEXT_IS_ADMIN_USERS=true
    elif [[ "$arg" == "--student-users" ]]; then
        NEXT_IS_STUDENT_USERS=true
    elif [[ "$arg" == "--name" ]]; then
        NEXT_IS_NAME=true
    elif [[ "$arg" == "--uid" ]]; then
        NEXT_IS_UID=true
    elif [[ "$arg" == "--email" ]]; then
        NEXT_IS_EMAIL=true
    elif [[ "$NEXT_IS_INTERACTIVE_USER" == true ]]; then
        INTERACTIVE_USERNAME="$arg"
        NEXT_IS_INTERACTIVE_USER=false
    elif [[ "$NEXT_IS_NAME" == true ]]; then
        INTERACTIVE_NAME="$arg"
        NEXT_IS_NAME=false
    elif [[ "$NEXT_IS_UID" == true ]]; then
        INTERACTIVE_UID="$arg"
        NEXT_IS_UID=false
    elif [[ "$NEXT_IS_EMAIL" == true ]]; then
        INTERACTIVE_EMAIL="$arg"
        NEXT_IS_EMAIL=false
    elif [[ "$NEXT_IS_ADMIN" == true ]]; then
        ADMIN_FILE="$arg"
        NEXT_IS_ADMIN=false
    elif [[ "$NEXT_IS_ROSTER" == true ]]; then
        ROSTER_FILE="$arg"
        NEXT_IS_ROSTER=false
    elif [[ "$NEXT_IS_ADMIN_USERS" == true ]]; then
        ADMIN_USERS_FILE="$arg"
        NEXT_IS_ADMIN_USERS=false
    elif [[ "$NEXT_IS_STUDENT_USERS" == true ]]; then
        STUDENT_USERS_FILE="$arg"
        NEXT_IS_STUDENT_USERS=false
    elif [[ -z "$MODE" && -z "$ADMIN_FILE" && ! "$arg" == --* ]]; then
        ADMIN_FILE="$arg"
    elif [[ -z "$MODE" && -z "$ROSTER_FILE" && ! "$arg" == --* ]]; then
        ROSTER_FILE="$arg"
    fi
done

# Auto-detect file types based on content (Heuristic)
guess_file_type() {
    local f=$1
    if [[ ! -f "$f" ]]; then echo "unknown"; return; fi
    local h=$(head -n 1 "$f")
    if [[ "$h" =~ ^Term: ]] || [[ "$h" =~ ^UID, ]]; then
        echo "roster"
    elif [[ "$h" =~ ^username, ]]; then
        echo "admin"
    else
        echo "unknown"
    fi
}

if [[ -n "$ADMIN_FILE" && -z "$ROSTER_FILE" ]]; then
    type=$(guess_file_type "$ADMIN_FILE")
    if [[ "$type" == "roster" ]]; then
        echo "Note: Detected student roster in first argument. Proceeding in Roster mode."
        ROSTER_FILE="$ADMIN_FILE"
        ADMIN_FILE=""
    fi
elif [[ -n "$ADMIN_FILE" && -n "$ROSTER_FILE" ]]; then
    t1=$(guess_file_type "$ADMIN_FILE")
    t2=$(guess_file_type "$ROSTER_FILE")
    if [[ "$t1" == "roster" && "$t2" == "admin" ]]; then
         echo "Note: Detected swapped Admin/Roster files. Auto-correcting."
         tmp="$ADMIN_FILE"
         ADMIN_FILE="$ROSTER_FILE"
         ROSTER_FILE="$tmp"
    fi
fi

if [[ -z "$ADMIN_FILE" && -z "$ROSTER_FILE" && -z "$ADMIN_USERS_FILE" && -z "$STUDENT_USERS_FILE" && -z "$MODE" ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "CSV Input (full data):"
    echo "  --admin <file>         Admin CSV (username,name,password,uid,email)"
    echo "  --roster <file>        Roster CSV (student roster format)"
    echo ""
    echo "Simple Username Lists (one username per line):"
    echo "  --admin-users <file>   File with admin usernames (one per line)"
    echo "  --student-users <file> File with student usernames (one per line)"
    echo ""
    echo "Interactive:"
    echo "  --add-admin            Add single admin interactively"
    echo "  --add-student          Add single student interactively"
    exit 1
fi

echo "Starting PostgreSQL population..."

# Define database names
ADMIN_DB="admin"
CS143_DB="cs143"

# ==============================================================================
# 0. AUTHENTICATION CONFIGURATION (Consolidated)
# ==============================================================================
# Ensure Peer Authentication is configured BEFORE any psql commands run.
PG_VERSION=$(ls /etc/postgresql/ 2>/dev/null | sort -V | tail -n 1)
if [[ -n "$PG_VERSION" ]]; then
    HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    if [[ -f "$HBA_FILE" ]]; then
        NEEDS_RELOAD=false
        
        # 1. Force 'postgres' user to use peer (often defaults to md5/scram)
        if grep -qE "^local\s+all\s+postgres\s+(md5|scram-sha-256)" "$HBA_FILE"; then
            echo "Fixing postgres user authentication to peer in $HBA_FILE..."
            sudo sed -i -E 's/^(local\s+all\s+postgres\s+)(md5|scram-sha-256)/\1peer/' "$HBA_FILE"
            NEEDS_RELOAD=true
        fi
        
        # 2. Ensure generic 'peer' auth exists for all other users (students/admins)
        # We insert this AT THE TOP of the file to ensure it takes precedence over default rules.
        if ! grep -q "^local\s*all\s*all\s*peer" "$HBA_FILE"; then
            echo "Adding global peer authentication to top of $HBA_FILE..."
            # Create temp file with new rule at top, then append original content
            echo "local   all             all                                     peer" | cat - "$HBA_FILE" | sudo tee "$HBA_FILE.tmp" > /dev/null
            sudo mv "$HBA_FILE.tmp" "$HBA_FILE"
            sudo chown postgres:postgres "$HBA_FILE"
            sudo chmod 640 "$HBA_FILE"
            NEEDS_RELOAD=true
        fi
        
        if [[ "$NEEDS_RELOAD" == true ]]; then
            sudo systemctl reload postgresql
            echo "PostgreSQL authentication updated and service reloaded."
            sleep 1
        fi
    fi
else
    echo "Warning: Could not detect PostgreSQL version. Skipping pg_hba.conf configuration."
fi

# ==============================================================================
# 1. DATABASE & SCHEMA SETUP (Batch Mode Only)
# ==============================================================================
# Skip initial setup for interactive modes (assumes prior batch setup)
if [[ -z "$MODE" ]]; then

# Setup Admin Database (Central Registry)
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$ADMIN_DB'" | grep -q 1; then
    sudo -u postgres createdb "$ADMIN_DB"
    echo "Created database '$ADMIN_DB'."
    sudo -u postgres psql -d "$ADMIN_DB" -c "REVOKE CONNECT ON DATABASE \"$ADMIN_DB\" FROM PUBLIC;"
    echo "Restricted access to '$ADMIN_DB'."
else
    echo "Database '$ADMIN_DB' already exists."
fi

# Setup Student Database (Shared Workspace)
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$CS143_DB'" | grep -q 1; then
    sudo -u postgres createdb "$CS143_DB"
    echo "Created database '$CS143_DB'."
else
    echo "Database '$CS143_DB' already exists."
fi

# Configure Global Search Path for CS143_DB
sudo -u postgres psql -c "ALTER DATABASE \"$CS143_DB\" SET search_path TO \"\$user\", public;" >/dev/null
echo "Configured global search_path for '$CS143_DB' to '\"\$user\", public'."

# Setup Exam Databases (midterm, final) - Admin Only
for db in "midterm" "final"; do
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
        sudo -u postgres createdb "$db"
        echo "Created restricted database '$db'."
        sudo -u postgres psql -d "$db" -c "REVOKE CONNECT ON DATABASE \"$db\" FROM PUBLIC;"
        echo "Restricted access to '$db'."
    else
        echo "Database '$db' already exists."
    fi
done

# Configure Public Schema Permissions in CS143
echo "Configuring permissions for 'public' schema in '$CS143_DB'..."
sudo -u postgres psql -d "$CS143_DB" -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
sudo -u postgres psql -d "$CS143_DB" -c "GRANT USAGE ON SCHEMA public TO PUBLIC;"
sudo -u postgres psql -d "$CS143_DB" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO PUBLIC;"
sudo -u postgres psql -d "$CS143_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;"

# Ensure 'students' Table Exists
sudo -u postgres psql -d "$ADMIN_DB" -c "
CREATE TABLE IF NOT EXISTS students (
    student_id SERIAL PRIMARY KEY,
    student_name VARCHAR(255) NOT NULL,
    username VARCHAR(100) NOT NULL UNIQUE,
    hashed_university_id VARCHAR(255) NOT NULL UNIQUE,
    email_address VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);"
echo "Ensured 'students' table exists in '$ADMIN_DB'."

# Fix sequence if it's out of sync
sudo -u postgres psql -d "$ADMIN_DB" -c "
SELECT setval('students_student_id_seq', COALESCE((SELECT MAX(student_id) FROM students), 0) + 1, false);
" >/dev/null 2>&1

fi # End Batch Setup

# ==============================================================================
# 2. USER PROVISIONING FUNCTIONS
# ==============================================================================

# Function to process Admin Postgres
process_admins_postgres() {
    local input=$1
    echo "Processing Admin Postgres: $input"
    
    while IFS=, read -r username name password uid email || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        if [[ -z "$username" || "$username" == "username" ]]; then continue; fi

        if ! id "$username" &>/dev/null; then
            echo "Warning: Unix user '$username' does not exist. Skipping Admin Postgres setup."
            continue
        fi

        echo "Provisioning Admin Postgres user '$username'..."
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
                sudo -u postgres createuser --superuser "$username"
                echo "Created Postgres superuser '$username'."
        fi

        sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA IF NOT EXISTS \"$username\" AUTHORIZATION \"$username\";" >/dev/null
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO public, \"$username\";" >/dev/null
        sudo -u postgres psql -d "$CS143_DB" -c "ALTER DEFAULT PRIVILEGES FOR ROLE \"$username\" IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;" >/dev/null

        hashed_uid=$(echo -n "$uid" | sha256sum | awk '{print $1}')
        
        sudo -u postgres psql -d "$ADMIN_DB" -c "
        INSERT INTO students (student_name, username, hashed_university_id, email_address)
        VALUES ('$name', '$username', '$hashed_uid', '$email')
        ON CONFLICT (username) DO UPDATE 
        SET student_name = EXCLUDED.student_name, 
            hashed_university_id = EXCLUDED.hashed_university_id,
            email_address = EXCLUDED.email_address;
        " >/dev/null
        echo "Registered admin '$username' in students table."
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
         if ! id "$u" &>/dev/null; then return 1; fi
         for p in "${PROVISIONED_USERS[@]}"; do
             [[ "$p" == "$u" ]] && return 1
         done
         return 0
    }

    while IFS=, read -r c1 c2 c3 c4 c5 c6 c7 rest || [ -n "$c1" ]; do
        if ! [[ "$c1" =~ ^[0-9]{3}-[0-9]{3}-[0-9]{3}$ ]]; then continue; fi
        
        raw_uid="$c1"
        last_name_raw=$(echo "$c2" | tr -d '"' | xargs)
        first_names_raw=$(echo "$c3" | tr -d '"' | xargs)
        name="$first_names_raw $last_name_raw"
        email=$(echo "$c4" | xargs)
        
        target_username=""
        
        if [[ -z "$target_username" ]]; then
             f=$(sanitize "$first_names_raw")
             l=$(sanitize "$last_name_raw")
             c1="${f:0:1}${l}"; c1=${c1:0:8}
             if is_available "$c1"; then target_username="$c1"; fi
             if [[ -z "$target_username" ]] && is_available "$f"; then target_username="$f"; fi
             if [[ -z "$target_username" ]] && is_available "$l"; then target_username="$l"; fi
        fi

        if [[ -z "$target_username" ]]; then
             echo "Warning: No matching/available system user found for '$name'. Skipping Postgres."
             continue
        fi

        username="$target_username"
        PROVISIONED_USERS+=("$username")
        
        echo "Provisioning Postgres for '$username' ($name)..."
        
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
               sudo -u postgres psql -c "CREATE ROLE \"$username\" WITH LOGIN;" >/dev/null
               echo "Created Postgres role '$username'."
        fi

        sudo -u postgres psql -d "$CS143_DB" -c "GRANT CONNECT ON DATABASE \"$CS143_DB\" TO \"$username\";" >/dev/null

        if ! sudo -u postgres psql -d "$CS143_DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
               sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
               sudo -u postgres psql -d "$CS143_DB" -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
               echo "Created private schema '$username' in '$CS143_DB'."
        fi
        
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null

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

process_admin_users_list() {
    local input=$1
    echo "Processing Admin Users List: $input"
    while IFS= read -r username || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        if [[ -z "$username" || "$username" == \#* ]]; then continue; fi

        if ! id "$username" &>/dev/null; then
            echo "Warning: Unix user '$username' does not exist. Skipping."
            continue
        fi
        
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
            sudo -u postgres createuser --superuser "$username"
            echo "Created Postgres superuser '$username'."
        else
            echo "Postgres superuser '$username' already exists."
        fi

        sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA IF NOT EXISTS \"$username\" AUTHORIZATION \"$username\";" >/dev/null
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO public, \"$username\";" >/dev/null
        sudo -u postgres psql -d "$CS143_DB" -c "ALTER DEFAULT PRIVILEGES FOR ROLE \"$username\" IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;" >/dev/null

        local real_name=""
        if command -v finger &>/dev/null; then
            real_name=$(finger "$username" 2>/dev/null | grep "Name:" | sed 's/.*Name: //' | head -1)
        fi
        if [[ -z "$real_name" ]]; then
            real_name=$(getent passwd "$username" 2>/dev/null | cut -d: -f5 | cut -d, -f1)
        fi
        if [[ -z "$real_name" ]]; then real_name="$username"; fi
        
        local hashed_uid=$(echo -n "$username" | sha256sum | awk '{print $1}')
        
        sudo -u postgres psql -d "$ADMIN_DB" -c "
        INSERT INTO students (student_name, username, hashed_university_id, email_address)
        VALUES ('$real_name', '$username', '$hashed_uid', '$username@localhost')
        ON CONFLICT (username) DO UPDATE 
        SET student_name = EXCLUDED.student_name
        WHERE students.student_name = '' OR students.student_name IS NULL;
        " >/dev/null
        echo "Registered admin '$username' in students table."
    done < "$input"
}

process_student_users_list() {
    local input=$1
    echo "Processing Student Users List: $input"
    while IFS= read -r username || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        if [[ -z "$username" || "$username" == \#* ]]; then continue; fi

        if ! id "$username" &>/dev/null; then
            echo "Warning: Unix user '$username' does not exist. Skipping."
            continue
        fi

        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
            sudo -u postgres psql -c "CREATE ROLE \"$username\" WITH LOGIN;" >/dev/null
            echo "Created Postgres role '$username'."
        fi

        sudo -u postgres psql -d "$CS143_DB" -c "GRANT CONNECT ON DATABASE \"$CS143_DB\" TO \"$username\";" >/dev/null

        if ! sudo -u postgres psql -d "$CS143_DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
            sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
            sudo -u postgres psql -d "$CS143_DB" -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
            echo "Created private schema '$username' in '$CS143_DB'."
        fi
        
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null

        local real_name=""
        if command -v finger &>/dev/null; then
            real_name=$(finger "$username" 2>/dev/null | grep "Name:" | sed 's/.*Name: //' | head -1)
        fi
        if [[ -z "$real_name" ]]; then
            real_name=$(getent passwd "$username" 2>/dev/null | cut -d: -f5 | cut -d, -f1)
        fi
        if [[ -z "$real_name" ]]; then real_name="$username"; fi
        
        local hashed_uid=$(echo -n "$username" | sha256sum | awk '{print $1}')
        
        sudo -u postgres psql -d "$ADMIN_DB" -c "
        INSERT INTO students (student_name, username, hashed_university_id, email_address)
        VALUES ('$real_name', '$username', '$hashed_uid', '$username@localhost')
        ON CONFLICT (username) DO UPDATE 
        SET student_name = EXCLUDED.student_name
        WHERE students.student_name = '' OR students.student_name IS NULL;
        " >/dev/null
        echo "Registered student '$username' in students table."
    done < "$input"
}

# ==============================================================================
# 3. EXECUTION
# ==============================================================================

if [[ -n "$ADMIN_FILE" ]]; then
    process_admins_postgres "$ADMIN_FILE"
fi
if [[ -n "$ROSTER_FILE" ]]; then
    process_roster_postgres "$ROSTER_FILE"
fi
if [[ -n "$ADMIN_USERS_FILE" ]]; then
    process_admin_users_list "$ADMIN_USERS_FILE"
fi
if [[ -n "$STUDENT_USERS_FILE" ]]; then
    process_student_users_list "$STUDENT_USERS_FILE"
fi

if [[ "$MODE" == "interactive_admin" ]]; then
    if [[ -z "$INTERACTIVE_USERNAME" ]]; then
        read -rp "Enter Admin Username (must exist in system): " INTERACTIVE_USERNAME
    fi
    read -rp "Enter Full Name: " INTERACTIVE_NAME
    read -rp "Enter UID (or any identifier): " INTERACTIVE_UID
    read -rp "Enter Email: " INTERACTIVE_EMAIL
    
    t=$(mktemp)
    echo "$INTERACTIVE_USERNAME,$INTERACTIVE_NAME,unused,$INTERACTIVE_UID,$INTERACTIVE_EMAIL" > "$t"
    process_admins_postgres "$t"
    rm "$t"
    echo "Admin '$INTERACTIVE_USERNAME' provisioned."
fi

if [[ "$MODE" == "interactive_student" ]]; then
    if [[ -z "$INTERACTIVE_USERNAME" ]]; then
        read -rp "Enter Student Username (must exist in system): " INTERACTIVE_USERNAME
    fi
    if [[ -z "$INTERACTIVE_NAME" ]]; then
        read -rp "Enter Full Name: " INTERACTIVE_NAME
    fi
    if [[ -z "$INTERACTIVE_UID" ]]; then
        read -rp "Enter UID: " INTERACTIVE_UID
    fi
    if [[ -z "$INTERACTIVE_EMAIL" ]]; then
        read -rp "Enter Email: " INTERACTIVE_EMAIL
    fi
    
    username="$INTERACTIVE_USERNAME"
    if ! id "$username" &>/dev/null; then
        echo "Error: Unix user '$username' does not exist."
        exit 1
    fi
    
    echo "Provisioning Postgres for student '$username'..."
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE ROLE \"$username\" WITH LOGIN;" >/dev/null
    fi
    sudo -u postgres psql -d "$CS143_DB" -c "GRANT CONNECT ON DATABASE \"$CS143_DB\" TO \"$username\";" >/dev/null
    if ! sudo -u postgres psql -d "$CS143_DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
        sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
        sudo -u postgres psql -d "$CS143_DB" -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
    fi
    sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null
    
    hashed_uid=$(echo -n "$INTERACTIVE_UID" | sha256sum | awk '{print $1}')
    sudo -u postgres psql -d "$ADMIN_DB" -c "
    INSERT INTO students (student_name, username, hashed_university_id, email_address)
    VALUES ('$INTERACTIVE_NAME', '$username', '$hashed_uid', '$INTERACTIVE_EMAIL')
    ON CONFLICT (username) DO UPDATE 
    SET student_name = EXCLUDED.student_name, 
        hashed_university_id = EXCLUDED.hashed_university_id,
        email_address = EXCLUDED.email_address;
    " >/dev/null
    echo "Student '$username' provisioned."
fi

# ==============================================================================
# 4. ENVIRONMENT CONFIGURATION (Batch Only)
# ==============================================================================
if [[ -z "$MODE" ]]; then

# Configure Global Default Database (cs143)
echo "Configuring default database (PGDATABASE=$CS143_DB)..."
if grep -q "^PGDATABASE=" /etc/environment 2>/dev/null; then
    sudo sed -i "s/^PGDATABASE=.*/PGDATABASE=$CS143_DB/" /etc/environment
else
    echo "PGDATABASE=$CS143_DB" | sudo tee -a /etc/environment >/dev/null
fi

PROFILE_SCRIPT="/etc/profile.d/cs143-env.sh"
echo "export PGDATABASE=$CS143_DB" | sudo tee "$PROFILE_SCRIPT" > /dev/null
sudo chmod 644 "$PROFILE_SCRIPT"

# Final Permission Refresh
echo "Refreshing usage/select permissions on public schema..."
sudo -u postgres psql -d "$CS143_DB" -c "GRANT USAGE ON SCHEMA public TO PUBLIC;"
sudo -u postgres psql -d "$CS143_DB" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO PUBLIC;"

fi

echo "PostgreSQL population complete."