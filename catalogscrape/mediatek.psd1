@{
    VendorKey = 'MediaTek_WiFi'
    Targets   = @(
        @{
            Name    = 'MediaTek_WiFi_Family'
            Devices = @(
                # One entry per driver GENERATION, not per chip: each generation ships a single
                # unified INF covering every hwid below (verified by extracting live packages),
                # so per-chip entries (a) re-download the identical CAB once per chip and
                # (b) stale-pick whenever the newest package only surfaces in a sibling's
                # 25-row relevance window. Observed before consolidation (2026-08): RZ608/MT7921
                # stuck on 3.5.0.1392/25.40.2.585 while 26.40.2.587 sat in RZ616's window only;
                # MT7927 stuck on 26.30.3.64 while 26.40.3.65 sat in MT7925's window only.
                # Selection is highest-version-first per Key+Arch group; hwid verification
                # (engine) requires any of the HWID-shaped queries below to appear in the
                # record's Supported Hardware IDs and in the extracted INF.

                # Wi-Fi 6/6E (mtkwl6ex.sys): MT7921=7961, MT7921K/RZ608=0608, MT7922/RZ616=0616,
                # plus alt ids 7902/7922. The x64 branch was renumbered 3.5 -> 25.40 -> 26.40;
                # no ARM64 packages exist for this generation (as of 2026-08).
                @{
                    Key = 'WiFi6'; Label = 'MT7921_22_WiFi6_Family'
                    Queries = @('VEN_14C3&DEV_7961', 'VEN_14C3&DEV_0608', 'VEN_14C3&DEV_0616', 'VEN_14C3&DEV_7902', 'VEN_14C3&DEV_7922', 'MT7921', 'RZ608', 'MT7922', 'RZ616')
                    PreferredBranches = @('26.40', '25.40', '3.5')
                    TitleExclude = @('NDIS', '(?i)bluetooth|uart')
                }

                # Wi-Fi 7 (mtkwecx.sys): MT7925=7925 (RZ717=0717), MT7927=7927 (RZ738=0738,
                # MT6639 silicon id=6639). x64 rides 26.30/26.40; ARM64 has its own 6.4 branch
                # (first ARM64 driver 6.4.0.3037, 2026-05, NTARM64-only INF covering the whole
                # family — one package serves every chip/rebrand here).
                @{
                    Key = 'WiFi7'; Label = 'MT7925_27_WiFi7_Family'
                    Queries = @('VEN_14C3&DEV_7925', 'VEN_14C3&DEV_7927', 'VEN_14C3&DEV_0717', 'VEN_14C3&DEV_0738', 'VEN_14C3&DEV_6639', 'MT7925', 'MT7927', 'RZ717', 'RZ738')
                    PreferredBranches = @('26.40', '26.30', '6.4')
                    TitleExclude = @('NDIS', '(?i)bluetooth|uart')
                }
            )
        }
    )
}
