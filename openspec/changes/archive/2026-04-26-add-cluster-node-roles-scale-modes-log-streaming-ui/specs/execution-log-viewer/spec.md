## ADDED Requirements

### Requirement: Execution record persistence
The system SHALL persist execution metadata for every operation including mode (batch or direct), Slurm job id when present, target nodes, terminal status, and log file path.

#### Scenario: Execution record created on operation start
- **WHEN** an expand or shrink operation is started
- **THEN** an execution record is created with mode, target nodes, and initial status

#### Scenario: Execution record updated on completion
- **WHEN** an operation finishes or fails
- **THEN** the execution record is updated with terminal status and the log file path

### Requirement: Deterministic batch-mode log file locations
The system SHALL write batch mode expand/shrink execution logs to deterministic file paths on the headnode that can be located by Slurm job id.

#### Scenario: Batch log located by job id
- **WHEN** the backend has a Slurm job id for a completed or running batch operation
- **THEN** it can construct the log file path deterministically without searching

### Requirement: Live log streaming for batch mode
The system SHALL stream live logs for running batch operations by reading the deterministic Slurm log file over SSH while separately polling `sacct` for job state.

#### Scenario: Live batch log stream delivered to UI
- **WHEN** an operator views a running batch operation in the UI
- **THEN** log lines are delivered to the UI in near-real-time as they are written to the log file

#### Scenario: Batch log stream ends on job completion
- **WHEN** `sacct` reports the job has reached a terminal state
- **THEN** the log stream is finalized and the UI transitions to completed state

### Requirement: Live log streaming for direct mode
The system SHALL capture direct mode execution stdout/stderr into application-managed log files accessible to the log viewer.

#### Scenario: Live direct-mode log stream delivered to UI
- **WHEN** an operator views a running direct-mode operation in the UI
- **THEN** log lines are delivered in near-real-time as the operation executes on the headnode

### Requirement: Completed log replay
The system SHALL allow operators to replay logs from completed operations for both batch and direct execution modes.

#### Scenario: Completed batch log replayed
- **WHEN** an operator views a completed batch operation in the history panel
- **THEN** the full log output is displayed using the persisted log path

#### Scenario: Completed direct-mode log replayed
- **WHEN** an operator views a completed direct-mode operation in the history panel
- **THEN** the full log output is displayed using the persisted log path

### Requirement: History and log viewer UI
The system SHALL display a history and log panel listing current and past operations with inline log viewing, showing metadata such as execution mode, job id if present, target nodes, and terminal state.

#### Scenario: Operation history listed
- **WHEN** an operator opens the history and log panel
- **THEN** all past and current operations are listed with mode, target nodes, status, and job id where applicable

#### Scenario: Inline log viewer opened for an operation
- **WHEN** an operator selects an operation from the history list
- **THEN** the inline log viewer displays the log output for that operation in follow mode if running, or replay mode if completed
