#!/bin/bash

# Percona Server for MongoDB Population Script
# This script provisions user accounts and database permissions:
#   - Creates course database: admins read/write, students read-only
#   - Creates per-student databases: each student has their own private database
#   - Generates X.509 client certificates for passwordless authentication
#
# Prerequisites: Run mongodb-bootstrap.sh first.
# Students are read from PostgreSQL admin.students table.
# Admins are read from a text file (one username per line).

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/mongodb-config.json"

# Default values
COURSE_DB=""
ADMIN_FILE=""
MONGO_ADMIN_USER="mongoadmin"
MONGO_ADMIN_PASS=""

# Certificate configuration
CERT_DIR="/etc/mongodb/ssl"
CA_CERT="$CERT_DIR/ca.pem"
CA_KEY="$CERT_DIR/ca-key.pem"
SERVER_CERT="$CERT_DIR/server.pem"
CLIENT_CERT_DIR="/etc/mongodb/client-certs"

# ==============================================================================
# LOAD CONFIG FILE
# ==============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Check if jq is available
        if command -v jq > /dev/null 2>&1; then
            MONGO_ADMIN_USER=$(jq -r '.mongo_admin_user // "mongoadmin"' "$CONFIG_FILE")
            # Use IFS read to prevent shell expansion of special characters in password
            IFS= read -r MONGO_ADMIN_PASS < <(jq -r '.mongo_admin_pass // ""' "$CONFIG_FILE")
            COURSE_DB=$(jq -r '.course_db // ""' "$CONFIG_FILE")
            local cfg_admin_file=$(jq -r '.admin_users_file // ""' "$CONFIG_FILE")
            if [[ -n "$cfg_admin_file" && -z "$ADMIN_FILE" ]]; then
                # Resolve relative path from config file location
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
        echo "Using default values. Create mongodb-config.json to configure."
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
FORCE_REGENERATE=false

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
        --mongo-admin-pass)
            MONGO_ADMIN_PASS="$2"
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
        --force|-f)
            FORCE_REGENERATE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script provisions MongoDB user accounts and databases:"
            echo "  - Course database: admins read/write, students read-only"
            echo "  - Per-student databases: <username> with read/write for owner"
            echo "  - X.509 certificates for passwordless authentication"
            echo ""
            echo "Configuration is read from mongodb-config.json:"
            echo "  - mongo_admin_user: MongoDB admin username"
            echo "  - mongo_admin_pass: MongoDB admin password"
            echo "  - course_db: Course database name (required)"
            echo "  - admin_users_file: Path to admin usernames file"
            echo ""
            echo "Options:"
            echo "  --config <file>           Path to config file (default: mongodb-config.json)"
            echo "  --admin-users <file>      Override admin users file from config"
            echo "  --mongo-admin-pass <pass> Override MongoDB admin password from config"
            echo "  --add-admin <username>    Add a single admin user (interactive mode)"
            echo "  --add-student <username>  Add a single student user (interactive mode)"
            echo "  --force, -f               Force regeneration of certificates and users"
            echo "  --help, -h                Show this help message"
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

# Validate required arguments
if [[ -z "$MONGO_ADMIN_PASS" ]]; then
    echo "MongoDB admin password not set in config file or command-line args."
    read -s -p "Enter MongoDB admin password: " MONGO_ADMIN_PASS
    echo ""
    if [[ -z "$MONGO_ADMIN_PASS" ]]; then
        echo "Error: Password cannot be empty."
        exit 1
    fi
fi

if [[ "$MONGO_ADMIN_PASS" =~ [^a-zA-Z0-9_.-] ]]; then
    echo "Warning: Admin password contains special characters."
    echo "This is OK (we use CLI flags, not URI), but may cause issues"
    echo "with other tools that embed credentials in MongoDB URIs."
fi

if [[ -z "$COURSE_DB" ]]; then
    echo "Error: Course database name not set."
    echo "Set 'course_db' in $CONFIG_FILE (e.g. \"course_db\": \"msba405\")"
    exit 1
fi

# Verify MongoDB is configured
if [[ ! -f "$CA_CERT" ]] || [[ ! -f "$SERVER_CERT" ]]; then
    echo "Error: MongoDB certificates not found."
    echo "Please run mongodb-bootstrap.sh first."
    exit 1
fi

