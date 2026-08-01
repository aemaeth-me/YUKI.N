# NVIDIA — Agent Memory / Long-context positions

Sources:
- https://blogs.nvidia.com/blog/reasoning-ai-agents-decision-making/ (May 13, 2025)
- https://developer.nvidia.com/blog/inside-nvidia-nemotron-3-techniques-tools-and-data-that-make-it-efficient-and-accurate/ (Dec 15, 2025)
- https://docs.nvidia.com/enterprise-reference-architectures/ai-q-research-agent-blueprint/latest/system-overview-and-architecture.html

## Position on agent memory (Nemotron Labs blog, May 2025)

- Key components to build an AI agent: **tools, memory, and planning modules**.
- Reasoning can be added by augmenting planning modules with a reasoning model (NVIDIA Nemotron or DeepSeek-R1).
- AI-Q NVIDIA AI Blueprint + NVIDIA NeMo Agent toolkit: reference workflow for advanced agentic AI systems. AI-Q integrates multimodal data extraction/retrieval using Nemotron RAG models, NIM microservices, AI agents.
- NeMo Agent toolkit (open source, GitHub): connect, profile, optimize teams of AI agents, full system traceability and performance profiling. Framework-agnostic.

## Nemotron 3 (Dec 2025): 1M-token context

- Hybrid **Mamba-Transformer mixture-of-experts (MoE)** architecture enabling high-throughput, long-context agentic AI systems with **native 1M-token context windows**.
- Optimized for multi-agent workflows (retrievers, planners, tool executors, verifiers) across large contexts and long time spans.
- 1M-token context supports "long-running agent memory," deep multi-document reasoning, keeping entire evidence sets, history buffers, and multi-stage plans in a single context window.
- Mamba excels at tracking long-range dependencies with minimal memory overhead; Transformer layers for structural/logical relations.
- **Long context instead of external memory/chunking**: "Instead of relying on fragmented chunking heuristics, agents can keep entire evidence sets, history buffers, and multi-stage plans in a single context window."
- Open: model weights under NVIDIA Open Model License; ~10T token synthetic corpus; training recipes in GitHub.

## AI-Q Research Agent Blueprint (Enterprise Reference Architecture)

- AI-Q: agentic framework for research using RAG (NeMo Retriever extraction: chunk + embed multimodal data → Vector DB like Milvus).
- RAG layer provides grounded context retrieval (semantic + hybrid search, metadata filtering, reranking).
- Instruct LLM judges whether additional internet search needed (Tavily), synthesizes final response.

## Key takeaways for memory design

- NVIDIA's official agent-stack emphasis: hardware/memory bandwidth (Vera CPU, graph prefetcher for "agent memory traversal"), long-context models (Nemotron 3 1M) as a memory strategy, and RAG/vector retrieval (AI-Q, NeMo Retriever) for grounding. No dedicated first-party "memory tool API" published at this level; memory is handled via context windows + vector/RAG + framework tooling.
