@{
    # Intel GPU display drivers (DCH) from the Microsoft Update Catalog — single-source, same engine
    # as every other scraper. Intel ships a UNIFIED DCH driver: one "Intel Corporation - Display" CAB
    # (iigd_dch*.inf + igdkmd*64.sys) binds Arc A-series (DG2/Alchemist), Arc B-series (Battlemage),
    # Iris Xe, and recent Core / Core Ultra integrated graphics. So a single device with several
    # representative HWID queries dedups to ONE download (the Marvell AQC1xx pattern) and the winning
    # INF binds the whole modern lineup. Selection is highest-version-first (catalog date as tiebreak).
    #
    # SCOPE: POST-BOOT CONVENIENCE only. A GPU cannot serve iSCSI/PXE boot, so nothing here is
    # boot-critical and it gets NO boot-start promotion in build_win11pxe.ps1 (unlike the NIC scrapers).
    #
    # COVERAGE LIMITS (catalog-only, intentional):
    #   * Catalog lags intel.com by ~1-4 months and is WHQL-only (no beta). Fine for a homelab image.
    #   * Very old iGPUs (6th-10th gen) sit on a separate legacy branch (intel.com download 19344) and
    #     are NOT pulled here. Arc Pro ISV-certified drivers are not published to the catalog (out of scope).
    #   * Drive ONLY by HWID: a bare "Intel ... Display" NAME query returns 1000+ unpaginated rows and the
    #     engine parses only the first 25 relevance rows; a per-HWID query returns the Display CAB up top.
    # Representative DEV ids (VEN_8086): E20B = Arc B580, 56A0 = Arc A770, 9A49 = Iris Xe (Tiger Lake),
    # 7D55 = Arc iGPU (Meteor Lake). All resolve to the same unified package.
    VendorKey = 'Intel_Display'
    Targets   = @(
        @{
            Name    = 'Intel_Graphics_DCH'
            Devices = @(
                @{ Key = 'Arc_Xe'; Label = 'Intel Arc / Iris Xe / UHD (unified DCH)';
                    Queries = @('VEN_8086&DEV_E20B', 'VEN_8086&DEV_56A0', 'VEN_8086&DEV_9A49', 'VEN_8086&DEV_7D55') }
            )
        }
    )
}
