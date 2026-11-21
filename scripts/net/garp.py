"""Send a gratuitous ARP: "the address IP is at my MAC", to the whole segment.

  python3 garp.py DEV IP          (run as root: it opens a raw packet socket)

When a floating IP (VIP) moves from one host to another, the other machines on
the segment still hold an ARP-cache entry that maps the VIP to the OLD host's
MAC. They keep sending frames there until the entry expires. A gratuitous ARP
replaces that entry at once. The guest image has no arping, so this does what
`arping -U` does, with the packet laid out below (RFC 5227, section 3).
"""

import socket
import struct
import sys

dev, ip = sys.argv[1], socket.inet_aton(sys.argv[2])
# AF_PACKET + SOCK_RAW: we write whole Ethernet frames. 0x0806 is ARP.
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
s.bind((dev, 0))
mac = s.getsockname()[4]
BROADCAST = b"\xff" * 6
frame = (
    # Ethernet header: destination, source, EtherType 0x0806 (ARP).
    BROADCAST
    + mac
    + struct.pack("!H", 0x0806)
    # ARP: hardware type 1 (Ethernet), protocol 0x0800 (IPv4), address sizes
    # 6 and 4, opcode 1 (request). "Request" is what arping -U sends.
    + struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1)
    # Sender MAC and IP, then target MAC (unknown: zeros) and IP. A gratuitous
    # ARP has the same IP as sender and target: it asks about itself.
    + mac
    + ip
    + b"\x00" * 6
    + ip
)
for _ in range(3):
    s.send(frame)
print(f"garp: {sys.argv[2]} is at {mac.hex(':')} (sent on {dev})")
