#!/usr/bin/env sh

# This script is used to integrate your local changes with the remote
# repository. See the documentation in the pre-commit-sample file for
# information on what we check prior to committing and pushing your changes.
# This script is intended as a convenient one-liner to commit your changes, push
# them to the remote repository, and watch the GitHub Actions workflow run in
# your terminal to ensure that the build is successful.

set -e

if [ ! -e ./.git/hooks/pre-commit ]; then
    ln -s ../../pre-commit-sample ./.git/hooks/pre-commit
else
    if [ "$(readlink -f ./.git/hooks/pre-commit)" != "$(readlink -f ./pre-commit-sample)" ]; then
        echo "\n\n"
        echo "\e[1;31m"
        echo "**********************************************************************"
        echo "* Error: pre-commit hook conflict                                    *"
        echo "*                                                                    *"
        echo "* You have an existing pre-commit hook at ./.git/hooks/pre-commit, so *"
        echo "* we will not install the hook required by this script. Please       *"
        echo "* review the hook in ./pre-commit-sample and consider removing your  *"
        echo "* current pre-commit hook.                                           *"
        echo "**********************************************************************"
        echo "\e[0m"
        echo "\n\n"
        exit 1
    fi
fi

git add -N .
git add -p
git commit --no-verify -m "TEMPORARY UNTESTED COMMIT\n\nIf you are seeing this in the commit log, it probably means that the integrate.sh script failed. You should do a soft reset to the commit prior to this commit."

if git diff --exit-code; then
    echo "No uncommitted changes to stash"
    changes_stashed=0
else
    echo "Stashing uncommitted changes"
    changes_stashed=1
    git restore --staged .
    git stash push --include-untracked -m "Temporary stash for uncommitted changes"
fi

git pull --rebase
git reset --soft HEAD^
git status 
mix clean 
git commit
git push
if [ $changes_stashed -eq 1 ]; then
    git stash pop
fi
sleep 2
gh run watch --exit-status