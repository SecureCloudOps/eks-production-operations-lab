# Baseline capture sanitization

The five baseline text captures retain their operational observations. Before the
first GitHub push, observed node hostnames, IPv4 addresses and the ALB hostname
were replaced throughout the unpublished history with consistent NODE, IP and
ALB aliases. Trailing spaces in these captures were also removed. These tokens
are publication labels, not routable addresses.

Original captures and Git history were preserved in a verified encrypted local
backup. Commit authors, dates and messages were retained; rewritten commit hashes
changed. Execution provenance may refer to the original, backed-up commit hashes.
No Terraform configuration or infrastructure was changed by this sanitization.
