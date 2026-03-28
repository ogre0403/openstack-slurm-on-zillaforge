# Run Kolla-Ansible in Slurm flow



## Expand Compute Node

```mermaid
sequenceDiagram
    actor User
    participant HN as Slurm<br/>Headnode
    participant C1 as Slurm<br/>Compute-1
    box rgb(228, 240, 250) Allocated for Expand Job
        participant C2 as Slurm<br/>Compute-2
        participant C3 as Slurm<br/>Compute-3
    end
    participant Ctrl as OpenStack<br/>Controller
    participant OSC1 as OpenStack<br/>Compute-1
    participant Bastion

    User->>HN: make singilarity-sbatch-expand<br/>PARTITION=p OCCUPY_NUM=2
    HN->>HN: sbatch -J expand -N 2 submit.sh add
    HN-->>C2: Allocate node
    HN-->>C3: Allocate node

    C2->>C2: submit.sh add
    Note over C2: NODE_LIST=slurm-compute-2,slurm-compute-3<br/>(scontrol show hostnames)

    C2->>C2: singularity exec kolla-ansible.sif<br/>add_computes.sh NODE_LIST
    rect rgb(243, 238, 237)

        loop bootstrap-servers -> prechecks -> pull -> deploy
            C2->>C2: kolla-ansible cmd --limit NODE_LIST
            C2->>C3: kolla-ansible cmd --limit NODE_LIST
        end

        C2-->>Ctrl: nova-compute registered
        C3-->>Ctrl: nova-compute registered
    end
    Note over C2: sleep infinity & wait for SIGUSR1 to recycle
```



## Shrink Compute Node

```mermaid
sequenceDiagram
    actor User
    participant HN as Slurm<br/>Headnode
    
    box rgb(249, 234, 216) Allocated for Shrink Job
        participant C1 as Slurm<br/>Compute-1
    end

    box rgb(228, 240, 250) Allocated for Expand Job
        participant C2 as Slurm<br/>Compute-2
        participant C3 as Slurm<br/>Compute-3
    end

    participant Ctrl as OpenStack<br/>Controller
    participant OSC1 as OpenStack<br/>Compute-1
    participant Bastion

    Note over C2: sleep infinity & wait for SIGUSR1 to recycle

    User->>HN: make singilarity-sbatch-shrink<br/>PARTITION=p JOB_ID=xxx
    HN->>HN: sbatch -J shrink -N 1 submit.sh del JOB_ID
    HN-->>C1: Allocate node

    C1->>C1: submit.sh del JOB_ID
    Note over C1: NODE_LIST = squeue -j JOB_ID -> hostnames<br/>-> slurm-compute-2,slurm-compute-3
    C1->>C1: singularity exec kolla-ansible.sif<br/>del_computes.sh NODE_LIST

    rect rgb(243, 238, 237)
        loop each NODE in [slurm-compute-2, slurm-compute-3]
            C1->>Ctrl: openstack compute service set --disable NODE nova-compute
        end

        C1->>C2: kolla-ansible stop --limit NODE_LIST
        C1->>C3: kolla-ansible stop --limit NODE_LIST

        loop each NODE in [slurm-compute-2, slurm-compute-3]
            C1->>Ctrl: openstack network agent delete (NODE)
            C1->>Ctrl: openstack compute service delete (NODE)
        end

        C1->>C2: kolla-ansible destroy --limit NODE_LIST
        C1->>C3: kolla-ansible destroy --limit NODE_LIST
    end
    C1->>HN: scancel --batch --signal=SIGUSR1 JOB_ID
    HN-->>C2: SIGUSR1
    C2->>C2: trap SIGUSR1 -> exit 0
    HN->>C2: Deallocate
    HN->>C3: Deallocate
    C1->>C1: exit 0
    HN->>C1: Deallocate
```