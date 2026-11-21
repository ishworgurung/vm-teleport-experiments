"""A counting loop for CPython compiled to WebAssembly (experiment 3).

Each _ckpt.checkpoint() may pause this process and resume it on another
machine; `i` and `total` must carry on as if nothing happened.
"""

import platform
import sys

import _ckpt

print(f"python {sys.version.split()[0]} on {sys.platform}/{platform.machine()}")
total = 0
for i in range(40):
    total += i
    print(f"hello world {i} total={total}")
    if i in (9, 19, 29):
        _ckpt.checkpoint()
