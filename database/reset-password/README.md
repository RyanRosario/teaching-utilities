# Password Reset Application

A Node.js web application for self-service Unix password resets.

## Prerequisites

- Node.js (v14 or higher)
- npm
- PostgreSQL (running locally or accessible via network)
- Nginx (for reverse proxy)
- `sudo` access to run `passwd` command

## Installation

### 1. Copy to /opt

```bash
sudo cp -r reset-password /opt/password-reset
cd /opt/password-reset
sudo chown -R root:root /opt/password-reset
```

### 2. Install Dependencies

```bash
cd /opt/password-reset
sudo npm install
```

## Configuration

### Edit `config.json`

Update the configuration file with your specific settings:

```json
{
  "courseName": "CS 143",
  "appUrl": "https://reset.cs143.org",
  "port": 3000,
  "email": {
    "host": "smtp.gmail.com",
    "port": 587,
    "secure": false,
    "auth": {
      "user": "your-email@gmail.com",
      "pass": "your-app-password"
    },
    "from": "CS 143 <noreply@cs143.org>"
  },
  "database": {
    "host": "localhost",
    "port": 5432,
    "user": "ryan",
    "password": "your-db-password",
    "database": "admin",
    "ssl": false
  }
}
```

**Configuration Options:**
- `courseName`: Display name for the course (shown in emails and UI)
- `appUrl`: Public URL where the app is hosted (used in email links)
- `port`: Internal port the Node.js app listens on
- `email`: SMTP configuration for sending password reset emails
- `database`: PostgreSQL connection settings

### Sudo Permissions

The application uses `sudo passwd <username>` to change passwords. The user running the Node.js application must have permission to run this command without a password prompt.

Edit the sudoers file:
```bash
sudo visudo
```

Add this line (assuming the app runs as `www-data`):
```
www-data ALL=(root) NOPASSWD: /usr/bin/passwd
```

## Running the Application

### Option 1: Direct Execution (Testing)

```bash
cd /opt/password-reset
node app.js
```

### Option 2: Systemd Service (Production)

Create `/etc/systemd/system/password-reset.service`:

```ini
[Unit]
Description=Password Reset Service
After=network.target postgresql.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/password-reset
ExecStart=/usr/bin/node /opt/password-reset/app.js
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

Enable and start the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable password-reset
sudo systemctl start password-reset
sudo systemctl status password-reset
```

## Nginx Configuration

### 1. Install Nginx

```bash
sudo apt update
sudo apt install nginx
```

### 2. Create Site Configuration

Copy the sample configuration:
```bash
sudo cp /opt/password-reset/nginx-sample.conf /etc/nginx/sites-available/password-reset
sudo ln -s /etc/nginx/sites-available/password-reset /etc/nginx/sites-enabled/
```

Edit `/etc/nginx/sites-available/password-reset` and update the `server_name` to match your domain.

### 3. Test and Reload Nginx

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## SSL Certificate with Let's Encrypt

### 1. Install Certbot

```bash
sudo apt install certbot python3-certbot-nginx
```

### 2. Obtain Certificate

Replace `reset.cs143.org` with your actual domain:
```bash
sudo certbot --nginx -d reset.cs143.org
```

Follow the prompts to:
- Enter your email address
- Agree to terms of service
- Choose whether to redirect HTTP to HTTPS (recommended: Yes)

### 3. Auto-Renewal

Certbot automatically sets up a cron job for renewal. Test it:
```bash
sudo certbot renew --dry-run
```

## Troubleshooting

### Database Connection
- Verify PostgreSQL is running: `sudo systemctl status postgresql`
- Check credentials in `config.json`
- Ensure `pg_hba.conf` allows connections from localhost

### Email Not Sending
- Check SMTP credentials
- For Gmail, use an App Password (not your regular password)
- Check firewall allows outbound port 587

### Permission Denied for passwd
- Verify sudoers entry is correct
- Check the user running the service matches the sudoers entry

### Nginx 502 Bad Gateway
- Ensure the Node.js app is running: `sudo systemctl status password-reset`
- Check the port in `config.json` matches the nginx `proxy_pass` port
