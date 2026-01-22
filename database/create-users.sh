#!/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." 
   exit 1
fi

INPUT_FILE=$1

# Validations
if [[ -z "$INPUT_FILE" ]]; then
    echo "Usage: $0 <path_to_user_csv>"
    echo "CSV Format: username,name,password"
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' not found."
    exit 1
fi

# Parse arguments
RECREATE=false
if [[ "$2" == "--recreate" ]]; then
    RECREATE=true
fi

LOG_FILE="create-users.log"
# Redirect all output to log file and syslog
# logger -s sends the message to standard error as well as to the system log
exec > >(tee -a "$LOG_FILE" >(logger -t create-users)) 2>&1


# Install libpam-pwquality for password complexity enforcement
# This ensures that when users change their password (enforced below), they must pick a strong one.
if ! dpkg -s libpam-pwquality >/dev/null 2>&1; then
    echo "Installing libpam-pwquality..."
    apt-get update && apt-get install -y libpam-pwquality
fi

# Configure Password Quality (System-wide)
# modifying /etc/security/pwquality.conf
PW_CONF="/etc/security/pwquality.conf"

echo "Configuring secure password requirements in $PW_CONF..."

# Function to ensure a config key-value pair exists
set_pw_config() {
    local key=$1
    local value=$2
    if grep -q "^#\?${key}\s*=" "$PW_CONF"; then
        sed -i "s/^#\?${key}\s*=.*$/${key} = ${value}/" "$PW_CONF"
    else
        echo "${key} = ${value}" >> "$PW_CONF"
    fi
}

# Enforce secure policies:
# enforce_for_root: 0 allows the admin (running this script) to set initial passwords
# that might not pass the strict checks (e.g. simple temp passwords).
set_pw_config "enforce_for_root" "0"

# Note: We do NOT set minlen/minclass yet. If they are already set in the file from a previous run,
# we might need to relax them temporarily if the initial passwords in CSV are weak.
# dictionary check can also fail even if len is 1 (e.g. if password is a word).
# enforcing=0 should stop the module from rejecting the password even if checks fail.
# dictcheck=0 stops the module from even performing the dictionary check (silencing the warning).
set_pw_config "minlen" "1"
set_pw_config "minclass" "1"
set_pw_config "enforcing" "0"
set_pw_config "dictcheck" "0"

# Enable SSH Password Authentication
# This ensures that created users can actually log in using the passwords we just set.
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    echo "Enabling SSH PasswordAuthentication..."
    # Ensure PasswordAuthentication is set to yes
    if grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" "$SSHD_CONFIG"
    elif grep -q "^#\?PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" "$SSHD_CONFIG"
    else
        echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
    fi

    # Ensure UsePAM is yes (Critical for chage -d 0 password expiry handling)
    if grep -q "^UsePAM" "$SSHD_CONFIG"; then
         sed -i "s/^UsePAM.*/UsePAM yes/" "$SSHD_CONFIG"
    else
         echo "UsePAM yes" >> "$SSHD_CONFIG"
    fi
    
    # Restart SSH service into ensure these changes take effect
    if systemctl is-active --quiet ssh; then
        systemctl restart ssh
    elif systemctl is-active --quiet sshd; then
        systemctl restart sshd
    fi
else
    echo "Warning: $SSHD_CONFIG not found. Skipping SSH configuration."
fi

echo "Starting user creation process from $INPUT_FILE..."

# Array to track created users for rollback
CREATED_USERS=()

# Rollback function to delete users created in this session on failure
rollback() {
    echo "!!! ERROR ENCOUNTERED. ROLLING BACK !!!"
    echo "cleaning up ${#CREATED_USERS[@]} users..."
    for user in "${CREATED_USERS[@]}"; do
        echo "Removing user: $user"
        userdel -r "$user" || echo "Failed to remove user: $user"
    done
    echo "Rollback complete. Exiting."
    exit 1
}

# Trap any uncaught error (though we handle most manually below)
# We might not want a strict trap on ERR because valid checks like `id $username` return non-zero
# So we will rely on manual calls to rollback in the critical section.


# Read file line by line
# IFS=, sets the delimiter to comma
# || [ -n "$username" ] ensures the last line is read even if it doesn't end with a newline
# Parsing 5 columns: username,name,password,uid,email
while IFS=, read -r username name password uid email || [ -n "$username" ]; do
    
    # Trim leading/trailing whitespace and remove carriage returns (fix for Windows/DOS CSVs)
    # xargs trims whitespace, tr -d '\r' removes the hidden return char that breaks passwords
    username=$(echo "$username" | tr -d '\r' | xargs)
    name=$(echo "$name" | tr -d '\r' | xargs)
    password=$(echo "$password" | tr -d '\r' | xargs)

    # Skip empty lines or header lines that might look like "username,name,password"
    if [[ -z "$username" || "$username" == "username" ]]; then
        continue
    fi

    # Check if user already exists
    if id "$username" &>/dev/null; then
        if [ "$RECREATE" = true ]; then
            echo "User '$username' exists. Deleting and recreating (as requested via --recreate)..."
            # userdel -r removes home dir and mail spool
            if ! userdel -r "$username"; then
                 echo "Error: Failed to delete user '$username'. Skipping recreation."
                 continue
            fi
            # User deleted, proceed to creation below
        else
            echo "Skipping '$username' (exists). Pass --recreate to overwrite."
            continue
        fi
    fi

    # Attempt to add user directly (EAFP: Easier to Ask for Forgiveness than Permission)
    # capturing output to handle errors cleanly
    if output=$(useradd -m -U -s /bin/bash -c "$name" -G sudo "$username" 2>&1); then
        # Success (Exit code 0)
        # Track user immediately for rollback
        CREATED_USERS+=("$username")

        # Set password
        echo "$username:$password" | chpasswd
        if [[ $? -ne 0 ]]; then
            echo "Error: Password set failed for '$username'."
            rollback
        fi

        # Force password change
        chage -d 0 "$username"
        if [[ $? -ne 0 ]]; then
             echo "Error: Failed to force password expire for '$username'."
             rollback
        fi
        
        echo "Success: Created admin user '$username'."

    else
        # useradd failed, check exit code
        RET=$?
        if [[ $RET -eq 9 ]]; then
             # Exit code 9 = username already in use
             echo "Warning: User '$username' already exists (useradd code 9). Skipping."
        else
             # Genuine error
             echo "Error: Failed to create user '$username'. Output: $output"
             rollback
        fi
    fi

done < "$INPUT_FILE"

echo "All users processed."

# Now that users are created with their initial (potentially weak) passwords,
# we ENFORCE the strict policy for future password changes.
echo "Enforcing strict password policies (min 8 chars, 3 classes) for future changes..."
set_pw_config "minlen" "8"
set_pw_config "minclass" "3"
set_pw_config "retry" "3"
set_pw_config "enforcing" "1"
set_pw_config "dictcheck" "1"

echo "User creation process complete."
