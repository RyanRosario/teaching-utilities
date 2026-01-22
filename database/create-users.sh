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

LOG_FILE="create-users.log"
# Redirect all output to log file and syslog
# logger -s sends the message to standard error as well as to the system log
exec > >(tee -a "$LOG_FILE" | logger -t create-users -s) 2>&1


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
# minlen: Minimum length of 12 characters
# minclass: Require at least 3 character classes (uppercase, lowercase, digits, special)
# retry: Allow 3 retries
set_pw_config "minlen" "12"
set_pw_config "minclass" "3"
set_pw_config "retry" "3"
set_pw_config "enforce_for_root" "1" # Optional: enforce for root actions too

echo "Starting user creation process from $INPUT_FILE..."

# Read file line by line
# IFS=, sets the delimiter to comma
# || [ -n "$username" ] ensures the last line is read even if it doesn't end with a newline
while IFS=, read -r username name password || [ -n "$username" ]; do
    
    # Trim leading/trailing whitespace
    username=$(echo "$username" | xargs)
    name=$(echo "$name" | xargs)
    password=$(echo "$password" | xargs)

    # Skip empty lines or header lines that might look like "username,name,password"
    if [[ -z "$username" || "$username" == "username" ]]; then
        continue
    fi

    # Check if user already exists
    if id "$username" &>/dev/null; then
        echo "Warning: User '$username' already exists. Skipping."
    else
        # Create user
        # -m: Create home directory if it doesn't exist
        # -s: Set default shell to bash
        # -c: Set GECOS field (Full Name)
        # -G: Add strict to secondary group 'sudo' (for admin privileges)
        # -U: Create a user group with the same name
        if useradd -m -U -s /bin/bash -c "$name" -G sudo "$username"; then
            
            # Set password using chpasswd (reads user:password from stdin)
            echo "$username:$password" | chpasswd
            
            if [[ $? -eq 0 ]]; then
                # Force password change on next login
                chage -d 0 "$username"
                echo "Success: Created admin user '$username'. Password change forced on next login."
            else
                echo "Error: User '$username' created but password update failed."
            fi
        else
            echo "Error: Failed to create user '$username'."
        fi
    fi

done < "$INPUT_FILE"

echo "User creation process complete."
