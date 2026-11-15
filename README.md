# valhalla-pi-setup

One-shot installer for a fully offline [Valhalla](https://github.com/valhalla/valhalla) routing stack on a Raspberry Pi (or any 64-bit Debian-family machine). No containers: everything runs natively as systemd services.

You get, behind a single web port (default 8100):

- **Valhalla** routing engine (turn-by-turn routes, isochrones)
- **Vector map tiles with POIs**, built from OpenStreetMap with [planetiler](https://github.com/onthegomap/planetiler) and served by [go-pmtiles](https://github.com/protomaps/go-pmtiles)
- **[Photon](https://github.com/komoot/photon)** place, address and POI search (optional)
- The official **[Valhalla web app](https://github.com/valhalla/web-app)**, patched to use only the local services

## Usage

```bash
curl -fsSLO https://raw.githubusercontent.com/jlaprade-git/valhalla-pi-setup/main/setup-valhalla-pi.sh
sudo bash setup-valhalla-pi.sh --region north-america/us/illinois
```

The region is a [Geofabrik](https://download.geofabrik.de) path: the part of the download URL between the host name and `-latest.osm.pbf`. Examples: `europe/andorra`, `north-america/us/texas`, `europe/germany/berlin`.

When it finishes it prints the address to open, for example `http://<pi-address>:8100`.

### Options

| Option | Meaning |
|---|---|
| `--region PATH` | Geofabrik region (required on the first run, remembered afterwards) |
| `--search PATH` | Photon index: `auto` (default, derived from the region), `none`, or an explicit path such as `north-america/usa` |
| `--data-dir DIR` | Install location (default `/opt/valhalla-stack`). Point it at an SSD if you have one. |
| `--web-port N` | Web interface port (default 8100, or the next free port) |
| `--center LAT,LON` | Initial map position (default: middle of the region) |
| `--yes` | Do not ask for confirmation |
| `--no-start` | Install everything but do not enable or start services |
| `--uninstall` | Stop and remove the services and the nginx site |

## Requirements

- 64-bit OS (arm64 or amd64), Debian 12 or newer / Raspberry Pi OS
- 4 GB RAM minimum, 8 GB recommended
- An SSD is strongly recommended
- A Pi can build a city, a state or a small country. Do not try a continent.

## Disk space

Search dominates: the prebuilt Photon index is per country (the whole USA for any US state), about a 10.6 GB download that unpacks to roughly 17 GB. Rough totals:

| Region | Final, with search | Final, no search | Peak during install |
|---|---|---|---|
| Rhode Island | about 18 GB | about 1 GB | about 33 GB |
| Illinois | about 20 GB | about 2.5 GB | about 37 GB |
| Texas | about 21 GB | about 4 GB | about 41 GB |
| California | about 23 GB | about 5.5 GB | about 49 GB |

These are estimates. The script prints its own estimate and the free space before it starts.

## Playing nicely with other services

- Internal services (routing, tiles, search) listen on 127.0.0.1 only.
- Every port is checked before use. If one is taken, the next free port is chosen.
- If nginx is already installed, one extra site is added and existing sites are untouched. If it is not, nginx is installed without claiming port 80.
- Everything lives under one directory and runs as a dedicated `valhalla` system user.
- Safe to re-run: finished steps are skipped and interrupted downloads resume.

## Managing it

```bash
systemctl status valhalla-routing valhalla-tiles valhalla-photon
journalctl -u valhalla-routing -f
sudo bash setup-valhalla-pi.sh --uninstall
```

## Test status

Tested end to end on Debian 13 (amd64) with a small region: install, port-collision handling, routing, map rendering and search. Not yet tested on real Raspberry Pi hardware, and the fallback path for Debian 12 (private Python 3.12) has not been exercised. Time-dependent routing is limited because no time zone database is built.

## Credits

Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors. Tile schema © [OpenMapTiles](https://openmaptiles.org/). Map style based on [OpenFreeMap](https://openfreemap.org/) Liberty. Search indexes from the Photon project, hosted by GraphHopper.
