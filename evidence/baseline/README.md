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

The September 10 publication review found one remaining internal control-plane
hostname embedded in leader-election messages. The follow-up correction uses
`<CONTROL-PLANE-01>` consistently, retaining event order, timing, reasons and
leader-election suffixes. Original captures remain in encrypted private backups;
source hashes in historical provenance continue to identify those originals.

The follow-up history correction also replaces commit author/committer email
addresses with the owner's GitHub noreply address, preserving names, messages and
original timestamps. The private backup retains the original metadata.
