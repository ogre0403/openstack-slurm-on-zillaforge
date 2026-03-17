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
        sshpass \
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
    &&  pip install python-openstackclient


# 建立預設帳號
RUN groupadd -g 1000 kolla && \
    useradd -u 1000 -g 1000 -m -s /bin/bash kolla


ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections
RUN kolla-ansible install-deps

WORKDIR /home/kolla

COPY kolla-ansible/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
# CMD ["sleep", "infinity"]
