# Copilot personalization and memory — Microsoft Learn

Source: https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-personalization-memory
(ms.date: 2025-11-18; updated_at: 2026-05-22)

## Overview

- Copilot personalization and memory are in preview (Frontier program) and subject to change.
- Copilot memory is available to Copilot Chat users with and without a Microsoft 365 Copilot license.
- **No action is required to turn on Copilot memory**; you only need to turn it off if desired.

## Three components

Memory includes: **saved memories**, **details inferred from chat history**, and **custom instructions**.

## Where memories are stored

Memories (saved memories + inferred from chat history + custom instructions) are stored in the **user's Exchange mailbox in a hidden folder**. Thus they follow the same security and compliance policies as other mailbox data (Customer Lockbox, encryption at rest).

## Admin controls

- **Enhanced personalization** is the control that allows Copilot memory to be used by end-users. On by default. Configurable programmatically via Microsoft Graph (`enhancedPersonalizationSetting` resource type).
- End-users with Enhanced personalization off see user-level controls (Custom instructions, Saved memories, Chat history) in Settings > Personalization as turned off.

## Retention

- **Retention policies/labels from Purview don't apply to Copilot memory.** No admin controls to enforce retention rules specifically for Copilot memory.
- **Custom instructions**: turning off the control stops Copilot from applying them but doesn't remove them.
- **Saved memories**: retained until the end-user explicitly deletes them in Settings > Personalization. Deleting a chat doesn't delete saved memories generated from that chat.
- **Chat history**: details are dynamic — Copilot might update or discard older details as it learns what's most helpful to retain. If a user deletes all chats where info was shared, traces are deleted from Chat History details within seven days. If the Chat history control is turned off, all details from chat history are deleted after 30 days.

## Data subject requests / discoverability

- Admins can use eDiscovery and Microsoft Graph Explorer to search, export, and delete users' memory data.
- Copilot memory is located in the `CopilotMemory` folder (item class `<IPM.Contact>`).
- Custom instructions aren't discoverable via eDiscovery but can be manually exported by the user.
- Memory and personalization actions don't generate audit log entries in Purview.
- Admins can't restrict what type of information is added to Copilot memory.

## Related: Introducing Copilot Memory (Tech Community, July 14, 2025)

- Copilot Memory: Copilot picks up important details from conversations ("I prefer Python for data science") and remembers them. Users can tell Copilot "please remember..." — logged as a memory.
- Custom Instructions: explicit behavioral guidance applied automatically in future interactions.
- "Memory updated" signal when Copilot remembers something new; view/edit/delete from Settings; can turn memory off.
- Copilot only saves info when there's clear intent to remember: "I prefer Python for all data science tasks" → remembered; "Write Python code for k-means clustering" → not remembered.
- Memory and custom instructions not currently available for Agents (as of July 2025).
- Generally available July 2025, on by default; admin can disable org-wide; memory data discoverable via Purview eDiscovery.
- Personal Copilot (May 2025): Memory feature builds a user profile; users can tell Copilot to forget a memory; visual "Narrative" on mobile showing Copilot's memories of you.

## Related: Memory update (MC1158329, Sept 2025)

- Updating Memory in Microsoft 365 Copilot to personalize responses using **chat history**.
- Public preview (Frontier) mid-November 2025; GA begins early January 2026 (completion expected July 2026).
- Users get redesigned Memory settings page; existing admin/user-level Memory settings respected.
