# Measurement Strategy

The main target is estimating laptop energy use while the machine is plugged in
and accessed remotely, with no external power meter.

## Practical model

For this usage pattern, the first software-only model should be:

```text
estimated_total_watts = cpu_package_watts + gpu_watts + platform_baseline_watts
energy_wh = estimated_total_watts * elapsed_hours
```

The platform baseline covers RAM, SSD, network, chipset, fans, conversion losses,
and other components that are not included in CPU/GPU package sensors.

The current Windows estimator uses this tunable CPU model:

```text
cpu_estimated_watts = cpu_idle_watts +
    (cpu_tdp_watts - cpu_idle_watts) * (cpu_load_percent / 100) ^ cpu_curve_exponent
```

The defaults are intentionally conservative:

- CPU idle: `2.5 W`
- CPU TDP: `45 W`
- CPU curve exponent: `1.35`
- Platform baseline: `7 W`

These should be calibrated later against battery discharge or an external meter
if higher accuracy is needed.

## Signal priority

1. Direct system or adapter watt sensor.
2. CPU/GPU/component power sensors plus configurable baseline.
3. Battery discharge estimate when unplugged.
4. Battery charge/current only as contextual data while plugged in.

Battery telemetry alone is not enough when the laptop is plugged in and full,
because battery current can be zero while the laptop still draws AC power.

## Probe scripts

Use these scripts to discover what a specific machine exposes:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\probe-windows.ps1 -DurationSeconds 60 -IntervalSeconds 5 -OutputPath .\probe-windows.json
```

```bash
bash ./scripts/probe-linux.sh 60 5 ./probe-linux.json
```

The Windows probe checks:

- Windows power-related performance counters.
- WMI/CIM battery classes.
- OpenHardwareMonitor/LibreHardwareMonitor WMI power sensors if available.
- NVIDIA GPU power through `nvidia-smi` if available.

If LibreHardwareMonitor is available locally, the dedicated probe loads
`LibreHardwareMonitorLib.dll` directly and does not require the GUI or WMI:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\probe-librehardwaremonitor.ps1 -DurationSeconds 60 -IntervalSeconds 5 -OutputPath .\probe-librehardwaremonitor.json
```

The Linux probe checks:

- `/sys/class/power_supply`.
- `/sys/class/hwmon/*/power*_input`.
- Intel RAPL energy counters under `/sys/class/powercap`.

## How to interpret results

Good first-version sources:

- `\Power Meter(*)\Power` on Windows.
- `SensorType = Power` from OpenHardwareMonitor/LibreHardwareMonitor WMI.
- `SensorType = Power` from the direct LibreHardwareMonitor library probe.
- `power.draw` from `nvidia-smi`.
- `power*_input` from Linux `hwmon`.
- Intel RAPL energy deltas for CPU package energy.

Weak plugged-in/full-battery sources:

- Battery percentage.
- Battery estimated runtime.
- Battery current close to zero.
- Battery charge rate when the battery is already full.

## Service storage target

The service should store one row per minute:

```sql
CREATE TABLE power_minute (
    timestamp_utc INTEGER PRIMARY KEY,
    sample_count INTEGER NOT NULL,
    average_watts REAL NOT NULL,
    minimum_watts REAL,
    maximum_watts REAL,
    energy_wh REAL NOT NULL,
    source TEXT NOT NULL,
    confidence TEXT NOT NULL
);
```

Hourly, daily, and monthly consumption can be queried from minute rows using
`SUM(energy_wh)`.