# ==============================================================================
# HELPER: Run mongosh with admin credentials (TLS mode, password auth)
# ==============================================================================
run_mongosh() {
    local eval_cmd="$1"
    /usr/bin/mongosh --quiet \
        --host 127.0.0.1 --port 27017 \
        --tls --tlsCAFile "$CA_CERT" \
        --username "$MONGO_ADMIN_USER" \
        --password "$MONGO_ADMIN_PASS" \
        --authenticationDatabase admin \
        --eval "$eval_cmd"
}

# ==============================================================================
# CERTIFICATE GENERATION
# ==============================================================================
generate_client_cert() {
    local username="$1"
    local user_cert_dir="$CLIENT_CERT_DIR/$username"
    local user_cert="$user_cert_dir/mongodb.pem"
    
    if [[ -f "$user_cert" ]]; then
        if [[ "$FORCE_REGENERATE" == true ]]; then
            echo "Force regenerating certificate for $username..."
            sudo rm -rf "$user_cert_dir"
        else
            echo "Certificate for $username already exists. Use --force to regenerate."
            return
        fi
    fi
    
    echo "Generating client certificate for: $username"
    
    sudo mkdir -p "$user_cert_dir"
    
    # Generate user's private key and CSR
    sudo openssl genrsa -out "$user_cert_dir/key.pem" 4096
    
    # The CN must match the MongoDB username
    # MongoDB uses the full subject DN as the username for X.509 auth
    # IMPORTANT: Use different OU than server cert to avoid "internal cluster member" error
    sudo openssl req -new -key "$user_cert_dir/key.pem" -out "$user_cert_dir/user.csr" \
        -subj "/C=US/ST=California/L=Los Angeles/O=UCLA/OU=Users/CN=$username"
    
    # Create extension file for client auth
    cat << EOF | sudo tee "$user_cert_dir/client-ext.cnf"
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF
    
    # Sign with CA
    sudo openssl x509 -req -days 365 -in "$user_cert_dir/user.csr" \
        -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
        -out "$user_cert_dir/cert.pem" -extfile "$user_cert_dir/client-ext.cnf"
    
    # Combine key and cert
    sudo cat "$user_cert_dir/key.pem" "$user_cert_dir/cert.pem" | sudo tee "$user_cert" > /dev/null
    
    # Set ownership so user can read their cert
    if id "$username" &>/dev/null; then
        sudo chown -R "$username:$username" "$user_cert_dir"
        sudo chmod 700 "$user_cert_dir"
        sudo chmod 600 "$user_cert"
        
        # Create convenience symlink in user's home directory
        local user_home=$(eval echo "~$username")
        if [[ -d "$user_home" ]]; then
            sudo mkdir -p "$user_home/.mongodb"
            sudo ln -sf "$user_cert" "$user_home/.mongodb/client.pem"
            sudo ln -sf "$CA_CERT" "$user_home/.mongodb/ca.pem"
            sudo chown -R "$username:$username" "$user_home/.mongodb"
        fi
    fi
    
    # Cleanup CSR and extension file
    sudo rm -f "$user_cert_dir/user.csr" "$user_cert_dir/client-ext.cnf"
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
    
    # Generate client certificate (for local terminal access)
    generate_client_cert "$admin"
    
    # The X.509 subject DN becomes the MongoDB username (RFC 2253 format, OU=Users to avoid cluster member error)
    local subject_dn="CN=$admin,OU=Users,O=UCLA,L=Los Angeles,ST=California,C=US"
    local admin_db="$admin"
    
    # Create X.509 user with admin privileges (for local terminal access)
    # Admins get: readWriteAnyDatabase (create/manage any DB), dbAdminAnyDatabase (admin any DB)
    run_mongosh "
        db.getSiblingDB('\$external').createUser({
            user: '$subject_dn',
            roles: [
                { role: 'readWriteAnyDatabase', db: 'admin' },
                { role: 'dbAdminAnyDatabase', db: 'admin' }
            ]
        });
    " 2>/dev/null || true
    
    # Create SCRAM-SHA-256 user for remote access (DataGrip)
    if [[ -n "$password" ]]; then
        run_mongosh "
            db.getSiblingDB('admin').createUser({
                user: '$admin',
                pwd: '$password',
                roles: [
                    { role: 'readWriteAnyDatabase', db: 'admin' },
                    { role: 'dbAdminAnyDatabase', db: 'admin' }
                ]
            });
        " 2>/dev/null || true
        echo "Created SCRAM admin user for remote access: $admin"
    else
        # Create user with temporary password - admin must use password reset
        local temp_pass=$(openssl rand -base64 12)
        run_mongosh "
            db.getSiblingDB('admin').createUser({
                user: '$admin',
                pwd: '$temp_pass',
                roles: [
                    { role: 'readWriteAnyDatabase', db: 'admin' },
                    { role: 'dbAdminAnyDatabase', db: 'admin' }
                ]
            });
        " 2>/dev/null || true
        echo "Created SCRAM admin user with temp password (use password reset app): $admin"
    fi
    
    echo "Created MongoDB user for admin: $admin"
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
    
    # Generate client certificate (for local terminal access)
    generate_client_cert "$student"
    
    # RFC 2253 format DN with OU=Users to avoid cluster member error
    local subject_dn="CN=$student,OU=Users,O=UCLA,L=Los Angeles,ST=California,C=US"
    local student_db="$student"
    
    # Create student's personal database
    run_mongosh "db.getSiblingDB('$student_db').createCollection('_init');" 2>/dev/null || true
    
    # Create X.509 user for local terminal access (passwordless)
    run_mongosh "
        db.getSiblingDB('\$external').createUser({
            user: '$subject_dn',
            roles: [
                { role: 'read', db: '$COURSE_DB' },
                { role: 'readWrite', db: '$student_db' }
            ]
        });
    " 2>/dev/null || true
    
    # Create SCRAM-SHA-256 user for remote access (DataGrip)
    # Password will be synced with Unix password via password reset app
    if [[ -n "$password" ]]; then
        run_mongosh "
            db.getSiblingDB('$student_db').createUser({
                user: '$student',
                pwd: '$password',
                roles: [
                    { role: 'read', db: '$COURSE_DB' },
                    { role: 'readWrite', db: '$student_db' }
                ]
            });
        " 2>/dev/null || true
        echo "Created SCRAM user for remote access: $student"
    else
        # Create user with temporary password - student must use password reset
        local temp_pass=$(openssl rand -base64 12)
        run_mongosh "
            db.getSiblingDB('$student_db').createUser({
                user: '$student',
                pwd: '$temp_pass',
                roles: [
                    { role: 'read', db: '$COURSE_DB' },
                    { role: 'readWrite', db: '$student_db' }
                ]
            });
        " 2>/dev/null || true
        echo "Created SCRAM user with temp password (use password reset app): $student"
    fi
    
    echo "Created MongoDB user for student: $student"
}

