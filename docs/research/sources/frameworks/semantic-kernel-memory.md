# Semantic Kernel (Microsoft) Memory / Vector Store

> Source: https://learn.microsoft.com/en-us/semantic-kernel/concepts/vector-store-connectors/ (fetched 2026-08-01)
> 状态：Vector Store 功能 Preview / RC（2026-04-09 更新）。

## 演进：从 Memory Store 到 Vector Store

Semantic Kernel 有两代向量存储抽象：

1. **Legacy Memory Store**：主接口 `Microsoft.SemanticKernel.Memory.IMemoryStore`（`ISemanticTextMemory`），已废弃。
2. **新 Vector Store**：主基类 `Microsoft.Extensions.VectorData.VectorStore`（.NET 生态，独立于 SK core stack）。

区别：Vector Store 支持自定义 schema、每条记录多向量、多种向量类型、metadata 预过滤、可选索引/距离函数；Legacy Memory Store 不支持这些。

## 抽象层

- **`VectorStore`**：跨集合操作（ListCollectionNames），获取 `VectorStoreCollection<TKey, TRecord>`。
- **`VectorStoreCollection<TKey, TRecord>`**：集合级操作（exists/create/delete collection；upsert/get/delete record），继承 `IVectorSearchable<TRecord>` 提供向量检索。
- **`IVectorSearchable<TRecord>`**：`SearchAsync` — 支持传入文本（由注册的 embedding generator 或向量库自身 vectorize）或直接传向量。

model-first：用注解/装饰器标注字段类型（key / data(filterable) / vector(dimensions, distance function, index kind)）。

## 连接器（out-of-the-box）

C#：Azure AI Search、Cosmos DB MongoDB/NoSQL、Couchbase、Elasticsearch、In-Memory、MongoDB、Oracle、Pinecone、Postgres、Qdrant、Redis、SQL Server、SQLite、Weaviate 等。
Python：Azure AI Search、Chroma、Cosmos DB、Faiss、In-Memory、MongoDB、Pinecone、Postgres、Qdrant、Redis、SQL Server、Weaviate 等。
Java：Azure AI Search、JDBC、MySQL、Oracle、Postgres、Redis、SQLite、Volatile 等。

## RAG 集成

把 `VectorSearchBase` 包装成 Text Search 实现暴露为 plugin，可被 prompt template 或 function calling 调用。

## 与"agent memory"的关系

Semantic Kernel 本身不提供高层级的"对话记忆"抽象——它把 vector store 当作 RAG/检索底座，通过 plugin/search function 暴露给 agent；对话上下文由 kernel 的消息历史管理（AgentFramework 的 Chat History connector，未在本页）。
