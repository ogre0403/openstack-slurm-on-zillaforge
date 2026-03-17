

image:
	docker build -t kolla-ansible:latest -f kolla-ansible/Dockerfile .

kolla-up:
	docker compose -f kolla-ansible/docker-compose.yaml up -d

kolla-exec:
	docker exec -u kolla -w /home/kolla -e HOME=/home/kolla -it kolla_ansible bash

kolla-down:
	docker compose -f kolla-ansible/docker-compose.yaml down