grant_admin_access_to_student_db() {
    local admin="$1"
    local student_db="$2"
    
    local admin_subject="CN=$admin,OU=Users,O=UCLA,L=Los Angeles,ST=California,C=US"
    
    run_mongosh "
        db.getSiblingDB('\$external').grantRolesToUser('$admin_subject', [
            { role: 'readWrite', db: '$student_db' }
        ]);
    " 2>/dev/null || true
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
    echo "Setting up course database '$COURSE_DB'..."
    run_mongosh "db.getSiblingDB('$COURSE_DB').createCollection('_init');" 2>/dev/null || true
    
    # -------------------------------------------------------------------------
    # 2. Provision Admins
    # -------------------------------------------------------------------------
    for admin in "${ADMINS[@]}"; do
        provision_admin "$admin"
    done
    
    # -------------------------------------------------------------------------
    # 3. Provision Students
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
    # 4. Grant admins access to all student databases
    # -------------------------------------------------------------------------
    echo "Granting admins access to student databases..."
    for admin in "${ADMINS[@]}"; do
        for student in "${STUDENTS[@]}"; do
            grant_admin_access_to_student_db "$admin" "$student"
        done
    done
    
    # -------------------------------------------------------------------------
    # 5. Update system-wide mongosh alias
    # -------------------------------------------------------------------------
    echo "Updating system-wide mongosh alias..."
    sudo tee /etc/profile.d/mongosh.sh > /dev/null << 'PROFILE_EOF'
#!/bin/bash
_MONGO_CLIENT_CERT_DIR="/etc/mongodb/client-certs"
_MONGO_CA_CERT="/etc/mongodb/ssl/ca.pem"
_MONGO_USER_CERT="$_MONGO_CLIENT_CERT_DIR/$USER/mongodb.pem"
_MONGO_USER_DB="$USER"

if [[ -f "$_MONGO_USER_CERT" && -f "$_MONGO_CA_CERT" ]]; then
    # mongosh alias
    alias mongosh="mongosh 'mongodb://127.0.0.1:27017/${_MONGO_USER_DB}?authSource=\$external' --tls --tlsCertificateKeyFile ${_MONGO_USER_CERT} --tlsCAFile ${_MONGO_CA_CERT} --authenticationMechanism MONGODB-X509"
    
    # mongoimport alias
    alias mongoimport="mongoimport --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
    
    # mongoexport alias
    alias mongoexport="mongoexport --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
    
    # mongodump alias
    alias mongodump="mongodump --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
    
    # mongorestore alias
    alias mongorestore="mongorestore --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
fi

unset _MONGO_CLIENT_CERT_DIR _MONGO_CA_CERT _MONGO_USER_CERT _MONGO_USER_DB
PROFILE_EOF
    sudo chmod 644 /etc/profile.d/mongosh.sh
    
    echo ""
    echo "=============================================="
    echo "Batch Provisioning Complete"
    echo "=============================================="
    echo ""
    echo "Summary:"
    echo "  - Course database: $COURSE_DB"
    echo "  - Admins provisioned: ${#ADMINS[@]}"
    echo "  - Students provisioned: ${#STUDENTS[@]}"
    echo ""
    echo "Passwordless Access:"
    echo "  Users can simply run 'mongosh' - no password required!"
    echo "  Certificates stored in: $CLIENT_CERT_DIR/<username>/"
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
    run_mongosh "db.getSiblingDB('$COURSE_DB').createCollection('_init');" 2>/dev/null || true
    
    if [[ "$INTERACTIVE_TYPE" == "admin" ]]; then
        provision_admin "$INTERACTIVE_USERNAME"
        
        # Grant access to existing student databases
        echo "Granting access to existing student databases..."
        if command -v psql > /dev/null 2>&1; then
            while IFS= read -r student; do
                student=$(echo "$student" | xargs)
                if [[ -n "$student" ]]; then
                    grant_admin_access_to_student_db "$INTERACTIVE_USERNAME" "$student"
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
                    grant_admin_access_to_student_db "$admin" "$INTERACTIVE_USERNAME"
                fi
            done < "$ADMIN_FILE"
        fi
        
        echo ""
        echo "Student '$INTERACTIVE_USERNAME' provisioned successfully!"
    fi
    
    # Update system-wide mongosh alias
    echo "Updating system-wide mongosh alias..."
    sudo tee /etc/profile.d/mongosh.sh > /dev/null << 'PROFILE_EOF'
#!/bin/bash
_MONGO_CLIENT_CERT_DIR="/etc/mongodb/client-certs"
_MONGO_CA_CERT="/etc/mongodb/ssl/ca.pem"
_MONGO_USER_CERT="$_MONGO_CLIENT_CERT_DIR/$USER/mongodb.pem"
_MONGO_USER_DB="$USER"

if [[ -f "$_MONGO_USER_CERT" && -f "$_MONGO_CA_CERT" ]]; then
    # mongosh alias
    alias mongosh="mongosh 'mongodb://127.0.0.1:27017/${_MONGO_USER_DB}?authSource=\$external' --tls --tlsCertificateKeyFile ${_MONGO_USER_CERT} --tlsCAFile ${_MONGO_CA_CERT} --authenticationMechanism MONGODB-X509"
    
    # mongoimport alias
    alias mongoimport="mongoimport --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
    
    # mongoexport alias
    alias mongoexport="mongoexport --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
    
    # mongodump alias
    alias mongodump="mongodump --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
    
    # mongorestore alias
    alias mongorestore="mongorestore --ssl --sslCAFile ${_MONGO_CA_CERT} --sslPEMKeyFile ${_MONGO_USER_CERT} --authenticationDatabase '\$external' --authenticationMechanism MONGODB-X509"
fi

unset _MONGO_CLIENT_CERT_DIR _MONGO_CA_CERT _MONGO_USER_CERT _MONGO_USER_DB
PROFILE_EOF
    sudo chmod 644 /etc/profile.d/mongosh.sh
    
    echo ""
    echo "The user can now connect with: mongosh"
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

echo "=============================================="
echo "Percona Server for MongoDB - User Provisioning"
echo "=============================================="
echo ""

if [[ "$MODE" == "interactive" ]]; then
    provision_interactive
else
    provision_batch
fi
