"""Fixtures for Slurm and OpenStack collector test data."""


# --- Slurm scontrol --oneliner fixtures ---

SCONTROL_NODES_OUTPUT = """\
NodeName=slurm-compute-1 Arch=x86_64 CoresPerSocket=2 CPUAlloc=0 CPUTot=4 CPULoad=0.00 AvailableFeatures=(null) ActiveFeatures=(null) Gres=(null) NodeAddr=192.168.95.10 NodeHostName=slurm-compute-1 OS=Linux RealMemory=8000 AllocMem=0 FreeMem=7500 Sockets=2 Boards=1 State=IDLE ThreadsPerCore=1 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A Partitions=all,odd Reason=none
NodeName=slurm-compute-2 Arch=x86_64 CoresPerSocket=2 CPUAlloc=4 CPUTot=4 CPULoad=3.50 AvailableFeatures=(null) ActiveFeatures=(null) Gres=(null) NodeAddr=192.168.95.11 NodeHostName=slurm-compute-2 OS=Linux RealMemory=8000 AllocMem=8000 FreeMem=2000 Sockets=2 Boards=1 State=ALLOCATED ThreadsPerCore=1 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A Partitions=all,even Reason=none
NodeName=slurm-compute-3 Arch=x86_64 CoresPerSocket=2 CPUAlloc=0 CPUTot=4 CPULoad=0.00 AvailableFeatures=(null) ActiveFeatures=(null) Gres=(null) NodeAddr=192.168.95.12 NodeHostName=slurm-compute-3 OS=Linux RealMemory=8000 AllocMem=0 FreeMem=7500 Sockets=2 Boards=1 State=DOWN* ThreadsPerCore=1 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A Partitions=all,odd Reason=Not responding
"""

# --- OpenStack CLI JSON fixtures ---

COMPUTE_SERVICE_LIST_JSON = """[
  {
    "ID": "abc-123",
    "Binary": "nova-compute",
    "Host": "slurm-compute-3",
    "Zone": "nova",
    "Status": "enabled",
    "State": "up"
  },
  {
    "ID": "abc-124",
    "Binary": "nova-compute",
    "Host": "slurm-compute-4",
    "Zone": "nova",
    "Status": "enabled",
    "State": "up"
  },
  {
    "ID": "abc-125",
    "Binary": "nova-scheduler",
    "Host": "controller",
    "Zone": "internal",
    "Status": "enabled",
    "State": "up"
  }
]"""

NETWORK_AGENT_LIST_JSON = """[
  {
    "ID": "net-001",
    "Agent Type": "OVN Controller agent",
    "Host": "slurm-compute-3",
    "Alive": true,
    "State": true,
    "Binary": "ovn-controller"
  },
  {
    "ID": "net-002",
    "Agent Type": "OVN Controller agent",
    "Host": "slurm-compute-4",
    "Alive": true,
    "State": true,
    "Binary": "ovn-controller"
  }
]"""
