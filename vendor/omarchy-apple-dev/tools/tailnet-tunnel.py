#!/usr/bin/env python3
# graft's copy of tools/tailnet-tunnel.py from joshuaswarren/omarchy-apple-dev, MIT license
# (vendor/omarchy-apple-dev/LICENSE), taken at d585573d9da52394abba82840f6b5e6d15e304c7. graft's
# changes: without --port it looks for the RemotePairing port in the whole dynamic range (upstream:
# 49152-49167), first on the port that worked last (--port-file), and its exit status says whether
# the device answered at all. When OMARCHY_REF moves, diff upstream's file from that commit to the
# new one and apply what's useful here.
"""Open an iOS 27 RemotePairing tunnel to a phone over Tailscale (or any routed IP).

  tailnet-tunnel.py pair                    one time, phone on USB: write a host-independent pairing record
  tailnet-tunnel.py HOST [--port P | --port-file FILE] [--hold SECONDS] [--udid U]
                                            tunnel to HOST (the phone's 100.x address); prints one line
                                            "RSD <address> <port>" for `--rsd` options and holds the tunnel

Without --port it finds the RemotePairing port: the one in --port-file for the device, if that still
works, else the open ports in 49152-65535 (lockdownd's 62078 aside), each tried with the pairing
record. The port that works goes into --port-file. Exit status 3: nothing answered (the device is
asleep, locked or off the tailnet); 4: ports answered, but none took the RemotePairing handshake.

The tunnel needs a TUN device, so the tunnel command runs as root (it re-executes itself with sudo).
Run it with pymobiledevice3's Python (the venv that has `pymobiledevice3` installed).
"""
import argparse
import asyncio
import os
import plistlib
import resource
import sys
from contextlib import suppress
from pathlib import Path

PORT_SCAN = range(49152, 65536)
LOCKDOWN_PORT = 62078
# The scan's connects at once, and how long each waits. More at once loses SYNs on the way; the
# device answers in well under a second, also through a DERP relay.
SCAN_CONNECTS = 1000
SCAN_TIMEOUT = 1.0
# How long a port gets to finish the handshake (the RemotePairing port takes well under a second;
# other services hold the connection open without answering), and a port given with --port.
TRY_TIMEOUT = 4
PORT_TIMEOUT = 20
NO_ANSWER, NO_REMOTEPAIRING = 3, 4
RECORD_DIR = Path.home() / ".local/share/pymobiledevice3"


def records():
    return sorted(RECORD_DIR.glob("remote_*.plist"))


def pick_udid(udid):
    if udid:
        return udid
    found = [p.stem.removeprefix("remote_") for p in records()]
    if len(found) != 1:
        sys.exit(f"need --udid: {len(found)} RemotePairing records in {RECORD_DIR}")
    return found[0]


def pair():
    """`lockdown remotepairing --pair` over USB, then pin the host identifier into the record.

    pymobiledevice3 derives the host identifier from this machine's hostname and the phone ties the
    pairing key to it. Without the pinned value the record works only on the machine that made it.
    """
    import subprocess

    from pymobiledevice3.pair_records import generate_host_id

    exe = Path(sys.executable).with_name("pymobiledevice3")
    subprocess.run([str(exe), "lockdown", "remotepairing", "--pair"], check=True, stdout=subprocess.DEVNULL)
    for p in records():
        d = plistlib.loads(p.read_bytes())
        d.setdefault("host_identifier", generate_host_id())
        p.write_bytes(plistlib.dumps(d))
        p.chmod(0o600)
        print(f"pairing record ready: {p} (copy this file to any host that should reach the phone)")


async def connect(udid, host, port, timeout=PORT_TIMEOUT):
    from pymobiledevice3.remote.tunnel_service import RemotePairingTunnelService

    svc = RemotePairingTunnelService(udid, host, port)
    try:
        await asyncio.wait_for(svc.connect(autopair=False), timeout=timeout)
    except BaseException:
        # Also when cancelled, which connect() doesn't close for once the socket is open.
        with suppress(Exception):
            await svc.close()
        raise
    return svc


async def first_service(udid, host, ports):
    """The handshake on PORTS at once: the first service to complete it, or None."""
    tries = {asyncio.create_task(connect(udid, host, p, TRY_TIMEOUT)): p for p in ports}
    found = None
    async for t in asyncio.as_completed(tries):
        try:
            found = await t
            break
        except Exception as e:
            print(f"{host}:{tries[t]}: no RemotePairing handshake: {e!r}", file=sys.stderr)
    for t in tries:
        t.cancel()
    for r in await asyncio.gather(*tries, return_exceptions=True):
        if not isinstance(r, BaseException) and r is not found:
            await r.close()
    return found


async def knock(host, port, timeout):
    """Whether PORT accepts a TCP connection: True, False when refused, None when nothing answers."""
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except ConnectionRefusedError:
        return False
    except (OSError, TimeoutError, asyncio.TimeoutError):
        return None
    w.close()
    return True


