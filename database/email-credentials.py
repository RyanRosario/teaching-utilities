#!/usr/bin/env python3
"""
email_credentials.py - Email username/password to students from database

Reads student data from admin.students table and sends each student their credentials.
Password is the student's University ID Number (which they already know).

Usage:
    ./email_credentials.py --config email-config.json
    ./email_credentials.py --config email-config.json --dry-run
    ./email_credentials.py --config email-config.json --test-email test@example.com

Options:
    --config FILE       Path to JSON configuration file (required)
    --dry-run           Print emails without sending
    --test-email ADDR   Send all emails to this address instead (for testing)
"""

import smtplib
import argparse
import json
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import psycopg2
import time


def generate_email_body(name, username):
    """Generate personalized email body"""
    # Handle "Last, First" or just "First Last" format
    if ',' in name:
        first_name = name.split(',')[1].strip()
    else:
        first_name = name.split()[0].strip()
    
    return f"""Hello {first_name},

Your login credentials for the course system are:

Username: {username}
Password: Your University ID Number

IMPORTANT!!! To connect to the server, or the database, you CANNOT
be connected to UCLA_WEB wifi. You MUST connect to UCLA_WIFI or eduroam.

You will be required to change your password on first login.
The new password must have lowercase, upper case, number and
special characters.

Please review the following video (https://youtu.be/A8OqdndPULw) and Lecture 5 materials to learn how the server works.

You can reset your password at any time at https://cs143.org/reset/

If you have any issues logging in, please contact the course staff
via Piazza or in office hours.

Have a great day!
Mr. Roboto, for CS 143 Course Staff
"""


def send_email(smtp_conn, from_addr, to_addr, subject, body, cc_addr=None):
    """Send email via established SMTP connection"""
    msg = MIMEMultipart()
    msg['From'] = from_addr
    msg['To'] = to_addr
    msg['Subject'] = subject
    if cc_addr:
        msg['Cc'] = cc_addr
    msg.attach(MIMEText(body, 'plain'))
    
    smtp_conn.send_message(msg)
    time.sleep(10)


def main():
    parser = argparse.ArgumentParser(description='Email credentials to students')
    parser.add_argument('--config', required=True, help='Path to JSON configuration file')
    parser.add_argument('--dry-run', action='store_true', help='Print emails without sending')
    parser.add_argument('--test-email', help='Send all emails to this address (testing)')
    
    args = parser.parse_args()
    
    # Load config file
    print(f"Loading configuration from {args.config}...")
    try:
        with open(args.config, 'r') as f:
            config = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Config file '{args.config}' not found.")
        return 1
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in config file: {e}")
        return 1
    
    # Validate required config keys
    required_keys = ['smtp_host', 'smtp_user', 'smtp_password', 'from_addr', 'db_user', 'db_password']
    missing_keys = [k for k in required_keys if k not in config]
    if missing_keys:
        print(f"ERROR: Missing required config keys: {', '.join(missing_keys)}")
        return 1
    
    # Set defaults for optional keys
    config.setdefault('smtp_port', 587)
    config.setdefault('db_host', 'localhost')
    config.setdefault('db_port', 5432)
    config.setdefault('db_name', 'admin')
    config.setdefault('subject', 'Your Course Login Credentials')
    config.setdefault('test_email', '')
    config.setdefault('dry_run', False)
    
    # CLI args override config file
    dry_run = args.dry_run or config.get('dry_run', False)
    test_email = args.test_email or config.get('test_email', '') or None
    
    # Connect to PostgreSQL
    print("Connecting to PostgreSQL...")
    db_kwargs = {
        'user': config['db_user'],
        'dbname': config['db_name'],
        'password': config['db_password'],
        'host': config['db_host'],
        'port': config['db_port']
    }
    
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
    
    # Connect to SMTP
    smtp_conn = None
    print(f"Connecting to {config['smtp_host']}:{config['smtp_port']}...")
    smtp_conn = smtplib.SMTP(config['smtp_host'], config['smtp_port'])
    smtp_conn.starttls()
    smtp_conn.login(config['smtp_user'], config['smtp_password'])
    print("Connected and authenticated.")
    
    # Send emails
    sent_count = 0
    for student in students:
        body = generate_email_body(student['name'], student['username'])
        
        if dry_run:
            # In dry-run mode, send to test_email instead of student
            if not test_email:
                print("ERROR: dry_run is enabled but test_email is not set in config.")
                return 1
            to_addr = test_email
            cc_addr = None  # No CC in dry-run
        else:
            # Real send: to student, CC the instructor
            to_addr = student['email']
            cc_addr = config['from_addr']
        
        try:
            send_email(smtp_conn, config['from_addr'], to_addr, config['subject'], body, cc_addr)
            if dry_run:
                print(f"✓ [DRY-RUN] Sent to {test_email} (would be {student['name']} <{student['email']}>)")
            else:
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
