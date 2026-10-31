# wlperch — TODO

Open items only; what's done is in the git history and the README.

## Features
- [ ] Time tracker: optional window-rule assignment on numbered workspaces (e.g. by app/title)
- [ ] Calculator: persist the history across daemon runs

## Not yet verified for real
- [ ] Group lock: a live end-to-end check on real monitors (tested in headless sway only)
- [ ] Tuya 3.3/3.4 against real devices: only 3.5 verified live; 3.3/3.4 covered by tinytuya test vectors
- [ ] Audio presets: applying one live (desk.sh switches audio to an output that wasn't available)
- [ ] Idle: the Sunshine hold (`wlperch idle hold sunshine --pid …`) during a real stream
- [ ] Background service: the systemd switch-over end to end in a real session
- [ ] Release: the aarch64 build on real ARM hardware (tested under qemu only)
- [ ] Release: the workflow's publish step (runs on the next `v*` tag)
