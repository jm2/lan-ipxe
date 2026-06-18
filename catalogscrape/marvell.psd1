@{
    # Marvell Ethernet NICs. Marvell's modern NIC portfolio is two acquired lines:
    #   * Aquantia AQtion (AQC1xx, multi-gig / 10G) — acquired 2019; unified aqnic650 driver.
    #   * QLogic FastLinQ (QL41xxx/45xxx, 10/25/100G; VEN_1077, qend.sys) — acquired via Cavium.
    #
    # FastLinQ is deliberately NOT scraped here: the qend driver is NOT on the Microsoft Update
    # Catalog in any form. Verified (2026-06) that EVERY VEN_1077&DEV_*, "qend", "QLogic FastLinQ",
    # "QL41162/41164", and "FastLinQ 41000/45000" query returns 0 results. A bare "Marvell FastLinQ"
    # name search returns only Aquantia "Marvell - Net" packages (Marvell tags its whole NIC line
    # with the brand) — every hit extracts to aqnic650.sys / VEN_1D6A, i.e. the SAME Aquantia driver
    # the AQC entry below already pulls (and an OLDER build than the HWID query finds). So a FastLinQ
    # entry would be mislabeled, redundant, and a downgrade. Source qend from Marvell's site / OEM
    # channel, or rely on the in-box driver; it cannot be obtained from the catalog.
    #
    # Marvell's own-design "Yukon" 88E80xx is GbE-only and in-box; out of this 10GbE+ scope.
    VendorKey = 'Marvell_Ethernet'
    Targets   = @(
        @{
            Name    = 'Marvell_Aquantia_PCIe'
            Devices = @(
                # One unified driver (aqnic650.sys, Provider=Marvell, VEN_1D6A) covers the ENTIRE
                # AQC1xx PCIe family — its INF binds 25 device ids including DEV_D107 (AQC107) and
                # DEV_04C0 (AQC113). Verified both HWID searches resolve to byte-identical INF/SYS.
                # Both ids are queried for robustness; results dedup to the single newest package
                # (live: v3.1.11.0, 2026-03-19) and produce ONE download, not two.
                @{ Key = 'AQC1xx'; Label = 'Aquantia AQtion AQC1xx 10G/multi-gig (AQC107/AQC113)';
                    Queries = @('VEN_1D6A&DEV_D107', 'VEN_1D6A&DEV_04C0') }
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
    )
}
