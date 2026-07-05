# ACS Installer Guide

When setting up ACS for a new user, follow `site/steward_agent_installer.md` step by step. It walks through:

- Checking if ACS is already running
- Asking the user about their preferences (LLM provider, embeddings, database, log streaming)
- Generating `steward.env`, `steward.docker-compose.yml`, and `AGENTS_STEWARD.md`
- Verifying setup after startup

This is the primary onboarding flow for new ACS users.
