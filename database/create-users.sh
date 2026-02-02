#!/bin/bash

# Exit on error (be careful with this, we handle some errors manually)
# set -e 

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)." 
   exit 1
fi

# ==============================================================================
# 1. SETUP & PATHING
# ==============================================================================

# Get the directory where this script is stored (for calling sibling scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="create-users.log"
exec > >(tee -a "$LOG_FILE" >(logger -t create-users)) 2>&1

# Parse arguments
ADMIN_FILE=""
ROSTER_FILE=""
RECREATE=false
SKIP_POSTGRES=false

for arg in "$@"; do
    if [[ "$arg" == "--recreate" ]]; then RECREATE=true;
    elif [[ "$arg" == "--no-postgres" ]]; then SKIP_POSTGRES=true;
    elif [[ "$arg" == "--add-admin" ]]; then MODE="interactive_admin"; NEXT_IS_INTERACTIVE_USER=true;
    elif [[ "$arg" == "--add-student" ]]; then MODE="interactive_student"; NEXT_IS_INTERACTIVE_USER=true;
    elif [[ "$arg" == "--admin" ]]; then NEXT_IS_ADMIN=true;
    elif [[ "$arg" == "--roster" ]]; then NEXT_IS_ROSTER=true;
    elif [[ "$NEXT_IS_INTERACTIVE_USER" == true ]]; then INTERACTIVE_USERNAME="$arg"; NEXT_IS_INTERACTIVE_USER=false;
    elif [[ "$NEXT_IS_ADMIN" == true ]]; then ADMIN_FILE="$arg"; NEXT_IS_ADMIN=false;
    elif [[ "$NEXT_IS_ROSTER" == true ]]; then ROSTER_FILE="$arg"; NEXT_IS_ROSTER=false;
    elif [[ -z "$MODE" && -z "$ADMIN_FILE" && ! "$arg" == --* ]]; then ADMIN_FILE="$arg";
    elif [[ -z "$MODE" && -z "$ROSTER_FILE" && ! "$arg" == --* ]]; then ROSTER_FILE="$arg";
    fi
done

# Auto-detect file types (Heuristic)
guess_file_type() {
    local f=$1
    if [[ ! -f "$f" ]]; then echo "unknown"; return; fi
    local h=$(head -n 1 "$f")
    if [[ "$h" =~ ^Term: ]] || [[ "$h" =~ ^UID, ]]; then echo "roster";
    elif [[ "$h" =~ ^username, ]]; then echo "admin";
    else echo "unknown"; fi
}

if [[ -n "$ADMIN_FILE" && -z "$ROSTER_FILE" ]]; then
    if [[ "$(guess_file_type "$ADMIN_FILE")" == "roster" ]]; then
        echo "Note: Detected student roster in first argument. Proceeding in Roster mode."
        ROSTER_FILE="$ADMIN_FILE"; ADMIN_FILE=""
    fi
elif [[ -n "$ADMIN_FILE" && -n "$ROSTER_FILE" ]]; then
    if [[ "$(guess_file_type "$ADMIN_FILE")" == "roster" && "$(guess_file_type "$ROSTER_FILE")" == "admin" ]]; then
         echo "Note: Detected swapped Admin/Roster files. Auto-correcting."
         tmp="$ADMIN_FILE"; ADMIN_FILE="$ROSTER_FILE"; ROSTER_FILE="$tmp"
    fi
fi

if [[ -z "$ADMIN_FILE" && -z "$ROSTER_FILE" && -z "$MODE" ]]; then
    echo "Usage: $0 [options] [files]"
    exit 1
fi

# ==============================================================================
# 2. SECURITY CONFIGURATION & TRAPS
# ==============================================================================

PW_CONF="/etc/security/pwquality.conf"

set_pw_config() {
    local key=$1
    local value=$2
    if grep -q "^#\?${key}\s*=" "$PW_CONF"; then
        sed -i "s/^#\?${key}\s*=.*$/${key} = ${value}/" "$PW_CONF"
    else
        echo "${key} = ${value}" >> "$PW_CONF"
    fi
}

# Define a cleanup function to restore security settings even on crash
restore_security_settings() {
    echo "Restoring/Enforcing strict password policies..."
    set_pw_config "minlen" "8"
    set_pw_config "minclass" "3"
    set_pw_config "retry" "3"
    set_pw_config "enforcing" "1"
    set_pw_config "dictcheck" "1"
    set_pw_config "enforce_for_root" "1" # Re-enable root enforcement if desired
}

