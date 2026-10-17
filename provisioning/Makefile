-include .env

TPI_HOSTNAME ?= turingpi.local
TPI_USERNAME ?= root
TPI_SDCARD   := /mnt/sdcard
PASSWORD_HASH ?=

export TPI_HOSTNAME
export TPI_USERNAME
export TPI_PASSWORD
export PASSWORD_HASH

# Slot mapping (since 2026-07-03: node3 is the server, node1 rejoins as agent)
SERVER_SLOT  := 3   # node3 (172.16.20.80, SATA SSD)
AGENT1_SLOT  := 1   # node1 (172.16.20.82)
AGENT2_SLOT  := 4   # node4 (172.16.20.83)

SERVER_IP    := 172.16.20.80
AGENT1_IP    := 172.16.20.82
AGENT2_IP    := 172.16.20.83

K3S_VERSION  := v1.34.6+k3s1

# SSH public key to inject into butane templates. Override in .env or on the
# command line (SSH_PUBKEY=/path/to/key.pub make ignition).
SSH_PUBKEY   ?= $(HOME)/.ssh/id_ed25519.pub

MICROOS_RAW  := images/openSUSE-MicroOS.aarch64-RaspberryPi.raw

# Kept outside the repo tree so the admin credential never sits next to
# git-tracked files (matches the ansible group_vars default).
KUBECONFIG_PATH ?= $(HOME)/.kube/homelab-config

.PHONY: ignition images flash-all power-on wait-for-nodes \
        bootstrap-server bootstrap-agents bootstrap-k3s join-node1 \
        provision deploy-server cluster flash-node1 flash-node3 flash-node4 \
        verify-node1 verify-node3 verify-node3-k3s verify-node4 verify-node4-k3s \
        uart validate lint

# Delete targets whose recipe failed so the next `make` run actually retries
# them instead of treating the half-written output as up-to-date.
.DELETE_ON_ERROR:

## Decompress base image (run once after download)
$(MICROOS_RAW):
	xz -dk $(MICROOS_RAW).xz

## Transpile a single Butane template -> Ignition JSON.
## Substitutes @@SSH_PUBKEY@@ with the contents of $(SSH_PUBKEY) before
## piping to butane. The .bu.in files are templates; they are not valid
## butane configs on their own and must be processed through this rule.
ignition/%.ign: butane/%.bu.in $(SSH_PUBKEY)
	mkdir -p ignition
	@[ -r $(SSH_PUBKEY) ] || { echo "SSH_PUBKEY not readable: $(SSH_PUBKEY)"; exit 1; }
	@[ -n "$$PASSWORD_HASH" ] || { echo "PASSWORD_HASH is empty; set it in .env"; exit 1; }
	KEY=$$(cat $(SSH_PUBKEY)); HASH=$$PASSWORD_HASH; sed -e "s|@@SSH_PUBKEY@@|$$KEY|g" \
		-e "s|@@PASSWORD_HASH@@|$$HASH|g" \
		-e "s|@@K3S_VERSION@@|$(K3S_VERSION)|g" $< | butane --pretty --strict > $@

## Transpile all Butane configs
ignition: ignition/node1.ign ignition/node3.ign ignition/node4.ign

## Validate all ignition configs against schema (requires ignition-validate)
validate: ignition
	@for f in ignition/node1.ign ignition/node3.ign ignition/node4.ign; do \
		ignition-validate "$$f" && echo "  OK: $$f" || exit 1; \
	done

## Prepare per-node images with ignition partition baked in
images: $(MICROOS_RAW) ignition
	sudo bash prepare-image.sh node1
	sudo bash prepare-image.sh node3
	sudo bash prepare-image.sh node4

