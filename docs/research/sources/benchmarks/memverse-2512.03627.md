# [2512.03627] MemVerse: Multimodal Memory for Lifelong Learning Agents

## Authors
Authors: Junming Liu , Yifei Sun , Weihua Cheng , Haodong Lei , Yirong Chen , Licheng Wen , Xuemeng Yang , Daocheng Fu , Pinlong Cai , Nianchen Deng , Yi Yu , Shuyue Hu , Botian Shi , Ding Wang

## Comments
25 pages, 6 figures, 14 tables

## Abstract
Abstract: Despite rapid progress in large-scale language and vision models, AI agents still suffer from a fundamental limitation: they cannot remember. Without reliable memory, agents catastrophically forget past experiences, struggle with long-horizon reasoning, and fail to operate coherently in multimodal or interactive environments. We introduce MemVerse, a model-agnostic, plug-and-play memory framework that bridges fast parametric recall with hierarchical retrieval-based memory, enabling scalable and adaptive multimodal intelligence. MemVerse maintains short-term memory for recent context while transforming raw multimodal experiences into structured long-term memories organized as hierarchical knowledge graphs. This design supports continual consolidation, adaptive forgetting, and bounded memory growth. To handle real-time demands, MemVerse introduces a periodic distillation mechanism that compresses essential knowledge from long-term memory into the parametric model, allowing fast, differentiable recall while preserving interpretability. Extensive experiments demonstrate that MemVerse significantly improves multimodal reasoning and continual learning efficiency, empowering agents to remember, adapt, and reason coherently across extended interactions.
