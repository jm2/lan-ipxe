@{
    VendorKey = 'Qualcomm_WiFi'
    Targets   = @(
        @{
            Name    = 'Qualcomm_PCIe_Family'
            Devices = @(
                # Queries use the modern Qualcomm vendor id (VEN_17CB) + marketing name. The
                # marketing-name search drags in the combo chip's Bluetooth/UART entries, hence
                # the TitleExclude. PreferredBranches acts only as a same-version tiebreak /
                # log annotation (selection is highest-version-first). Branch reality verified
                # live 2026-08: QCA6390 x64 ended at 1.0.0.1769 (2021-12, product abandoned);
                # WCN6855 rides the 2.0 line on x64 (the old 3.0 entries never matched anything
                # in the catalog for these two devices); WCN7850 is on 3.1.
                @{ Key = '1101'; Label = 'QCA6390'; Queries = @('VEN_17CB&DEV_1101', 'Killer AX500'); PreferredBranches = @('1.0'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '1103'; Label = 'WCN6855'; Queries = @('VEN_17CB&DEV_1103', 'FastConnect 6900'); PreferredBranches = @('2.0', '1.0'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '1107'; Label = 'WCN7850'; Queries = @('VEN_17CB&DEV_1107', 'FastConnect 7800'); PreferredBranches = @('3.1'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
            )
        }
    )
}
