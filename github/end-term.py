#!/usr/bin/env python

"""End of term procesing for a Github organization.

(1) Clones all repositories for backup
(2) Deletes all repositories
(3) Deletes all teams
(4) Removes all non-owner users

This script requires a personal access token, and the author
recommends using a dummy account for this purpose.
"""

__author__      = "Ryan R. Rosario"

import datetime
from github import Github
import configparser
import os
import time
import git
import argparse


def load_from_file(filename):
    """Load items from a file, one per line."""
    if not filename or not os.path.exists(filename):
        return []
    
    with open(filename, 'r') as f:
        return [line.strip() for line in f if line.strip()]


def clone_org_repos(org_name, token, dest_dir="repos"):
    g = Github(token)
    org = g.get_organization(org_name)
    username = g.get_user().login
    print("Hello, {}!".format(username))
    
    if not os.path.exists(dest_dir):
        os.makedirs(dest_dir)
    
    # Get paginated list of repos and iterate
    repos = org.get_repos(type='all')
    for repo in repos:
        print(f"Processing repository: {repo.name}")
        if repo.archived:  # Skip archived repos
            continue
            
        if g.get_rate_limit().core.remaining < 100:
            reset_time = g.get_rate_limit().core.reset
            sleep_time = (reset_time - datetime.datetime.now()).seconds + 60
            time.sleep(sleep_time)
        
        repo_path = os.path.join(dest_dir, repo.name)
        if not os.path.exists(repo_path):
            git.Repo.clone_from(
                repo.clone_url.replace("https://", f"https://{token}@"),
                repo_path
            )
        time.sleep(2)


def delete_org_repos(org_name, token, include_repos=None, ignore_owner_check=False):
    g = Github(token)
    org = g.get_organization(org_name)
    
    # Get list of owners
    owners = set(org.get_members(role="admin"))
    owner_logins = {owner.login for owner in owners}
    
    # Get all repos
    repos = org.get_repos(type='all')
    
    for repo in repos:
        print(f"\nProcessing: {repo.name}")
        
        # Only delete repos from include list, or all if include_repos is empty
        if include_repos and repo.name not in include_repos:
            print(f"Skipping repo not in include list: {repo.name}")
            continue
            
        # Skip if no admin access
        if not repo.permissions.admin:
            print(f"Skipping {repo.name} - insufficient permissions")
            continue
        
        try:
            # Check if any owners are collaborators on this repo (unless ignore_owner_check is True)
            if not ignore_owner_check:
                collaborators = set(repo.get_collaborators())
                collaborator_logins = {collab.login for collab in collaborators}
                
                if owner_logins.intersection(collaborator_logins):
                    print(f"Skipping {repo.name} - contains organization owners as collaborators")
                    continue
                    
            print(f"Deleting repository: {repo.name}")
            repo.delete()
            time.sleep(2)  # Be nice to the API
        except Exception as e:
            print(f"Error deleting {repo.name}: {e}")


def remove_non_owners(org_name, token, delete_users=None):
    # Authenticate with the provided token
    g = Github(token)
    org = g.get_organization(org_name)

    print(f"Processing organization: {org.login}")
    
    # Get all members of the organization
    members = org.get_members(role="member")
    
    for member in members:
        try:
            # Only delete specified users, or remove all non-owners if delete_users is empty
            if delete_users and member.login not in delete_users:
                print(f"Keeping user not in delete list: {member.login}")
                continue
                
            # Remove member
            print(f"Removing member: {member.login}")
            org.remove_from_membership(member)
            time.sleep(2)  # Pause to respect rate limits
            
        except Exception as e:
            print(f"Error processing {member.login}: {e}")


def delete_teams(org_name, token, include_teams=None, ignore_owner_check=False):
    g = Github(token)
    org = g.get_organization(org_name)
   
    print(f"Processing organization: {org.login}")
   
    # Get list of owners
    owners = set(org.get_members(role="admin"))
   
    # Get all teams
    teams = org.get_teams()
   
    for team in teams:
        # Only delete teams from include list, or all if include_teams is empty
        if include_teams and team.name not in include_teams:
            print(f"Keeping team not in delete list: {team.name}")
            continue
            
        try:
            # Check if any owners are in this team (unless ignore_owner_check is True)
            if not ignore_owner_check:
                team_members = set(team.get_members())
                
                if team_members.intersection(owners):
                    print(f"Skipping team '{team.name}' as it contains owners")
                    continue
               
            print(f"Deleting team: {team.name}")
            team.delete()
            time.sleep(1)
           
        except Exception as e:
            print(f"Error processing team {team.name}: {e}")


def main():
    # Set up command line arguments
    parser = argparse.ArgumentParser(description='Clone and clean up GitHub organization repositories')
    parser.add_argument('--config', default='config.cfg', help='Path to configuration file')
    parser.add_argument('--user-file', help='File containing usernames to DELETE (one per line)')
    parser.add_argument('--team-file', help='File containing team names to DELETE (one per line)')
    parser.add_argument('--repo-file', help='File containing repository names to DELETE (one per line)')
    
    # Add flags for each stage
    parser.add_argument('--clone-only', action='store_true', help='Only clone repositories')
    parser.add_argument('--delete-repos-only', action='store_true', help='Only delete repositories')
    parser.add_argument('--remove-users-only', action='store_true', help='Only remove non-owner users')
    parser.add_argument('--delete-teams-only', action='store_true', help='Only delete teams')
    
    # Add owner check override flag
    parser.add_argument('--ignore-owner-check', action='store_true', 
                        help='Ignore the owner check when deleting repositories or teams')
    
    args = parser.parse_args()
    
    # Load configuration
    config = configparser.ConfigParser()
    config.read(args.config)
    
    # Get basic configuration
    config['github'].get('userid', 'Not specified')
    org = config['github'].get('organization', 'Not specified')
    token = config['github'].get('token', 'Not specified')
    
    # Load inclusions/exclusions from files (if provided)
    delete_users = load_from_file(args.user_file)
    include_teams = load_from_file(args.team_file)
    include_repos = load_from_file(args.repo_file)
    
    # Check if any stage-specific flags are set
    stage_flags = [args.clone_only, args.delete_repos_only, args.remove_users_only, args.delete_teams_only]
    run_all_stages = not any(stage_flags)
    
    # Execute the functions based on flags
    if run_all_stages or args.clone_only:
        print("=== CLONING REPOSITORIES ===")
        clone_org_repos(org, token, "repos")
        
    if run_all_stages or args.delete_repos_only:
        print("=== DELETING REPOSITORIES ===")
        delete_org_repos(org, token, include_repos, args.ignore_owner_check)

    if run_all_stages or args.delete_teams_only:
        print("=== DELETING TEAMS ===")
        delete_teams(org, token, include_teams, args.ignore_owner_check)
        
    if run_all_stages or args.remove_users_only:
        print("=== REMOVING NON-OWNER USERS ===")
        remove_non_owners(org, token, delete_users)


if __name__ == "__main__":
    main()