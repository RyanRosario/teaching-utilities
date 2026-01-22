#!/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." 
   exit 1
fi

# Parse arguments
# Usage: ./create-users.sh [ADMIN_FILE] [ROSTER_FILE] [--recreate]
ADMIN_FILE=""
ROSTER_FILE=""
RECREATE=false

# Simple argument parsing loop
for arg in "$@"; do
    if [[ "$arg" == "--recreate" ]]; then
        RECREATE=true
    elif [[ -z "$ADMIN_FILE" && ! "$arg" == --* ]]; then
        ADMIN_FILE="$arg"
    elif [[ -z "$ROSTER_FILE" && ! "$arg" == --* ]]; then
        ROSTER_FILE="$arg"
    fi
done

if [[ -z "$ADMIN_FILE" ]]; then
    # At least one file is usually expected, but technically we could support optional.
    # User said "accept two files".
    echo "Usage: $0 <admin_csv> <student_roster_csv> [--recreate]"
    exit 1
fi
if [[ ! -f "$ADMIN_FILE" ]]; then
     echo "Error: Admin File '$ADMIN_FILE' not found."
     exit 1
fi
if [[ -n "$ROSTER_FILE" && ! -f "$ROSTER_FILE" ]]; then
     echo "Error: Roster File '$ROSTER_FILE' not found."
     exit 1
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


# Helper functions for Username Generation
USERNAME_MAX=8
declare -a PROPOSED_USERNAMES=()

