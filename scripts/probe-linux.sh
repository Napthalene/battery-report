#!/usr/bin/env bash
set -euo pipefail

duration_seconds="${1:-30}"
interval_seconds="${2:-5}"
output_path="${3:-}"

if [[ "$interval_seconds" -lt 1 ]]; then
  echo "interval_seconds must be at least 1" >&2
  exit 1
fi

if [[ "$duration_seconds" -lt 0 ]]; then
  echo "duration_seconds must be 0 or greater" >&2
  exit 1
fi

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

read_file_value() {
  local path="$1"
  if [[ -r "$path" ]]; then
    cat "$path"
  fi
}

emit_power_supply() {
  local first_device=true
  printf '['
  for device in /sys/class/power_supply/*; do
    [[ -d "$device" ]] || continue
    if [[ "$first_device" == false ]]; then
      printf ','
    fi
    first_device=false

    local name type status online voltage_now current_now power_now energy_now charge_now capacity
    name="$(basename "$device")"
    type="$(read_file_value "$device/type")"
    status="$(read_file_value "$device/status")"
    online="$(read_file_value "$device/online")"
    voltage_now="$(read_file_value "$device/voltage_now")"
    current_now="$(read_file_value "$device/current_now")"
    power_now="$(read_file_value "$device/power_now")"
    energy_now="$(read_file_value "$device/energy_now")"
    charge_now="$(read_file_value "$device/charge_now")"
    capacity="$(read_file_value "$device/capacity")"

    printf '{'
    printf '"name":%s,' "$(printf '%s' "$name" | json_escape)"
    printf '"type":%s,' "$(printf '%s' "$type" | json_escape)"
    printf '"status":%s,' "$(printf '%s' "$status" | json_escape)"
    printf '"online":%s,' "$(printf '%s' "$online" | json_escape)"
    printf '"voltageNowMicrovolts":%s,' "${voltage_now:-null}"
    printf '"currentNowMicroamps":%s,' "${current_now:-null}"
    printf '"powerNowMicrowatts":%s,' "${power_now:-null}"
    printf '"energyNowMicrowattHours":%s,' "${energy_now:-null}"
    printf '"chargeNowMicroampHours":%s,' "${charge_now:-null}"
    printf '"capacityPercent":%s' "${capacity:-null}"
    printf '}'
  done
  printf ']'
}

emit_hwmon_power() {
  local first_sensor=true
  printf '['
  for input in /sys/class/hwmon/hwmon*/power*_input; do
    [[ -r "$input" ]] || continue
    if [[ "$first_sensor" == false ]]; then
      printf ','
    fi
    first_sensor=false

    local hwmon sensor_name label power microwatts
    hwmon="$(dirname "$input")"
    sensor_name="$(basename "$input" _input)"
    label_file="$hwmon/${sensor_name}_label"
    label="$(read_file_value "$label_file")"
    power="$(read_file_value "$input")"

    printf '{'
    printf '"path":%s,' "$(printf '%s' "$input" | json_escape)"
    printf '"chip":%s,' "$(printf '%s' "$(read_file_value "$hwmon/name")" | json_escape)"
    printf '"label":%s,' "$(printf '%s' "$label" | json_escape)"
    printf '"powerMicrowatts":%s' "${power:-null}"
    printf '}'
  done
  printf ']'
}

emit_rapl_powercap() {
  local first_zone=true
  printf '['
  for zone in /sys/class/powercap/intel-rapl:*; do
    [[ -d "$zone" ]] || continue
    if [[ "$first_zone" == false ]]; then
      printf ','
    fi
    first_zone=false

    printf '{'
    printf '"path":%s,' "$(printf '%s' "$zone" | json_escape)"
    printf '"name":%s,' "$(printf '%s' "$(read_file_value "$zone/name")" | json_escape)"
    printf '"energyMicrojoules":%s,' "$(read_file_value "$zone/energy_uj")"
    printf '"maxEnergyRangeMicrojoules":%s' "$(read_file_value "$zone/max_energy_range_uj")"
    printf '}'
  done
  printf ']'
}

emit_sample() {
  printf '{'
  printf '"timestampUtc":%s,' "$(date -u +"%Y-%m-%dT%H:%M:%SZ" | json_escape)"
  printf '"powerSupply":'
  emit_power_supply
  printf ',"hwmonPower":'
  emit_hwmon_power
  printf ',"raplEnergy":'
  emit_rapl_powercap
  printf '}'
}

sample_count=1
if [[ "$duration_seconds" -gt 0 ]]; then
  sample_count=$(( duration_seconds / interval_seconds ))
  if [[ "$sample_count" -lt 1 ]]; then
    sample_count=1
  fi
fi

json="$(
  printf '{'
  printf '"probeVersion":1,'
  printf '"platform":"linux",'
  printf '"durationSeconds":%s,' "$duration_seconds"
  printf '"intervalSeconds":%s,' "$interval_seconds"
  printf '"samples":['
  for ((index = 0; index < sample_count; index++)); do
    if [[ "$index" -gt 0 ]]; then
      printf ','
    fi
    emit_sample
    if [[ "$index" -lt $(( sample_count - 1 )) ]]; then
      sleep "$interval_seconds"
    fi
  done
  printf '],'
  printf '"interpretation":{'
  printf '"bestSignals":['
  printf '%s' '"powerSupply power_now is direct battery/adapter power when present.",'
  printf '%s' '"hwmon power*_input exposes hardware component power such as CPU/GPU/package when available.",'
  printf '%s' '"intel-rapl energy_uj allows CPU package energy integration from differences between samples.",'
  printf '%s' '"Battery energy_now/current_now is weak for plugged-and-full laptops because battery flow can be near zero."'
  printf ']}}'
)"

if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  printf '%s\n' "$json" > "$output_path"
  echo "Wrote probe report to $output_path"
else
  printf '%s\n' "$json"
fi
