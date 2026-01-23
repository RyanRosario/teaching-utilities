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
    if [[ "$arg" == "--add-admin" ]]; then
        MODE="interactive_admin"
    elif [[ "$arg" == "--add-student" ]]; then
        MODE="interactive_student"
    elif [[ "$arg" == "--admin" ]]; then
        NEXT_IS_ADMIN=true
    elif [[ "$arg" == "--roster" ]]; then
        NEXT_IS_ROSTER=true
    elif [[ "$NEXT_IS_ADMIN" == true ]]; then
        ADMIN_FILE="$arg"
        NEXT_IS_ADMIN=false
    elif [[ "$NEXT_IS_ROSTER" == true ]]; then
        ROSTER_FILE="$arg"
        NEXT_IS_ROSTER=false
    elif [[ -z "$ADMIN_FILE" && ! "$arg" == --* ]]; then
        ADMIN_FILE="$arg"
    elif [[ -z "$ROSTER_FILE" && ! "$arg" == --* ]]; then
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
    # Single file passed. Check if it's actually roster.
    type=$(guess_file_type "$ADMIN_FILE")
    if [[ "$type" == "roster" ]]; then
        echo "Note: Detected student roster in first argument. Proceeding in Roster mode."
        ROSTER_FILE="$ADMIN_FILE"
        ADMIN_FILE=""
    fi
elif [[ -n "$ADMIN_FILE" && -n "$ROSTER_FILE" ]]; then
    # Two files. Check if swapped.
    t1=$(guess_file_type "$ADMIN_FILE")
    t2=$(guess_file_type "$ROSTER_FILE")
    if [[ "$t1" == "roster" && "$t2" == "admin" ]]; then
         echo "Note: Detected swapped Admin/Roster files. Auto-correcting."
         tmp="$ADMIN_FILE"
         ADMIN_FILE="$ROSTER_FILE"
         ROSTER_FILE="$tmp"
    fi
fi

if [[ "$MODE" == "interactive_admin" ]]; then
     # For Postgres Admin process, we only strictly need the username to exist in system.
     # But the csv parser expects: username,name,password,uid,email
     read -rp "Enter Admin Username (must exist in system): " u
     
     t=$(mktemp)
     # Dummy fillers for non-postgres fields
     echo "$u,Interactive Admin,pass,0,email@local" > "$t"
     process_admins_postgres "$t"
     rm "$t"
     exit 0 # We assume they might want to run peer-auth setup? 
            # Actually peer auth setup is global. We should probably let it run or duplicate it?
            # Let's let it run if we want full setup, OR just exit. 
            # Usually populate is for users.
            # But the script ends with peer auth config.
            # Let's just run the function and maybe fall through? 
            # The structure of the script defaults to "if variables are set". 
            # If we exit here, peer auth won't double-check. 
            # Let's exit, assuming peer auth is a one-time setup.
     exit 0

elif [[ "$MODE" == "interactive_student" ]]; then
     read -rp "Enter Student UID (NNN-NNN-NNN): " i
     read -rp "Enter Last Name: " l
     read -rp "Enter First Name: " f
     read -rp "Enter Email: " e
     
     t=$(mktemp)
     # Format: UID, "Last, First", Email...
     echo "$i,\"$l, $f\",$e,INT,MODE,," > "$t"
     process_roster_postgres "$t"
     rm "$t"
     exit 0
fi

if [[ -z "$ADMIN_FILE" && -z "$ROSTER_FILE" && -z "$MODE" ]]; then
    echo "Usage: $0 [options]"
    echo "  --admin <file>   Admin CSV"
    echo "  --roster <file>  Roster CSV"
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
else
    echo "Database '$ADMIN_DB' already exists."
fi

# 0.5 Setup Student Database (Shared Workspace)
CS143_DB="cs143"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$CS143_DB'" | grep -q 1; then
    sudo -u postgres createdb "$CS143_DB"
    echo "Created database '$CS143_DB'."
    # We DO want students to connect here, but only see their own schemas.
