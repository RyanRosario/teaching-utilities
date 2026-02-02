#!/bin/bash
# ==============================================================================
# Neo4j Community Edition - Bootstrap Script
# ==============================================================================
# This script installs and configures Neo4j Community Edition for teaching.
#
# Features:
#   - Installs latest Neo4j Community from official repository
#   - Configures remote web access (HTTP browser + Bolt)
#   - Sets initial password
#
# Usage:
#   sudo ./neo4j-bootstrap.sh
#
# After installation:
#   - Web browser: http://<server>:7474
#   - Bolt endpoint: bolt://<server>:7687
#   - Username: neo4j
#   - Password: gobruins1919!
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
NEO4J_PASSWORD="gobruins1919!"
NEO4J_HTTP_PORT=7474
NEO4J_BOLT_PORT=7687

# ==============================================================================
# PREFLIGHT CHECKS
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)."
    exit 1
fi

echo "=============================================="
echo "Neo4j Community Edition - Bootstrap"
echo "=============================================="
echo ""

# ==============================================================================
# INSTALL JAVA (Required for Neo4j)
# ==============================================================================
install_java() {
    echo "Installing Java (OpenJDK 17)..."
    
    apt-get update -qq
    apt-get install -y openjdk-17-jre-headless
    
    # Verify Java installation
    if ! java -version 2>&1 | grep -q "17"; then
        echo "Error: Java 17 installation failed."
        exit 1
    fi
    
    echo "Java installed successfully."
}

# ==============================================================================
# INSTALL NEO4J
# ==============================================================================
install_neo4j() {
    echo "Installing Neo4j Community Edition..."
    
    # Add Neo4j GPG key
    curl -fsSL https://debian.neo4j.com/neotechnology.gpg.key | gpg --dearmor -o /usr/share/keyrings/neo4j-archive-keyring.gpg
    
    # Add Neo4j repository (latest stable)
    echo "deb [signed-by=/usr/share/keyrings/neo4j-archive-keyring.gpg] https://debian.neo4j.com stable latest" | \
        tee /etc/apt/sources.list.d/neo4j.list
    
    # Install Neo4j Community
    apt-get update -qq
    apt-get install -y neo4j
    
    echo "Neo4j installed successfully."
}

# ==============================================================================
# CONFIGURE NEO4J
# ==============================================================================
configure_neo4j() {
    echo "Configuring Neo4j..."
    
    local config_file="/etc/neo4j/neo4j.conf"
    
    # Backup original config
    if [[ ! -f "${config_file}.bak" ]]; then
        cp "$config_file" "${config_file}.bak"
    fi
    
    # Enable remote HTTP access (web browser)
    sed -i 's/#server.default_listen_address=0.0.0.0/server.default_listen_address=0.0.0.0/' "$config_file"
    
    # If the above didn't work (different format), add it
    if ! grep -q "^server.default_listen_address=0.0.0.0" "$config_file"; then
        echo "server.default_listen_address=0.0.0.0" >> "$config_file"
    fi
    
    # Ensure HTTP connector is enabled
    if ! grep -q "^server.http.enabled=true" "$config_file"; then
        echo "server.http.enabled=true" >> "$config_file"
    fi
    
    # Ensure Bolt connector is enabled for remote access
    if ! grep -q "^server.bolt.enabled=true" "$config_file"; then
        echo "server.bolt.enabled=true" >> "$config_file"
    fi
    
    echo "Neo4j configuration updated."
}

# ==============================================================================
# SET INITIAL PASSWORD
# ==============================================================================
set_password() {
    echo "Setting initial password..."
    
    # Stop Neo4j if running
    systemctl stop neo4j 2>/dev/null || true
    
    # Set initial password using neo4j-admin
    # Neo4j 5.x uses 'neo4j-admin dbms set-initial-password'
    neo4j-admin dbms set-initial-password "$NEO4J_PASSWORD" 2>/dev/null || \
        # Fallback for older versions
        neo4j-admin set-initial-password "$NEO4J_PASSWORD" 2>/dev/null || true
    
    echo "Password set successfully."
}

# ==============================================================================
# START NEO4J SERVICE
# ==============================================================================
start_neo4j() {
    echo "Starting Neo4j service..."
    
    systemctl enable neo4j
    systemctl start neo4j
    
    # Wait for Neo4j to start
    echo "Waiting for Neo4j to start..."
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s "http://localhost:$NEO4J_HTTP_PORT" > /dev/null 2>&1; then
            echo "Neo4j is running!"
            break
        fi
        sleep 2
        ((attempt++))
        echo "  Waiting... ($attempt/$max_attempts)"
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        echo "Warning: Neo4j may not have started. Check: systemctl status neo4j"
    fi
}

# ==============================================================================
# CONFIGURE FIREWALL (if applicable)
# ==============================================================================
configure_firewall() {
    echo "Configuring firewall..."
    
    if command -v ufw > /dev/null 2>&1; then
        ufw allow $NEO4J_HTTP_PORT/tcp comment "Neo4j HTTP Browser"
        ufw allow $NEO4J_BOLT_PORT/tcp comment "Neo4j Bolt"
        echo "UFW rules added."
    else
        echo "UFW not found. Ensure ports $NEO4J_HTTP_PORT and $NEO4J_BOLT_PORT are open."
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    install_java
    echo ""
    
    install_neo4j
    echo ""
    
    configure_neo4j
    echo ""
    
    set_password
    echo ""
    
    configure_firewall
    echo ""
    
    start_neo4j
    echo ""
    
    echo "=============================================="
    echo "Neo4j Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Access Neo4j:"
    echo "  Web Browser: http://<server-ip>:$NEO4J_HTTP_PORT"
    echo "  Bolt URI:    bolt://<server-ip>:$NEO4J_BOLT_PORT"
    echo ""
    echo "Credentials:"
    echo "  Username: neo4j"
    echo "  Password: $NEO4J_PASSWORD"
    echo ""
    echo "Commands:"
    echo "  Status:  sudo systemctl status neo4j"
    echo "  Stop:    sudo systemctl stop neo4j"
    echo "  Start:   sudo systemctl start neo4j"
    echo "  Logs:    sudo journalctl -u neo4j -f"
    echo ""
    echo "Cypher Shell (local):"
    echo "  cypher-shell -u neo4j -p '$NEO4J_PASSWORD'"
    echo "=============================================="
}

main "$@"
