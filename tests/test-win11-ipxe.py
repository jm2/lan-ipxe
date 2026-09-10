#!/usr/bin/env python3
"""Exercise the generated Windows iPXE control flow with simulated NICs/LUNs."""
import copy
import ipaddress
import re
import subprocess
import unittest
from pathlib import Path

SOURCE = (Path(__file__).resolve().parents[1] / "update-pxe-images.sh").read_text()
BLOCK = SOURCE.split(":win11-pxe\n", 1)[1].split("\nEOF", 1)[0]
# Expand the actual Bash heredoc, preserving iPXE's escaped runtime variables.
MENU = subprocess.check_output(
    ["bash"], input="PXE_SERVER=192.168.1.11:81\nISCSI_TARGET_IQN=iqn.test:win11\n"
    "ISCSI_INITIATOR_PREFIX=iqn.test\ncat <<EOF\n" + BLOCK + "\nEOF\n", text=True
)
SERVER = ipaddress.ip_address("192.168.1.11")


def nic(ip="192.168.1.50", gateway="192.168.1.1", **extra):
    return {"ip": ip, "netmask": "255.255.255.0", "gateway": gateway,
            "mac": "00-11-22-33-44-55", "open": True, **extra}


class Boot:
    def __init__(self, interfaces):
        self.interfaces = copy.deepcopy(interfaces)
        self.settings = {}
        self.attempts = []
        self.dhcp = []
        self.attached = None
        self.booted = None
        self.lines = [line.strip() for line in MENU.splitlines()
                      if line.strip() and not line.lstrip().startswith("#")]
        self.labels = {line[1:]: i for i, line in enumerate(self.lines) if line.startswith(":")}

    def get(self, key):
        key = key.split(":", 1)[0]
        if "/" in key:
            device, property_name = key.split("/", 1)
            return self.interfaces.get(device, {}).get(property_name, "")
        return self.settings.get(key, "")

    def expand(self, text):
        for _ in range(10):
            expanded = re.sub(r"\$\{([^{}]+)\}", lambda m: str(self.get(m[1])), text)
            if expanded == text:
                return expanded
            text = expanded
        raise AssertionError("Unresolved recursive setting")

    def command(self, text):
        args = self.expand(text).split()
        if not args:
            return True
        cmd, *args = args
        if cmd == "echo":
            return True
        if cmd == "goto":
            if args[0] == "shell":
                self.finished = True
            else:
                self.pc = self.labels[args[0]]
            self.jumped = True
            return True
        if cmd == "set":
            key = args[0].split(":", 1)[0]
            value = " ".join(args[1:])
            if "/" in key:
                device, property_name = key.split("/", 1)
                self.interfaces[device][property_name] = value
            else:
                self.settings[key] = value
            return True
        if cmd == "isset":
            return bool(args)
        if cmd == "iseq":
            return len(args) == 2 and args[0] == args[1]
        if cmd == "inc":
            self.settings[args[0]] = int(self.get(args[0])) + 1
            return True
        if cmd in ("ifopen", "ifclose"):
            targets = args or list(self.interfaces)
            for target in targets:
                if target not in self.interfaces:
                    return False
                self.interfaces[target]["open"] = cmd == "ifopen"
            return True
        if cmd == "dhcp":
            device = args[-1]
            self.dhcp.append(device)
            address = self.interfaces[device].get("lease", "")
            self.interfaces[device]["ip"] = address
            return bool(address)
        if cmd == "sanunhook":
            self.attached = None
            return True
        if cmd == "sanhook":
            opened = [name for name, data in self.interfaces.items() if data["open"]]
            assert len(opened) == 1, "Another NIC could silently supply the route"
            device = opened[0]
            data = self.interfaces[device]
            self.attempts.append((device, data["gateway"]))
            local = SERVER in ipaddress.ip_network(data["ip"] + "/" + data["netmask"], strict=False)
            reachable = local or data["gateway"] not in ("", "0.0.0.0") or bool(data.get("121"))
            if reachable and data.get("authorized", True) and data.get("link", True):
                assert self.settings["initiator-iqn"] == "iqn.test:" + data["mac"]
                self.attached = device
                return True
            return False
        if cmd == "sanboot":
            assert args == ["--drive", "0x80"], "Boot must reuse the verified attachment"
            assert self.attached is not None
            self.booted = self.attached
            self.finished = True
            return True
        raise AssertionError("Unhandled iPXE command: " + cmd)

    def run(self):
        self.pc = 0
        self.finished = False
        for _ in range(3000):
            if self.finished:
                return self
            line = self.lines[self.pc]
            self.pc += 1
            if line.startswith(":"):
                continue
            parts = re.split(r"\s*(&&|\|\|)\s*", line)
            status = True
            self.jumped = False
            for i in range(0, len(parts), 2):
                if i == 0 or (parts[i - 1] == "&&" and status) or (parts[i - 1] == "||" and not status):
                    status = self.command(parts[i])
                    if self.jumped or self.finished:
                        break
            assert status or self.finished, "Unhandled failure would terminate iPXE: " + line
        raise AssertionError("Unbounded interface loop")


class GatewayTests(unittest.TestCase):
    def test_same_subnet(self):
        result = Boot({"net0": nic()}).run()
        self.assertEqual(result.booted, "net0")
        self.assertEqual(result.interfaces["net0"]["gateway"], "0.0.0.0")

    def test_route_on_second_nic_and_interface_number_gap(self):
        result = Boot({"net0": nic(authorized=False),
                       "net2": nic(mac="00-aa-bb-cc-dd-ee")}).run()
        self.assertEqual(result.booted, "net2")
        self.assertFalse(result.interfaces["net0"]["open"])
        self.assertEqual(result.interfaces["net0"]["gateway"], "192.168.1.1")
        self.assertEqual(result.interfaces["net2"]["gateway"], "0.0.0.0")

    def test_remote_subnet_restores_gateway(self):
        result = Boot({"net1": nic("10.0.0.50", "10.0.0.1")}).run()
        self.assertEqual(result.booted, "net1")
        self.assertEqual(result.attempts, [("net1", "0.0.0.0"), ("net1", "10.0.0.1")])

    def test_static_routes_preserve_gateway(self):
        result = Boot({"net0": nic("10.0.0.50", "10.0.0.1", **{"121": "static-route-bytes"})}).run()
        self.assertEqual(result.attempts, [("net0", "10.0.0.1")])

    def test_dhcp_only_when_needed(self):
        result = Boot({"net0": nic(ip="", lease="192.168.1.50")}).run()
        self.assertEqual(result.dhcp, ["net0"])
        self.assertEqual(result.booted, "net0")
        self.assertEqual(Boot({"net0": nic()}).run().dhcp, [])
        self.assertEqual(Boot({"net0": nic(ip="0.0.0.0", lease="192.168.1.50")}).run().dhcp, ["net0"])
        self.assertIsNone(Boot({"net0": nic(ip="")}).run().booted)

    def test_no_lun_does_not_boot_or_leave_gateway_changed(self):
        result = Boot({"net0": nic(authorized=False)}).run()
        self.assertIsNone(result.booted)
        self.assertEqual(result.interfaces["net0"]["gateway"], "192.168.1.1")
        self.assertIsNone(Boot({}).run().booted)


if __name__ == "__main__":
    unittest.main()
