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
  },
  "mongodb": {
    "adminUser": "mongoadmin",
    "adminPass": "your-mongo-admin-password",
    "host": "127.0.0.1",
    "port": 27017,
    "caFile": "/etc/mongodb/ssl/ca.pem"
  }
}
```

**Configuration Options:**
- `courseName`: Display name for the course (shown in emails and UI)
- `appUrl`: Public URL where the app is hosted (used in email links)
- `port`: Internal port the Node.js app listens on
- `email`: SMTP configuration for sending password reset emails
- `database`: PostgreSQL connection settings
- `mongodb`: MongoDB admin credentials for password sync (optional)
  - When configured, resetting a Unix password will also update the MongoDB SCRAM password
  - This allows students to use the same password for SSH and MongoDB (DataGrip) connections

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
WorkingDirectory=/opt/reset-password
ExecStart=/usr/bin/node /opt/reset-password/app.js
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
sudo cp /opt/reset-password/nginx-sample.conf /etc/nginx/sites-available/reset-password
sudo ln -s /etc/nginx/sites-available/reset-password /etc/nginx/sites-enabled/
```

Edit `/etc/nginx/sites-available/reset-password` and update the `server_name` to match your domain.

### 3. Test and Reload Nginx

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 4. Nginx Configuration File Contents

The `nginx-sample.conf` file should look like this (update `server_name` with your domain):

```nginx
# Nginx configuration for Password Reset Application

server {
    listen 80;
    server_name reset.cs143.org;

    # Redirect HTTP to HTTPS (after certbot configures SSL)
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name reset.cs143.org;

    # SSL certificates - Certbot will populate these
    # ssl_certificate /etc/letsencrypt/live/reset.cs143.org/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/reset.cs143.org/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;
    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Logging
    access_log /var/log/nginx/password-reset.access.log;
    error_log /var/log/nginx/password-reset.error.log;

    # Proxy to Node.js application
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

**Note:** After running `certbot --nginx`, the SSL certificate lines will be automatically uncommented and configured.


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

## Configuring PostgreSQL Password Authentication

If you get authentication errors, you may need to switch PostgreSQL from peer/ident authentication to password authentication.

### Step 1: Find the pg_hba.conf File

```bash
sudo -u postgres psql -c "SHOW hba_file;"
```

It is usually located in `/etc/postgresql/<version>/main/pg_hba.conf`

### Step 2: Edit the Configuration

Open the file in your text editor:
```bash
sudo nano /etc/postgresql/<version>/main/pg_hba.conf
```
(Replace `<version>` with your PostgreSQL version, e.g., `14` or `16`)

Scroll down to the bottom until you see lines that look like this:

```
# "local" is for Unix domain socket connections only
local   all             all                                     peer
# IPv4 local connections:
host    all             all             127.0.0.1/32            ident
```

Change the authentication method (the last column) from `peer`, `ident`, or `pam` to `md5` (or `scram-sha-256` if you are on a newer version).

It should look like this to allow password logins:

```
# "local" is for Unix domain socket connections only
local   all             all                                     md5
# IPv4 local connections:
host    all             all             127.0.0.1/32            md5
```

**Note:** `md5` tells Postgres to "expect a password."

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

### Step 3: Set a Password for the Database User

If you were using PAM/Peer before, your database user might not actually have a password set yet. You must set one now.

Log in as the superuser:
```bash
sudo -u postgres psql
```

Set the password for your user (replace `your_db_user` and `new_password`):
```sql
ALTER USER your_db_user WITH PASSWORD 'new_password';
```

Exit:
```sql
\q
```

### Step 4: Restart PostgreSQL

You must restart the database for the config changes to take effect:
```bash
sudo systemctl restart postgresql
```

## Log Retention (100 Days)

To track student activity and investigate potential academic integrity violations, configure all important logs to retain for 100 days.

### 1. System Logs and auth.log (journald + rsyslog)

Edit `/etc/systemd/journald.conf`:
```bash
sudo nano /etc/systemd/journald.conf
```

Set these values:
```ini
[Journal]
Storage=persistent
MaxRetentionSec=100d
MaxFileSec=1d
```

Restart journald:
```bash
sudo systemctl restart systemd-journald
```

For rsyslog (auth.log, syslog), edit `/etc/logrotate.d/rsyslog`:
```bash
sudo nano /etc/logrotate.d/rsyslog
```

Update the configuration:
```
/var/log/syslog
/var/log/auth.log
{
    rotate 100
    daily
    missingok
    notifempty
    delaycompress
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
```

### 2. Nginx Logs

Create/edit `/etc/logrotate.d/nginx`:
```bash
sudo nano /etc/logrotate.d/nginx
```

```
/var/log/nginx/*.log {
    daily
    rotate 100
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`
    endscript
}
```

### 3. PostgreSQL Logs

Edit PostgreSQL config:
```bash
sudo nano /etc/postgresql/*/main/postgresql.conf
```

Set:
```ini
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 0
log_statement = 'all'
log_connections = on
log_disconnections = on
```

Create logrotate for PostgreSQL `/etc/logrotate.d/postgresql`:
```
/var/lib/postgresql/*/main/log/*.log {
    daily
    rotate 100
    missingok
    notifempty
    compress
    delaycompress
    su postgres postgres
}
```

Restart PostgreSQL:
```bash
sudo systemctl restart postgresql
```

### 4. Verify Log Retention

Test logrotate configuration:
```bash
sudo logrotate -d /etc/logrotate.conf
```

Check current log sizes:
```bash
du -sh /var/log/nginx/
du -sh /var/log/postgresql/
du -sh /var/log/auth.log*
```

### Important Logs for Academic Integrity

| Log File | Purpose |
|----------|---------|
| `/var/log/auth.log` | SSH logins, sudo usage, authentication attempts |
| `/var/log/nginx/*.log` | Web requests, IP addresses, timestamps |
| PostgreSQL logs | All SQL queries (with pgaudit), connections |
| `/var/log/syslog` | System events, cron jobs |
