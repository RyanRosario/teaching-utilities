#!/usr/bin/env python3

"""Retrieve GitHub user information using a Personal Access Token.
This script can be run from the command line and supports
both token input and environment variable usage.
It also includes a verbose mode for additional details.
"""

__author__      = "Ryan R. Rosario"

import argparse
import sys
import os
from github import Github, GithubException

def get_github_user_info(token):
    """
    Retrieve GitHub user information using the provided token.
    
    :param token: GitHub Personal Access Token
    :return: Github user object or None if request fails
    """
    try:
        # Create a Github instance with the token
        g = Github(token)
        
        # Get the authenticated user
        user = g.get_user()
        
        return user
    
    except GithubException as gh_err:
        if gh_err.status == 401:
            print("Error: Invalid or expired token. Authentication failed.", file=sys.stderr)
        elif gh_err.status == 403:
            print("Error: Token lacks necessary permissions or rate limit exceeded.", file=sys.stderr)
        else:
            print(f"GitHub error occurred: {gh_err}", file=sys.stderr)
    
    except Exception as err:
        print(f"An unexpected error occurred: {err}", file=sys.stderr)
    
    return None

def main():
    # Set up argument parser
    parser = argparse.ArgumentParser(description='Retrieve GitHub user information using a Personal Access Token')
    
    # Add mutually exclusive group for token input
    token_group = parser.add_mutually_exclusive_group(required=True)
    token_group.add_argument('-t', '--token', 
                             help='GitHub Personal Access Token')
    token_group.add_argument('-e', '--env', 
                             action='store_true', 
                             help='Use GITHUB_TOKEN environment variable')

    # Add optional verbosity flag
    parser.add_argument('-v', '--verbose', 
                        action='store_true', 
                        help='Display additional user details')

    # Parse arguments
    args = parser.parse_args()

    # Determine token source
    if args.env:
        token = os.environ.get('GITHUB_TOKEN')
        if not token:
            print("Error: GITHUB_TOKEN environment variable is not set.", file=sys.stderr)
            sys.exit(1)
    else:
        token = args.token

    # Get user information
    user = get_github_user_info(token)
    
    if user:
        # Always print these core details
        print(f"Username: {user.login}")
        print(f"Name: {user.name or 'Not provided'}")
        
        # Print additional details if verbose flag is set
        if args.verbose:
            print("\nAdditional Details:")
            print(f"Email: {user.email or 'Not provided'}")
            print(f"Company: {user.company or 'Not provided'}")
            print(f"Location: {user.location or 'Not provided'}")
            print(f"Public Repos: {user.public_repos}")
            print(f"Followers: {user.followers}")
            print(f"Following: {user.following}")
            print(f"Total Private Repos: {user.total_private_repos}")
            print(f"Owned Private Repos: {user.owned_private_repos}")
            print(f"Account Type: {user.type}")
    else:
        sys.exit(1)

if __name__ == '__main__':
    main()