#!/bin/bash
# ==============================================================================
# ArangoDB - User Provisioning Script
# ==============================================================================
# This script provisions ArangoDB user accounts and databases:
#   - Creates course database (cs143): admins read/write, students read-only
#   - Creates per-student databases: each student has their own private database
#   - Passwordless local access via stored credentials (~/.arango_pass)
#   - System-wide arangosh alias for auto-authentication
#   - Password-based auth synced with Unix passwords (via password reset app)
#
# ArangoDB has no native Unix peer auth. Instead, each user's password is
# stored in ~/.arango_pass (chmod 600) and a system-wide alias auto-reads
# it so users just type "arangosh" with no password.
#
# Prerequisites: Run arangodb-bootstrap.sh first.
# Students are read from PostgreSQL admin.students table.
# Admins are read from a text file (one username per line).
#
# Permission Model:
#   - Admins:   read/write on course DB + read/write on ALL databases
#   - Students: read-only on course DB + read/write on personal DB (<username>)
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/arangodb-config.json"

# Default values
COURSE_DB=""
ADMIN_FILE=""
ARANGO_ROOT_PASSWORD=""
ARANGO_HOST="127.0.0.1"
ARANGO_PORT=8529

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq > /dev/null 2>&1; then
            IFS= read -r ARANGO_ROOT_PASSWORD < <(jq -r '.arango_root_password // ""' "$CONFIG_FILE")
            COURSE_DB=$(jq -r '.course_db // ""' "$CONFIG_FILE")
            local cfg_admin_file=$(jq -r '.admin_users_file // ""' "$CONFIG_FILE")
            if [[ -n "$cfg_admin_file" && -z "$ADMIN_FILE" ]]; then
                if [[ "$cfg_admin_file" != /* ]]; then
                    ADMIN_FILE="$SCRIPT_DIR/$cfg_admin_file"
                else
                    ADMIN_FILE="$cfg_admin_file"
                fi
            fi
            echo "Loaded configuration from $CONFIG_FILE"
        else
            echo "Warning: jq not installed. Cannot read config file."
            echo "Install with: sudo apt install jq"
        fi
    else
        echo "Warning: Config file not found: $CONFIG_FILE"
        echo "Using default values. Create arangodb-config.json to configure."
    fi
}

# Load config first (can be overridden by command-line args)
load_config

# ==============================================================================
# ARGUMENT PARSING (overrides config file)
# ==============================================================================
MODE=""
INTERACTIVE_USERNAME=""
INTERACTIVE_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            load_config
            shift 2
            ;;
        --admin-users)
            ADMIN_FILE="$2"
            shift 2
            ;;
        --arango-root-password)
            ARANGO_ROOT_PASSWORD="$2"
            shift 2
            ;;
        --add-admin)
            MODE="interactive"
            INTERACTIVE_TYPE="admin"
            INTERACTIVE_USERNAME="$2"
            shift 2
            ;;
        --add-student)
            MODE="interactive"
            INTERACTIVE_TYPE="student"
            INTERACTIVE_USERNAME="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script provisions ArangoDB user accounts and databases:"
            echo "  - Course database: admins read/write, students read-only"
            echo "  - Per-student databases: <username> with read/write for owner"
            echo "  - Passwordless local access via ~/.arango_pass"
            echo ""
            echo "Configuration is read from arangodb-config.json:"
            echo "  - arango_root_password: ArangoDB root password"
            echo "  - course_db: Course database name (required)"
            echo "  - admin_users_file: Path to admin usernames file"
            echo ""
            echo "Options:"
            echo "  --config <file>                  Path to config file (default: arangodb-config.json)"
            echo "  --admin-users <file>              Override admin users file from config"
            echo "  --arango-root-password <pass>     Override ArangoDB root password from config"
            echo "  --add-admin <username>            Add a single admin user (interactive mode)"
            echo "  --add-student <username>          Add a single student user (interactive mode)"
            echo "  --help, -h                        Show this help message"
            echo ""
            echo "Examples:"
            echo "  # Batch provisioning (uses config file)"
            echo "  $0"
            echo ""
            echo "  # Add single admin"
            echo "  $0 --add-admin jsmith"
            echo ""
            echo "  # Add single student"
            echo "  $0 --add-student jdoe"
            echo ""
            echo "Students are automatically loaded from PostgreSQL admin.students table."
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
# VALIDATION
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)."
    exit 1
fi

if [[ -z "$ARANGO_ROOT_PASSWORD" ]]; then
    read -s -p "Enter ArangoDB root password: " ARANGO_ROOT_PASSWORD
    echo ""
    if [[ -z "$ARANGO_ROOT_PASSWORD" ]]; then
        echo "Error: Password cannot be empty."
        exit 1
    fi
fi

if [[ -z "$COURSE_DB" ]]; then
    echo "Error: Course database name not set."
    echo "Set 'course_db' in $CONFIG_FILE (e.g. \"course_db\": \"cs143\")"
    exit 1
fi

# Verify ArangoDB is running
if ! curl -s "http://${ARANGO_HOST}:${ARANGO_PORT}/_api/version" -u "root:${ARANGO_ROOT_PASSWORD}" > /dev/null 2>&1; then
    echo "Error: Cannot connect to ArangoDB at http://${ARANGO_HOST}:${ARANGO_PORT}"
    echo "Ensure ArangoDB is running (systemctl status arangodb3) and password is correct."
    exit 1
fi
echo "ArangoDB connection verified."

# ==============================================================================
# HELPER: ArangoDB HTTP API via curl
# ==============================================================================
ARANGO_URL="http://${ARANGO_HOST}:${ARANGO_PORT}"
ARANGO_AUTH="root:${ARANGO_ROOT_PASSWORD}"

arango_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    if [[ -n "$data" ]]; then
        curl -s -X "$method" "${ARANGO_URL}${endpoint}" \
            -u "$ARANGO_AUTH" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "${ARANGO_URL}${endpoint}" \
            -u "$ARANGO_AUTH" \
            -H "Content-Type: application/json"
    fi
}

# ==============================================================================
# DATABASE MANAGEMENT
# ==============================================================================
create_database() {
    local db_name="$1"

    # Check if database already exists
    local exists
    exists=$(arango_api GET "/_api/database" | jq -r ".result[]" 2>/dev/null | grep -c "^${db_name}$" || true)

    if [[ "$exists" -eq 0 ]]; then
        echo "Creating database: $db_name"
        arango_api POST "/_api/database" "{\"name\": \"$db_name\"}" > /dev/null
    else
        echo "Database '$db_name' already exists."
    fi
}

# ==============================================================================
# USER MANAGEMENT
# ==============================================================================
create_user() {
    local username="$1"
    local password="$2"

    # Try to create user; if already exists, update password
    local result
    result=$(arango_api POST "/_api/user" "{\"user\": \"$username\", \"passwd\": \"$password\"}" 2>/dev/null)
    local error_code
    error_code=$(echo "$result" | jq -r '.errorNum // 0' 2>/dev/null)

    if [[ "$error_code" == "1702" ]]; then
        # User already exists — update password
        arango_api PATCH "/_api/user/$username" "{\"passwd\": \"$password\"}" > /dev/null
        echo "Updated existing user: $username"
    elif [[ "$error_code" != "0" && -n "$error_code" ]]; then
        echo "Warning: Error creating user $username: $(echo "$result" | jq -r '.errorMessage // "unknown"')"
    else
        echo "Created user: $username"
    fi
}

grant_database_access() {
    local username="$1"
    local db_name="$2"
    local permission="$3"   # "rw" or "ro"

    arango_api PUT "/_api/user/$username/database/$db_name" "{\"grant\": \"$permission\"}" > /dev/null
}

# ==============================================================================
# STORE USER PASSWORD (for passwordless local access)
# ==============================================================================
store_user_password() {
    local username="$1"
    local password="$2"
    local user_home

    user_home=$(eval echo "~$username")
    if [[ -d "$user_home" ]]; then
        echo "$password" | sudo tee "$user_home/.arango_pass" > /dev/null
        sudo chown "$username:$username" "$user_home/.arango_pass"
        sudo chmod 600 "$user_home/.arango_pass"
    fi
}

# ==============================================================================
# USER PROVISIONING FUNCTIONS
# ==============================================================================

provision_admin() {
    local admin="$1"
    local password="${2:-}"

    echo "Provisioning admin: $admin"

    # Verify Unix user exists
    if ! id "$admin" &>/dev/null; then
        echo "Warning: Unix user '$admin' does not exist. Skipping."
        return
    fi

    # Generate password (synced with Unix password via password reset app later)
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 16)
    fi

    # Create ArangoDB user
    create_user "$admin" "$password"

    # Grant admin read/write on ALL databases (including _system)
    grant_database_access "$admin" "*" "rw"
    echo "Granted admin '$admin' read/write access to all databases."

    # Store password for passwordless access
    store_user_password "$admin" "$password"

    echo "Admin '$admin' provisioned (passwordless via ~/.arango_pass)."
}

provision_student() {
    local student="$1"
    local password="${2:-}"

    echo "Provisioning student: $student"

    # Verify Unix user exists
    if ! id "$student" &>/dev/null; then
        echo "Warning: Unix user '$student' does not exist. Skipping."
        return
    fi

    # Generate password (synced with Unix password via password reset app later)
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 16)
    fi

    # Create student's personal database
    create_database "$student"

    # Create ArangoDB user
    create_user "$student" "$password"

    # Grant read-only access to course database
    grant_database_access "$student" "$COURSE_DB" "ro"

    # Grant read/write access to personal database
    grant_database_access "$student" "$student" "rw"

    # Revoke access to _system database
    grant_database_access "$student" "_system" "none"

    # Store password for passwordless access
    store_user_password "$student" "$password"

    echo "Student '$student' provisioned (passwordless via ~/.arango_pass)."
}

# ==============================================================================
# SYSTEM-WIDE ARANGOSH ALIAS (passwordless access)
# ==============================================================================
setup_arangosh_alias() {
    echo "Setting up system-wide arangosh alias..."
    sudo tee /etc/profile.d/arangosh.sh > /dev/null <<'PROFILE_EOF'
#!/bin/bash
# ArangoDB - Passwordless Authentication
# Reads per-user password from ~/.arango_pass and auto-authenticates
_ARANGO_PASS_FILE="$HOME/.arango_pass"

if [[ -f "$_ARANGO_PASS_FILE" ]]; then
    _ARANGO_PASS=$(cat "$_ARANGO_PASS_FILE")
    # Default to user's personal database, with arangosh alias
    alias arangosh="arangosh --server.endpoint tcp://127.0.0.1:8529 --server.username $USER --server.password $_ARANGO_PASS --server.database $USER"
    # Convenience alias for course database
    alias arangosh-course="arangosh --server.endpoint tcp://127.0.0.1:8529 --server.username $USER --server.password $_ARANGO_PASS --server.database \$(jq -r '.course_db // \"cs143\"' /etc/arangodb3/course.json 2>/dev/null || echo cs143)"
    unset _ARANGO_PASS
fi

unset _ARANGO_PASS_FILE
PROFILE_EOF
    sudo chmod 644 /etc/profile.d/arangosh.sh
    echo "System-wide arangosh alias configured in /etc/profile.d/arangosh.sh"
}

# ==============================================================================
# STORE COURSE DB NAME (for alias lookup)
# ==============================================================================
store_course_config() {
    echo "{\"course_db\": \"$COURSE_DB\"}" | sudo tee /etc/arangodb3/course.json > /dev/null
    sudo chmod 644 /etc/arangodb3/course.json
}

# ==============================================================================
# BATCH PROVISIONING
# ==============================================================================
provision_batch() {
    echo "Starting batch provisioning..."

    # Read admin usernames from file
    declare -a ADMINS=()
    if [[ -n "$ADMIN_FILE" && -f "$ADMIN_FILE" ]]; then
        while IFS= read -r username || [ -n "$username" ]; do
            username=$(echo "$username" | tr -d '\r' | xargs)
            if [[ -n "$username" && ! "$username" == \#* ]]; then
                ADMINS+=("$username")
            fi
        done < "$ADMIN_FILE"
        echo "Loaded ${#ADMINS[@]} admins from $ADMIN_FILE"
    else
        echo "Warning: No admin file specified or file not found."
        echo "Use --admin-users <file> to specify admin usernames."
    fi

    # Read student usernames from PostgreSQL
    declare -a STUDENTS=()
    if command -v psql > /dev/null 2>&1; then
        while IFS= read -r username; do
            username=$(echo "$username" | xargs)
            if [[ -n "$username" ]]; then
                STUDENTS+=("$username")
            fi
        done < <(sudo -u postgres psql -d admin -tAc "SELECT username FROM students;" 2>/dev/null)
        echo "Loaded ${#STUDENTS[@]} students from PostgreSQL admin.students"
    else
        echo "Warning: psql not found. Cannot load students from PostgreSQL."
    fi

    # -------------------------------------------------------------------------
    # 1. Setup Course Database
    # -------------------------------------------------------------------------
    echo ""
    echo "Setting up course database '$COURSE_DB'..."
    create_database "$COURSE_DB"

    # -------------------------------------------------------------------------
    # 2. Provision Admins
    # -------------------------------------------------------------------------
    echo ""
    echo "Provisioning admins..."
    for admin in "${ADMINS[@]}"; do
        provision_admin "$admin"
    done

    # -------------------------------------------------------------------------
    # 3. Provision Students
    # -------------------------------------------------------------------------
    echo ""
    echo "Provisioning students..."
    for student in "${STUDENTS[@]}"; do
        # Skip if student is also an admin
        is_admin=false
        for admin in "${ADMINS[@]}"; do
            if [[ "$student" == "$admin" ]]; then
                is_admin=true
                break
            fi
        done

        if [[ "$is_admin" == "false" ]]; then
            provision_student "$student"
        fi
    done

    # -------------------------------------------------------------------------
    # 4. Grant admins read/write on all student databases
    # -------------------------------------------------------------------------
    echo ""
    echo "Granting admins access to student databases..."
    for admin in "${ADMINS[@]}"; do
        for student in "${STUDENTS[@]}"; do
            grant_database_access "$admin" "$student" "rw"
        done
    done

    # -------------------------------------------------------------------------
    # 5. Store course config and setup alias
    # -------------------------------------------------------------------------
    store_course_config
    setup_arangosh_alias

    echo ""
    echo "=============================================="
    echo "ArangoDB Batch Provisioning Complete"
    echo "=============================================="
    echo ""
    echo "Summary:"
    echo "  - Course database: $COURSE_DB"
    echo "  - Admins provisioned: ${#ADMINS[@]}"
    echo "  - Students provisioned: ${#STUDENTS[@]}"
    echo ""
    echo "Permission Model:"
    echo "  - Admins:   read/write on ALL databases"
    echo "  - Students: read-only on '$COURSE_DB', read/write on personal DB"
    echo ""
    echo "Passwordless Access:"
    echo "  Users can simply run 'arangosh' — no password required!"
    echo "  Credentials stored in ~/.arango_pass (per-user, chmod 600)"
    echo ""
    echo "Web UI:  http://<server-ip>:$ARANGO_PORT"
    echo "=============================================="
}

# ==============================================================================
# INTERACTIVE PROVISIONING
# ==============================================================================
provision_interactive() {
    echo "Interactive provisioning: $INTERACTIVE_TYPE - $INTERACTIVE_USERNAME"

    if [[ -z "$INTERACTIVE_USERNAME" ]]; then
        echo "Error: Username is required."
        exit 1
    fi

    # Ensure course database exists
    create_database "$COURSE_DB"

    if [[ "$INTERACTIVE_TYPE" == "admin" ]]; then
        provision_admin "$INTERACTIVE_USERNAME"

        # Grant access to existing student databases
        echo "Granting access to existing student databases..."
        if command -v psql > /dev/null 2>&1; then
            while IFS= read -r student; do
                student=$(echo "$student" | xargs)
                if [[ -n "$student" ]]; then
                    grant_database_access "$INTERACTIVE_USERNAME" "$student" "rw"
                fi
            done < <(sudo -u postgres psql -d admin -tAc "SELECT username FROM students;" 2>/dev/null)
        fi

        echo ""
        echo "Admin '$INTERACTIVE_USERNAME' provisioned successfully!"

    elif [[ "$INTERACTIVE_TYPE" == "student" ]]; then
        provision_student "$INTERACTIVE_USERNAME"

        # Grant existing admins access to this student's database
        echo "Granting admins access to new student database..."
        if [[ -n "$ADMIN_FILE" && -f "$ADMIN_FILE" ]]; then
            while IFS= read -r admin || [ -n "$admin" ]; do
                admin=$(echo "$admin" | tr -d '\r' | xargs)
                if [[ -n "$admin" && ! "$admin" == \#* ]]; then
                    grant_database_access "$admin" "$INTERACTIVE_USERNAME" "rw"
                fi
            done < "$ADMIN_FILE"
        fi

        echo ""
        echo "Student '$INTERACTIVE_USERNAME' provisioned successfully!"
    fi

    # Update alias
    store_course_config
    setup_arangosh_alias

    echo ""
    echo "The user can now connect with: arangosh"
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

echo "=============================================="
echo "ArangoDB - User Provisioning"
echo "=============================================="
echo ""

if [[ "$MODE" == "interactive" ]]; then
    provision_interactive
else
    provision_batch
fi
