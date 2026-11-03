# Data Model: Agent Wake-Up Alert & 1-Click Approval

## Value Types & Enums (`src/Models/AgentModels.swift`)

### `AgentEventKind` (Extended)
```swift
public enum AgentEventKind: String, Codable, Sendable, CaseIterable {
    case started
    case working
    case needsApproval
    case done
    case almostDone
    case warning
    case usage
    case failed // NEW: unrecoverable failure / error event
}
```

### `AgentEvent.MetadataKey` (Extended)
| Key | Type | Description |
|---|---|---|
| `approvalRequestID` | `String` | Unique request identifier for pending hook-based approvals |
| `approvalChannel` | `String` | File path or identifier where decision payload must be written |
| `toolName` | `String` | Tool name being approved (e.g. `Bash`, `WriteFile`) |
| `commandSummary` | `String` | Short command or path summary (e.g. `git push origin main`) |
| `owningPID` | `String` | Process ID of the owning terminal or IDE process |
| `bundleID` | `String` | Bundle identifier of the owning terminal/IDE application |
| `workingDir` | `String` | Working directory of the agent (for git diff inspection) |

### `AgentApprovalRequest` (`Codable`, `Sendable`, `Equatable`, `Identifiable`)
| Field | Type | Description |
|---|---|---|
| `id` | `String` | Unique request token / UUID |
| `agentID` | `String` | Identifier of requesting agent |
| `agentName` | `String` | Display name of requesting agent |
| `toolName` | `String?` | Name of the tool requesting approval |
| `commandSummary` | `String?` | Command or argument summary |
| `decisionChannel` | `String` | Path to response file or FIFO |
| `createdAt` | `Date` | Timestamp of request creation |
| `expiresAt` | `Date` | Timestamp when token expires (TTL default 300s) |
| `isConsumed` | `Bool` | Whether the single-use token has already been spent |

### `AgentPopupState` (Extended)
| Field | Type | Description |
|---|---|---|
| `text` | `String` | Text content of popup |
| `kind` | `AgentEventKind` | Event kind (includes `.failed`, `.needsApproval`, etc.) |
| `agentName` | `String` | Name of the agent |
| `expiresAt` | `Date?` | Auto-dismiss date (`nil` for indefinite until handled) |
| `metadata` | `[String: String]?` | Metadata preserving quick action / approval parameters |

## Services & Stores

### `AgentApprovalStore` (`@MainActor`, `ObservableObject`)
- Manages active pending `[AgentApprovalRequest]`.
- Provides:
  - `register(request: AgentApprovalRequest)`
  - `approve(requestID: String) -> Bool`: sends `"approve"`, consumes token, returns success.
  - `request(for: String) -> AgentApprovalRequest?`
  - `purgeExpired(now: Date)`: removes expired tokens.

### `AppActivating` & `WorkspaceAppActivator`
- Protocol: `func activate(bundleID: String?, pid: pid_t?) -> Bool`
- Default implementation uses `NSRunningApplication(processIdentifier:)` or `NSWorkspace.shared.runningApplications`.

### `DiffViewing` & `SystemDiffViewer`
- Protocol: `func viewDiff(workingDirectory: URL?)`
- Default implementation executes git diff viewer or launches default diff tool.
