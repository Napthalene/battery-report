# Deploying BatteryService on a Linux VM

BatteryService is cloneable and deployable without a build step on Linux. The
Linux logger is a Python 3 script managed by `systemd`.

## 1. Clone

```bash
git clone <your-repo-url> BatteryService
cd BatteryService
```

If the shell scripts are not executable after clone, either run them through
`bash` or set executable bits:

```bash
chmod +x batteryservice.sh scripts/*.sh src/linux/batteryservice_linux.py
```

## 2. Check prerequisites

```bash
bash ./scripts/bootstrap-linux.sh --check
```

Required:

- Python 3
- systemd, for service installation

Optional:

- PowerShell (`pwsh`) only if you want to generate the rich HTML report on
  Linux using `batteryservice.sh report`.

## 3. Test one sample

```bash
./batteryservice.sh sample
tail -n 5 ./logs/power-minute-linux.csv
```

## 4. Install service

```bash
sudo bash ./scripts/bootstrap-linux.sh --install
```

Equivalent direct command:

```bash
sudo bash ./scripts/install-linux-systemd.sh
sudo bash ./scripts/install-linux-cli.sh
```

## 5. Operate service

```bash
systemctl status batteryservice --no-pager
sudo systemctl restart batteryservice
journalctl -u batteryservice -n 100 --no-pager
tail -n 10 ./logs/power-minute-linux.csv
```

## 6. Usage reports

Table output works with Python only:

```bash
./batteryservice.sh usage --from 2026-07-31 --group-by day -o table
./batteryservice.sh usage --group-by month -o json
```

After installing the CLI, use it from anywhere:

```bash
batteryservice usage --from 2026-07-31 --group-by day -o table
batteryservice status
batteryservice logs
```

HTML report generation through `batteryservice.sh report` requires PowerShell
(`pwsh`) on Linux. If you do not want that dependency, use:

```bash
./batteryservice.sh usage --group-by day -o html --output-file ./reports/usage.html
```

## 7. Serve report on the local network

Start a live HTTP report server:

```bash
batteryservice start-serve --days 7 --port 8765
```

Open it from another machine on the same LAN:

```text
http://VM-IP:8765/
```

Find the VM IP with:

```bash
hostname -I
```

The default bind address is `0.0.0.0`, which exposes the report on the VM's
network interfaces. Use it only on a trusted LAN/VPN, or bind to localhost for
SSH tunnel access:

```bash
batteryservice start-serve --host 127.0.0.1 --port 8765
```

## 8. Update existing deployment

After changes are pushed to GitHub:

```bash
cd /path/to/BatteryService
sudo batteryservice update
```

If the global command is not installed yet:

```bash
cd /path/to/BatteryService
sudo bash ./scripts/update-linux.sh
```

## Notes

- The service unit installed at `/etc/systemd/system/batteryservice.service`
  points to the clone path. If you move the repository, reinstall the service.
- Generated files under `logs/`, `reports/`, `bin/`, and local tools are ignored
  by Git.
- Linux power accuracy depends on available `/sys` telemetry. The logger uses
  direct power sensors where available and CPU-load estimation as fallback.
