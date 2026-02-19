#!/bin/bash
# ==============================================================================
# Redis - User Provisioning Script
# ==============================================================================
# This script provisions Redis ACL users for a teaching environment:
#   - Creates per-student ACL users with key-prefix isolation
#   - Students get read-only access to course keyspace, read/write to their own
#   - Admins get full access to all keys
#   - Passwordless local access via stored credentials (~/.redis_pass)
#
# Prerequisites: Run redis-bootstrap.sh first.
# Students are read from PostgreSQL admin.students table.
# Admins are read from a text file (one username per line).
#
# Redis ACL Model:
#   - Student "jdoe" can read/write keys matching "jdoe:*"
#   - Student "jdoe" can read keys matching "<course>:*" (shared data)
#   - Admins can read/write all keys
#
# Authentication:
#   Redis has no native peer/socket auth. Instead, each user's password is
#   stored in ~/.redis_pass (chmod 600) and a system-wide alias auto-reads
#   it so users just type "redis-cli" with no password.
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/redis-config.json"

# Default values
COURSE_DB=""
ADMIN_FILE=""
REDIS_ADMIN_PASS=""

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq > /dev/null 2>&1; then
            IFS= read -r REDIS_ADMIN_PASS < <(jq -r '.redis_password // ""' "$CONFIG_FILE")
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
    fi
}

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
        --redis-password)
            REDIS_ADMIN_PASS="$2"
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
            echo "This script provisions Redis ACL users:"
            echo "  - Students: read/write own keys (<username>:*), read course keys"
            echo "  - Admins: full access to all keys"
            echo ""
            echo "Configuration is read from redis-config.json:"
            echo "  - redis_password: Redis admin password"
            echo "  - course_db: Course key prefix (required)"
            echo "  - admin_users_file: Path to admin usernames file"
            echo ""
            echo "Options:"
            echo "  --config <file>           Path to config file (default: redis-config.json)"
            echo "  --admin-users <file>      Override admin users file from config"
            echo "  --redis-password <pass>   Override Redis admin password from config"
            echo "  --add-admin <username>    Add a single admin user"
            echo "  --add-student <username>  Add a single student user"
            echo "  --help, -h                Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                          # Batch provisioning"
            echo "  $0 --add-admin jsmith       # Add single admin"
            echo "  $0 --add-student jdoe       # Add single student"
            echo ""
            echo "Students are loaded from PostgreSQL admin.students table."
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
if [[ -z "$REDIS_ADMIN_PASS" ]]; then
    echo "Redis admin password not set in config file or command-line args."
    read -s -p "Enter Redis admin password: " REDIS_ADMIN_PASS
    echo ""
    if [[ -z "$REDIS_ADMIN_PASS" ]]; then
        echo "Error: Password cannot be empty."
        exit 1
    fi
fi

if [[ -z "$COURSE_DB" ]]; then
    echo "Error: Course key prefix not set."
    echo "Set 'course_db' in $CONFIG_FILE (e.g. \"course_db\": \"msba405\")"
    exit 1
fi

# Verify Redis is running
if ! redis-cli -a "$REDIS_ADMIN_PASS" --no-auth-warning ping 2>/dev/null | grep -q "PONG"; then
    echo "Error: Cannot connect to Redis. Is Redis running?"
    echo "Run redis-bootstrap.sh first, then check: systemctl status redis-server"
    exit 1
fi

# ==============================================================================
# HELPER: Run redis-cli with admin auth
# ==============================================================================
run_redis() {
    redis-cli -a "$REDIS_ADMIN_PASS" --no-auth-warning "$@"
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
        echo "$password" | sudo tee "$user_home/.redis_pass" > /dev/null
        sudo chown "$username:$username" "$user_home/.redis_pass"
        sudo chmod 600 "$user_home/.redis_pass"
    fi
}

# ==============================================================================
# USER PROVISIONING FUNCTIONS
# ==============================================================================

provision_admin() {
    local admin="$1"

    echo "Provisioning Redis admin: $admin"

    if ! id "$admin" &>/dev/null; then
        echo "Warning: Unix user '$admin' does not exist. Skipping."
        return
    fi

    local password
    password=$(openssl rand -base64 16)

    # Create ACL user with full access
    # ~* = all keys, &* = all channels, +@all = all commands
    run_redis ACL SETUSER "$admin" on ">$password" "~*" "&*" "+@all" > /dev/null

    # Store password for passwordless access
    store_user_password "$admin" "$password"

    echo "Created Redis admin user: $admin (passwordless via ~/.redis_pass)"
}

