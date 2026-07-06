# dns-watch

Small DNS availability and latency monitor for Quad9 and Elisa DNS resolvers.

The monitor checks configured DNS servers with dig, records response times, and sends Gotify plus email notifications when a resolver repeatedly fails or becomes unacceptably slow.

## Current behavior

- Checks Quad9:
  - 9.9.9.9
  - 149.112.112.112
- Checks Elisa:
  - 193.229.0.40
  - 193.229.0.42
- Runs once per minute through a systemd timer.
- Alerts after 3 consecutive bad checks.
- Treats DNS responses over 500 ms as slow.
- Sends recovery notifications after a previously alerted resolver becomes healthy again.

## Files

- dns-watch.sh
- systemd/dns-watch.service
- systemd/dns-watch.timer
- examples/dns-watch.env.example

## Notification config

The script reads notification settings from:

- /etc/dns-watch/dns-watch.env

You can override this path with the DNS_WATCH_ENV_FILE environment variable.

The env file is expected to define:

- GOTIFY_URL
- GOTIFY_TOKEN
- MAIL_FROM
- MAIL_TO
- MSMTP_BIN

The real env file contains secrets and must not be committed.

## Prerequisites

This monitor does not use a Python virtual environment.

It expects these system tools to be available:

- bash
- dig, from the dnsutils package
- curl
- msmtp, or another working mail command
- systemd
- reachable Gotify server and app token, if Gotify notifications are used

On Ubuntu/Debian, install the practical dependencies with:

    sudo apt update
    sudo apt install dnsutils curl msmtp

The host must also have a working notification config. By default, the script reads:

- /etc/dns-watch/dns-watch.env

Copy examples/dns-watch.env.example there and edit it for your host.

## Install

Create the notification config:

    sudo install -d -m 750 -o root -g root /etc/dns-watch
    sudo cp examples/dns-watch.env.example /etc/dns-watch/dns-watch.env
    sudo chmod 600 /etc/dns-watch/dns-watch.env
    sudo nano /etc/dns-watch/dns-watch.env

Copy the script:

    sudo cp dns-watch.sh /usr/local/bin/dns-watch.sh
    sudo chmod 755 /usr/local/bin/dns-watch.sh

Copy the systemd units:

    sudo cp systemd/dns-watch.service /etc/systemd/system/dns-watch.service
    sudo cp systemd/dns-watch.timer /etc/systemd/system/dns-watch.timer

Enable the timer:

    sudo systemctl daemon-reload
    sudo systemctl enable --now dns-watch.timer

## Check status

    systemctl status dns-watch.timer --no-pager
    systemctl list-timers dns-watch.timer
    sudo tail -n 20 /var/log/dns-watch.log

## Test manually

    sudo /usr/local/bin/dns-watch.sh
    sudo tail -n 20 /var/log/dns-watch.log

## Notes

This monitor intentionally uses DNS queries instead of ICMP ping.

Ping only shows whether a host responds at the network level. This script checks whether the resolver actually answers DNS queries and how long the response takes.
