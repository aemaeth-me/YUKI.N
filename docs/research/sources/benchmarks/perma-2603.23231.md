# [2603.23231] PERMA: Benchmarking Personalized Memory Agents via Event-Driven Preference and Realistic Task Environments

## Authors
Authors: Shuochen Liu , Junyi Zhu , Long Shu , Junda Lin , Yuhao Chen , Haotian Zhang , Chao Zhang , Derong Xu , Jia Li , Bo Tang , Zhiyu Li , Feiyu Xiong , Enhong Chen , Tong Xu

## Comments


## Abstract
Abstract: Empowering large language models with long-term memory is crucial for building agents that adapt to users' evolving needs. Existing evaluations of this capability typically interleave preference-related dialogues with irrelevant conversations, reducing the task to needle-in-a-haystack retrieval while ignoring relationships between events driving user preference evolution. Such settings overlook a fundamental characteristic of real-world personalization: preferences emerge gradually and accumulate across interactions within noisy contexts. To bridge this gap, we introduce PERMA, a benchmark designed to evaluate persona consistency over time beyond static preference recall. Additionally, we incorporate (1) text variability and (2) linguistic alignment to simulate erratic user inputs and individual idiolects in real-world data. PERMA consists of temporally ordered interaction events spanning multiple sessions and domains, with preference-related queries inserted over time. We design both multiple-choice and interactive tasks to probe the model's understanding of persona along the interaction timeline. Experiments demonstrate that by linking related interactions, advanced memory systems extract precise preferences and reduce token consumption, outperforming traditional semantic retrieval of raw dialogues. Nevertheless, they still struggle to maintain a coherent persona across temporal depth and cross-domain interference, highlighting the need for more robust personalized memory management in agents. Our code and data are open-sourced at this https URL .
