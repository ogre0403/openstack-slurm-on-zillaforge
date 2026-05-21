# These initial groups are the only groups required to be modified. The
# additional groups are for more control of the environment.

[compute]
%{ for node in compute_nodes ~}
${node.name} ansible_host=${node.ip}
%{ endfor ~}
