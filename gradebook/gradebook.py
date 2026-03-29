import argparse
import configparser
import logging
import pdb
import os
import pickle
import sys
import requests
import pandas as pd
from datetime import datetime

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from google.oauth2 import service_account

from googleapiclient.discovery import build
from google.oauth2.service_account import Credentials
import io
from googleapiclient.http import MediaIoBaseUpload

CONFIG_FILE = "canvas.cfg"

def get_weighted_groups(base_url, course_id, headers):
    groups_url = f'{base_url}/api/v1/courses/{course_id}/assignment_groups'
    groups = []
    page_url = groups_url
    
    while page_url:
        response = requests.get(page_url, headers=headers)
        response.raise_for_status()
        groups.extend(response.json())
        page_url = response.links.get('next', {}).get('url')
    
    # Create set of assignment group IDs that count towards final grade # [ADDED]
    weighted_groups = {
        group['id']: (group['name'], group['group_weight']) for group in groups 
        if group.get('group_weight', 0) > 0
    }
    
    logging.info(f"Found {len(weighted_groups)} weighted assignment groups")
    return weighted_groups

def get_assignments(base_url, course_id, headers, weighted_groups):
    # Get all assignments
    assignments_url = f'{base_url}/api/v1/courses/{course_id}/assignments'
    assignments = []
    page_url = assignments_url

    while page_url:
        response = requests.get(page_url, headers=headers)
        response.raise_for_status()
        assignments.extend(response.json())
        page_url = response.links.get('next', {}).get('url')

    # Filter to only assignments in weighted groups                     # [ADDED]
    weighted_assignments = {
        a['id']: a
        for a in assignments 
        if a.get('assignment_group_id') in weighted_groups
    }
    
    logging.info(f"Found {len(weighted_assignments)} assignments in weighted groups")
    return weighted_assignments

def get_roster(base_url, course_id, headers):
    # Get sections first                                          
    sections_url = f'{base_url}/api/v1/courses/{course_id}/sections'    
    sections = []                                                       
    page_url = sections_url                                            
                                                                       
    while page_url:                                                    
        response = requests.get(page_url, headers=headers)             
        response.raise_for_status()                                    
        sections.extend(response.json())                               
        page_url = response.links.get('next', {}).get('url')          
                                                                      
    section_dict = {s['id']: s['name'] for s in sections}             

    # Get all enrollments (for section data)
    enrollments_url = f'{base_url}/api/v1/courses/{course_id}/enrollments'
    params = {
        'type[]': 'StudentEnrollment',
        'include[]': ['user', 'sis_user_id', 'sis_section_id'],              
    }
    enrollments = []
    page_url = enrollments_url
    
    while page_url:
        response = requests.get(page_url, headers=headers, params=params)
        response.raise_for_status()
        enrollments.extend(response.json())
        page_url = response.links.get('next', {}).get('url')
    
    # Determine if the course has discussion sections (section IDs ending in a letter).
    # If it does, skip students enrolled only in the lecture section (IDs ending in a number),
    # as that usually indicates an erroneous enrollment before a PTE number was assigned.
    has_discussion_sections = any(
        e.get('sis_section_id', '')[-1].isalpha() 
        for e in enrollments 
        if e.get('sis_section_id')
    )

    # Create enrollment data frame
    roster = []
    for enrollment in enrollments:
        sid = enrollment.get('sis_section_id')
        if not sid:
            continue
        if has_discussion_sections and not sid[-1].isalpha():
            continue
        student = enrollment.pop('user')
        grade_summary = enrollment.pop('grades')
        roster.append([enrollment['sis_user_id'], enrollment['sis_section_id']])
    roster = pd.DataFrame(roster, columns=['UID', 'Section'])
    return roster

def get_submissions(base_url, course_id, assignments, headers):
    # Get all student submissions with comments
    submissions_url = f'{base_url}/api/v1/courses/{course_id}/students/submissions?per_page=200'
    params = {
        'student_ids[]': 'all',
        'include[]': ['user', 'submission_comments']
    }
    submissions = []
    page_url = submissions_url
    
    while page_url:
        response = requests.get(page_url, headers=headers, params=params)
        response.raise_for_status()
        submissions.extend(response.json())
        page_url = response.links.get('next', {}).get('url')

    # Create gradebook DataFrame
    gradebook_data = []
    for submission in submissions:
        # Skip if assignment isn't in a weighted group                  # [ADDED]
        if submission['assignment_id'] not in assignments:     # [ADDED]
            continue                                                    # [ADDED]
        # Extract comments
        comments = submission.get('submission_comments', [])
        comment_text = '; '.join([f"{c['author_name']}: {c['comment']}" 
                                for c in comments]) if comments else ''
        
        record = {
            'UID': submission['user']['sis_user_id'],
            'Name': submission['user']['name'],
            'assignment_id': submission['assignment_id'],
            'Score': submission['score'],
            'submitted_at': submission['submitted_at'],
            'Excused': submission['excused'],
            'Missing': submission['missing'],
            'Late': submission['late'],
            'Comments': comment_text
        }
        gradebook_data.append(record)
    
    grades = pd.DataFrame(gradebook_data)
    return grades

