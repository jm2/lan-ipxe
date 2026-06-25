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
                # Realtek publishes a per-PID modern USB NIC driver whose [version] major encodes
                # the chip (8153->1153.x, 8156->1156.x, ...). RTL8153/8156 have current drivers
                # (e.g. 1153.22.113.2026, Jan 2026).
                @{ Key = '1153'; Label = 'RTL8153'; Queries = @('VID_0BDA&PID_8153') }
                @{ Key = '1156'; Label = 'RTL8156'; Queries = @('VID_0BDA&PID_8156') }
                # RTL8157 (5G) / RTL8159 (PID 815A) have NO modern catalog driver yet — the only
                # match is a 2016/2018 generic legacy driver (11.19.602.2025) whose INF blankets
                # ~16 old PIDs. MinVersion floors that out (11.x < 1157/1159), so these SKIP today
                # and auto-pick the real per-chip driver the moment Realtek ships a 115x.x build.
                @{ Key = '1157'; Label = 'RTL8157'; MinVersion = '1157'; Queries = @('VID_0BDA&PID_8157') }
                @{ Key = '1159'; Label = 'RTL8159'; MinVersion = '1159'; Queries = @('VID_0BDA&PID_815A') }
            )
        }
    )
}
