@{
    VendorKey = 'Intel_Ethernet'
    Targets   = @(
        @{
            Name    = 'Intel_2.5G_Family'
            Devices = @(
                @{ Key = 'I225-V'; Label = 'I225'; Queries = @('VEN_8086&DEV_15F3') }
                @{ Key = 'I226-V'; Label = 'I226'; Queries = @('VEN_8086&DEV_125C') }
            )
        }
        @{
            Name    = 'Intel_1G_Family'
            Devices = @(
                # e1d is unified: any single package's INF covers all I219-V/LM generations.
                @{ Key = 'I219-V'; Label = 'I219'; Queries = @('VEN_8086&DEV_15B8') }
                @{ Key = 'I210'; Label = 'I210'; Queries = @('VEN_8086&DEV_1533') }
            )
        }
        @{
            Name    = 'Intel_10G_Family'
            Devices = @(
                @{ Key = 'X540'; Label = 'X540'; Queries = @('VEN_8086&DEV_1528') }
                @{ Key = 'X550'; Label = 'X550'; Queries = @('VEN_8086&DEV_1563') }
                @{ Key = 'X710'; Label = 'X710'; Queries = @('VEN_8086&DEV_1572') }
                # X520 = 82599 (ixgbe/ixn), EOL, NOT in-box and not covered by any other scraper.
                # Newest catalog driver is v3.9.58.9101 (2017) — but ONLY via the BARE HWID query;
                # appending "Windows 11" returns an older 2012 v2.11 set instead. Multiple 82599
                # DEV ids (SFP/backplane/T3/EN/QSFP variants) all carry the same X520 driver.
                @{ Key = 'X520'; Label = 'X520'; Queries = @(
                        'VEN_8086&DEV_10FB', 'VEN_8086&DEV_10F8', 'VEN_8086&DEV_151C',
                        'VEN_8086&DEV_154A', 'VEN_8086&DEV_154D', 'VEN_8086&DEV_1557', 'VEN_8086&DEV_1558'
                    )
                }
            )
        }
        @{
            Name    = 'Intel_100G_Family'
            Devices = @(
                # FIX: E810 datacenter driver packages are NOT tagged "Windows 11", so the
                # "<HWID> Windows 11" AND-search returns 0 results and the family was silently
                # skipped every run. Query the bare HWID instead (live: 0 -> 4 results).
                @{ Key = 'E810'; Label = 'E810'; Queries = @('VEN_8086&DEV_1592') }
            )
        }
        @{
            Name    = 'Intel_AVF_Family'
            Devices = @(
                @{ Key = 'IAVF'; Label = 'IAVF'; Queries = @('VEN_8086&DEV_1889') }
            )
        }
    )
}
