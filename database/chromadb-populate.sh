#!/bin/bash
# ==============================================================================
# ChromaDB - User Provisioning Script
# ==============================================================================
# This script provisions ChromaDB user environments:
#   - Creates per-student tenants and databases for isolation
#   - Stores auth token in ~/.chroma_token for each user
#   - Creates a Python helper script at ~/.chromadb_connect.py
#   - System-wide environment variable via /etc/profile.d
#
# ChromaDB uses a single shared server token for authentication.
# User isolation is achieved via separate tenants and databases.
# Each student gets:
#   - Their own tenant (named after username)
#   - A personal database within that tenant
#   - A read-only connection config for the course tenant
#
# Prerequisites: Run chromadb-bootstrap.sh first.
# Students are read from PostgreSQL admin.students table.
# Admins are read from a text file (one username per line).
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/chromadb-config.json"

COURSE_DB=""
ADMIN_FILE=""
CHROMA_HOST="127.0.0.1"
CHROMA_PORT=8000
CHROMA_SERVER_TOKEN=""

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq > /dev/null 2>&1; then
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
        fi
    fi
}

load_config

# ==============================================================================
# ARGUMENT PARSING
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
            echo "This script provisions ChromaDB user environments:"
            echo "  - Per-student tenants and databases for isolation"
            echo "  - Auth token stored in ~/.chroma_token for each user"
            echo "  - Python connection helper at ~/.chromadb_connect.py"
            echo ""
            echo "Configuration is read from chromadb-config.json:"
            echo "  - course_db: Course database/tenant name (e.g. cs143)"
            echo "  - admin_users_file: Path to admin usernames file"
            echo ""
            echo "Options:"
            echo "  --config <file>          Path to config file"
            echo "  --admin-users <file>     Override admin users file"
            echo "  --add-admin <username>   Add a single admin user"
            echo "  --add-student <username> Add a single student user"
            echo "  --help, -h              Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                              # Batch provisioning"
            echo "  $0 --add-admin jsmith            # Add single admin"
            echo "  $0 --add-student jdoe            # Add single student"
            echo ""
            echo "Students are loaded from PostgreSQL admin.students table."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
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

# Read server token
if [[ -f /etc/chromadb-server-token ]]; then
    CHROMA_SERVER_TOKEN=$(cat /etc/chromadb-server-token)
else
    echo "Error: Server token not found at /etc/chromadb-server-token"
    echo "Run chromadb-bootstrap.sh first."
    exit 1
fi

if [[ -z "$COURSE_DB" ]]; then
    echo "Error: Course database name not set."
    echo "Set 'course_db' in $CONFIG_FILE (e.g. \"course_db\": \"cs143\")"
    exit 1
fi

# Read server config
if [[ -f /etc/chromadb/server.json ]]; then
    CHROMA_PORT=$(jq -r '.port // 8000' /etc/chromadb/server.json)
fi

CHROMA_URL="http://${CHROMA_HOST}:${CHROMA_PORT}"
AUTH_HEADER="Authorization: Bearer ${CHROMA_SERVER_TOKEN}"

# Verify ChromaDB is running
if ! curl -sf "${CHROMA_URL}/api/v1/heartbeat" -H "$AUTH_HEADER" > /dev/null 2>&1; then
    # Try v2 API
    if ! curl -sf "${CHROMA_URL}/api/v2/heartbeat" -H "$AUTH_HEADER" > /dev/null 2>&1; then
        echo "Error: Cannot connect to ChromaDB at ${CHROMA_URL}"
        echo "Ensure ChromaDB is running (systemctl status chromadb)."
        exit 1
    fi
fi
echo "ChromaDB connection verified."