## Flash all nodes (pipeline: SCP next image while flashing current node)
## Server (node3) first -- WARNING: reflashing node3 wipes the RustFS backups
flash-all:
	tpi power off -n $(SERVER_SLOT)
	tpi power off -n $(AGENT1_SLOT)
	tpi power off -n $(AGENT2_SLOT)
	sleep 3
	scp images/node3.raw $(TPI_USERNAME)@$(TPI_HOSTNAME):$(TPI_SDCARD)/
	scp images/node1.raw $(TPI_USERNAME)@$(TPI_HOSTNAME):$(TPI_SDCARD)/ & \
		tpi flash -n $(SERVER_SLOT) -l -i $(TPI_SDCARD)/node3.raw --skip-crc; \
		S=$$?; wait; exit $$S
	ssh $(TPI_USERNAME)@$(TPI_HOSTNAME) "rm $(TPI_SDCARD)/node3.raw"
	tpi usb -n $(SERVER_SLOT) host
	tpi power on -n $(SERVER_SLOT)
	scp images/node4.raw $(TPI_USERNAME)@$(TPI_HOSTNAME):$(TPI_SDCARD)/ & \
		tpi flash -n $(AGENT1_SLOT) -l -i $(TPI_SDCARD)/node1.raw --skip-crc; \
		S=$$?; wait; exit $$S
	ssh $(TPI_USERNAME)@$(TPI_HOSTNAME) "rm $(TPI_SDCARD)/node1.raw"
	tpi usb -n $(AGENT1_SLOT) host
	tpi power on -n $(AGENT1_SLOT)
	tpi flash -n $(AGENT2_SLOT) -l -i $(TPI_SDCARD)/node4.raw --skip-crc
	ssh $(TPI_USERNAME)@$(TPI_HOSTNAME) "rm $(TPI_SDCARD)/node4.raw"
	tpi usb -n $(AGENT2_SLOT) host
	tpi power on -n $(AGENT2_SLOT)

## Power on all nodes
power-on:
	tpi power on -n $(SERVER_SLOT)
	tpi power on -n $(AGENT1_SLOT)
	tpi power on -n $(AGENT2_SLOT)
	@echo "Nodes powering on. Wait ~5-8 min for growdisk + firstboot + k3s install."

## Wait for all nodes to accept SSH
wait-for-nodes:
	@for ip in $(SERVER_IP) $(AGENT1_IP) $(AGENT2_IP); do \
		until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$$ip true 2>/dev/null; do \
			echo "  waiting for $$ip..."; sleep 10; \
		done; \
		echo "  $$ip is up"; \
	done

# ── Node verification ─────────────────────────────────────────────────────────

## Verify node1 (agent): SSH up, firstboot done, packages installed
verify-node1:
	@until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$(AGENT1_IP) true 2>/dev/null; do \
		echo "  waiting for $(AGENT1_IP)..."; sleep 10; \
	done
	@echo "node1 SSH up -- waiting for firstboot..."
	@until ssh root@$(AGENT1_IP) 'test -f /var/lib/firstboot-packages-done' 2>/dev/null; do \
		echo "  firstboot still running..."; sleep 15; \
	done
	@echo "=== node1 is up ==="
	ssh root@$(AGENT1_IP) 'hostname && ip -br addr show'
	ssh root@$(AGENT1_IP) 'rpm -q open-iscsi nfs-client curl bash-completion 2>&1'
	ssh root@$(AGENT1_IP) 'systemctl is-active iscsid'
	ssh root@$(AGENT1_IP) 'sysctl net.ipv4.ip_forward'

## Verify node3 (server): SSH up, firstboot done, packages installed
verify-node3:
	@until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$(SERVER_IP) true 2>/dev/null; do \
		echo "  waiting for $(SERVER_IP)..."; sleep 10; \
	done
	@echo "node3 SSH up -- waiting for firstboot..."
	@until ssh root@$(SERVER_IP) 'test -f /var/lib/firstboot-packages-done' 2>/dev/null; do \
		echo "  firstboot still running..."; sleep 15; \
	done
	@echo "=== node3 is up ==="
	ssh root@$(SERVER_IP) 'hostname && ip -br addr show'
	ssh root@$(SERVER_IP) 'rpm -q open-iscsi nfs-client curl bash-completion 2>&1'
	ssh root@$(SERVER_IP) 'systemctl is-active iscsid'
	ssh root@$(SERVER_IP) 'sysctl net.ipv4.ip_forward'

## Wait for k3s to be Ready on the server (node3), then print nodes
verify-node3-k3s:
	@until ssh -o StrictHostKeyChecking=no root@$(SERVER_IP) 'kubectl get nodes 2>/dev/null | grep -q Ready' 2>/dev/null; do \
		echo "  k3s not ready yet..."; sleep 15; \
	done
	ssh -o StrictHostKeyChecking=no root@$(SERVER_IP) 'kubectl get nodes'

## Verify node4 (agent): SSH up, firstboot done, packages installed
verify-node4:
	@until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$(AGENT2_IP) true 2>/dev/null; do \
		echo "  waiting for $(AGENT2_IP)..."; sleep 10; \
	done
	@echo "node4 SSH up -- waiting for firstboot..."
	@until ssh root@$(AGENT2_IP) 'test -f /var/lib/firstboot-packages-done' 2>/dev/null; do \
		echo "  firstboot still running..."; sleep 15; \
	done
	@echo "=== node4 is up ==="
	ssh root@$(AGENT2_IP) 'hostname && ip -br addr show'
	ssh root@$(AGENT2_IP) 'rpm -q open-iscsi nfs-client curl bash-completion 2>&1'
	ssh root@$(AGENT2_IP) 'systemctl is-active iscsid'
	ssh root@$(AGENT2_IP) 'sysctl net.ipv4.ip_forward'

