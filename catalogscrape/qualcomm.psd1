@{
    VendorKey = 'Qualcomm_WiFi'
    Targets   = @(
        @{
            Name    = 'Qualcomm_PCIe_Family'
            Devices = @(
                # Queries use the modern Qualcomm vendor id (VEN_17CB) + marketing name. The
                # marketing-name search drags in the combo chip's Bluetooth/UART entries, hence
                # the TitleExclude. PreferredBranches now acts only as a same-version tiebreak
                # (selection is highest-version-first); kept for traceability.
                @{ Key = '1101'; Label = 'QCA6390'; Queries = @('VEN_17CB&DEV_1101', 'Killer AX500'); PreferredBranches = @('3.0'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '1103'; Label = 'WCN6855'; Queries = @('VEN_17CB&DEV_1103', 'FastConnect 6900'); PreferredBranches = @('3.0'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
                @{ Key = '1107'; Label = 'WCN7850'; Queries = @('VEN_17CB&DEV_1107', 'FastConnect 7800'); PreferredBranches = @('3.1'); TitleExclude = @('NDIS', '(?i)bluetooth|uart') }
            )
        }
    )
}
