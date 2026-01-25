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
#                     Used when integrating with create-users.sh (creates Unix users + Postgres)
#   ROSTER_FILE     - Student roster CSV (UCLA format with UID, name, email, etc.)
#                     Used when integrating with create-users.sh (creates Unix users + Postgres)
#   ADMIN_USERS_FILE   - Simple text file with one admin username per line
#                        For PostgreSQL-only provisioning (Unix users must already exist)
#   STUDENT_USERS_FILE - Simple text file with one student username per line
#                        For PostgreSQL-only provisioning (Unix users must already exist)
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
    elif [[ "$NEXT_IS_INTERACTIVE_USER" == true ]]; then
        INTERACTIVE_USERNAME="$arg"
        NEXT_IS_INTERACTIVE_USER=false
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

# Interactive modes are handled after function definitions (see Main Execution section)

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
if [[ -n "$ADMIN_FILE" && ! -f "$ADMIN_FILE" ]]; then
     echo "Error: Admin File '$ADMIN_FILE' not found."
     exit 1
fi
if [[ -n "$ROSTER_FILE" && ! -f "$ROSTER_FILE" ]]; then
     echo "Error: Roster File '$ROSTER_FILE' not found."
     exit 1
fi
if [[ -n "$ADMIN_USERS_FILE" && ! -f "$ADMIN_USERS_FILE" ]]; then
     echo "Error: Admin Users File '$ADMIN_USERS_FILE' not found."
     exit 1
fi
if [[ -n "$STUDENT_USERS_FILE" && ! -f "$STUDENT_USERS_FILE" ]]; then
     echo "Error: Student Users File '$STUDENT_USERS_FILE' not found."
     exit 1
fi

echo "Starting PostgreSQL population..."

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

# 0.5.1 Configure Global Search Path for CS143_DB
# This ensures that ALL users connecting to this DB defaults to "$user", public
# This is a fallback if the Role-level search_path is missing or reset.
sudo -u postgres psql -c "ALTER DATABASE \"$CS143_DB\" SET search_path TO \"\$user\", public;" >/dev/null
echo "Configured global search_path for '$CS143_DB' to '\"\$user\", public'."

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

# Fix sequence if it's out of sync
sudo -u postgres psql -d "$ADMIN_DB" -c "
SELECT setval('students_student_id_seq', COALESCE((SELECT MAX(student_id) FROM students), 0) + 1, false);
" >/dev/null 2>&1

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
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO public, \"$username\";" >/dev/null
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
               

               
               echo "Created private schema '$username' in '$CS143_DB'."
        fi
        
        # Set search_path so they land in their schema by default (Apply to ALL students, existing or new)
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null

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

