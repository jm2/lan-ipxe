@{
    # NVIDIA GPU display drivers from the Microsoft Update Catalog — single-source (NOT nvidia.com),
    # same engine as every other scraper. Verified (2026-06) that bare HWID queries return complete,
    # WHQL-signed "NVIDIA - Display" CABs (nv_dispi.inf + nvlddmkm.sys), and that HWID targeting cleanly
    # separates the two branches NVIDIA ships:
    #   * GeForce HWIDs across Ampere/Ada/Blackwell ALL resolved to the SAME unified consumer package
    #     (live: 32.0.15.9186) — so one device with several HWID queries dedups to ONE download.
    #   * RTX-pro (ex-Quadro) HWIDs resolved to a DISTINCT, newer enterprise/ODE production-branch
    #     package (live: 32.0.15.9579, ~1.16 GB) — a second device, its own download.
    # Selection is highest-version-first. The human driver version (e.g. 581.xx) maps to the INF /
    # DriverStore form 32.0.15.xxxx that the catalog reports and the engine sorts on.
    #
    # SCOPE: POST-BOOT CONVENIENCE only. A GPU cannot serve iSCSI/PXE boot, so nothing here is
    # boot-critical and it gets NO boot-start promotion in build_win11pxe.ps1 (unlike the NIC scrapers).
    #
    # ACCEPTED LIMITATIONS (catalog-only): newest-WHQL-on-catalog, NOT day-0 Game Ready (GeForce lag
    #   ~5 months), and no GRD-vs-Studio / branch-version pinning. Data Center (Tesla) and vGPU/GRID
    #   drivers are not on the by-HWID catalog and are out of scope.
    # OEM-SCOPED PACKAGES: a few catalog NVIDIA submissions are published by an OEM and locked to their
    #   SUBSYS. Highest-[version] selection normally lands on the generic NVIDIA build; if an OEM-locked
    #   INF ever wins for a retail card, add a TitleExclude here to drop it (no engine change needed).
    VendorKey = 'NVIDIA_Display'
    Targets   = @(
        @{
            Name    = 'NVIDIA_GeForce'
            Devices = @(
                # Ada (RTX 4090 = 2684), Blackwell (RTX 5090 family = 2B85), Ampere (RTX 3080 = 2206)
                # all bind the one unified consumer package; queried together they dedup to one download.
                @{ Key = 'GeForce'; Label = 'GeForce RTX (consumer, unified)';
                    Queries = @('VEN_10DE&DEV_2684', 'VEN_10DE&DEV_2B85', 'VEN_10DE&DEV_2206') }
            )
        }
        @{
            Name    = 'NVIDIA_RTX_Pro'
            Devices = @(
                # RTX 6000 Ada (26B1) + RTX A6000 Ampere (2230) -> the professional production-branch
                # package (distinct from, and typically newer than, the consumer one).
                @{ Key = 'RTX_Pro'; Label = 'RTX / Quadro (workstation)';
                    Queries = @('VEN_10DE&DEV_26B1', 'VEN_10DE&DEV_2230') }
            )
        }
    )
}