## Wait for k3s to be Ready on node4, then print nodes
verify-node4-k3s:
	@until ssh -o StrictHostKeyChecking=no root@$(AGENT2_IP) 'kubectl get nodes 2>/dev/null | grep -q Ready' 2>/dev/null; do \
		echo "  k3s not ready yet..."; sleep 15; \
	done
	ssh -o StrictHostKeyChecking=no root@$(AGENT2_IP) 'kubectl get nodes'

# ── Bootstrap ─────────────────────────────────────────────────────────────────

## Fetch kubeconfig from the server (node3)
bootstrap-server:
	@until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$(SERVER_IP) true 2>/dev/null; do \
		echo "  waiting for SSH..."; sleep 10; \
	done
	@until ssh -o StrictHostKeyChecking=no root@$(SERVER_IP) 'kubectl get nodes 2>/dev/null | grep -q Ready' 2>/dev/null; do \
		echo "  k3s not ready yet..."; sleep 15; \
	done
	ssh -o StrictHostKeyChecking=no root@$(SERVER_IP) 'cat /var/lib/rancher/k3s/server/node-token' > .node-token
	@mkdir -p $(dir $(KUBECONFIG_PATH))
	ssh -o StrictHostKeyChecking=no root@$(SERVER_IP) 'cat /etc/rancher/k3s/k3s.yaml' | \
		sed 's/127.0.0.1/$(SERVER_IP)/' > $(KUBECONFIG_PATH)
	@chmod 600 $(KUBECONFIG_PATH)
	@echo "kubeconfig saved to $(KUBECONFIG_PATH)"

## Join node1 and node4 as k3s agents (parallel: each waits for SSH then drops token)
bootstrap-agents: .node-token
	@TOKEN=$$(cat .node-token); \
	for SLOT_IP in "$(AGENT1_IP)" "$(AGENT2_IP)"; do \
		( \
			until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$$SLOT_IP true 2>/dev/null; do \
				echo "  $$SLOT_IP: waiting for SSH..."; sleep 10; \
			done; \
			echo "  $$SLOT_IP: dropping agent token..."; \
			ssh -o StrictHostKeyChecking=no root@$$SLOT_IP \
				"echo 'K3S_URL=https://$(SERVER_IP):6443' > /var/lib/k3s-agent-token && \
				echo 'K3S_TOKEN=$$TOKEN' >> /var/lib/k3s-agent-token && \
				echo 'INSTALL_K3S_EXEC=\"agent --node-ip=$$SLOT_IP\"' >> /var/lib/k3s-agent-token"; \
			until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$$SLOT_IP \
				'systemctl is-active k3s-agent' 2>/dev/null; do \
				echo "  $$SLOT_IP: waiting for k3s-agent..."; sleep 15; \
			done; \
			echo "  $$SLOT_IP: k3s-agent running" \
		) & \
	done; \
	wait

## Join only node1 as agent (fresh token from the running server, drops token file)
join-node1:
	ssh -o StrictHostKeyChecking=no root@$(SERVER_IP) 'cat /var/lib/rancher/k3s/server/node-token' > .node-token
	@TOKEN=$$(cat .node-token); \
	until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$(AGENT1_IP) true 2>/dev/null; do \
		echo "  $(AGENT1_IP): waiting for SSH..."; sleep 10; \
	done; \
	echo "  $(AGENT1_IP): dropping agent token..."; \
	ssh -o StrictHostKeyChecking=no root@$(AGENT1_IP) \
		"echo 'K3S_URL=https://$(SERVER_IP):6443' > /var/lib/k3s-agent-token && \
		echo 'K3S_TOKEN=$$TOKEN' >> /var/lib/k3s-agent-token && \
		echo 'INSTALL_K3S_EXEC=\"agent --node-ip=$(AGENT1_IP)\"' >> /var/lib/k3s-agent-token"; \
	until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$(AGENT1_IP) \
		'systemctl is-active k3s-agent' 2>/dev/null; do \
		echo "  $(AGENT1_IP): waiting for k3s-agent..."; sleep 15; \
	done; \
	echo "  $(AGENT1_IP): k3s-agent running"

