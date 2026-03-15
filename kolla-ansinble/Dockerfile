FROM rockylinux/rockylinux:9

RUN     dnf makecache \
    &&  dnf -y update \
    &&  dnf -y install \
        git \
        python3-devel \
        libffi-devel \
        gcc \
        openssl-devel \
        python3-libselinux \
    &&  dnf clean all \
    &&  rm -rf /var/cache/dnf

RUN     dnf -y install \
        python3.11 \
        python3.11-devel \
    &&  dnf clean all \
    &&  rm -rf /var/cache/dnf \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9  1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 2

RUN curl -sS https://bootstrap.pypa.io/get-pip.py | /usr/bin/python3.11

RUN     pip install git+https://opendev.org/openstack/kolla-ansible@stable/2024.2 \
    &&  kolla-ansible install-deps

RUN     pip install python-openstackclient