provision_student() {
    local student="$1"

    echo "Provisioning Redis student: $student"

    if ! id "$student" &>/dev/null; then
        echo "Warning: Unix user '$student' does not exist. Skipping."
        return
    fi

    local password
    password=$(openssl rand -base64 16)

    # Create ACL user with:
    #   ~<username>:*   = read/write their own keyspace
    #   ~<course>:*     = read-only access to course data (%R = read-only pattern)
    #   +@all           = all commands allowed (restricted by key patterns)
    #   -@admin         = no admin commands (CONFIG, DEBUG, etc.)
    #   -@dangerous     = no dangerous commands (FLUSHALL, FLUSHDB, SHUTDOWN, etc.)
    run_redis ACL SETUSER "$student" on ">$password" \
        "~${student}:*" \
        "%R~${COURSE_DB}:*" \
        "&*" \
        "+@all" "-@admin" "-@dangerous" > /dev/null

    # Store password for passwordless access
    store_user_password "$student" "$password"

    echo "Created Redis student user: $student (passwordless via ~/.redis_pass)"
}

# ==============================================================================
# SYSTEM-WIDE REDIS-CLI ALIAS (passwordless access)
# ==============================================================================
setup_redis_alias() {
    echo "Setting up system-wide redis-cli alias..."
    sudo tee /etc/profile.d/redis.sh > /dev/null <<'PROFILE_EOF'
#!/bin/bash
# Redis - Passwordless Authentication
# Reads per-user password from ~/.redis_pass and auto-authenticates
_REDIS_PASS_FILE="$HOME/.redis_pass"

if [[ -f "$_REDIS_PASS_FILE" ]]; then
    _REDIS_PASS=$(cat "$_REDIS_PASS_FILE")
    alias redis-cli="redis-cli --user $USER --pass $_REDIS_PASS --no-auth-warning"
    unset _REDIS_PASS
fi

unset _REDIS_PASS_FILE
PROFILE_EOF
    sudo chmod 644 /etc/profile.d/redis.sh
    echo "System-wide redis-cli alias configured in /etc/profile.d/redis.sh"
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
    # 1. Provision Admins
    # -------------------------------------------------------------------------
    for admin in "${ADMINS[@]}"; do
        provision_admin "$admin"
    done

    # -------------------------------------------------------------------------
    # 2. Provision Students
    # -------------------------------------------------------------------------
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
    # 3. Persist ACL to disk
    # -------------------------------------------------------------------------
    echo "Saving ACL configuration to disk..."
    run_redis ACL SAVE > /dev/null

    # -------------------------------------------------------------------------
    # 4. Setup system-wide redis-cli alias for passwordless access
    # -------------------------------------------------------------------------
    setup_redis_alias

    echo ""
    echo "=============================================="
    echo "Redis Batch Provisioning Complete"
    echo "=============================================="
    echo ""
    echo "Summary:"
    echo "  - Course key prefix: ${COURSE_DB}:*"
    echo "  - Admins provisioned: ${#ADMINS[@]}"
    echo "  - Students provisioned: ${#STUDENTS[@]}"
    echo ""
    echo "Key Namespace Convention:"
    echo "  - Student private keys:  <username>:*  (e.g. jdoe:mykey)"
    echo "  - Course shared keys:    ${COURSE_DB}:*  (read-only for students)"
    echo ""
    echo "Passwordless Access:"
    echo "  Users can simply run 'redis-cli' — no password required!"
    echo "  Credentials stored in ~/.redis_pass (per-user, chmod 600)"
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

    if [[ "$INTERACTIVE_TYPE" == "admin" ]]; then
        provision_admin "$INTERACTIVE_USERNAME"
    elif [[ "$INTERACTIVE_TYPE" == "student" ]]; then
        provision_student "$INTERACTIVE_USERNAME"
    fi

    # Persist ACL to disk
    run_redis ACL SAVE > /dev/null

    # Update alias
    setup_redis_alias

    echo ""
    echo "User '$INTERACTIVE_USERNAME' provisioned successfully!"
    echo "They can now run 'redis-cli' — no password required."
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

echo "=============================================="
echo "Redis - User Provisioning"
echo "=============================================="
echo ""

if [[ "$MODE" == "interactive" ]]; then
    provision_interactive
else
    provision_batch
fi
