package providers

import (
	"github.com/gitgerby/lan-ipxe/driver-scrapers/core"
)

// NewIntelEthernet creates a new Intel Ethernet provider.
func NewIntelEthernet() core.DriverProvider {
	return &intelEthernet{
		devices: []core.DeviceTarget{
			{Prefix: "I225-V", HWID: "VEN_8086&DEV_15F3", FamilyName: "I225", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "I226-V", HWID: "VEN_8086&DEV_121F", FamilyName: "I226", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "I219-V", HWID: "VEN_8086&DEV_15FB", FamilyName: "I219", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "I210", HWID: "VEN_8086&DEV_153A", FamilyName: "I210", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "X540", HWID: "VEN_8086&DEV_1528", FamilyName: "X540", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "X550", HWID: "VEN_8086&DEV_15C1", FamilyName: "X550", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "X710", HWID: "VEN_8086&DEV_158B", FamilyName: "X710", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "E810", HWID: "VEN_8086&DEV_15C3", FamilyName: "E810", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "IAVF", HWID: "VEN_8086&DEV_1889", FamilyName: "IAVF", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
		},
	}
}

type intelEthernet struct {
	devices []core.DeviceTarget
}

func (p *intelEthernet) Name() string                              { return "Intel Ethernet" }
func (p *intelEthernet) ProviderKey() string                       { return "intel-eth" }
func (p *intelEthernet) Devices() []core.DeviceTarget              { return p.devices }
func (p *intelEthernet) SelectionStrategy() core.SelectionStrategy { return core.NewestByDate }
func (p *intelEthernet) ExcludeNDIS() bool                         { return false }

// NewIntelWiFi creates a new Intel WiFi provider.
func NewIntelWiFi() core.DriverProvider {
	return &intelWiFi{
		devices: []core.DeviceTarget{
			{Prefix: "BE200", HWID: "VEN_8086&DEV_2725", FamilyName: "BE200", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
			{Prefix: "AX200", HWID: "VEN_8086&DEV_2723", FamilyName: "AX200", PreferredBranches: []string{"3.1", "3.0", "2.3", "2.2", "2.1", "2.0", "1.43", "1.42", "1.41", "1.40", "1.39", "1.38", "1.37", "1.36", "1.35", "1.34", "1.33", "1.32", "1.31", "1.30", "1.29", "1.28", "1.27", "1.26", "1.25", "1.24", "1.23", "1.22", "1.21", "1.20", "1.19", "1.18", "1.17", "1.16", "1.15", "1.14", "1.13", "1.12", "1.11", "1.10", "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"}},
		},
	}
}

type intelWiFi struct {
	devices []core.DeviceTarget
}

func (p *intelWiFi) Name() string                              { return "Intel WiFi" }
func (p *intelWiFi) ProviderKey() string                       { return "intel-wifi" }
func (p *intelWiFi) Devices() []core.DeviceTarget              { return p.devices }
func (p *intelWiFi) SelectionStrategy() core.SelectionStrategy { return core.NewestByDate }
func (p *intelWiFi) ExcludeNDIS() bool                         { return false }

// NewMarvell creates a new Marvell provider.
func NewMarvell() core.DriverProvider {
	return &marvell{
		devices: []core.DeviceTarget{
			{Prefix: "AQC107", HWID: "VEN_14A5&DEV_AQC107", FamilyName: "AQC107", Queries: []string{"AQC-107T", "AQC107"}, PreferredBranches: []string{}},
			{Prefix: "AQC113", HWID: "VEN_14A5&DEV_AQC113", FamilyName: "AQC113", Queries: []string{"AQC-113", "AQC113"}, PreferredBranches: []string{}},
			{Prefix: "AQC111U", HWID: "VEN_14A5&DEV_AQC111", FamilyName: "AQC111U", Queries: []string{"AQC-111U", "AQC111U"}, PreferredBranches: []string{}},
		},
	}
}

type marvell struct {
	devices []core.DeviceTarget
}

func (p *marvell) Name() string                              { return "Marvell Ethernet" }
func (p *marvell) ProviderKey() string                       { return "marvell" }
func (p *marvell) Devices() []core.DeviceTarget              { return p.devices }
func (p *marvell) SelectionStrategy() core.SelectionStrategy { return core.NewestByDate }
func (p *marvell) ExcludeNDIS() bool                         { return false }

// NewRealtek creates a new Realtek provider.
func NewRealtek() core.DriverProvider {
	return &realtek{
		devices: []core.DeviceTarget{
			{Prefix: "RTL8125", HWID: "VEN_10EC&DEV_8125", FamilyName: "RTL8125", PreferredBranches: []string{}},
			{Prefix: "RTL8126", HWID: "VEN_10EC&DEV_9200", FamilyName: "RTL8126", PreferredBranches: []string{}},
			{Prefix: "RTL8127", HWID: "VEN_10EC&DEV_8127", FamilyName: "RTL8127", PreferredBranches: []string{}},
			{Prefix: "RTL8168", HWID: "VEN_10EC&DEV_8168", FamilyName: "RTL8168", PreferredBranches: []string{}},
			{Prefix: "RTL8153", HWID: "VEN_10EC&DEV_8153", FamilyName: "RTL8153", PreferredBranches: []string{}},
			{Prefix: "RTL8156", HWID: "VEN_10EC&DEV_8156", FamilyName: "RTL8156", PreferredBranches: []string{}},
			{Prefix: "RTL8157", HWID: "VEN_10EC&DEV_8157", FamilyName: "RTL8157", PreferredBranches: []string{}},
			{Prefix: "RTL8159", HWID: "VEN_10EC&DEV_8159", FamilyName: "RTL8159", PreferredBranches: []string{}},
		},
	}
}

type realtek struct {
	devices []core.DeviceTarget
}

func (p *realtek) Name() string                              { return "Realtek Ethernet" }
func (p *realtek) ProviderKey() string                       { return "realtek" }
func (p *realtek) Devices() []core.DeviceTarget              { return p.devices }
func (p *realtek) SelectionStrategy() core.SelectionStrategy { return core.NewestByDate }
func (p *realtek) ExcludeNDIS() bool                         { return false }

// NewQualcomm creates a new Qualcomm WiFi provider.
func NewQualcomm() core.DriverProvider {
	return &qualcomm{
		devices: []core.DeviceTarget{
			{Prefix: "QCA6390", HWID: "VEN_168C&DEV_0044", FamilyName: "QCA6390", Queries: []string{"QCA6390 Windows 11"}, PreferredBranches: []string{"3.0"}},
			{Prefix: "WCN6855", HWID: "VEN_168C&DEV_006E", FamilyName: "WCN6855", Queries: []string{"WCN6855 Windows 11"}, PreferredBranches: []string{"3.0"}},
			{Prefix: "WCN7850", HWID: "VEN_168C&DEV_0073", FamilyName: "WCN7850", Queries: []string{"WCN7850 Windows 11"}, PreferredBranches: []string{"3.1"}},
		},
	}
}

type qualcomm struct {
	devices []core.DeviceTarget
}

func (p *qualcomm) Name() string                              { return "Qualcomm WiFi" }
func (p *qualcomm) ProviderKey() string                       { return "qualcomm" }
func (p *qualcomm) Devices() []core.DeviceTarget              { return p.devices }
func (p *qualcomm) SelectionStrategy() core.SelectionStrategy { return core.SemanticVersionWithBranch }
func (p *qualcomm) ExcludeNDIS() bool                         { return true }

// NewMediaTek creates a new MediaTek WiFi provider.
func NewMediaTek() core.DriverProvider {
	return &mediatek{
		devices: []core.DeviceTarget{
			{Prefix: "MT7921_Filogic330", HWID: "VEN_14C3&DEV_0616", FamilyName: "MT7921_Filogic330", Queries: []string{"MT7921 Windows 11"}, PreferredBranches: []string{"3.5"}},
			{Prefix: "MT7921K", HWID: "VEN_14C3&DEV_0616", FamilyName: "MT7921K", Queries: []string{"MT7921K Windows 11"}, PreferredBranches: []string{"3.5"}},
			{Prefix: "MT7922", HWID: "VEN_14C3&DEV_0607", FamilyName: "MT7922", Queries: []string{"MT7922 Windows 11"}, PreferredBranches: []string{"3.5"}},
			{Prefix: "MT7925", HWID: "VEN_14C3&DEV_0603", FamilyName: "MT7925", Queries: []string{"MT7925 Windows 11"}, PreferredBranches: []string{"25.30", "5.7"}},
			{Prefix: "MT7927", HWID: "VEN_14C3&DEV_0604", FamilyName: "MT7927", Queries: []string{"MT7927 Windows 11"}, PreferredBranches: []string{"25.30", "5.7"}},
		},
	}
}

type mediatek struct {
	devices []core.DeviceTarget
}

func (p *mediatek) Name() string                              { return "MediaTek WiFi" }
func (p *mediatek) ProviderKey() string                       { return "mediatek" }
func (p *mediatek) Devices() []core.DeviceTarget              { return p.devices }
func (p *mediatek) SelectionStrategy() core.SelectionStrategy { return core.SemanticVersionWithBranch }
func (p *mediatek) ExcludeNDIS() bool                         { return true }