# Function to process simple admin username list (one username per line)
process_admin_users_list() {
    local input=$1
    echo "Processing Admin Users List: $input"
    
    while IFS= read -r username || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        # Skip empty lines and comments
        if [[ -z "$username" || "$username" == \#* ]]; then continue; fi

        if ! id "$username" &>/dev/null; then
            echo "Warning: Unix user '$username' does not exist. Skipping."
            continue
        fi

        echo "Provisioning Admin Postgres user '$username'..."
        
        # Create Superuser
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
            sudo -u postgres createuser --superuser "$username"
            echo "Created Postgres superuser '$username'."
        else
            echo "Postgres superuser '$username' already exists."
        fi

        # Create Personal Schema for Admin in CS143 DB
        sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA IF NOT EXISTS \"$username\" AUTHORIZATION \"$username\";" >/dev/null
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO public, \"$username\";" >/dev/null
        echo "Created admin workspace schema '$username' in '$CS143_DB'."

        # Ensure tables created by this Admin in PUBLIC are readable by everyone
        sudo -u postgres psql -d "$CS143_DB" -c "ALTER DEFAULT PRIVILEGES FOR ROLE \"$username\" IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;" >/dev/null

        # Try to get user info from system for students table
        # Use finger or getent to get real name
        local real_name=""
        if command -v finger &>/dev/null; then
            real_name=$(finger "$username" 2>/dev/null | grep "Name:" | sed 's/.*Name: //' | head -1)
        fi
        if [[ -z "$real_name" ]]; then
            real_name=$(getent passwd "$username" 2>/dev/null | cut -d: -f5 | cut -d, -f1)
        fi
        if [[ -z "$real_name" ]]; then
            real_name="$username"
        fi
        
        # For simple username list, use username as UID placeholder
        local hashed_uid=$(echo -n "$username" | sha256sum | awk '{print $1}')
        
        # Add to students table with available info
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

# Function to process simple student username list (one username per line)
process_student_users_list() {
    local input=$1
    echo "Processing Student Users List: $input"
    
    while IFS= read -r username || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        # Skip empty lines and comments
        if [[ -z "$username" || "$username" == \#* ]]; then continue; fi

        if ! id "$username" &>/dev/null; then
            echo "Warning: Unix user '$username' does not exist. Skipping."
            continue
        fi

        echo "Provisioning Postgres for student '$username'..."
        
        # Create Role (Login)
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
            sudo -u postgres psql -c "CREATE ROLE \"$username\" WITH LOGIN;" >/dev/null
            echo "Created Postgres role '$username'."
        else
            echo "Postgres role '$username' already exists."
        fi

        # Grant Connect to the DB
        sudo -u postgres psql -d "$CS143_DB" -c "GRANT CONNECT ON DATABASE \"$CS143_DB\" TO \"$username\";" >/dev/null

        # Create Schema
        if ! sudo -u postgres psql -d "$CS143_DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
            sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
            sudo -u postgres psql -d "$CS143_DB" -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
            echo "Created private schema '$username' in '$CS143_DB'."
        fi
        
        # Set search_path
        sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null

        # Get user info from system for students table
        local real_name=""
        if command -v finger &>/dev/null; then
            real_name=$(finger "$username" 2>/dev/null | grep "Name:" | sed 's/.*Name: //' | head -1)
        fi
        if [[ -z "$real_name" ]]; then
            real_name=$(getent passwd "$username" 2>/dev/null | cut -d: -f5 | cut -d, -f1)
        fi
        if [[ -z "$real_name" ]]; then
            real_name="$username"
        fi
        
        # Use username as UID placeholder
        local hashed_uid=$(echo -n "$username" | sha256sum | awk '{print $1}')
        
        # Insert into students table
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

# Main Execution
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

# Interactive modes
if [[ "$MODE" == "interactive_admin" ]]; then
    # Prompt for all required information
    if [[ -z "$INTERACTIVE_USERNAME" ]]; then
        read -rp "Enter Admin Username (must exist in system): " INTERACTIVE_USERNAME
    fi
    read -rp "Enter Full Name: " INTERACTIVE_NAME
    read -rp "Enter UID (or any identifier): " INTERACTIVE_UID
    read -rp "Enter Email: " INTERACTIVE_EMAIL
    
    # Create a temp CSV file with all the data
    t=$(mktemp)
    echo "$INTERACTIVE_USERNAME,$INTERACTIVE_NAME,unused,$INTERACTIVE_UID,$INTERACTIVE_EMAIL" > "$t"
    process_admins_postgres "$t"
    rm "$t"
    echo "Admin '$INTERACTIVE_USERNAME' provisioned and added to students table."
fi

if [[ "$MODE" == "interactive_student" ]]; then
    # Prompt for all required information
    if [[ -z "$INTERACTIVE_USERNAME" ]]; then
        read -rp "Enter Student Username (must exist in system): " INTERACTIVE_USERNAME
    fi
    read -rp "Enter Full Name: " INTERACTIVE_NAME
    read -rp "Enter UID (NNN-NNN-NNN): " INTERACTIVE_UID
    read -rp "Enter Email: " INTERACTIVE_EMAIL
    
    username="$INTERACTIVE_USERNAME"
    
    # Verify Unix user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: Unix user '$username' does not exist."
        exit 1
    fi
    
    echo "Provisioning Postgres for student '$username'..."
    
    # Create Role (Login)
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE ROLE \"$username\" WITH LOGIN;" >/dev/null
        echo "Created Postgres role '$username'."
    fi

    # Grant Connect to the DB
    sudo -u postgres psql -d "$CS143_DB" -c "GRANT CONNECT ON DATABASE \"$CS143_DB\" TO \"$username\";" >/dev/null

    # Create Schema
    if ! sudo -u postgres psql -d "$CS143_DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$username'" | grep -q 1; then
        sudo -u postgres psql -d "$CS143_DB" -c "CREATE SCHEMA \"$username\" AUTHORIZATION \"$username\";" >/dev/null
        sudo -u postgres psql -d "$CS143_DB" -c "REVOKE ALL ON SCHEMA \"$username\" FROM PUBLIC;" >/dev/null
        echo "Created private schema '$username' in '$CS143_DB'."
    fi
    
    # Set search_path
    sudo -u postgres psql -c "ALTER ROLE \"$username\" SET search_path TO \"$username\", public;" >/dev/null
    
    # Add to students table
    hashed_uid=$(echo -n "$INTERACTIVE_UID" | sha256sum | awk '{print $1}')
    sudo -u postgres psql -d "$ADMIN_DB" -c "
    INSERT INTO students (student_name, username, hashed_university_id, email_address)
    VALUES ('$INTERACTIVE_NAME', '$username', '$hashed_uid', '$INTERACTIVE_EMAIL')
    ON CONFLICT (username) DO UPDATE 
    SET student_name = EXCLUDED.student_name, 
        hashed_university_id = EXCLUDED.hashed_university_id,
        email_address = EXCLUDED.email_address;
    " >/dev/null
    
    echo "Student '$username' provisioned and added to students table."
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

# 3. Configure Global Default Database
# Set PGDATABASE in /etc/environment so it applies to ALL sessions (login, non-login, SSH, etc.)
# This ensures 'psql' connects to 'cs143' by default for everyone.
echo "Configuring default database (PGDATABASE=$CS143_DB)..."

# Add to /etc/environment (loaded by PAM for all session types)
if grep -q "^PGDATABASE=" /etc/environment 2>/dev/null; then
    sudo sed -i "s/^PGDATABASE=.*/PGDATABASE=$CS143_DB/" /etc/environment
else
    echo "PGDATABASE=$CS143_DB" | sudo tee -a /etc/environment >/dev/null
fi

# Also add to /etc/profile.d for shell scripts that source profile
PROFILE_SCRIPT="/etc/profile.d/cs143-env.sh"
echo "export PGDATABASE=$CS143_DB" | sudo tee "$PROFILE_SCRIPT" > /dev/null
sudo chmod 644 "$PROFILE_SCRIPT"

echo "Default database configured. New sessions will connect to '$CS143_DB' by default."



# 4. Final Permission Refresh
# Ensure ANY existing tables in public (created by anyone) are readable.
echo "Refreshing usage/select permissions on public schema..."
sudo -u postgres psql -d "$CS143_DB" -c "GRANT USAGE ON SCHEMA public TO PUBLIC;"
sudo -u postgres psql -d "$CS143_DB" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO PUBLIC;"

echo "PostgreSQL population complete."