# ==============================================================================
# HELPER: Create tenant and database via Python
# ==============================================================================
create_tenant_and_database() {
    local tenant="$1"
    local database="$2"

    /opt/chromadb/venv/bin/python3 - <<PYEOF
import chromadb
from chromadb.config import Settings
import sys

try:
    admin_client = chromadb.AdminClient(Settings(
        chroma_server_host="${CHROMA_HOST}",
        chroma_server_http_port=${CHROMA_PORT},
        chroma_client_auth_provider="chromadb.auth.token_authn.TokenAuthClientProvider",
        chroma_client_auth_credentials="${CHROMA_SERVER_TOKEN}",
        chroma_auth_token_transport_header="Authorization",
    ))

    # Create tenant
    try:
        admin_client.create_tenant("${tenant}")
        print(f"Created tenant: ${tenant}")
    except Exception as e:
        if "already exists" in str(e).lower() or "UniqueConstraint" in str(e):
            print(f"Tenant '${tenant}' already exists.")
        else:
            print(f"Warning creating tenant: {e}")

    # Create database within tenant
    try:
        admin_client.create_database("${database}", tenant="${tenant}")
        print(f"Created database: ${database} in tenant: ${tenant}")
    except Exception as e:
        if "already exists" in str(e).lower() or "UniqueConstraint" in str(e):
            print(f"Database '${database}' already exists in tenant '${tenant}'.")
        else:
            print(f"Warning creating database: {e}")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ==============================================================================
# STORE USER TOKEN AND CONNECTION HELPER
# ==============================================================================
store_user_token() {
    local username="$1"
    local user_home

    user_home=$(eval echo "~$username")
    if [[ ! -d "$user_home" ]]; then
        return
    fi

    # Store token
    echo "$CHROMA_SERVER_TOKEN" | sudo tee "$user_home/.chroma_token" > /dev/null
    sudo chown "$username:$username" "$user_home/.chroma_token"
    sudo chmod 600 "$user_home/.chroma_token"
}

create_connection_helper() {
    local username="$1"
    local is_admin="$2"
    local user_home

    user_home=$(eval echo "~$username")
    if [[ ! -d "$user_home" ]]; then
        return
    fi

    # Create Python connection helper
    cat > "$user_home/.chromadb_connect.py" <<HELPER_EOF
"""
ChromaDB Connection Helper
Generated by chromadb-populate.sh — do not edit manually.

Usage:
    from chromadb_connect import get_client, get_course_client

    # Connect to your personal database
    client = get_client()
    collection = client.get_or_create_collection("my_vectors")

    # Connect to the course database (read-only for students)
    course_client = get_course_client()
"""
import chromadb
from chromadb.config import Settings
import os

def _read_token():
    token_file = os.path.expanduser("~/.chroma_token")
    with open(token_file) as f:
        return f.read().strip()

def get_client():
    """Connect to your personal ChromaDB tenant/database."""
    return chromadb.HttpClient(
        host="${CHROMA_HOST}",
        port=${CHROMA_PORT},
        tenant="${username}",
        database="default",
        settings=Settings(
            chroma_client_auth_provider="chromadb.auth.token_authn.TokenAuthClientProvider",
            chroma_client_auth_credentials=_read_token(),
            chroma_auth_token_transport_header="Authorization",
        ),
    )

def get_course_client():
    """Connect to the course (${COURSE_DB}) tenant/database."""
    return chromadb.HttpClient(
        host="${CHROMA_HOST}",
        port=${CHROMA_PORT},
        tenant="${COURSE_DB}",
        database="default",
        settings=Settings(
            chroma_client_auth_provider="chromadb.auth.token_authn.TokenAuthClientProvider",
            chroma_client_auth_credentials=_read_token(),
            chroma_auth_token_transport_header="Authorization",
        ),
    )
HELPER_EOF

    sudo chown "$username:$username" "$user_home/.chromadb_connect.py"
    sudo chmod 644 "$user_home/.chromadb_connect.py"
}

# ==============================================================================
# USER PROVISIONING
# ==============================================================================
provision_admin() {
    local admin="$1"

    echo "Provisioning admin: $admin"

    if ! id "$admin" &>/dev/null; then
        echo "Warning: Unix user '$admin' does not exist. Skipping."
        return
    fi

    # Admins use the course tenant and their personal tenant
    create_tenant_and_database "$admin" "default"

    # Store token and connection helper
    store_user_token "$admin"
    create_connection_helper "$admin" "true"

    echo "Admin '$admin' provisioned."
}

provision_student() {
    local student="$1"

    echo "Provisioning student: $student"

    if ! id "$student" &>/dev/null; then
        echo "Warning: Unix user '$student' does not exist. Skipping."
        return
    fi

    # Create personal tenant and database
    create_tenant_and_database "$student" "default"

    # Store token and connection helper
    store_user_token "$student"
    create_connection_helper "$student" "false"

    echo "Student '$student' provisioned."
}

# ==============================================================================
# SYSTEM-WIDE ENVIRONMENT
# ==============================================================================
setup_profile() {
    echo "Setting up system-wide ChromaDB environment..."

    cat > /etc/profile.d/chromadb.sh <<'PROFILE_EOF'
#!/bin/bash
# ChromaDB — auto-configure environment for each user
if [[ -f "$HOME/.chroma_token" ]]; then
    export CHROMA_TOKEN=$(cat "$HOME/.chroma_token")
    export CHROMA_TENANT="$USER"
    export CHROMA_DATABASE="default"

    # Add connection helper to Python path
    if [[ -f "$HOME/.chromadb_connect.py" ]]; then
        export PYTHONPATH="$HOME:${PYTHONPATH}"
    fi
fi
PROFILE_EOF
    chmod 644 /etc/profile.d/chromadb.sh
    echo "System-wide ChromaDB profile configured."
}

# ==============================================================================
# BATCH PROVISIONING
# ==============================================================================
provision_batch() {
    echo "Starting batch provisioning..."

    # Read admin usernames
    declare -a ADMINS=()
    if [[ -n "$ADMIN_FILE" && -f "$ADMIN_FILE" ]]; then
        while IFS= read -r username || [ -n "$username" ]; do
            username=$(echo "$username" | tr -d '\r' | xargs)
            if [[ -n "$username" && ! "$username" == \#* ]]; then
                ADMINS+=("$username")
            fi
        done < "$ADMIN_FILE"
        echo "Loaded ${#ADMINS[@]} admins from $ADMIN_FILE"
    fi

    # Read students from PostgreSQL
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

    # Create course tenant
    echo ""
    echo "Setting up course tenant '$COURSE_DB'..."
    create_tenant_and_database "$COURSE_DB" "default"

    # Provision admins
    echo ""
    echo "Provisioning admins..."
    for admin in "${ADMINS[@]}"; do
        provision_admin "$admin"
    done

    # Provision students
    echo ""
    echo "Provisioning students..."
    for student in "${STUDENTS[@]}"; do
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

    # Setup profile
    setup_profile

    echo ""
    echo "=============================================="
    echo "ChromaDB Batch Provisioning Complete"
    echo "=============================================="
    echo ""
    echo "Summary:"
    echo "  - Course tenant: $COURSE_DB"
    echo "  - Admins provisioned: ${#ADMINS[@]}"
    echo "  - Students provisioned: ${#STUDENTS[@]}"
    echo ""
    echo "Isolation Model:"
    echo "  Each user gets their own tenant with a 'default' database."
    echo "  All users share the same auth token (ChromaDB limitation)."
    echo "  Isolation is enforced by directing each user to their tenant."
    echo ""
    echo "Student Usage:"
    echo "  from chromadb_connect import get_client, get_course_client"
    echo "  client = get_client()          # personal tenant"
    echo "  course = get_course_client()   # course tenant"
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

    # Ensure course tenant exists
    create_tenant_and_database "$COURSE_DB" "default"

    if [[ "$INTERACTIVE_TYPE" == "admin" ]]; then
        provision_admin "$INTERACTIVE_USERNAME"
        echo "Admin '$INTERACTIVE_USERNAME' provisioned successfully!"
    elif [[ "$INTERACTIVE_TYPE" == "student" ]]; then
        provision_student "$INTERACTIVE_USERNAME"
        echo "Student '$INTERACTIVE_USERNAME' provisioned successfully!"
    fi

    setup_profile
}

# ==============================================================================
# MAIN
# ==============================================================================

echo "=============================================="
echo "ChromaDB - User Provisioning"
echo "=============================================="
echo ""

if [[ "$MODE" == "interactive" ]]; then
    provision_interactive
else
    provision_batch
fi