def extract_canvas_gradebook(api_token, course_id, base_url):
    """
    Extracts gradebook data from Canvas LMS for a specific course.
    Args:
        api_token (str): Canvas API token
        course_id (int): Course ID to extract grades from
        base_url (str): Canvas instance URL (e.g. 'https://school.instructure.com')
    Returns:
        pandas.DataFrame: Gradebook data
    """
    headers = {'Authorization': f'Bearer {api_token}'}
    weighted_groups = get_weighted_groups(base_url, course_id, headers)
    weighted_assignments = get_assignments(base_url, course_id, headers, weighted_groups)
    roster = get_roster(base_url, course_id, headers)
    logging.info(f"Roster has {len(roster)} students")
    grades = get_submissions(base_url, course_id, weighted_assignments, headers)
    logging.info(f"Submissions has {len(grades)} records")
    
    # Add assignment data
    assignment_data = pd.DataFrame(list(weighted_assignments.values()))[['id', 'name', 'due_at', 'points_possible', 'assignment_group_id']]

    # Clean up dates and sort
    grades['submitted_at'] = pd.to_datetime(grades['submitted_at'])
    grades = grades.sort_values(['Name', 'UID', 'assignment_id'])    

    grades = roster.merge(grades, left_on='UID', right_on='UID').merge(assignment_data, left_on='assignment_id', right_on='id')
    grades = grades.rename(columns={
        'name': 'Assignment',
        'points_possible': 'PointsPossible'
    })
    
    # Map assignment_group_id to group name (Category)
    group_name_map = {gid: info[0] for gid, info in weighted_groups.items()}
    grades['Category'] = grades['assignment_group_id'].map(group_name_map)
    
    return grades, assignment_data

def parse_section(section_str):
    term, dept, crsnum, act = section_str.split('-')
    # For discussion sections like '1A', include the letter suffix.
    # For lecture-only sections like '80', just use the number.
    num_part = ''.join(c for c in act if c.isdigit())
    letter_part = act[-1] if act[-1].isalpha() else ''
    return f"sec {int(num_part)}{letter_part}"

def parse_uid(uid):
    return f"{uid[:3]}-{uid[3:6]}-{uid[6:]}"

def parse(scores: pd.DataFrame, mapping_csv_path: str):
    if mapping_csv_path:
        mapping_df = pd.read_csv(mapping_csv_path)
        mapping = dict(zip(mapping_df['Canvas'], mapping_df['Sheet']))
        # Only keep assignments that have a mapping; drop unmapped ones
        scores = scores[scores['Assignment'].isin(mapping.keys())]
        scores['Assignment'] = scores['Assignment'].apply(lambda x: mapping.get(x, x))
        # Also apply the mapping to category names (e.g., "Homework and Programming" → "HW")
        scores['Category'] = scores['Category'].apply(lambda x: mapping.get(x, x))
    

    scores['UID'] = scores['UID'].map(parse_uid)
    scores['Section'] = scores['Section'].map(parse_section)
    print(scores)
    
    # BUGFIX: If a student does not have a score because they did not take a specific form of the exam
    # toss the assignment.
    # PRECONDITION: All empty/missing grades must be set to zero.
    scores = scores.fillna({'Score': 0, 'Excused': False})
    scores['Excused'] = scores['Excused'].astype(bool)
    scores['PointsPossible'] = scores['PointsPossible'].mask(scores['Excused'], 0)
    return scores[['Name', 'UID', 'Section', 'Assignment', 'Category', 'due_at', 'Score', 'Excused', 'Late', 'Missing', 'PointsPossible', 'Comments']]
    
