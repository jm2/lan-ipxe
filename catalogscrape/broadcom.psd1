@{
    VendorKey = 'Broadcom_Ethernet'
    Targets   = @(
        # Broadcom NetXtreme-E / NetXtreme-C (bnxt) 10GbE+ controllers. All SKUs resolve to the
        # SAME unified driver on the catalog (v210.0.71.0, 2017-12-21) under per-SKU listings, so
        # the family is grouped by media type into one download each (the INF is family-wide).
        #
        # COVERAGE LIMITS (catalog-only; documented intentionally):
        #   * Catalog tops out at v210.0.71.0 (2017). Newer Broadcom releases (220.x+) are only on
        #     Broadcom's site / OEM channels, NOT the Microsoft Update Catalog.
        #   * Thor BCM575xx/576xx (100/200/400G: DEV_1750/1751/1752/1760) have NO catalog drivers.
        #   * NetXtreme II 10G (bnx2x: BCM578xx DEV_164x/166x/168x/16Ax) has NO per-HWID catalog
        #     driver — the only catalog entry is an HP-OEM "BCM57810 NetXtreme II" v7.4.25.0 (2013)
        #     found by name search. By choice it is NOT scraped: build_win11pxe.ps1 promotes the
        #     in-box b06bdrv/bxvbda.sys IF the Win11 image still ships it (NOT guaranteed on 24H2+).
        # All HWIDs below were verified to return Broadcom NIC drivers on the live catalog.
        @{
            Name    = 'Broadcom_NetXtremeE_10GBASE-T'
            Devices = @(
                @{ Key = 'NetXtremeE-T'; Label = 'NetXtreme-E 10GBASE-T (BCM57406/57407/57416/57417)';
                    Queries = @('VEN_14E4&DEV_16D2', 'VEN_14E4&DEV_16D5', 'VEN_14E4&DEV_16D8', 'VEN_14E4&DEV_16D9');
                    TitleExclude = @('NDIS') }
            )
        }
        @{
            Name    = 'Broadcom_NetXtremeEC_SFP'
            Devices = @(
                @{ Key = 'NetXtremeEC-SFP'; Label = 'NetXtreme-E/C 10/25/40/50G SFP (BCM573xx/574xx)';
                    Queries = @(
                        'VEN_14E4&DEV_16C8', 'VEN_14E4&DEV_16C9', 'VEN_14E4&DEV_16CA',
                        'VEN_14E4&DEV_16CE', 'VEN_14E4&DEV_16CF', 'VEN_14E4&DEV_16D0',
                        'VEN_14E4&DEV_16D1', 'VEN_14E4&DEV_16D6', 'VEN_14E4&DEV_16D7'
                    );
                    TitleExclude = @('NDIS') }
            )
        }
        @{
            Name    = 'Broadcom_NetXtremeE_100G'
            Devices = @(
                @{ Key = 'NetXtremeE-100G'; Label = 'NetXtreme-E 50/100G (BCM57454)';
                    Queries = @('VEN_14E4&DEV_1614'); TitleExclude = @('NDIS') }
            )
        }
    )
}
