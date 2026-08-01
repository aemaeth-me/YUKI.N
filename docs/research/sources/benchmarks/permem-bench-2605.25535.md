# [2605.25535] Personalize-then-Store: Benchmarking and Learning Personalized Memory for Long-horizon Agents

## Authors
Authors: Yeonjun In , Wonjoong Kim , Sangwu Park , Kanghoon Yoon , Chanyoung Park

## Comments
preprint

## Abstract
Abstract: Existing large language model (LLM) based memory systems apply universal, static policies that overlook a fundamental reality: the contexts that are worth storing in memory are different across users. This misalignment wastes limited memory budget on transient interactions while failing to preserve critical context for long horizon tasks. To address this gap, we investigate an underexplored question: can LLM based memory systems learn personalized memory policies? We introduce PerMemBench, the first benchmark for evaluating personalized memory systems, featuring multi year, multi domain interaction histories across diverse user personas. We further present the first empirical study of memory personalization, proposing session level storage gating, a lightweight framework that selectively bypasses memory operations for transient sessions. Our study confirms that personalization yields substantial retention gains under perfect gating, yet reveals that accurate gating remains an open and critical challenge.