def create_sheet(grades):
    dfs = []
    pivotcols = ['Score', 'Excused', 'Late', 'Missing', 'PointsPossible', 'Comments']
    for col in pivotcols:
        pivoted = grades.pivot_table(
            index=['Name', 'UID', 'Section'],
            columns='Assignment',
            values=col,
            aggfunc='first'
        )
        if col != 'Score':
            pivoted.columns = [f"{col_name}_{col}" for col_name in pivoted.columns]
        dfs.append(pivoted)
    scores = pd.concat(dfs, axis=1)
    
    # Build assignment-to-category mapping and add as a '_Category' row
    # This lets replicate_tabs.py know which category each assignment belongs to
    cat_map = grades.drop_duplicates('Assignment').set_index('Assignment')['Category']
    # Get score column names (columns without suffixes)
    score_cols = [c for c in scores.columns if not any(c.endswith(f'_{s}') for s in ['Excused', 'Late', 'Missing', 'PointsPossible', 'Comments'])]
    
    # Create a category row that maps each column to its category
    cat_row = {}
    for col in scores.columns:
        base_name = col
        for suffix in ['_Excused', '_Late', '_Missing', '_PointsPossible', '_Comments']:
            if col.endswith(suffix):
                base_name = col[:len(col) - len(suffix)]
                break
        cat_row[col] = cat_map.get(base_name, '')
    
    # Build assignment-to-due_at mapping (earliest due date per assignment)
    due_map = grades.drop_duplicates('Assignment').set_index('Assignment')['due_at']
    
    # Store the category mapping and due dates as DataFrame attributes
    scores.attrs['category_map'] = dict(zip(score_cols, [cat_map.get(c, '') for c in score_cols]))
    scores.attrs['due_map'] = dict(zip(score_cols, [str(due_map.get(c, '')) for c in score_cols]))
    
    return scores

def write_dataframe_to_sheet(sheets_service, spreadsheet_id, df, sheet_name='Sheet1'):
    """
    Writes a Pandas DataFrame to a Google Sheet.

    Args:
        sheets_service: The Google Sheets API service object.
        spreadsheet_id (str): The ID of the spreadsheet.
        dataframe (pd.DataFrame): The Pandas DataFrame to write.
        sheet_name (str): The name of the sheet/tab within the spreadsheet.

    Returns:
        dict: The API response from updating the sheet.
    """
    # Convert DataFrame to a list of lists, ensuring all values are JSON-serializable.
    # numpy/pandas types (NaN, Timestamp, numpy.bool_) are not valid JSON and the
    # Sheets API silently drops them.
    dataframe = df.reset_index()
    def sanitize(val):
        if pd.isna(val):
            return ''
        if isinstance(val, (pd.Timestamp, datetime)):
            return val.isoformat()
        # Convert numpy types to native Python types
        if hasattr(val, 'item'):
            return val.item()
        return val
    
    headers = [str(c) for c in dataframe.columns.tolist()]
    rows = [[sanitize(v) for v in row] for row in dataframe.values.tolist()]
    values = [headers] + rows
    
    # Prepare the body for the API request
    body = {
        'values': values
    }

    spreadsheet = sheets_service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
    # Define the range to write data (entire sheet in this case)
    existing_sheets = [sheet['properties']['title'] for sheet in spreadsheet['sheets']]

    if sheet_name not in existing_sheets:
        # Add the sheet if it doesn't exist
        create_body = {
            "requests": [
                {
                    "addSheet": {
                        "properties": {
                            "title": sheet_name
                        }
                    }
                }
            ]
        }
        # Use the batchUpdate method to send the request
        response = sheets_service.spreadsheets().batchUpdate(
            spreadsheetId=spreadsheet_id, body=create_body
        ).execute()
        print(f"Sheet '{sheet_name}' created.")
        # return response
    else:
        print(f"Sheet '{sheet_name}' already exists.")
    range_name = f"{sheet_name}!A1"

    # Use the Sheets API to update values
    response = sheets_service.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=range_name,
        valueInputOption="RAW",  # Use "RAW" to insert data as-is, or "USER_ENTERED" for formatting
        body=body
    ).execute()

    print(f"Data written to {range_name} in spreadsheet ID: {spreadsheet_id}")
    return response

def create_google_sheet(wide, long, title, credentials_path, share_email, new=False, separate=False):
    sheet, id = get_or_create_sheet(title, credentials_path)
    share_sheet(id, credentials_path, share_email)

    # Write data to sheet
    write_dataframe_to_sheet(sheet, id, wide, sheet_name='Raw Data')
    
    # Write category mapping to a hidden 'Categories' tab
    if hasattr(wide, 'attrs') and 'category_map' in wide.attrs:
        cat_map = wide.attrs['category_map']
        due_map = wide.attrs.get('due_map', {})
        cat_data = [['Assignment', 'Category', 'DueAt']] + [[k, v, due_map.get(k, '')] for k, v in cat_map.items()]
        
        # Write using the sheets service
        spreadsheet = sheet.spreadsheets().get(spreadsheetId=id).execute()
        existing_sheets = [s['properties']['title'] for s in spreadsheet['sheets']]
        if 'Categories' not in existing_sheets:
            sheet.spreadsheets().batchUpdate(
                spreadsheetId=id,
                body={'requests': [{'addSheet': {'properties': {'title': 'Categories'}}}]}
            ).execute()
        
        sheet.spreadsheets().values().clear(
            spreadsheetId=id, range="'Categories'!A1:ZZ1000"
        ).execute()
        sheet.spreadsheets().values().update(
            spreadsheetId=id,
            range="'Categories'!A1",
            valueInputOption='RAW',
            body={'values': cat_data}
        ).execute()
        logging.info(f"Wrote {len(cat_map)} category mappings to 'Categories' tab")
    
    return sheet, id

