# Security

Report a suspected vulnerability through GitHub's private vulnerability reporting: open the
repository's Security tab and choose "Report a vulnerability". No response time is promised.

Do not post credentials, personal backup files or exploit details in public issues. If private
reporting is unavailable, hold back sensitive details until a private channel is available.

An exposed credential must be revoked or rotated with its provider. Removing it from the
current tree does not remove it from Git history.

## Repository configuration trust

Treat `.agentic-workflow-kit.json` as executable code, including when reviewing pull requests.
Its command settings can run programs under your account and its announcement setting can
select a posting destination. Inspect changes before allowing the workspace's hooks or skills
to run. OCR gateways, endpoints and credential sources are accepted only from user options or
the environment, never from this repository file. Configure only gateways you trust with the
credential and the code sent for review.
