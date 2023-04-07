# Code Review Scripts

## Motivation
When I review code, in addition to viewing the diffs, I like to navigate around in the 
changed codebase to explore the ramifications of those changes and look at related 
code. This helps me understand the context and ask better questions. I find it's 
easiest to do that if I can bring the proposed changes into my local development 
environment.

## What these scripts do
`review-pr` is the main entry point. It should be run in the top level of a local 
copy of a repo. Given a pull request id for a pull request against that repo, it will

1. Stash any work in progress
   - **NOTE:** This stash is done as a safety measure only. It's better to stash your 
     work in progress yourself, before running the script.
2. Save the name of the current branch you are working in
3. Identify the source and target branches for the PR and pull updated copies of both 
   into the local copy
4. Create a new local temp branch that is a copy of the target branch
5. Do a preview merge of the source branch into the temp branch. (`git merge 
   --no-commit --no-ff ...`)

You can then use your favorite IDE to review the diffs and dig around in the code. 

When finished, run `review-finished` in the top level of the local copy to discard the 
preview merge and temp branch and return to your local branch. Note that any code 
changes that got stashed will not be popped off the stash; you'll need to do that 
yourself. 

If you want to review a branch for which no pull request has yet been created, use 
`review-branch`, giving the name of the branch to be reviewed. `review-finished` also 
works for cleaning up in this case.

## Requirements

1. bash (accessed via `#!/usr/bin/env bash`)
2. awk
3. cut
4. grep
5. [jq](https://github.com/stedolan/jq) for JSON parsing a GitHub api response
6. a GitHub oauth token that gives permission to read the repo in question. 
   - For a 'Classic' token, the permissions `repo:status` and `public_repo` will 
   suffice in many cases.
   - The token should be stored in the same folder as the scripts, with the name `.ghub_oauth_pr_review`
   - `.gitignore` includes an entry for `.ghub_oauth*` to help insure the file is not
       committed to this repo.

## Configuration
As mentioned above, you must provide a `.ghub_oauth_pr_review` file with a GitHub 
oauth token. 

The file `.codereview.config.default` included in this repo provides some basic 
configuration values. Should you wish to override any of those, put your overrides into 
a file called `.codereview.config`. 

## Improvements
These started as quick and dirty scripts for personal use only and have evolved 
slowly over the years. For wider use they'd probably benefit from, among other things:

1. better option processing
2. a help option
3. bash linting
