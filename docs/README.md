# Documentation

**English** | [简体中文](README.zh-CN.md)

Start with the [project overview and setup guide](../README.md). Each public guide has a language link near its title. The standard README and technical-document filenames open in English; their Chinese counterparts remain available through those links.

## Setup and operation

- [Mac Host](../host/README.md): setup, start/stop/restart, Android phone preparation, notifications, context management, and chat-history clearing.
- [Relay](../relay/README.md): Cloudflare deployment, APNs configuration, routes, limits, and the experimental ADB tunnel.
- [MCP services](mcp-services.md): built-in services, connected office tools, local configuration, and ModelScope imports.
- [Skills](../skills/README.md): the skill catalog and installation instructions. English reference copies are available for every skill; the runtime continues to load the existing Chinese `SKILL.md` files.

## Architecture and implementation references

- [Technical proposal v0.1](architecture.md): system architecture, connectivity, the Host, the iOS app, and the proposed implementation stages.
- [Wire protocol](protocol.md): identity, pairing, encryption, transport, requests, events, and data structures.
- [Phone UI automation migration](phone-ui-automation.md): the migration instructions and decisions recorded for the implementation agent.
- [iOS cryptographic test vectors](../ios/OPATests/VECTORS.md): shared compatibility vectors and how they are used.

## App design references

- [Orbit app design brief](design/orbit-app-design.md)
- [iOS redesign implementation plan](design/implementation-plan.md)
- [Wave 2 implementation briefs](design/wave2-briefs.md)
- [Design direction v2](design/v2-direction.md)

Design and migration documents record different stages of the project. Read the status in each document before treating a proposal or a planned step as implemented behavior.
