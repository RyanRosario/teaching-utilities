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
                echo "Success: Created admin user '$username'."
            else
                echo "Error: User '$username' created but password update failed."
            fi
        else
            echo "Error: Failed to create user '$username'."
        fi
    fi

done < "$INPUT_FILE"

echo "User creation process complete."
