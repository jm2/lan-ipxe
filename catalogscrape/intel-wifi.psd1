@{
    VendorKey = 'Intel_WiFi'
    Targets   = @(
        # Intel bundles all supported adapters into unified packages, so two searches cover
        # AC 9260 through BE200. DEV_272B is the correct Wi-Fi 7 BE200 PCI id (do NOT use
        # DEV_2725 — that is the AX210; gonefishin's providers.yaml has that wrong).
        @{
            Name    = 'Intel_WiFi7_Family'
            Devices = @(
                @{ Key = 'BE200'; Label = 'BE200'; Queries = @('VEN_8086&DEV_272B') }
            )
        }
        @{
            Name    = 'Intel_WiFi6_Family'
            Devices = @(
                @{ Key = 'AX200'; Label = 'AX200'; Queries = @('VEN_8086&DEV_2723') }
            )
        }
    )
}
