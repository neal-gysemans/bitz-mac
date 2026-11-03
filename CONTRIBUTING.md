# Contributing to Bitz

Thank you for your interest in contributing to **Bitz the Cyber Cat**! 🐱⚡

To maintain repository security, code quality, and organized project tracking, we follow a strict **"Ticket First + Pull Request"** contribution model. The core `AkramKs/bitz-mac` repository is private, while public binary releases are served via `AkramKs/bitz-releases` (see [DISTRIBUTION.md](docs/DISTRIBUTION.md)). **Direct pushes to `main` are strictly forbidden.**

---

## 🔒 Golden Rules

1. **No Direct Pushes to `main`**: All code contributions must enter through a Pull Request.
2. **Mandatory Issue Tickets**: Every Pull Request must reference an existing, approved issue ticket (e.g. `Closes #42`). PRs submitted without a corresponding ticket will not be accepted.
3. **Automated CI Gates**: All PRs must pass the automated ticket verification and Swift CI test suites before they can be merged.
4. **Code Review & Approval**: Every PR requires a review and approval from a maintainer.

---

## 🛠️ Step-by-Step Contribution Workflow

### 1. Create or Find an Issue Ticket
Before writing any code:
- Search existing [Issues](https://github.com/AkramKs/bitz-mac/issues) to see if someone is already working on the problem or feature.
- If not found, open a new ticket using the appropriate template:
  - **🐛 Bug Report**: For errors, UI glitches, or broken functionality.
  - **✨ Feature Request**: For new capabilities, animations, or UX enhancements.
- Discuss the proposed approach on the ticket with maintainers.

### 2. Create a Feature / Bugfix Branch
Always branch off the latest `main`:

```bash
git checkout main
git pull origin main
git checkout -b feature/123-your-feature-name
# or for bug fixes:
git checkout -b fix/123-fix-description
```
*(Tip: Include the ticket number in the branch name)*

### 3. Develop & Verify Locally
Ensure your changes follow the project structure and satisfy all tests:

- **Run unit tests**:
  ```bash
  swift test
  # or
  /usr/bin/swift test
  ```
- **Build and run the app bundle**:
  ```bash
  ./Scripts/package_and_run.sh release
  ```
- Write new unit tests in `Tests/BitzTests/` covering your changes.

### 4. Open a Pull Request
- Push your branch to GitHub:
  ```bash
  git push -u origin feature/123-your-feature-name
  ```
- Open a Pull Request targeting `main`.
- The PR template will load automatically. Fill out all sections and ensure you link the ticket:
  ```markdown
  Closes #123
  ```
- Automated GitHub Actions will immediately verify:
  - ✅ **Verify Linked Issue / Ticket**: Ensures an issue ticket is linked.
  - ✅ **Build & Test (macOS 14)**: Ensures code compiles and all unit tests pass.

### 5. Review & Merge
- Address feedback requested during code review.
- When all checks pass and the PR is approved, maintainers will squash and merge your PR into `main`.

### 6. Close Linked Tickets & Post-Merge Cleanup
- **Mandatory Ticket Closure**: Verify that all linked issue tickets are officially closed. If a ticket was not automatically closed by GitHub, immediately close it (`gh issue close <id>`). Never leave completed issue tickets open.
- Delete the remote feature branch and pull the latest `main` locally.

> **AI Agents & Automated Workflows**: See [AGENTS.md](AGENTS.md) for full engineering invariants and workflow rules.

---

## 📋 Coding Guidelines
- **Swift Concurrency & Strict Typing**: Follow Swift 6 / macOS 14+ idioms. Keep UI changes thread-safe on the main actor.
- **Rive & Window Layering**: Avoid modifying window level or overlay behaviors without thorough verification against existing contracts.
- **Clean Commits**: Write descriptive commit messages summarizing the "why" and "what".

---

## 🛡️ Security Vulnerabilities
If you discover a security vulnerability, please do NOT open a public issue. Follow the instructions in [SECURITY.md](SECURITY.md) to report it privately.
