#!/bin/bash
REMOTE_URL=""
BRANCH_NAME="main"
COMMIT_MESSAGE="Initial commit"
GITHUB_USER="deepchatterjeevns"
REPO_NAME="otel-tempo-gke-aws"
while getopts "r:b:m:" opt; do
  case $opt in
    r) REMOTE_URL="$OPTARG" ;;
    b) BRANCH_NAME="$OPTARG" ;;
    m) COMMIT_MESSAGE="$OPTARG" ;;
    *) echo "Usage: $0 [-r remote_url] [-b branch_name] [-m commit_message]"; exit 1 ;;
  esac
done
if [ -z "$REMOTE_URL" ]; then
  REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
fi
git init
git add -A
git commit -m "$COMMIT_MESSAGE"
git remote add origin "$REMOTE_URL" 2>/dev/null || git remote set-url origin "$REMOTE_URL"
git push -u origin "$BRANCH_NAME"
echo "AWS repo initialized and pushed to $REMOTE_URL"