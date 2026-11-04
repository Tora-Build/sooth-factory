# Security policy

## Scope and support

Sooth Factory is experimental software. The current `main` branch is the development target for security reports. Local tests and internal reviews do not establish production readiness or an independent external audit. [STATUS](STATUS.md) records verification and deployments.

`ManualAdjudicator` is a demo and test sample. A repository fix does not change an already deployed contract. Include the chain, contract address and source revision when reporting an issue in a deployment.

## Reporting a vulnerability

Use GitHub's [private vulnerability reporting form](https://github.com/Tora-Build/sooth-factory/security/advisories/new) when **Report a vulnerability** is available. Reports go to this repository's maintainers. Do not publish exploit details, private keys or credentials in an issue, pull request or discussion.

A private report should include:

- The affected revision, contract or tool, and relevant chain/deployment identifiers.
- Expected and observed behavior, impact and prerequisites.
- A minimal local reproduction or test using synthetic assets and accounts.
- Any known mitigation and a private way to follow up.

Use local or explicitly authorized test environments for reproduction. Coordinate disclosure with the maintainers so affected operators can assess and address the issue.