else
    echo "Database '$CS143_DB' already exists."
fi

# 0.6 Setup Exam Databases (midterm, final) - Admin Only
for db in "midterm" "final"; do
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
        sudo -u postgres createdb "$db"
        echo "Created restricted database '$db'."
        # Restrict Access: Only Superusers (Admins) can connect
        sudo -u postgres psql -d "$db" -c "REVOKE CONNECT ON DATABASE \"$db\" FROM PUBLIC;"
        echo "Restricted access to '$db'."
    else
        echo "Database '$db' already exists."
    fi
done

# Configure Public Schema Permissions in CS143
# Goal: Everyone can READ public, only Admins can EDIT public.
# Note: Admins are Superusers, so they ignore permission checks (have full access).
# We restrict 'PUBLIC' (which includes students) to Read-Only.

echo "Configuring permissions for 'public' schema in '$CS143_DB'..."
# 1. Revoke CREATE from PUBLIC (Students cannot create tables in public)
sudo -u postgres psql -d "$CS143_DB" -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
# 2. Grant USAGE (Access) and SELECT (Read) to PUBLIC
sudo -u postgres psql -d "$CS143_DB" -c "GRANT USAGE ON SCHEMA public TO PUBLIC;"
sudo -u postgres psql -d "$CS143_DB" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO PUBLIC;"
# 3. Ensure future tables created by postgres/admins are readable by PUBLIC
sudo -u postgres psql -d "$CS143_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;"

# ALWAYS Ensure Table Exists
# Use IF NOT EXISTS in SQL to handle re-runs safely
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

        # Create Personal Schema for Admin in CS143 DB
        # Admins have full access anyway (Superuser), but this gives them a personal workspace.
        sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA IF NOT EXISTS \"$username\" AUTHORIZATION \"$username\";" >/dev/null
        # Set search_path for Admin to default to their schema
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null
        echo "Created admin workspace schema '$username' in '$CS143_DB'."

        # Ensure tables created by this Admin in PUBLIC are readable by everyone (Students)
        sudo -u postgres psql -d "$CS143_DB" -c "ALTER DEFAULT PRIVILEGES FOR ROLE \"$username\" IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;" >/dev/null
        echo "Configured default privileges for Admin '$username' (Public tables will be readable)."

        # Insert Admin into students table (as requested)
        # Admins might not have a real student UID, so we use their provided UID or hash it.
        # The CSV has 'uid' column.
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
        # Removed: The provided roster does NOT have an override column. 
        # c6/c7 contain Class/Grade info.
        
        target_username=""
        
        # 1. Try Standard Generation candidates
        # We try to match what create-users.sh would have generated.
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

        # B. Create Schema in CS143_DB
        # Students connect to CS143_DB (cs143).
        
        # 1. Grant Connect to the DB
        sudo -u postgres psql -d "$CS143_DB" -c "GRANT CONNECT ON DATABASE \"$CS143_DB\" TO \"$username\";" >/dev/null

        # 2. Designate Schema
        if ! sudo -u postgres psql -d "$CS143_DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
               sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
               
               # Isolate it: No one else can usage/create in this schema
               sudo -u postgres psql -d "$CS143_DB" -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
               
               # Set search_path so they land in their schema by default
               sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null
               
               echo "Created private schema '$username' in '$CS143_DB'."
        fi

        # C. Insert into admin.students (Registry is still in ADMIN_DB)
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

# 3. Configure Global Environment for PGDATABASE
# This ensures that when any user types 'psql', it connects to 'cs143' by default
# (instead of trying to connect to 'username' database which doesn't exist).
PROFILE_SCRIPT="/etc/profile.d/cs143-env.sh"
echo "Configuring global shell environment in $PROFILE_SCRIPT..."
echo "export PGDATABASE=$CS143_DB" | sudo tee "$PROFILE_SCRIPT" > /dev/null
sudo chmod 644 "$PROFILE_SCRIPT"

echo "PostgreSQL population complete."