# Trap EXIT to ensure security settings are always restored
trap restore_security_settings EXIT

# Install libpam-pwquality
if ! dpkg -s libpam-pwquality >/dev/null 2>&1; then
    echo "Installing libpam-pwquality..."
    apt-get update && apt-get install -y libpam-pwquality
fi

echo "Temporarily relaxing password requirements for bulk creation..."
set_pw_config "enforce_for_root" "0"
set_pw_config "minlen" "1"
set_pw_config "minclass" "1"
set_pw_config "enforcing" "0"
set_pw_config "dictcheck" "0"

# SSH Configuration
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    echo "Ensuring SSH PasswordAuthentication is enabled..."
    
    # 1. PasswordAuth: Uncomment/Update existing line
    if grep -q "^#\?PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" "$SSHD_CONFIG"
    else
        # Only append if it doesn't exist at all
        echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
    fi

    # 2. UsePAM: Uncomment/Update existing line
    if grep -q "^#\?UsePAM" "$SSHD_CONFIG"; then
         sed -i "s/^#\?UsePAM.*/UsePAM yes/" "$SSHD_CONFIG"
    else
         echo "UsePAM yes" >> "$SSHD_CONFIG"
    fi
    
    if systemctl is-active --quiet ssh; then systemctl restart ssh; fi
fi

# ==============================================================================
# 3. USER CREATION LOGIC
# ==============================================================================

CREATED_USERS=()

rollback() {
    echo "!!! ERROR ENCOUNTERED. ROLLING BACK !!!"
    for user in "${CREATED_USERS[@]}"; do
        echo "Removing user: $user"
        userdel -r "$user" || true
    done
    exit 1
}

USERNAME_MAX=8
declare -a PROPOSED_USERNAMES=()

