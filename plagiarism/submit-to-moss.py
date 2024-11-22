import argparse
import configparser
import os
import sys
import mosspy

CONFIG_FILE = "plagiarism.cfg"

def submit(user_id: str, submissions: str, outdir: str, lang: str):
    m = mosspy.Moss(user_id, lang)

    print("Adding files...")
    m.addFilesByWildcard(os.path.join(submissions, "*.txt"))

    print("Sending to MOSS...")
    url = m.send(lambda file_path, display_name: print('*', end='', flush=True))
    print()

    print ("Report Url: " + url)

    report_file = "report.html" if not outdir else os.path.join(outdir, "report.html")
    report_dir = "report" if not outdir else os.path.join(outdir, "report")
    m.saveWebPage(url, report_file)

    # Download whole report locally including code diff links
    mosspy.download_report(url, report_dir, connections=8, log_level=10, on_read=lambda url: print('*', end='', flush=True))

def parse_config(config_file: str) -> str:
    # Initialize the parser
    config = configparser.ConfigParser()
    
    # Check if the configuration file exists
    if not os.path.isfile(config_file):
        print(f"Configuration file '{config_file}' not found.")
        return
    
    # Read the configuration file
    config.read(config_file)
    
    # Access values in specific sections
    if 'moss' in config:
        moss_userid = config['moss'].get('userid', 'Not specified')
    else:
        print("Section 'moss' not found in configuration.")
        print("Please provide the 'userid' in the configuration file.")
        print("userid = 0")
        sys.exit(1)
    return moss_userid

def main(user_id=None, submissions=None, outdir=None, separate_dirs=True, lang=None):
    submit(user_id, submissions, outdir, lang)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Submit student to work MOSS.")
    parser.add_argument("--user_id", type=str, help="User ID (required if file is moss.cfg missing)")
    parser.add_argument("--submissions", type=str, required=True, help="Path to the submissions directory")
    parser.add_argument("--separate_dirs", action="store_true", help="Flag to specify if each student's files are in separate directories (default: True)")
    parser.add_argument("--language", type=str, help="Language of the files.")
    parser.add_argument("--outdir", type=str, help="Output directory to store the Moss analysis results")

    # Parse arguments
    args = parser.parse_args()

    # Check if the file exists in the current directory
    config = None
    user_id = None
    if not os.path.isfile(CONFIG_FILE):
        # File doesn't exist; user_id must be provided
        if args.user_id is None:
            print("Error: 'user_id' is required when the file is missing.")
            sys.exit(1)
    else: # File exists; read the configuration
        user_id = parse_config(CONFIG_FILE)

    # Check if submissions path is provided
    if not args.submissions:
        print("Error: 'submissions' path is required.")
        sys.exit(1)

    main(user_id=user_id, submissions=args.submissions, outdir=args.outdir, separate_dirs=args.separate_dirs, lang=args.language)