sanitize_username() {
    local s="${1-}"
    # Lowercase, keep a-z0-9_, trim
    s=$(echo "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]//g')
    printf '%s' "${s:0:$USERNAME_MAX}"
}

is_taken() {
    local uname="$1"
    
    # Check batch collisions first
    for u in "${PROPOSED_USERNAMES[@]}"; do
        [[ "$u" == "$uname" ]] && return 0
    done

    # Check system
    if id "$uname" &>/dev/null; then 
         if [ "$RECREATE" = true ]; then
             return 1 # Not taken (will be overwritten)
         fi
         return 0 # Taken
    fi

    return 1
}

propose_username() {
    local first="$1"
    local last="$2"
    local f l base

    f=$(sanitize_username "$first")
    l=$(sanitize_username "$last")
    
    # Strategy: First Initial + Last Name
    base="${f:0:1}${l}"
    base="${base:0:$USERNAME_MAX}"
    
    if [[ -n "$base" ]] && ! is_taken "$base"; then
        echo "$base"
        return 0
    fi
    
    # Fallback 1: First Name only
    if [[ ${#f} -ge 3 ]] && ! is_taken "$f"; then
         echo "$f"
         return 0
    fi
    
    # Fallback 2: Last Name only
    if [[ ${#l} -ge 3 ]] && ! is_taken "$l"; then
         echo "$l"
         return 0
    fi
    
    return 1
}

# Function to process Admin File
process_admins_file() {
    local input=$1
    echo "Processing Admin File: $input"
    
    # Parsing 5 columns: username,name,password,uid,email
    while IFS=, read -r username name password uid email || [ -n "$username" ]; do
        
        # Sanitize inputs
        username=$(echo "$username" | tr -d '\r' | xargs)
        name=$(echo "$name" | tr -d '\r' | xargs)
        password=$(echo "$password" | tr -d '\r' | xargs)

        # Skip empty lines or header lines
        if [[ -z "$username" || "$username" == "username" ]]; then
            continue
        fi

        # Check if user already exists
        if id "$username" &>/dev/null; then
            if [ "$RECREATE" = true ]; then
                echo "User '$username' exists. Deleting and recreating (as requested via --recreate)..."
                if ! userdel -r "$username"; then
                     echo "Error: Failed to delete user '$username'. Skipping recreation."
                     continue
                fi
            else
                echo "Skipping '$username' (exists). Pass --recreate to overwrite."
                continue
            fi
        fi

        # Attempt to add user directly
        if output=$(useradd -m -U -s /bin/bash -c "$name" -G sudo "$username" 2>&1); then
            # Success
            CREATED_USERS+=("$username")
            echo "$username:$password" | chpasswd
            if [[ $? -ne 0 ]]; then echo "Error: Password set failed for '$username'."; rollback; fi
            chage -d 0 "$username"
            if [[ $? -ne 0 ]]; then echo "Error: Failed to force password expire for '$username'."; rollback; fi
            echo "Success: Created admin user '$username'."
        else
            RET=$?
            if [[ $RET -eq 9 ]]; then
                 echo "Warning: User '$username' already exists (useradd code 9). Skipping."
            else
                 echo "Error: Failed to create user '$username'. Output: $output"
                 rollback
            fi
        fi

    done < "$input"
}

# Function to process Student Roster
process_roster_file() {
    local input=$1
    echo "Processing Roster File: $input"
    
    # Reset batch tracking
    PROPOSED_USERNAMES=()
    declare -a P_UIDS P_NAMES P_EMAILS P_PASSWORDS

    while IFS=, read -r c1 c2 c3 c4 c5 c6 c7 rest || [ -n "$c1" ]; do
        # 1. Skip rows not matching UID pattern (NNN-NNN-NNN)
        if ! [[ "$c1" =~ ^[0-9]{3}-[0-9]{3}-[0-9]{3}$ ]]; then
            continue
        fi

        raw_uid="$c1"
        password=$(echo "$raw_uid" | tr -d '-') # Pwd = UID no dashes
        
        # Parse Name (expecting "Last, First" to split across c2, c3 due to comma)
        last_name_raw=$(echo "$c2" | tr -d '"' | xargs)
        first_names_raw=$(echo "$c3" | tr -d '"' | xargs)
        name="$first_names_raw $last_name_raw"
        email=$(echo "$c4" | xargs)
        
        # Username Parsing / Generation
        # Check c7 then c6 for potential override
        override=""
        possible_c7=$(echo "$c7" | tr -d '\r' | xargs)
        possible_c6=$(echo "$c6" | tr -d '\r' | xargs)
        
        # If c7 looks like a specific username override
        if [[ -n "$possible_c7" ]] && [[ "$possible_c7" =~ ^[a-z0-9_]+$ ]]; then
             override="$possible_c7"
        elif [[ -n "$possible_c6" ]] && [[ "$possible_c6" =~ ^[a-z0-9_]+$ ]]; then
             override="$possible_c6"
        fi

        global_uname=""
        if [[ -n "$override" ]]; then
             if ! is_taken "$override"; then
                  global_uname="$override"
             else
                  echo "Warning: Override '$override' unavailable. Generating generic username."
             fi
        fi

        if [[ -z "$global_uname" ]]; then
             global_uname=$(propose_username "$first_names_raw" "$last_name_raw")
             if [[ -z "$global_uname" ]]; then
                  echo "Error: Could not generate unique username for $name. Skipping."
                  continue
             fi
        fi

        # Add to batch
        PROPOSED_USERNAMES+=("$global_uname")
        P_UIDS+=("$raw_uid")
        P_NAMES+=("$name")
        P_EMAILS+=("$email")
        P_PASSWORDS+=("$password")
        
    done < "$input"

    # Preview
    echo ""
    echo "--- User Creation Preview (Batch Size: ${#P_UIDS[@]}) ---"
    printf "%-12s %-12s %-30s\n" "UID" "Username" "Name"
    echo "--------------------------------------------------------"
    for ((i=0; i<${#P_UIDS[@]}; i++)); do
         printf "%-12s %-12s %-30s\n" "${P_UIDS[$i]}" "${PROPOSED_USERNAMES[$i]}" "${P_NAMES[$i]}"
    done
    echo "--------------------------------------------------------"

    # Process Batch
    for ((i=0; i<${#P_UIDS[@]}; i++)); do
        u="${PROPOSED_USERNAMES[$i]}"
        n="${P_NAMES[$i]}"
        p="${P_PASSWORDS[$i]}"
        
        # Check Existence
        if id "$u" &>/dev/null; then
             if [ "$RECREATE" = true ]; then
                 echo "User '$u' exists. Deleting..."
                 userdel -r "$u" 2>/dev/null || true
             else
                 echo "Skipping existing user '$u'."
                 continue
             fi
        fi

        # Create
        if useradd -m -s /bin/bash -c "$n" "$u"; then
              CREATED_USERS+=("$u")
              echo "$u:$p" | chpasswd
              if [[ $? -ne 0 ]]; then
                   echo "Error: Password set failed for $u"; rollback;
              fi
              # Force Change
              chage -d 0 "$u"
              echo "Created system user '$u'."
        else
              echo "Error: Failed to create user '$u'"; rollback;
        fi
    done
}

# Main Execution Flow

echo "Starting user creation process..."

if [[ -n "$ADMIN_FILE" ]]; then
    process_admins_file "$ADMIN_FILE"
fi

if [[ -n "$ROSTER_FILE" ]]; then
    process_roster_file "$ROSTER_FILE"
fi

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
