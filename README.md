# Whonix Proxmox Setup Script

An automated bash script for deploying Whonix Gateway and Workstation VMs on Proxmox VE 9.1.5+.

## Overview

This script automates the deployment of Whonix, a privacy-focused virtual desktop environment that routes all traffic through Tor. It creates two VMs:
- **Whonix Gateway**: Routes traffic through Tor and provides network isolation
- **Whonix Workstation**: Isolated workstation that can only communicate via the Gateway

## Prerequisites

- Proxmox VE 9.1.5 or later
- Root access to the Proxmox host
- Internet connection for downloading Whonix templates
- Sufficient storage space (~6GB for both VMs)
- `wget` or `curl` for downloads

## Quick Start

```bash
# Download the script
wget https://raw.githubusercontent.com/sjanett/Whonix-Proxmox-setup/main/whonix-proxmox-setup.sh

# Make it executable
chmod +x whonix-proxmox-setup.sh

# Run the script
./whonix-proxmox-setup.sh
```

### One-Line Installation

For a quick installation, you can use the following one-line command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sjanett/Whonix-Proxmox-setup/main/whonix-proxmox-setup.sh)"
```

Or using wget:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/sjanett/Whonix-Proxmox-setup/main/whonix-proxmox-setup.sh)"
```

## Configuration

Edit the script variables before running, or use command-line options:

```bash
# Run with custom storage locations
./whonix-proxmox-setup.sh --iso-storage local --disk-storage local-lvm

# Run with custom resource allocation
./whonix-proxmox-setup.sh --gateway-ram 1024 --workstation-ram 4096

# Skip confirmation prompts
./whonix-proxmox-setup.sh --yes
```

### Configurable Options

| Option | Default | Description |
|--------|---------|-------------|
| `STORAGE_ISO` | `local` | Storage backend for ISO/OVA files |
| `STORAGE_DISK` | `local-lvm` | Storage backend for VM disk images |
| `GATEWAY_CPU` | `1` | CPU cores for Gateway VM |
| `GATEWAY_RAM` | `512` | RAM (MB) for Gateway VM |
| `WORKSTATION_CPU` | `2` | CPU cores for Workstation VM |
| `WORKSTATION_RAM` | `2048` | RAM (MB) for Workstation VM |
| `GATEWAY_DISK_SIZE` | `10` | Disk size (GB) for Gateway |
| `WORKSTATION_DISK_SIZE` | `20` | Disk size (GB) for Workstation |
| `GATEWAY_NAME` | `Whonix-Gateway` | VM name for Gateway |
| `WORKSTATION_NAME` | `Whonix-Workstation` | VM name for Workstation |
| `EXTERNAL_BRIDGE` | `vmbr0` | External network bridge |
| `INTERNAL_BRIDGE` | `vmbr1` | Internal Whonix network bridge |
| `AUTOSTART` | `true` | Auto-start VMs on Proxmox boot |

## Network Architecture

```
Internet ──→ vmbr0 (External) ──→ Gateway (eth1)
                                      │
                                      ↓
                                 Gateway (eth0)
                                      │
                                      ↓
                                 vmbr1 (Internal)
                                      │
                                      ↓
                              Workstation (eth0)
```

- **Gateway**: Connected to both external (vmbr0) and internal (vmbr1) networks
- **Workstation**: Only connected to internal network (vmbr1), completely isolated from external network
- All Workstation traffic is routed through Tor via the Gateway

## Command-Line Options

```
Usage: whonix-proxmox-setup.sh [OPTIONS]

Options:
  --iso-storage NAME      Storage for ISO files (default: local)
  --disk-storage NAME     Storage for VM disks (default: local-lvm)
  --gateway-cpu N         Gateway CPU cores (default: 1)
  --gateway-ram N         Gateway RAM in MB (default: 512)
  --workstation-cpu N     Workstation CPU cores (default: 2)
  --workstation-ram N     Workstation RAM in MB (default: 2048)
  --gateway-disk N        Gateway disk size in GB (default: 10)
  --workstation-disk N    Workstation disk size in GB (default: 20)
  --gateway-name NAME     Gateway VM name (default: Whonix-Gateway)
  --workstation-name NAME Workstation VM name (default: Whonix-Workstation)
  --gateway-id N          Gateway VM ID (default: auto)
  --workstation-id N      Workstation VM ID (default: auto)
  --external-bridge NAME  External bridge name (default: vmbr0)
  --internal-bridge NAME  Internal bridge name (default: vmbr1)
  --no-autostart          Disable auto-start on boot
  --no-bridge             Don't create internal bridge
  --yes                   Skip confirmation prompts
  --dry-run               Show what would be done without executing
  --help                  Show this help message
  --version               Show version information
```

## Logs

The script logs all operations to `/var/log/whonix-setup.log`.

## Post-Installation

After the script completes:

1. Wait 2-3 minutes for Whonix services to initialize
2. The Gateway will automatically connect to the Tor network
3. Check Tor status in the Gateway console
4. Start the Workstation VM after the Gateway is fully booted

### Accessing the VMs

```bash
# Access Gateway console
qm terminal <gateway-vm-id>

# Access Workstation console
qm terminal <workstation-vm-id>

# Or use the Proxmox web interface
```

## Troubleshooting

### Common Issues

**VM fails to start:**
- Check that storage backends exist and have sufficient space
- Verify the VM IDs are not already in use

**Network connectivity issues:**
- Ensure the external bridge (vmbr0) is properly configured
- Check that the internal bridge (vmbr1) was created successfully

**Download failures:**
- Verify internet connectivity from the Proxmox host
- Try downloading the template manually and specify the path

## Security Considerations

- The Workstation VM is completely isolated from the external network
- All Workstation traffic is routed through Tor
- The Gateway should be kept updated for security patches
- Review Whonix documentation for additional security hardening

## License

This script is provided under the MIT License.

## Contributing

Contributions are welcome! Please submit issues and pull requests to the GitHub repository.

## References

- [Whonix Documentation](https://www.whonix.org/wiki/Documentation)
- [Proxmox VE Documentation](https://pve.proxmox.com/wiki/Main_Page)
- [Tor Project](https://www.torproject.org/)
