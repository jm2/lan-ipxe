@{
    # AMD Radeon GPU display drivers from the Microsoft Update Catalog — single-source, same engine as
    # every other scraper. Verified (2026-06) that consumer HWIDs return "Advanced Micro Devices, Inc. -
    # Display" WHQL CABs (amdkmdag.sys), and that Radeon Pro (W-series) HWIDs return a real Pro-keyed
    # BASE WHQL display CAB (live: W7900 DEV_7448 -> 32.0.21036.18). The ISV-certified "PRO Edition /
    # Radeon PRO Software for Enterprise" SKU is NOT published to the catalog — the base display driver
    # drives the card fully (display + compute runtime) and is what we ship; ISV certification is out of
    # scope. Selection is highest-version-first (catalog date as tiebreak).
    #
    # SCOPE: POST-BOOT CONVENIENCE only. A GPU cannot serve iSCSI/PXE boot, so nothing here is
    # boot-critical and it gets NO boot-start promotion in build_win11pxe.ps1 (unlike the NIC scrapers).
    #
    # WHY ONE DEVICE PER FAMILY (not a single multi-HWID device like Intel/NVIDIA): AMD ships a current
    #   branch (RX 6000-9000 / RDNA2-4) and a separate legacy branch, and the catalog carries per-family
    #   submissions — so pooling families under one Key risks the highest-[version] winner being a package
    #   whose INF does not bind an older family. Keeping families separate guarantees each listed card gets
    #   a binding driver (cost: one download per family — trim this table to the cards you actually run).
    # COVERAGE: catalog lags amd.com by ~1 quarter. The 25-relevance-row cap is sharper for AMD (many
    #   per-Windows-build submissions per HWID); the newest build normally still sits in the top rows.
    # Representative DEV ids (VEN_1002): 7550 = RX 9000 (Navi48), 744C = RX 7900 (Navi31),
    #   73BF = RX 6800/6900 (Navi21), 7448 = Radeon Pro W7900 (Navi31 GL), 73A3 = Radeon Pro W6800 (Navi21 GL).
    VendorKey = 'AMD_Display'
    Targets   = @(
        @{
            Name    = 'AMD_Radeon_Consumer'
            Devices = @(
                @{ Key = 'RX9000'; Label = 'Radeon RX 9000 (RDNA4)'; Queries = @('VEN_1002&DEV_7550') }
                @{ Key = 'RX7000'; Label = 'Radeon RX 7000 (RDNA3)'; Queries = @('VEN_1002&DEV_744C') }
                @{ Key = 'RX6000'; Label = 'Radeon RX 6000 (RDNA2)'; Queries = @('VEN_1002&DEV_73BF') }
            )
        }
        @{
            Name    = 'AMD_Radeon_Pro'
            Devices = @(
                @{ Key = 'ProW7000'; Label = 'Radeon Pro W7000 (RDNA3)'; Queries = @('VEN_1002&DEV_7448') }
                @{ Key = 'ProW6000'; Label = 'Radeon Pro W6000 (RDNA2)'; Queries = @('VEN_1002&DEV_73A3') }
            )
        }
    )
}
