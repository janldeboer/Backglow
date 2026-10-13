# Security policy

## Supported versions

Security fixes go into the latest 3.x release. Older versions, including the pre-3.0 *macOS Ambient Lighting* builds and the legacy `SerialLEDcontroller` sketch, are not updated.

| Version | Supported |
| --- | --- |
| 3.x (latest) | Yes |
| < 3.0 | No |

## Reporting a vulnerability

Please do not open a public issue. Report it privately instead:

- on GitHub via **Security → Report a vulnerability** in this repository, or
- by email to [contact@jandeboer.de](mailto:contact@jandeboer.de).

Describe the problem, the affected version and how to reproduce it. You will get an answer within a week. Backglow is a one-person project, so a fix can take longer; you will hear how it is going, and you are credited in the release notes unless you prefer not to be.

## Scope

Relevant reports include, for example:

- the app capturing, storing or sending screen content beyond the computed LED colors, or making network connections,
- the app opening serial ports it should not, or crashing or misbehaving on malicious data from a serial device,
- the firmware mishandling malformed serial input or profile data,
- problems with the signed and notarized release builds or the release pipeline.

Problems that require an already compromised Mac or physical access to the controller are out of scope.
