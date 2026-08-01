# Announcing the Agent2Agent Protocol (A2A)

URL: https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/
Authors: Miku Jha (Director, AI/ML Partner Engineering Google Cloud), Todd Segal (Principal Engineer)
Published: 2025-04-09

---

Today, we’re launching a new, open protocol called Agent2Agent (A2A), with support and contributions from more than 50 technology partners like Atlassian, Box, Cohere, Intuit, Langchain, MongoDB, PayPal, Salesforce, SAP, ServiceNow, UKG and Workday; and leading service providers including Accenture, BCG, Capgemini, Cognizant, Deloitte, HCLTech, Infosys, KPMG, McKinsey, PwC, TCS, and Wipro. The A2A protocol will allow AI agents to communicate with each other, securely exchange information, and coordinate actions on top of various enterprise platforms or applications.

> A2A is an open protocol that complements Anthropic's Model Context Protocol (MCP), which provides helpful tools and context to agents.

## A2A design principles

A2A is an open protocol that provides a standard way for agents to collaborate with each other, regardless of the underlying framework or vendor. While designing the protocol with our partners, we adhered to five key principles:

*   **Embrace agentic capabilities**: A2A focuses on enabling agents to collaborate in their natural, unstructured modalities, even when they don’t share memory, tools and context. We are enabling true multi-agent scenarios without limiting an agent to a "tool."
*   **Build on existing standards:** The protocol is built on top of existing, popular standards including HTTP, SSE, JSON-RPC, which means it’s easier to integrate with existing IT stacks businesses already use daily.
*   **Secure by default**: A2A is designed to support enterprise-grade authentication and authorization, with parity to OpenAPI’s authentication schemes at launch.
*   **Support for long-running tasks:** A2A is designed to be flexible and support everything from quick tasks to deep research that may take hours or even days when humans are in the loop.
*   **Modality agnostic:** The agentic world isn’t limited to just text, which is why we’ve designed A2A to support various modalities, including audio and video streaming.

## How A2A works

A2A facilitates communication between a "client" agent and a "remote" agent. This interaction involves several key capabilities:

*   **Capability discovery:** Agents can advertise their capabilities using an "Agent Card" in JSON format.
*   **Task management:** Communication is oriented towards task completion. The "task" object has a lifecycle; output is known as an "artifact."
*   **Collaboration:** Agents can send each other messages to communicate context, replies, artifacts, or user instructions.
*   **User experience negotiation:** Each message includes "parts," a fully formed piece of content; parts negotiate UI capabilities (iframes, video, web forms, etc.).
