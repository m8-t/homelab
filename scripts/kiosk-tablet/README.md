# kiosk-tablet

Tiny Prometheus exporter for the kiosk tablet (LineageOS, no root). It runs in Termux, reads `termux-battery-status` and serves battery metrics on port 9100 (override with `EXPORTER_PORT`). Results are cached for 15s. Python stdlib only.

## Tablet setup

```sh
pkg install python termux-api openssh
```

Install the Termux:API and Termux:Boot apps from F-Droid and open Termux:Boot once so it registers for boot. Disable Android battery optimization for Termux, Termux:API and Termux:Boot, otherwise the processes get killed.

## Deploy from the host

```sh
scp -P 8022 termux-exporter.py <tablet-ip>:
ssh -p 8022 <tablet-ip> 'mkdir -p ~/.termux/boot'
scp -P 8022 start-services <tablet-ip>:.termux/boot/
ssh -p 8022 <tablet-ip> 'chmod +x ~/termux-exporter.py ~/.termux/boot/start-services'
```

`start-services` runs at boot: wake lock, `sshd`, and the exporter (each only if not already running).

## Test

```sh
curl http://<tablet-ip>:9100/metrics
```

Unit tests: `python -m unittest -v test_termux_exporter`
