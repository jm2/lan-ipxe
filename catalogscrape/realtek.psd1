@{
    VendorKey = 'Realtek_Ethernet'
    Targets   = @(
        @{
            Name    = 'RTL_PCIe_Family'
            Devices = @(
                @{ Key = '1125'; Label = 'RTL8125'; Queries = @('VEN_10EC&DEV_8125') }
                @{ Key = '1126'; Label = 'RTL8126'; Queries = @('VEN_10EC&DEV_8126') }
                @{ Key = '1127'; Label = 'RTL8127'; Queries = @('VEN_10EC&DEV_8127') }
                @{ Key = '1168'; Label = 'RTL8168'; Queries = @('VEN_10EC&DEV_8168') }
            )
        }
        @{
            Name    = 'RTL_USB_Family'
            Devices = @(
                # USB packages carry a stale 2016/2018 catalog versionDate, so selection-by-date
                # used to pick the OLDER build. The engine now selects by highest [version]
                # (date as tiebreak), so e.g. RTL8159 correctly picks 11.19.602.2025 over the
                # 2018-dated 11.19.20.602.
                @{ Key = '1153'; Label = 'RTL8153'; Queries = @('VID_0BDA&PID_8153') }
                @{ Key = '1156'; Label = 'RTL8156'; Queries = @('VID_0BDA&PID_8156') }
                @{ Key = '1157'; Label = 'RTL8157'; Queries = @('VID_0BDA&PID_8157') }
                @{ Key = '1159'; Label = 'RTL8159'; Queries = @('VID_0BDA&PID_815A') }
            )
        }
    )
}
