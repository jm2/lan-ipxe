@{
    # Marvell Ethernet NICs. Marvell's modern NIC portfolio is two acquired lines:
    #   * Aquantia AQtion (AQC1xx, multi-gig / 10G)  — acquired 2019
    #   * QLogic FastLinQ (QL41xxx/45xxx, 10/25/100G) — acquired via Cavium
    # Both are current Marvell products, so both live here. (Marvell's own-design "Yukon"
    # 88E80xx is GbE-only and in-box; out of this 10GbE+ scope.)
    VendorKey = 'Marvell_Ethernet'
    Targets   = @(
        @{
            Name    = 'Marvell_Aquantia_PCIe'
            Devices = @(
                @{ Key = 'AQC107'; Label = 'AQC107'; Queries = @('VEN_1D6A&DEV_D107') }
                @{ Key = 'AQC113'; Label = 'AQC113'; Queries = @('VEN_1D6A&DEV_04C0') }
            )
        }
        @{
            Name    = 'Marvell_Aquantia_USB'
            Devices = @(
                # FIX: the old VID_1D6A&PID_D111 (+TRENDnet VID_20F4 / ASIX VID_0B95) entries
                # all returned 0 results — 1D6A is Aquantia's PCIe vendor id, not a USB VID.
                # The real first-party USB id is VID_2ECA&PID_C101 (live: 20 results, Aquantia
                # Net v1.8.0.0). These are Win10-era WHQL packages, so the "Windows 11" suffix
                # also zeroes them: query bare. Drivers are chipset-wide, so the single
                # first-party id covers the TRENDnet/ASIX rebrands too.
                @{ Key = 'AQC111U'; Label = 'AQC111U'; Queries = @('VID_2ECA&PID_C101') }
            )
        }
        @{
            Name    = 'Marvell_FastLinQ'
            Devices = @(
                # FastLinQ (qend) is ONE unified Windows driver across the whole 41000 (QL41xxx,
                # 10/25/40/50G incl. QL41162/41164 10GBASE-T) AND 45000 (QL45xxx, up to 100G)
                # series, so the single name query covers both. The catalog has NO 45xxx- or HWID-
                # specific entry (every QL45000/FastLinQ 45000/VEN_1077&DEV_* search returns 0);
                # the driver is reachable only by NAME, as OEM (Lenovo/Dell/HPE) "Marvell - Net"
                # listings — newest v3.1.4.0 (2021-08). Bare (name-based); not in-box; storage
                # personalities excluded. Adding 45xxx-specific queries would be dead (0 results) —
                # 45xxx is covered by the same unified package this already pulls.
                @{ Key = 'FastLinQ'; Label = 'FastLinQ 41xxx/45xxx 10-100G (QL41162/41164, QL45xxx)';
                    Queries = @('Marvell FastLinQ', 'FastLinQ');
                    TitleExclude = @('(?i)FCoE', '(?i)iSCSI', '(?i)storage') }
            )
        }
    )
}
