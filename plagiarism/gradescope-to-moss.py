import argparse
import os
import sys

import pandas as pd 

METADATA_FILENAME = "submission_metadata.csv"

def parse_metadata(metadata_file: str) -> pd.DataFrame:
    metadata = pd.read_csv(metadata_file)

    student_data = ["First Name", "Last Name", "Student ID", "Email", "Submission ID"]

    # Starting with column 9 (0-indexed):
    # row i is the item score
    # row i+1 is the item weight
    # row i+2 is the item graded?
    # row i+3 is the item response
    # row i+4 is the item submitted at
    # we are only interested in item response.
    item_responses = [ metadata.columns[i] for i in range(12, len(metadata.columns), 5) ]
    columns = student_data + item_responses
    return metadata[columns]

def generate_moss_file(moss_directory: str, row: pd.Series):
    # You should write a script to remove student_id, name and email from this file
    # before sending to MOSS or any other tool.
    student_id = row["Student ID"]
    submission_id = row["Submission ID"]
    first_name = row["First Name"]
    last_name = row["Last Name"]
    email = row["Email"]

    # Create a file for the student
    # The filename should be changed to remove ID and name before sending to MOSS.
    filename = f"{student_id}-{first_name}-{last_name}.txt"
    with open(os.path.join(moss_directory, filename), "w") as f:
        f.write(f"{first_name}\n{last_name}\n{student_id}\n{email}\n\n\n\n")
        extracted_columns = row.iloc[6:]
        for index, value in extracted_columns.items():
            f.write(f"{index}\n\n{value}\n\n\n\n")
    print(f"Created Moss submission for {first_name} {last_name} ({student_id})")

def generate_moss(moss_directory: str, submissions: pd.DataFrame):
     # For each student generate one file at the root level.
    submissions.apply(lambda row: generate_moss_file(moss_directory, row), axis=1)

def main(gradescope: str, moss: str):
    # Read the metadata file
    metadata_file = os.path.join(gradescope, METADATA_FILENAME)
    if not os.path.exists(metadata_file):
        print(f"Error: {metadata_file} does not exist")
        sys.exit(1)

    metadata = parse_metadata(metadata_file)

    # Create a directory to store the Moss submissions
    os.makedirs(moss, exist_ok=True)

    generate_moss(moss, metadata)

    print("All Moss submissions created successfully")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Convert a Gradescope metadata file to a Moss submission')
    parser.add_argument('gradescope_dir', type=str, help='Path to the directory containing the submissions')
    parser.add_argument('moss_dir', type=str, help='Path to the directory where the Moss submissions will be stored')
    args = parser.parse_args()

    if not os.path.exists(args.gradescope_dir):
        print(f"Error: {args.gradescope_dir} does not exist")
        sys.exit(1)
    
    main(args.gradescope_dir, args.moss_dir)