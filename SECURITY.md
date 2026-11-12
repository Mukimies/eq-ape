# Security policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a security problem.

Include the EQ Ape version, macOS version, and the steps to reproduce. EQ Ape is a hobby project maintained by Mukimies; there is no guaranteed response time, but reports are read and taken seriously.

## Scope

EQ Ape runs unsandboxed, receives all system audio through a Core Audio process tap, and reads config files you choose. Reports about the handling of those files, the permission flow, or anything that could leave audio muted or leak audio are especially welcome.

## Supported versions

Only the latest release receives fixes. The current releases are pre-releases (beta), ad-hoc signed and not notarized.
