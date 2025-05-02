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

1. Clone the project repository:

   ```bash
   git clone https://github.com/YonKu0/infini-app.git
   ```
2. Change into the vm configuration directory:

   ```bash
   cd infini-app/vm-config
   ```

## Download Fedora CoreOS

1. Download the latest Fedora CoreOS QEMU image:

   ```bash
   curl -LO https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/42.20250410.3.1/x86_64/fedora-coreos-42.20250410.3.1-qemu.x86_64.qcow2.xz
   ```
2. Decompress the image:

   ```bash
   xz -d fedora-coreos-42.20250410.3.1-qemu.x86_64.qcow2.xz
   ```


## SSH Key Setup

### Generate SSH Key Pair (One-Time Setup)

If you don’t already have an SSH key pair for this project, generate one:

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
docker run --rm -i -v "$(pwd):/pwd" quay.io/coreos/butane:release \
  --pretty < butane-config.yml > config.ign
```

## Launch the VM with QEMU

Use the following base command to launch the VM. Append the appropriate **acceleration flag** based on your operating system.

### Base Command

```bash
qemu-system-x86_64 \
  -m 8096 -smp 2 \
  -drive if=virtio,file=fedora-coreos-42.20250410.3.1-qemu.x86_64.qcow2 \
  -fw_cfg name=opt/com.coreos/config,file=config.ign \
  -nic user,hostfwd=tcp::2222-:22,hostfwd=tcp::5050-:5050,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443,hostfwd=tcp::9090-:9090 \
  -nic user,model=virtio
```

### OS-Specific Flags

To improve performance, add the following flag depending on your platform:

* **Linux:** Add `-enable-kvm`
* **Windows:** Add `-accel whpx`
* **macOS:** No additional flag needed


## SSH Access

1. Open a new terminal and navigate to your secrets directory:

   ```bash
   cd secrets
   ```
2. Ensure your SSH agent is running and load your key:

   ```bash
   eval "$(ssh-agent -s)"
   ssh-add infini_ops_id_ed25519
   ```
3. Wait for the VM to fully boot and connect to it:

   ```bash
   ssh -i infini_ops_id_ed25519 -p 2222 infini-ops@localhost
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

## Deployment

1. On your local machine, ensure you’re in the project root directory.
2. Run the deployment script:

   ```bash
   bash scripts/deploy.sh -i localhost  -k secrets/infini_ops_id_ed25519 -P 2222
   ```

   * `-i`: VM IP address
   * `-k`: SSH key file
   * `-P`: SSH port

The script will:

* Copy application code, Dockerfiles, and Prometheus configs to the VM
* Build and start the application and Prometheus containers
* Validate the `/metrics` endpoint

## Post-Deployment Testing

From your host machine, verify the following:

* **Application metrics:**

  ```bash
  curl http://localhost:5050/metrics
  ```
* **REST API endpoint:**

  ```bash
  curl http://localhost:5050/api/items
  ```
* **Prometheus UI:**
  Open in browser: `http://localhost:9090`

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

Reboot the VM again:

```bash
sudo reboot
```

After reconnecting via SSH, ensure:

* The random IP address is unchanged
* Application and Prometheus containers are running:

  ```bash
  docker ps | grep -E 'infini-app|prometheus'
  ```

## Troubleshooting

* **Port Collisions:** Ensure ports `22`, `5050`, `80`, `443`, and `9090` are free on your host.
* **SSH Failures:** Confirm your SSH key permissions (`chmod 600`) and that the agent has your key.
* **Ignition Errors:** Use `butane --strict` locally to validate your `butane-config.yml`.
* **Disk Space:** Verify you have enough disk space for the CoreOS image and containers.
