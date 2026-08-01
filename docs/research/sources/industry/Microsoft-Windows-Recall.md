# Windows Recall — Microsoft

Sources:
- https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/recall/
- https://blogs.windows.com/windowsexperience/2024/09/27/update-on-recall-security-and-privacy-architecture/
- https://support.microsoft.com/en-us/windows/ai/ai-features/retrace-your-steps-with-recall

## What it is

Recall is an AI-assisted feature on Copilot+ PCs that helps users find anything they've seen on their PC. Users search with natural-language clues or use a timeline to scroll through past activity (apps, documents, websites). Once found, users can jump back to the content via the relaunch button (deep links via the UserActivity API).

- GA release on Copilot+ PCs: April 25, 2025.
- Preview for Windows Insiders: announced Nov 22, 2024.
- Copilot+ PCs only (Qualcomm/Intel/AMD NPU devices), Secured-core PCs.
- Requires Windows Hello Enhanced Sign-in Security (biometric) enrollment.
- Storage: at least 50 GB free; snapshots pause automatically below 25 GB.

## How it works

- Periodic snapshots of the active screen (every few seconds and when active window content changes), taken only if user opted in.
- On-device OCR + image recognition + semantic indexing (embeddings) → search over text and images.
- "Click to Do" (uses local Phi Silica model) connects actions to content in snapshots.
- Timeline segmented by blocks of time.
- Snapshots stored locally; never sent to Microsoft/third parties; not shared between users; not used to train AI.

## Security & privacy architecture (Sept 27, 2024 blog)

Four principles:
1. **Snapshots and vector database always encrypted.** Encryption keys protected via TPM, tied to Windows Hello ESS identity, only usable within a **Virtualization-based Security Enclave (VBS Enclave)**.
2. **VBS Enclaves** (same hypervisor as Azure) segment memory into a protected area; Zero Trust; cryptographic attestation. Isolation boundary from both kernel and administrative users.
3. **Only accessible after Windows Hello authentication** (Enhanced Sign-in Security biometrics). Just-in-time decryption; authorization timeout + anti-hammering.
4. **Always opt-in.** Snapshots not taken unless user chooses. Deleting/pausing/filtering at any time.

Architecture components:
- **Semantic Index**: converts images/text into vectors for search. Vectors encrypted by keys protected in VBS Enclave; all queries within the enclave.
- **Snapshot Store**: saved snapshots + metadata (launch URIs, timestamps, title bar strings, app dwell times). Each snapshot encrypted by individual keys.
- **Recall User Experience**: timeline, search, viewing snapshots.
- **Snapshot Service**: background process for saving snapshots and querying.

Additional controls:
- **Sensitive information filtering** (on by default): filters out snapshots when sensitive info (passwords, credit cards) detected.
- Filter apps and websites; InPrivate browsing and DRM content not saved.
- IT admins can disable snapshot saving (but cannot enable it); `DisableAIDataAnalysis` policy.
- DLP provider integration API (`SetDataLossPreventionProvider` policy): Recall queries DLP providers before capturing; can allow/audit/warn/block capture.
- Recall is available by default for devices not managed by an organization.

## Timeline of release changes

- May 20, 2024: announced with Copilot+ PCs; "photographic memory".
- June 2024: preview delayed to Insider Program due to security concerns.
- Aug/Oct 2024: further delays; additional security protections ("just in time" decryption with Windows Hello ESS; encrypted search index DB).
- Sept 27, 2024: security & privacy architecture blog.
- Nov 22, 2024: Insider preview with Click to Do.
- April 25, 2025: GA on Copilot+ PCs.
