#!/bin/bash

# Password Reset Application Setup Script
# This script installs and configures Node.js, Nginx, Certbot, and the password reset app.
# Run this AFTER psql-bootstrap.sh has set up PostgreSQL.

set -e

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "This script installs and configures the password reset application stack:"
            echo "  - Node.js (LTS via NodeSource)"
            echo "  - Nginx (with password reset app configuration)"
            echo "  - Certbot (for SSL certificates)"
            echo "  - Google Cloud Ops Agent (for GCE logging)"
            echo ""
            echo "Options:"
            echo "  --help, -h       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

echo "Starting Password Reset Application setup..."

# 1. Install Latest Node.js (via NodeSource)
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
echo "Installed Node.js version: $(node --version)"

# 2. Install Nginx
echo "Installing Nginx..."
sudo apt-get install -y nginx
sudo systemctl enable nginx
echo "Nginx installed and enabled."

# 3. Configure Nginx for Password Reset App
if [ -f /opt/reset-password/nginx-sample.conf ]; then
    echo "Configuring Nginx for password reset app..."
    sudo cp /opt/reset-password/nginx-sample.conf /etc/nginx/sites-available/reset-password
    sudo ln -sf /etc/nginx/sites-available/reset-password /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl reload nginx
    echo "Nginx configured for password reset app."
else
    echo "Note: /opt/reset-password/nginx-sample.conf not found. Skipping nginx site configuration."
    echo "You can configure Nginx manually after deploying the password reset app to /opt/reset-password."
fi

# 4. Install Certbot for SSL Certificates
echo "Installing Certbot..."
sudo apt-get install -y certbot python3-certbot-nginx
echo "Certbot installed. Run 'sudo certbot --nginx -d YOUR_DOMAIN' to obtain SSL certificate."

# 5. Install Google Cloud Ops Agent (for GCE Logging)
echo "Installing Google Cloud Ops Agent..."
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install
rm -f add-google-cloud-ops-agent-repo.sh

# 6. Configure Nginx log rotation (100 days)
echo "Configuring Nginx log retention for 100 days..."
cat <<EOF | sudo tee /etc/logrotate.d/nginx
/var/log/nginx/*.log {
    daily
    rotate 100
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 \$(cat /var/run/nginx.pid)
    endscript
}
EOF
echo "Nginx logs configured for 100-day retention."

# 7. Open HTTP/HTTPS ports in firewall (if UFW is active)
if command -v ufw > /dev/null; then
    echo "Allowing HTTP and HTTPS through UFW..."
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
fi

echo "-----------------------------------------------------"
echo "Password Reset Application Setup Complete"
echo ""
echo "Installed:"
echo "  - Node.js $(node --version)"
echo "  - Nginx"
echo "  - Certbot"
echo "  - Google Cloud Ops Agent"
echo ""
echo "Next steps:"
echo "  1. Deploy the password reset app to /opt/reset-password"
echo "  2. Run 'npm install' in /opt/reset-password"
echo "  3. Configure the app's .env file"
echo "  4. Run 'sudo certbot --nginx -d YOUR_DOMAIN' for SSL"
echo "  5. Start the app with pm2 or systemd"
echo "-----------------------------------------------------"
