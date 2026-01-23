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
import argparse
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import MySQLdb
import time
import random

def generate_email_body(name, username, password):
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
    time.sleep(random.randint(50, 65))


def main():
    parser = argparse.ArgumentParser(description='Email credentials to students')
    parser.add_argument('--smtp-host', required=True, help='SMTP server hostname')
    parser.add_argument('--smtp-port', type=int, default=587, help='SMTP port (default: 587)')
    parser.add_argument('--smtp-user', required=True, help='SMTP username')
    parser.add_argument('--smtp-password', required=True, help='SMTP password')
    parser.add_argument('--from-addr', required=True, help='From address (e.g. "Admin <admin@example.com>")')
    parser.add_argument('--subject', default='Your Course Login Credentials', help='Email subject')
    parser.add_argument('--dry-run', action='store_true', help='Print emails without sending')
    parser.add_argument('--test-email', help='Send all emails to this address (testing)')
    parser.add_argument('--db-host', default='localhost', help='MySQL host (default: localhost)')
    parser.add_argument('--db-port', type=int, default=3306, help='MySQL port (default: 3306)')
    parser.add_argument('--db-user', default='root', help='MySQL user (default: root)')
    parser.add_argument('--db-password', help='MySQL password')
    parser.add_argument('--db-socket', help='MySQL socket path')
    
    args = parser.parse_args()
    
    # Connect to MySQL
    print("Connecting to MySQL...")
    db_kwargs = {
        'user': args.db_user,
        'db': 'admin'
    }
    
    if args.db_password:
        db_kwargs['passwd'] = args.db_password
    
    if args.db_socket:
        db_kwargs['unix_socket'] = args.db_socket
    else:
        db_kwargs['host'] = args.db_host
        db_kwargs['port'] = args.db_port
    
    try:
        db = MySQLdb.connect(**db_kwargs)
        cursor = db.cursor()
    except Exception as e:
        print(f"ERROR: Failed to connect to database: {e}")
        return 1
    
    # Query students with AES_DECRYPT in SQL
    query = """
        SELECT 
            CAST(AES_DECRYPT(UNHEX(hashed_university_id), '5549829') AS CHAR) as decrypted_uid,
            student_name, 
            email_address, 
            username 
        FROM student 
        WHERE email_address IS NOT NULL AND email_address != ''
    """
    cursor.execute(query)
    rows = cursor.fetchall()
    
    students = []
    for row in rows:
        uid, name, email, username = row
        if not all([uid, name, email, username]):
            print(f"WARNING: Skipping incomplete row: {row}")
            continue
        
        password = str(uid).replace('-', '')
        students.append({
            'name': name,
            'email': email,
            'username': username,
            'password': password
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
        body = generate_email_body(student['name'], student['username'], student['password'])
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