def get_or_create_sheet(spreadsheet_name, credentials_path):
    # Set up credentials and service
    SCOPES = [
        'https://www.googleapis.com/auth/drive',
        'https://www.googleapis.com/auth/spreadsheets'
    ]
    creds = service_account.Credentials.from_service_account_file(
        credentials_path, scopes=SCOPES)
    
    # Initialize the Sheets and Drive API services
    sheets_service = build('sheets', 'v4', credentials=creds)
    drive_service = build('drive', 'v3', credentials=creds)
    
    try:
        # Use the Drive API to search for the spreadsheet by name
        query = f"name = '{spreadsheet_name}' and mimeType = 'application/vnd.google-apps.spreadsheet'"
        response = drive_service.files().list(
            q=query,
            spaces='drive',
            fields='files(id, name)',
            pageSize=1
        ).execute()
        files = response.get('files', [])
        
        if files:
            # Spreadsheet exists
            spreadsheet_id = files[0]['id']
            logging.info(f"Found existing sheet: {spreadsheet_name} (ID: {spreadsheet_id})")
        else:
            # Spreadsheet does not exist, create it
            sheet_metadata = sheets_service.spreadsheets().create(body={
                'properties': {'title': spreadsheet_name}
            }).execute()
            spreadsheet_id = sheet_metadata['spreadsheetId']
            logging.info(f"Created new sheet: {spreadsheet_name} (ID: {spreadsheet_id})")
        
        return sheets_service, spreadsheet_id
    except Exception as e:
        logging.error(f"An error occurred: {e}")
        return None, None

def share_sheet(spreadsheet_id, credentials_path, share_email):
    # Scopes for Google Sheets and Drive API
    SCOPES = ['https://www.googleapis.com/auth/drive', 'https://www.googleapis.com/auth/spreadsheets']

    # Authenticate using the service account
    credentials = Credentials.from_service_account_file(
        credentials_path, 
        scopes=SCOPES
    )
    drive_service = build('drive', 'v3', credentials=credentials)

    permissions = {
    'type': 'user',        # Can be 'user', 'group', 'domain', or 'anyone'
    'role': 'writer',      # Can be 'owner', 'writer', or 'reader'
    'emailAddress': share_email
    }

    # Add permissions
    drive_service.permissions().create(
        fileId=spreadsheet_id,
        body=permissions,
        fields='id'
    ).execute()


def main():
    parser = argparse.ArgumentParser(description='Extract Canvas gradebook data')
    parser.add_argument('course_id', type=int, help='Canvas course ID')
    parser.add_argument('--title', type=str, help='Output spreadsheet filename')
    parser.add_argument('--new', action='store_true', help='Create new spreadsheet')
    parser.add_argument('--separate', action='store_true', help='Create separate sheets per assignment')
    parser.add_argument('--mapping', type=str, help='Column name mapping')

    args = parser.parse_args()

    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)
    
    token = config.get('canvas', 'token')
    course_id = args.course_id
    base_url = config.get('canvas', 'base_url')
    
    # Read sheets configuration
    try:
        credentials_path = config.get('sheets', 'service_account_file')
        share_email = config.get('sheets', 'share_email')
    except (configparser.NoSectionError, configparser.NoOptionError):
        logging.error("Missing [sheets] configuration in config file. Please specify service_account_file and share_email.")
        sys.exit(-1)

    logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

    # Get gradebook data
    grades = extract_canvas_gradebook(token, course_id, base_url)
    grades = parse(grades[0], args.mapping)
    completed = create_sheet(grades)
    desktop = os.path.expanduser("~/Desktop")
    with open(os.path.join(desktop, "grades-completed.pkl"), "wb") as g:
        pickle.dump(completed, g)
    with open(os.path.join(desktop, "grades.pkl"), "wb") as g:
        pickle.dump(grades, g)
    with open(os.path.join(desktop, "grades-completed.pkl"), "rb") as g:
        completed = pickle.load(g)
    with open(os.path.join(desktop, "grades.pkl"), "rb") as g:
        grades = pickle.load(g)

    # title = title if args.title else create_title(course_id)
    if not args.title:
        logging.error("Title is required")
        sys.exit(-1)
    temp = create_google_sheet(completed, grades, args.title, credentials_path, share_email, args.new, args.separate)

if __name__ == '__main__':
    main()


# Sample Canvas API call
# wget --header="Authorization: Bearer TOKEN" "https://<canvas_domain>/api/v1/courses/<course_id>/enrollments?type[]=StudentEnrollment&include[]=user&include[]=sis_user_id&include[]=section" -O enrollments.json
