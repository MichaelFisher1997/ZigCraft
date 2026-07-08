# Security Policy

## Supported Versions

ZigCraft is pre-1.0 software. Security fixes are provided for the current `dev` branch and the latest `main` release branch when one exists.

| Version | Supported |
| ------- | --------- |
| `dev` | Yes |
| latest `main` | Yes |
| older branches | No |

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through GitHub Security Advisories for this repository. If private advisories are unavailable, contact the repository owner directly and do not open a public issue with exploit details.

Include:
- Affected commit, branch, or release.
- Steps to reproduce or proof-of-concept details.
- Impact assessment and any known mitigations.
- Whether the issue is already public.

## Response SLA

- Initial acknowledgement: within 7 calendar days.
- Triage update: within 14 calendar days after acknowledgement.
- Fix or mitigation target: as soon as practical based on severity and exploitability.

## Scope

In scope:
- Engine code, build scripts, CI workflows, release artifacts, and bundled assets in this repository.
- Vulnerabilities that can cause code execution, data loss, unsafe file access, dependency compromise, or CI credential exposure.

Out of scope:
- Vulnerabilities requiring local administrative access before exploitation.
- Issues in third-party tools unless ZigCraft pins or packages them insecurely.
- Denial-of-service reports without a practical security impact beyond normal development instability.

Coordinated disclosure is expected. Please allow maintainers time to investigate and prepare fixes before public disclosure.
