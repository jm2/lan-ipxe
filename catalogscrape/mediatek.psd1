@{
    VendorKey = 'MediaTek_WiFi'
    Targets   = @(
        @{
            Name    = 'MediaTek_WiFi_Family'
            Devices = @(
                @{ Key = '7961'; Label = 'MT7921_Filogic330'; Queries = @('VEN_14C3&DEV_7961', 'MT7921'); PreferredBranches = @('3.5'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '0608'; Label = 'MT7921K_RZ608'; Queries = @('VEN_14C3&DEV_0608', 'RZ608'); PreferredBranches = @('3.5'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '0616'; Label = 'MT7922_RZ616'; Queries = @('VEN_14C3&DEV_0616', 'MT7922', 'RZ616'); PreferredBranches = @('3.5'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                # Wi-Fi 7 branches: 26.40 is the current x64 top branch (was 26.30); 6.4 is the
                # NEW ARM64-only branch (first ARM64 MediaTek Wi-Fi 7 driver, 6.4.0.3037, 2026-05,
                # NTARM64-only INF). Selection is highest-version-first PER Key+Arch group, so the
                # separate numbering never collides; the branch list is updated only so the
                # [branch ...] log line stays informative.
                #
                # The AMD rebrands (RZ717=DEV_0717, RZ738=DEV_0738) and the MT7927 silicon id
                # (MT6639=DEV_6639) ship in the SAME INF/package as the base HWIDs (verified in
                # 6.4.0.3037: one INF lists DEV_7925/0717/7927/0738/6639), so they are extra
                # QUERIES widening the 25-row relevance windows — NOT separate device entries,
                # which would re-download the identical CAB once per key.
                @{ Key = '7925'; Label = 'MT7925_Filogic380'; Queries = @('VEN_14C3&DEV_7925', 'VEN_14C3&DEV_0717', 'MT7925', 'RZ717'); PreferredBranches = @('26.40', '26.30', '6.4'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '7927'; Label = 'MT7927_Filogic380High'; Queries = @('VEN_14C3&DEV_7927', 'VEN_14C3&DEV_0738', 'VEN_14C3&DEV_6639', 'MT7927', 'RZ738'); PreferredBranches = @('26.40', '26.30', '6.4'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
            )
        }
    )
}
