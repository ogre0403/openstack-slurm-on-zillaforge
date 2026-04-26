## ADDED Requirements

### Requirement: Shared orchestration pipeline
The system SHALL execute both expand and shrink operations through a shared pipeline consisting of: determine target nodes, run pre hook playbook, run payload script, run post hook playbook — regardless of execution mode.

#### Scenario: Expand executed through shared pipeline
- **WHEN** an expand operation is triggered in any mode
- **THEN** the pre hook, payload (`add_computes.sh`), and post hook execute in order with the same credential and mount assumptions used by the existing flow

#### Scenario: Shrink executed through shared pipeline
- **WHEN** a shrink operation is triggered in any mode
- **THEN** the pre hook, payload (`del_computes.sh`), and post hook execute in order using the same assumptions

### Requirement: Batch mode execution
The system SHALL submit expand and shrink operations as Slurm batch jobs equivalent to `make ... singularity-sbatch-expand` and `make ... singularity-sbatch-shrink`, record the returned Slurm job id, and monitor execution state with `sacct`.

#### Scenario: Batch expand submitted successfully
- **WHEN** an operator triggers a batch expand with a valid partition and node count
- **THEN** the job is submitted to Slurm, the job id is recorded, and execution state is polled via `sacct`

#### Scenario: Batch expand rejected — partition unavailable
- **WHEN** an operator requests batch mode but the specified Slurm partition does not exist
- **THEN** the operation is rejected with an actionable error message before submission

#### Scenario: Batch shrink by job id
- **WHEN** an operator triggers a batch shrink with a valid Slurm job id
- **THEN** the shrink is submitted targeting that job id, the new job id is recorded, and execution is monitored

### Requirement: Direct mode execution
The system SHALL support direct mode execution on the Slurm headnode over SSH as a fallback when Slurm partition capacity is insufficient, using the same hooks, payload scripts, credentials, bind mounts, and image assumptions as batch mode.

#### Scenario: Direct expand executed with operator confirmation
- **WHEN** an operator selects direct mode, acknowledges the confirmation prompt, and triggers expand
- **THEN** the shared pipeline executes directly on the headnode over SSH without requiring Slurm scheduler allocation

#### Scenario: Direct mode blocked by concurrent direct operation
- **WHEN** an operator attempts to start a direct mode operation while another direct operation is already running
- **THEN** the system rejects the request with a conflict explanation

#### Scenario: Direct mode rejected without confirmation
- **WHEN** an operator attempts to start a direct mode operation without acknowledging the confirmation
- **THEN** the operation does not proceed

### Requirement: Shrink targeting
The system SHALL support shrink targeting by Slurm job id and by selected nodes, rejecting ambiguous or unsafe selections with a clear explanation.

#### Scenario: Shrink by selected nodes resolves safely
- **WHEN** an operator selects a valid, unambiguous set of nodes for shrink
- **THEN** the selection is accepted and the shrink proceeds with those nodes as targets

#### Scenario: Shrink by selected nodes rejected — ambiguous selection
- **WHEN** the selected nodes are of mixed origin, in conflict state, or cannot be safely resolved
- **THEN** the operation is rejected with a specific explanation of why the selection is unsafe

### Requirement: Operations panel UI
The system SHALL display an operations panel for expand and shrink with execution-mode selection, batch as default and direct as fallback, and clear warnings around direct mode.

#### Scenario: Batch mode is the default selection
- **WHEN** an operator opens the operations panel
- **THEN** batch mode is pre-selected as the default execution mode

#### Scenario: Direct mode warning displayed
- **WHEN** an operator selects direct mode
- **THEN** the UI displays a prominent warning before allowing the operation to proceed
