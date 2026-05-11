## ADDED Requirements

### Requirement: Unified node inventory
The system SHALL merge Slurm and OpenStack state into a normalized per-node inventory record containing node_name, ip, slurm_state, openstack_compute_registered, role, and notes.

#### Scenario: Node present only in Slurm
- **WHEN** a node is present in Slurm and not registered as a nova-compute service
- **THEN** the node's role is classified as `slurm-worker`

#### Scenario: Node registered as OpenStack compute
- **WHEN** a node is registered as an OpenStack nova-compute service
- **THEN** the node's role is classified as `openstack-compute`

#### Scenario: Node claimed by both systems
- **WHEN** both Slurm and OpenStack report active ownership of the same node, or one side appears stale
- **THEN** the node's role is classified as `conflict` and a mismatch warning is surfaced

### Requirement: Live state collection from Slurm
The system SHALL collect Slurm node state from the headnode over SSH using `sinfo`, `scontrol show nodes`, `squeue`, and `sacct`.

#### Scenario: Slurm data collected successfully
- **WHEN** the backend queries the Slurm headnode via SSH
- **THEN** current node states are returned and merged into the inventory

#### Scenario: SSH connection to headnode fails
- **WHEN** the SSH connection to the headnode is unavailable
- **THEN** the inventory reflects the failure and surfaces an actionable operator message rather than a raw error

### Requirement: Live state collection from OpenStack
The system SHALL collect OpenStack compute and network agent state on the bastion using existing credential files.

#### Scenario: OpenStack data collected successfully
- **WHEN** the backend queries OpenStack using available credentials
- **THEN** compute and agent registration state is returned and merged into the inventory

#### Scenario: OpenStack credentials missing
- **WHEN** required credential files are absent from the expected path
- **THEN** an actionable message is surfaced and the inventory reflects the missing data source

### Requirement: Node inventory UI view
The system SHALL display a node inventory view showing each node's identity, Slurm state, OpenStack registration, inferred role, and mismatch indicators.

#### Scenario: Inventory loaded and displayed
- **WHEN** the operator opens the node inventory view
- **THEN** all nodes are listed with their identity, states, role classification, and any mismatch indicators visible

#### Scenario: Conflict node highlighted
- **WHEN** a node is classified as `conflict`
- **THEN** the UI displays a mismatch indicator on that node's row
