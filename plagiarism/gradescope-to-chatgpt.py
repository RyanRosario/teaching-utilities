import argparse
import configparser
import os
import pdb
import re
import sys


import pandas as pd  # 

from openai import OpenAI

CONFIG_FILE = "plagiarism.cfg"
METADATA_FILENAME = "submission_metadata.csv"
PROBABILITY = r"Probability:\s*(([0-9]*\.?[0-9]+))"


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
    if 'chatgpt' in config:
        oai_org = config['chatgpt'].get('organization', 'Not specified')
        oai_token = config['chatgpt'].get('project', 'Not specified')
    else:
        print("Section 'chatgpt' not found in configuration.")
        sys.exit(1)
    return oai_org, oai_token

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

def chatgpt(cell, client):
    completion = client.chat.completions.create(
    model="gpt-4o",
    messages=[
        {
            "role": "system",
            "content": "What is the probability that the following text came from ChatGPT? At the end of your response, print a line that contains only the word 'Probability: ' followed by the probability score on a scale from 0 to 1."
        },
        {
            "role": "user",
            "content": """
{}
            """.format(cell)
        }
    ])
    return completion


def generate_chatgpt(client, submissions: pd.DataFrame):
    # For each student generate one file at the root level.
    results = []
    narratives = []
    series_names = None
    for index, row in submissions.iterrows():
        extracted_columns = row.iloc[6:]
        subject = extracted_columns.iloc[2:6]
        series_names_scores = [colname.replace('Response', 'ChatGPT Score') for colname in subject.index]
        series_names_narratives = [colname.replace('Response', 'ChatGPT Response') for colname in subject.index]
        response = [chatgpt(column, client) for column in subject]
        messages = [response[i].choices[0].message.content for i in range(len(response))]
        match = [re.search(PROBABILITY, el).group(1) for el in messages]
        results.append(match)
        narratives.append(messages)
    scores = pd.DataFrame(results, columns=series_names_scores)
    responses = pd.DataFrame(narratives, columns=series_names_narratives)
    return pd.concat([submissions, scores, responses], axis=1)


def main(gradescope: str, outfile: str, org: str, project: str):
    client = OpenAI(
        organization=org,
        api_key=project
    )
    # Read the metadata file
    metadata_file = os.path.join(gradescope, METADATA_FILENAME)
    if not os.path.exists(metadata_file):
        print(f"Error: {metadata_file} does not exist")
        sys.exit(1)

    metadata = parse_metadata(metadata_file)
    results = generate_chatgpt(client, metadata)
    results.to_csv(outfile, index=False)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Check a Gradescope web assignment with ChatGPT')
    parser.add_argument('gradescope_dir', type=str, help='Path to the directory containing the submissions')
    parser.add_argument('outfile', type=str, help='File where the results will be stored')
    args = parser.parse_args()

    if not os.path.exists(args.gradescope_dir):
        print(f"Error: {args.gradescope_dir} does not exist")
        sys.exit(1)

        # Check if the file exists in the current directory
    org = None
    project = None
    if not os.path.isfile(CONFIG_FILE):
        print("Error: OpenAI ChatGPT authentication credentials must be in config file.")
    else: # File exists; read the configuration
        org, project = parse_config(CONFIG_FILE)
    
    main(args.gradescope_dir, args.outfile, org, project)