## Full k3s bootstrap: server first, then agents + addons in parallel
bootstrap-k3s: bootstrap-server
	$(MAKE) -j2 bootstrap-agents deploy-server
	@echo "Cluster bootstrapped. Run: export KUBECONFIG=$(KUBECONFIG_PATH)"

## Full pipeline: ignition + images + flash + bootstrap
provision: ignition images flash-all bootstrap-k3s
	@echo "=== Cluster fully provisioned ==="

## Deploy addons to the server (node3)
deploy-server: bootstrap-server
	cd ../ansible && ansible-playbook addons.yml -l node3 \
		-e "local_kubeconfig_path=$(KUBECONFIG_PATH)"

## Full one-shot: provision cluster + deploy addons
cluster: provision
	@echo "=== Cluster ready ==="

## Build node1 image, upload to BMC, and flash slot 1
flash-node1: ignition/node1.ign
	sudo bash prepare-image.sh node1
	tpi power off -n $(AGENT1_SLOT)
	sleep 3
	scp images/node1.raw $(TPI_USERNAME)@$(TPI_HOSTNAME):$(TPI_SDCARD)/
	tpi flash -n $(AGENT1_SLOT) -l -i $(TPI_SDCARD)/node1.raw --skip-crc
	ssh $(TPI_USERNAME)@$(TPI_HOSTNAME) "rm $(TPI_SDCARD)/node1.raw"
	tpi usb -n $(AGENT1_SLOT) host
	tpi power on -n $(AGENT1_SLOT)

## Build node3 image, upload to BMC, and flash slot 3
## WARNING: wipes the SATA SSD including RustFS Velero backups
flash-node3: ignition/node3.ign
	sudo bash prepare-image.sh node3
	tpi power off -n $(SERVER_SLOT)
	sleep 3
	scp images/node3.raw $(TPI_USERNAME)@$(TPI_HOSTNAME):$(TPI_SDCARD)/
	tpi flash -n $(SERVER_SLOT) -l -i $(TPI_SDCARD)/node3.raw --skip-crc
	ssh $(TPI_USERNAME)@$(TPI_HOSTNAME) "rm $(TPI_SDCARD)/node3.raw"
	tpi usb -n $(SERVER_SLOT) host
	tpi power on -n $(SERVER_SLOT)

## Flash only node4 (requires image already on SD card)
flash-node4:
	tpi power off -n $(AGENT2_SLOT)
	sleep 3
	tpi flash -n $(AGENT2_SLOT) -l -i $(TPI_SDCARD)/node4.raw --skip-crc
	tpi usb -n $(AGENT2_SLOT) host

## Copy SSH public key to BMC authorized_keys (run once; prompts for BMC password)
bmc-add-key:
	@KEY="$(SSH_KEY)"; HOST="$(TPI_HOSTNAME)"; USER="$(TPI_USERNAME)"; \
	[ -n "$$KEY"  ] || { printf "SSH key path [~/.ssh/id_ed25519]: "; read -r KEY;  KEY=$${KEY:-~/.ssh/id_ed25519}; }; \
	[ -n "$$HOST" ] || { printf "BMC hostname [turingpi.local]: ";     read -r HOST; HOST=$${HOST:-turingpi.local}; }; \
	[ -n "$$USER" ] || { printf "BMC username [root]: ";               read -r USER; USER=$${USER:-root}; }; \
	ssh-copy-id -i "$$KEY" "$$USER@$$HOST"

## Authenticate with TuringPi BMC (run once; token valid 3h by default)
tpi-login:
	@[ -n "$(TPI_HOSTNAME)" ] || echo "Tip: set TPI_HOSTNAME in .env to skip the tpi default (turingpi.local)"
	tpi auth

## Attach to any node UART via BMC (usage: make uart NODE=1)
## Mapping for BMC firmware >= 2.1.0: node N = ttyS(N).
## (Firmware <= 2.0.5 used node1=ttyS2, node2=ttyS1, node3=ttyS4, node4=ttyS5)
uart:
	@case "$(NODE)" in \
		1|2|3|4) DEV=ttyS$(NODE) ;; \
		*) echo "usage: make uart NODE=<1-4>"; exit 1 ;; \
	esac; \
	ssh -t $(TPI_USERNAME)@$(TPI_HOSTNAME) "picocom /dev/$$DEV -b 115200"

## Lint ansible, gitops, and shell scripts
lint:
	cd .. && yamllint ansible/ gitops/ .yamllint.yml .ansible-lint
	cd .. && ansible-lint ansible/
	shellcheck prepare-image.sh ../scripts/gen-kubeconfig.sh