sanitize_username() {
    local s="${1-}"
    s=$(echo "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]//g')
    printf '%s' "${s:0:$USERNAME_MAX}"
}

is_taken() {
    local uname="$1"
    # Check current batch
    for u in "${PROPOSED_USERNAMES[@]}"; do [[ "$u" == "$uname" ]] && return 0; done
    # Check system
    if id "$uname" &>/dev/null; then 
         [ "$RECREATE" = true ] && return 1 
         return 0 
    fi
    return 1
}

propose_username() {
    local first="$1"
    local last="$2"
    local f l base
    f=$(sanitize_username "$first")
    l=$(sanitize_username "$last")
    
    base="${f:0:1}${l}"; base="${base:0:$USERNAME_MAX}"
    if [[ -n "$base" ]] && ! is_taken "$base"; then echo "$base"; return 0; fi
    
    if [[ ${#f} -ge 3 ]] && ! is_taken "$f"; then echo "$f"; return 0; fi
    if [[ ${#l} -ge 3 ]] && ! is_taken "$l"; then echo "$l"; return 0; fi
    return 1
}

process_admins_file() {
    local input=$1
    while IFS=, read -r username name password uid email || [ -n "$username" ]; do
        username=$(echo "$username" | tr -d '\r' | xargs)
        name=$(echo "$name" | tr -d '\r' | xargs)
        password=$(echo "$password" | tr -d '\r' | xargs)

        if [[ -z "$username" || "$username" == "username" ]]; then continue; fi

        if id "$username" &>/dev/null; then
            if [ "$RECREATE" = true ]; then
                userdel -r "$username" 2>/dev/null || true
            else
                echo "Skipping existing admin '$username'."
                continue
            fi
        fi

        if useradd -m -U -s /bin/bash -c "$name" -G sudo "$username"; then
            CREATED_USERS+=("$username")
            echo "$username:$password" | chpasswd
            if [[ $? -ne 0 ]]; then rollback; fi
            echo "Created admin '$username'."
        else
            rollback
        fi
    done < "$input"
}

process_roster_file() {
    local input=$1
    PROPOSED_USERNAMES=()
    declare -a P_UIDS P_NAMES P_PASSWORDS

    while IFS=, read -r c1 c2 c3 c4 c5 c6 c7 rest || [ -n "$c1" ]; do
        if ! [[ "$c1" =~ ^[0-9]{3}-[0-9]{3}-[0-9]{3}$ ]]; then continue; fi

        raw_uid="$c1"
        password=$(echo "$raw_uid" | tr -d '-')
        last_name_raw=$(echo "$c2" | tr -d '"' | xargs)
        first_names_raw=$(echo "$c3" | tr -d '"' | xargs)
        name="$first_names_raw $last_name_raw"

        global_uname=$(propose_username "$first_names_raw" "$last_name_raw")
        
        if [[ -z "$global_uname" ]]; then
             echo "Error: Could not generate username for $name. Skipping."
             continue
        fi

        PROPOSED_USERNAMES+=("$global_uname")
        P_UIDS+=("$raw_uid")
        P_NAMES+=("$name")
        P_PASSWORDS+=("$password")
    done < "$input"

    for ((i=0; i<${#P_UIDS[@]}; i++)); do
        u="${PROPOSED_USERNAMES[$i]}"
        n="${P_NAMES[$i]}"
        p="${P_PASSWORDS[$i]}"
        
        if id "$u" &>/dev/null; then
             if [ "$RECREATE" = true ]; then
                 userdel -r "$u" 2>/dev/null || true
             else
                 continue
             fi
        fi

        if useradd -m -s /bin/bash -c "$n" "$u"; then
              CREATED_USERS+=("$u")
              echo "$u:$p" | chpasswd
              if [[ $? -ne 0 ]]; then rollback; fi
              chage -d 0 "$u"
              echo "Created student '$u'."
        else
              rollback
        fi
    done
}

# ==============================================================================
# 4. EXECUTION
# ==============================================================================

if [[ -n "$ADMIN_FILE" ]]; then process_admins_file "$ADMIN_FILE"; fi
if [[ -n "$ROSTER_FILE" ]]; then process_roster_file "$ROSTER_FILE"; fi

# Interactive Blocks
if [[ "$MODE" == "interactive_admin" ]]; then
     if [[ -z "$INTERACTIVE_USERNAME" ]]; then read -rp "Enter Admin Username: " u; else u="$INTERACTIVE_USERNAME"; fi
     read -rp "Enter Real Name: " n
     read -s -rp "Enter Initial Password: " p; echo
     read -rp "Enter UID: " i
     read -rp "Enter Email: " e
     
     t=$(mktemp)
     echo "$u,$n,$p,$i,$e" > "$t"
     process_admins_file "$t"
     
     if [[ "$SKIP_POSTGRES" != true && -f "$SCRIPT_DIR/postgres-populate.sh" ]]; then
          "$SCRIPT_DIR/postgres-populate.sh" --admin "$t"
     fi
     rm "$t"
fi

if [[ "$MODE" == "interactive_student" ]]; then
     if [[ -z "$INTERACTIVE_USERNAME" ]]; then read -rp "Enter Username: " username; else username="$INTERACTIVE_USERNAME"; fi
     read -rp "Enter Full Name: " name
     read -rp "Enter Student UID: " uid
     read -rp "Enter Email: " email
     
     if id "$username" &>/dev/null && [ "$RECREATE" != true ]; then echo "User exists."; exit 1; fi
     [ "$RECREATE" == true ] && userdel -r "$username" 2>/dev/null || true
     
     password=$(echo "$uid" | tr -d '-')
     useradd -m -s /bin/bash -c "$name" "$username"
     echo "$username:$password" | chpasswd
     chage -d 0 "$username"
     
     if [[ "$SKIP_POSTGRES" != true && -f "$SCRIPT_DIR/postgres-populate.sh" ]]; then
          "$SCRIPT_DIR/postgres-populate.sh" --add-student "$username" --name "$name" --uid "$uid" --email "$email"
     fi
fi

# ==============================================================================
# 5. POSTGRES TRIGGER (BATCH) & CLEANUP
# ==============================================================================

# Note: Security settings are restored automatically by the 'trap' defined earlier

if [[ "$SKIP_POSTGRES" != true && -f "$SCRIPT_DIR/postgres-populate.sh" ]]; then
    if [[ -n "$ADMIN_FILE" || -n "$ROSTER_FILE" ]]; then
         echo "Triggering Postgres population..."
         CMD="$SCRIPT_DIR/postgres-populate.sh"
         if [[ -n "$ADMIN_FILE" ]]; then CMD="$CMD --admin \"$ADMIN_FILE\""; fi
         if [[ -n "$ROSTER_FILE" ]]; then CMD="$CMD --roster \"$ROSTER_FILE\""; fi
         eval "$CMD"
    fi
fi

echo "Done."