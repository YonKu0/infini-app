# Infini-Quest Deployment Guide

## Table of Contents

* [Prerequisites](#prerequisites)
* [Repository Setup](#repository-setup)
* [Download Fedora CoreOS](#download-fedora-coreos)
* [Generate Ignition Config](#generate-ignition-config)
* [Launch the VM with QEMU](#launch-the-vm-with-qemu)

  * [OS-Specific Flags](#os-specific-flags)
* [SSH Key Setup](#ssh-key-setup)
* [SSH Access](#ssh-access)
* [Validate Random IP Address](#validate-random-ip-address)
* [Deployment](#deployment)
* [Post-Deployment Testing](#post-deployment-testing)
* [Persistence Verification](#persistence-verification)
* [Troubleshooting](#troubleshooting)

---

### Note on `localhost`

> Throughout this guide, `localhost` is used to refer to the local loopback address. You may substitute `localhost` with `127.0.0.1` in any command or URL — both are functionally equivalent.

---

## Prerequisites

Before you begin, ensure the following are installed on your host machine:

* **QEMU**: Follow the instructions at [https://www.qemu.org/download/](https://www.qemu.org/download/) to install QEMU for your operating system.
* **Butane (optional)**: You can install Butane natively or use the Docker image `quay.io/coreos/butane:release`.
* **`xz` utility**: For decompressing `.xz` images.
* **`curl`**: For downloading the CoreOS image.
* **Git**: To clone the repository.
* **SSH client**: To connect to the VM.
* **Docker/Podman**: Required by the deployment script on the VM.

## Repository Setup

Clone the project repository:

   ```bash
   git clone https://github.com/YonKu0/infini-app.git
   ```

## Download Fedora CoreOS

1. Download Fedora CoreOS QEMU v41.20250315.3.0 image:

   ```bash
   curl -Lo vm-config/fedora-coreos-41.20250315.3.0-qemu.x86_64.qcow2.xz \
   https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/41.20250315.3.0/x86_64/fedora-coreos-41.20250315.3.0-qemu.x86_64.qcow2.xz
   ```
   
2. Decompress the image:

   ```bash
   xz -d vm-config/fedora-coreos-41.20250315.3.0-qemu.x86_64.qcow2.xz
   ```


## SSH Key Setup

### Generate SSH Key Pair (One-Time Setup)

Generate an SSH key pair for this project. 

```bash
mkdir secrets && ssh-keygen -t ed25519 -f secrets/infini_ops_id_ed25519 -C "infini-ops" -N ""
```

This will generate:

* `secrets/infini_ops_id_ed25519` (private key)
* `secrets/infini_ops_id_ed25519.pub` (public key)

### Update Your Butane Config

In your `butane-config.yml`, under `passwd.users[0].ssh_authorized_keys`, insert the contents of the `.pub` file:

```yaml
passwd:
  users:
    - name: infini-ops
      groups: [sudo, docker]
      home_dir: /home/infini-ops
      shell: /bin/bash
      ssh_authorized_keys:
        - ssh-ed25519 AAAAC3...xyz infini-ops # << Put here the public key
```

> 📌 You can copy it with:

```bash
cat secrets/infini_ops_id_ed25519.pub
```

Or insert it automatically with this command:

For Linux
```bash
pubkey=$(<secrets/infini_ops_id_ed25519.pub)
sed -i -E "s|^(\s*-\s*)ssh-ed25519\s+.*|\1${pubkey//\//\/}|" vm-config/butane-config.yml
```

For MacOS
```bash
pubkey=$(<secrets/infini_ops_id_ed25519.pub)
sed -i '' -E "s|^([[:space:]]*-[[:space:]]*)ssh-ed25519[[:space:]]+.*|\1${pubkey//\//\\/}|" vm-config/butane-config.yml
```

Then regenerate the ignition config:

```bash
docker run --rm -i -v "$PWD/vm-config:/pwd" quay.io/coreos/butane:release \
  --pretty < vm-config/butane-config.yml > vm-config/config.ign
```

## Launch the VM with QEMU

Use the following base command to launch the VM. Append the appropriate **acceleration flag** based on your operating system.

### Base Command

```bash
qemu-system-x86_64 \
  -m 8096 -smp 2 \
  -drive if=virtio,file=vm-config/fedora-coreos-41.20250315.3.0-qemu.x86_64.qcow2 \
  -fw_cfg name=opt/com.coreos/config,file=vm-config/config.ign \
  -nic user,hostfwd=tcp::2222-:22,hostfwd=tcp::5050-:5050,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443,hostfwd=tcp::9090-:9090 \
  -nic user,model=virtio
```

### OS-Specific Flags

To improve performance, add the following flag depending on your platform:

* **Linux:** Add `-enable-kvm`
* **Windows:** Add `-accel whpx`
* **macOS:** No additional flag needed


## SSH Access

1. Ensure your SSH agent is running and load your key:

   ```bash
   eval "$(ssh-agent -s)"
   ssh-add secrets/infini_ops_id_ed25519
   ```
2. Wait for the VM to fully boot and connect to it:

   ```bash
   ssh -i secrets/infini_ops_id_ed25519 -p 2222 infini-ops@localhost
   ```

## Validate Random IP Address

Once logged in:

```bash
ip addr | grep 'inet 192.168.'
```

You should see an address in the `192.168.42.1–192.168.69.254` range. Reboot the VM to verify persistence:

```bash
sudo reboot
# After reconnecting via SSH again
ip addr | grep 'inet 192.168.'
```

## How `deploy.sh` Works

The `deploy.sh` script automates the deployment of your Docker Compose application and Prometheus on a Fedora CoreOS VM:

1. **Pre-flight checks**: Verifies you have `ssh`, `scp`, `ping`, `curl` and that `docker-compose.yml` and `prometheus.yml` exist in your local app directory.
2. **VM reachability & SSH wait**: Pings the VM and retries SSH until it's reachable.
3. **Port conflict scan**: Ensures nothing else is listening on your app (5050) or Prometheus (9090) ports on the VM.
4. **Copy files**: Uses `scp` to push your application code and config files into `~/$APP_DIR` on the VM.
5. **Deploy stack**: SSHes into the VM, tears down any existing stack, builds images, and brings up containers in the background.
6. **Health-check**: Polls the `/metrics` endpoint until it returns HTTP 200 with valid Prometheus output.


## Deployment

1. From your project root, run:

   ```bash
   bash scripts/deploy.sh \
     -i <VM_IP> \
     -k <SSH_KEY> \
     -P <SSH_PORT> \
     [-u <SSH_USER>] \
     [-d <APP_DIR>] \
     [-p <APP_PORT>]
   ```

2. Common flags:

   * `-i`: VM IP address (required)
   * `-k`: SSH key file (default: `~/.ssh/id_rsa`)
   * `-P`: SSH port on VM (default: `22`)
   * `-u`: SSH username (default: `infini-ops`)
   * `-d`: Remote directory (default: `app`)
   * `-p`: Application port (default: `5050`)

**Example:**

```bash
 bash scripts/deploy.sh \
   -i localhost \
   -k secrets/infini_ops_id_ed25519 \
   -P 2222
```

## Post-Deployment Testing

On your host machine, verify:

* **Application metrics:**

  ```bash
  curl http://localhost:5050/metrics
  ```
* **API endpoint:**

  ```bash
  curl http://localhost:5050/api/items
  ```
* **Prometheus UI:** Open `http://localhost:9090` in your browser.

### Database Write Test

```bash
curl -X POST http://localhost:5050/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "Test Item", "quantity": 13, "price": 9.99}'
```

Expected JSON response:

```json
{
  "created_at": "2025-04-30T12:08:38.800742",
  "id": "<uuid>"
}
```

## Persistence Verification

1. Reboot the VM:

   ```bash
   sudo reboot
   ```
2. SSH back in and confirm:

   * The random IP is unchanged.
   * Both containers are running:

     ```bash
     docker ps | grep -E 'infini-app|prometheus'
     ```

## Troubleshooting

* **Port Collisions:** Ensure ports `22`, `5050`, `80`, `443`, and `9090` are free on your host.
* **SSH Failures:** Confirm your SSH key permissions (`chmod 600`) and that the agent has your key.
* **Ignition Errors:** Use `butane --strict` locally to validate your `butane-config.yml`.
* **Disk Space:** Verify you have enough disk space for the CoreOS image and containers.

## Design Decisions & Trade‑Offs
* **Butane + Ignition** allows fully automated, reproducible VM bootstrapping without manual provisioning. Using `ConditionFirstBoot=yes` ensures the random IP assignment runs only once.
* **Multistage Docker build** balances build-time dependencies isolation and minimal runtime footprint.
* **docker-compose** chosen for simplicity in a single‑node context; could be replaced by Kubernetes in larger deployments.
* **Retry logic** and **port checks** in `deploy.sh` increase robustness against transient network issues and resource conflicts.
---
## Future Improvements
* **Scaling:** Migrate to Kubernetes or Nomad for dynamic service discovery and horizontal scaling.
* **Security:** Integrate TLS certificates via Let’s Encrypt; enable Docker Content Trust.
* **Observability:** Add Grafana dashboards; integrate centralized logging (ELK or Loki).
* **High Availability:** Use multiple VM replicas with load‑balancer and shared persistence (NFS or Object Storage).
---
## Resources & References
* Fedora CoreOS docs: [https://docs.fedoraproject.org/en-US/fedora-coreos/](https://docs.fedoraproject.org/en-US/fedora-coreos/)
* Butane GitHub: [https://github.com/coreos/butane](https://github.com/coreos/butane)
* Docker best practices: [https://docs.docker.com/develop/develop-images/dockerfile\_best-practices/](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
* Prometheus docs: [https://prometheus.io/docs/](https://prometheus.io/docs/)
