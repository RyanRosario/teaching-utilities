#!/usr/bin/env python3
"""
email_credentials.py - Email username/password to students from database

Reads student data from admin.student table and sends each student their credentials.
Password is decrypted UID with dashes removed.

Usage:
    ./email_credentials.py --smtp-host smtp.gmail.com --smtp-port 587 \
        --smtp-user your-email@example.com --smtp-password 'your-app-password' \
        --from-addr 'Course Admin <admin@example.com>' --subject 'Your Course Login'

Options:
    --dry-run           Print emails without sending
    --test-email ADDR   Send all emails to this address instead (for testing)
    --db-host HOST      MySQL host (default: localhost)
    --db-port PORT      MySQL port (default: 3306)
    --db-user USER      MySQL user (default: root)
    --db-password PASS  MySQL password
    --db-socket PATH    MySQL socket path (alternative to host/port)
"""

import smtplib
import json
import os
import argparse
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import psycopg2
import psycopg2.extras
import time
import random

def generate_email_body(name, username):
    """Generate personalized email body"""
    return f"""Hello {name.split(',')[1]},

Your login credentials for the course system are:

Username: {username}
Password: Your University ID Number

IMPORTANT!!! To connect to the server, or the database, you CANNOT
be connected to UCLA_WEB wifi. You MUST connect to UCLA_WIFI or eduroam.

You will be required to change your password on first login.
The new password must have lowercase, upper case, number and
special characters.

Please review the following video (https://youtu.be/o-VnMvYhvo0) to learn how the server works.

You can reset your password at any time at https://cs143.org/reset/

If you have any issues logging in, please contact the course staff
via Piazza or in office hours.

Have a great day!
Mr. Roboto, for CS 143 Course Staff
"""


def send_email(smtp_conn, from_addr, to_addr, subject, body):
    """Send email via established SMTP connection"""
    msg = MIMEMultipart()
    msg['From'] = 'CS 143 Course Staff <rosario@g.ucla.edu>' # from_addr
    msg['To'] = to_addr # to_addr
    msg['Subject'] = 'CS 143 Server' # subject
    msg['Cc'] = 'rrosario@cs.ucla.edu'
    msg.attach(MIMEText(body, 'plain'))
    
    smtp_conn.send_message(msg)
    time.sleep(10)


def main():
    # 1. First pass: Check for --config argument only
    conf_parser = argparse.ArgumentParser(add_help=False)
    conf_parser.add_argument('--config', help='Path to JSON configuration file')
    args, remaining_argv = conf_parser.parse_known_args()

    # 2. Load defaults from config file if specified
    defaults = {
        'smtp_port': 587,
        'db_host': 'localhost',
        'db_port': 5432,
        'db_user': 'ryan',
        'db_password': '6j5t6dqm$',
        'subject': 'Your Course Login Credentials'
    }

    if args.config:
        if os.path.exists(args.config):
            print(f"Loading configuration from {args.config}...")
            try:
                with open(args.config, 'r') as f:
                    config_data = json.load(f)
                    defaults.update(config_data)
            except Exception as e:
                print(f"Error loading config file: {e}")
                return 1
        else:
            print(f"Error: Config file '{args.config}' not found.")
            return 1

    # 3. Main parser with defaults from config
    parser = argparse.ArgumentParser(
        description='Email credentials to students',
        parents=[conf_parser] # Include the --config arg in help
    )
    
    # helper to check if key is in defaults to avoid 'required=True' if it is provided in config
    def required_if_missing(key):
        return key not in defaults

    parser.add_argument('--smtp-host', required=required_if_missing('smtp_host'), help='SMTP server hostname')
    parser.add_argument('--smtp-port', type=int, help='SMTP port (default: 587)')
    parser.add_argument('--smtp-user', required=required_if_missing('smtp_user'), help='SMTP username')
    parser.add_argument('--smtp-password', required=required_if_missing('smtp_password'), help='SMTP password')
    parser.add_argument('--from-addr', required=required_if_missing('from_addr'), help='From address')
    parser.add_argument('--subject', help='Email subject')
    parser.add_argument('--dry-run', action='store_true', help='Print emails without sending')
    parser.add_argument('--test-email', help='Send all emails to this address (testing)')
    parser.add_argument('--db-host', help='PostgreSQL host (default: localhost)')
    parser.add_argument('--db-port', type=int, help='PostgreSQL port (default: 5432)')
    parser.add_argument('--db-user', help='PostgreSQL user (default: ryan)')
    parser.add_argument('--db-password', help='PostgreSQL password')
    parser.add_argument('--db-socket', help='PostgreSQL socket path')
    
    parser.set_defaults(**defaults)
    
    args = parser.parse_args(remaining_argv)
    
    # Connect to PostgreSQL
    print("Connecting to PostgreSQL...")
    db_kwargs = {
        'user': args.db_user,
        'dbname': 'admin', # Using 'admin' database as requested
        'password': args.db_password,
        'host': args.db_host,
        'port': args.db_port
    }
    
    if args.db_socket:
        # psycopg2 uses 'host' for unix socket directory if it starts with /
        db_kwargs['host'] = args.db_socket
    
    try:
        db = psycopg2.connect(**db_kwargs)
        cursor = db.cursor()
    except Exception as e:
        print(f"ERROR: Failed to connect to database: {e}")
        return 1
    
    # Query students from public.students
    query = """
        SELECT 
            student_name, 
            email_address, 
            username 
        FROM public.students 
        WHERE email_address IS NOT NULL AND email_address != ''
    """
    cursor.execute(query)
    rows = cursor.fetchall()
    
    students = []
    for row in rows:
        name, email, username = row
        if not all([name, email, username]):
            print(f"WARNING: Skipping incomplete row: {row}")
            continue
        
        students.append({
            'name': name,
            'email': email,
            'username': username
        })
    
    cursor.close()
    db.close()
    
    print(f"Loaded {len(students)} students from database")
    
    # Connect to SMTP (skip if dry-run)
    smtp_conn = None
    if not args.dry_run:
        print(f"Connecting to {args.smtp_host}:{args.smtp_port}...")
        smtp_conn = smtplib.SMTP(args.smtp_host, args.smtp_port)
        smtp_conn.starttls()
        smtp_conn.login(args.smtp_user, args.smtp_password)
        print("Connected and authenticated.")
    
    # Send emails
    sent_count = 0
    for student in students:
        body = generate_email_body(student['name'], student['username'])
        to_addr = args.test_email if args.test_email else student['email']
        
        if args.dry_run:
            print(f"\n{'='*70}")
            print(f"To: {to_addr}")
            print(f"Subject: {args.subject}")
            print(f"{'='*70}")
            print(body)
        else:
            try:
                send_email(smtp_conn, args.from_addr, to_addr, args.subject, body)
                print(f"✓ Sent to {student['name']} <{to_addr}>")
                sent_count += 1
            except Exception as e:
                print(f"✗ Failed to send to {student['name']} <{to_addr}>: {e}")
    
    if smtp_conn:
        smtp_conn.quit()
    
    print(f"\nComplete: {sent_count}/{len(students)} emails sent.")
    return 0


if __name__ == '__main__':
    exit(main())
