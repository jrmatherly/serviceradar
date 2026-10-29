# Prints "File RuleID Fingerprint" for findings outside test and vendored paths.
# Usage: jq -r -f scripts/gitleaks-triage.jq report.json
.[] | select(.File | test("(^|/)(test|tests|testdata|fixtures|third_party|vendor)/|^contrib/snmp/mibs/") | not)
| "\(.File) \(.RuleID) \(.Fingerprint)"
