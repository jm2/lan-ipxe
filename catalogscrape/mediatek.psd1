@{
    VendorKey = 'MediaTek_WiFi'
    Targets   = @(
        @{
            Name    = 'MediaTek_WiFi_Family'
            Devices = @(
                @{ Key = '7961'; Label = 'MT7921_Filogic330'; Queries = @('VEN_14C3&DEV_7961', 'MT7921'); PreferredBranches = @('3.5'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '0608'; Label = 'MT7921K_RZ608'; Queries = @('VEN_14C3&DEV_0608', 'RZ608'); PreferredBranches = @('3.5'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '0616'; Label = 'MT7922_RZ616'; Queries = @('VEN_14C3&DEV_0616', 'MT7922', 'RZ616'); PreferredBranches = @('3.5'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                # 26.30 is the current top branch for MT7925/MT7927 (newer than 25.30/5.7).
                # Selection is highest-version-first so 26.30.x wins regardless; the branch list
                # is updated only so the [branch ...] log line stays informative.
                @{ Key = '7925'; Label = 'MT7925_Filogic380'; Queries = @('VEN_14C3&DEV_7925', 'MT7925'); PreferredBranches = @('26.30', '25.30', '5.7'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '7927'; Label = 'MT7927_Filogic380High'; Queries = @('VEN_14C3&DEV_7927', 'MT7927'); PreferredBranches = @('26.30', '25.30', '5.7'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
            )
        }
    )
}