async def answers(host):
    """Whether HOST answers at all, on a few ports, open or refused. Saves scanning one that's off."""
    knocks = [asyncio.create_task(knock(host, p, 3)) for p in (LOCKDOWN_PORT, *PORT_SCAN[:8])]
    try:
        async for t in asyncio.as_completed(knocks):
            if await t is not None:
                return True
        return False
    finally:
        for t in knocks:
            t.cancel()


async def open_ports(host, ports):
    """Of PORTS, the open ones, and the ones that didn't answer."""
    gate = asyncio.Semaphore(SCAN_CONNECTS)

    async def gated(port):
        async with gate:
            return await knock(host, port, SCAN_TIMEOUT)

    results = await asyncio.gather(*(gated(p) for p in ports))
    return [p for p, r in zip(ports, results) if r], [p for p, r in zip(ports, results) if r is None]


def remembered(path, udid):
    """The port in PATH for UDID, or None."""
    with suppress(OSError):
        for line in path.read_text().splitlines():
            f = line.split()
            if len(f) == 2 and f[0] == udid and f[1].isdigit():
                return int(f[1])


def remember(path, udid, port):
    keep = []
    with suppress(OSError):
        keep = [l for l in path.read_text().splitlines() if l.split() and l.split()[0] != udid]
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("".join(f"{l}\n" for l in [*keep, f"{udid} {port}"]))
    tmp.replace(path)


async def scan(udid, host, tried):
    """The service on an open port in PORT_SCAN (but TRIED and lockdownd's) that takes the handshake.

    A burst of connects loses some of them on the way, so when the open ports found have no
    service, the ports that didn't answer get a second pass.
    """
    if not await answers(host):
        sys.stderr.write(f"nothing answered on {host}\n")
        sys.exit(NO_ANSWER)
    todo = [p for p in PORT_SCAN if p not in (LOCKDOWN_PORT, tried)]
    seen = []
    for _ in range(2):
        found, todo = await open_ports(host, todo)
        seen += found
        if found:
            print(f"open on {host}: {' '.join(map(str, found))}", file=sys.stderr)
            if svc := await first_service(udid, host, found):
                return svc
        if not todo:
            break
    if seen:
        sys.stderr.write(f"{host} answered on {' '.join(map(str, sorted(seen)))}, but none took the RemotePairing handshake\n")
        sys.exit(NO_REMOTEPAIRING)
    # A device closes its RemotePairing port while it's locked or idle.
    sys.stderr.write(f"{host} answered, but no port in {PORT_SCAN.start}-{PORT_SCAN.stop - 1} is open\n")
    sys.exit(NO_ANSWER)


async def find_service(udid, host, port, port_file):
    if port:
        try:
            return await connect(udid, host, port)
        except (OSError, TimeoutError, asyncio.TimeoutError) as e:
            sys.stderr.write(f"no RemotePairing service answered on {host}:{port}: {e!r}\n")
            sys.exit(NO_ANSWER)
    last = remembered(port_file, udid) if port_file else None
    if last and (svc := await first_service(udid, host, [last])):
        return svc
    svc = await scan(udid, host, last)
    if port_file:
        remember(port_file, udid, svc.port)
    return svc


async def tunnel(args):
    from pymobiledevice3.remote.common import TunnelProtocol
    from pymobiledevice3.remote.tunnel_service import start_tunnel_over_remotepairing

    udid = pick_udid(args.udid)
    svc = await find_service(udid, args.host, args.port, args.port_file)
    # TCP needs TLS-PSK ciphers (Python 3.13+ with sslpsk); older Pythons use QUIC, as pymobiledevice3 does.
    proto = TunnelProtocol.TCP if sys.version_info >= (3, 13) else TunnelProtocol.QUIC
    async with start_tunnel_over_remotepairing(svc, protocol=proto) as t:
        print(f"RSD {t.address} {t.port}", flush=True)
        await asyncio.sleep(args.hold)


def main():
    if sys.argv[1:2] == ["pair"]:
        return pair()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("--port", type=int, help="RemotePairing port (default: find it in 49152-65535)")
    ap.add_argument("--port-file", type=Path,
                    help='"UDID PORT" lines: try the port there first, and keep the one that works')
    ap.add_argument("--hold", type=int, default=3600, help="seconds to keep the tunnel open")
    ap.add_argument("--udid")
    args = ap.parse_args()
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", "-n", "env", f"HOME={Path.home()}", sys.executable, *sys.argv])
    # A socket for each of the scan's connects.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = SCAN_CONNECTS + 256
    if soft != resource.RLIM_INFINITY and soft < want:
        resource.setrlimit(resource.RLIMIT_NOFILE, (want if hard == resource.RLIM_INFINITY else min(want, hard), hard))
    asyncio.run(tunnel(args))


if __name__ == "__main__":
    main()
