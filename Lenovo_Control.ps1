# ================================================================
#  LENOVO CONTROL WIDGET
#  Charging mode, keyboard lighting and Fn Lock for Lenovo Legion
#  and IdeaPad laptops - with no Vantage service, no Legion
#  Toolkit, nothing running in the background.
#
#  GENERAL PURPOSE BY DESIGN
#  There is no model whitelist. The widget PROBES the hardware at
#  startup and shows only what actually answers:
#
#    Charging mode  - \\.\EnergyDrv IOCTL 0x831020F8
#    Fn Lock        - \\.\EnergyDrv IOCTL 0x831020E8
#    Lighting       - whichever of these responds:
#                       * per-key Spectrum  (HID, 960-byte report)
#                       * 4-zone RGB        (HID, 33-byte report)
#                       * single-colour     (EnergyDrv IOCTL 0x83102144)
#
#  Keyboard type is decided by the HID feature-report LENGTH, not
#  by USB product ID, so it keeps working on model years that did
#  not exist when this was written.
#
#  Anything that does not answer is hidden rather than shown as a
#  dead control. All protocol values come from verified open source
#  (LenovoLegionToolkit, 4JX/L5P-Keyboard-RGB,
#  Triangle-GitHub/LegionLaptopToolkitCLI, alstergee/legion-spectrum-control).
#
#  Needs Administrator to open the energy driver.
#  -Hidden starts straight into the system tray.
# ================================================================

param([switch]$Hidden)

try {

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LenovoHw
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        byte[] lpInBuffer, uint nInBufferSize, byte[] lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    // Needed because the tray icon is redrawn from a Bitmap on every
    // battery update. Bitmap.GetHicon() allocates a GDI icon handle that
    // is NOT freed by Icon.Dispose(), so without this the process leaks
    // a handle every refresh and eventually stops drawing anything.
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr SetupDiGetClassDevsW(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData,
        ref Guid InterfaceClassGuid, uint MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, IntPtr DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize, out uint RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [DllImport("hid.dll")]
    public static extern void HidD_GetHidGuid(out Guid HidGuid);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr HidDeviceObject, ref HIDD_ATTRIBUTES Attributes);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(IntPtr HidDeviceObject, out IntPtr PreparsedData);
    [DllImport("hid.dll")]
    public static extern bool HidD_FreePreparsedData(IntPtr PreparsedData);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern int HidP_GetCaps(IntPtr PreparsedData, ref HIDP_CAPS Capabilities);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetFeature(IntPtr HidDeviceObject, byte[] ReportBuffer, int ReportBufferLength);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetFeature(IntPtr HidDeviceObject, byte[] ReportBuffer, int ReportBufferLength);

    private const uint GENERIC_READ  = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_RW = 0x00000003;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    private const uint DIGCF_PRESENT = 0x02;
    private const uint DIGCF_DEVICEINTERFACE = 0x10;

    // Every Lenovo HID interface seen during the last scan - the single
    // most useful thing to report when a keyboard is not recognised.
    public static string ScanLog = "";
    // Feature-report length of the matched keyboard: 33 = 4-zone RGB,
    // 960 = per-key Spectrum. This is the type discriminator.
    public static int MatchedFeatureLength = 0;
    public static int MatchedProductId = 0;

    public static IntPtr OpenEnergyDriver()
    {
        return CreateFileW("\\\\.\\EnergyDrv", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
            IntPtr.Zero, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
    }

    // Finds a Lenovo lighting-capable HID interface. Deliberately keyed on
    // feature-report length rather than product ID: Lenovo has shipped many
    // PIDs (0xC955, 0xC965, 0xC975, 0xC985, 0xC994, 0xC197...) but the report
    // length has stayed 33 for 4-zone and 960 for per-key Spectrum.
    public static IntPtr FindLightingDevice()
    {
        StringBuilder log = new StringBuilder();
        MatchedFeatureLength = 0;
        MatchedProductId = 0;

        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);

        IntPtr devInfo = SetupDiGetClassDevsW(ref hidGuid, IntPtr.Zero, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (devInfo == IntPtr.Zero || devInfo == new IntPtr(-1))
        {
            ScanLog = "SetupDiGetClassDevs failed (" + Marshal.GetLastWin32Error() + ")";
            return IntPtr.Zero;
        }

        IntPtr found = IntPtr.Zero;
        try
        {
            for (uint i = 0; ; i++)
            {
                SP_DEVICE_INTERFACE_DATA ifData = new SP_DEVICE_INTERFACE_DATA();
                ifData.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(devInfo, IntPtr.Zero, ref hidGuid, i, ref ifData))
                    break;

                uint required = 0;
                SetupDiGetDeviceInterfaceDetailW(devInfo, ref ifData, IntPtr.Zero, 0, out required, IntPtr.Zero);
                if (required == 0) continue;

                IntPtr detail = Marshal.AllocHGlobal((int)required);
                string path = null;
                try
                {
                    Marshal.WriteInt32(detail, (IntPtr.Size == 8) ? 8 : 6);
                    uint unused;
                    if (SetupDiGetDeviceInterfaceDetailW(devInfo, ref ifData, detail, required, out unused, IntPtr.Zero))
                        path = Marshal.PtrToStringUni(new IntPtr(detail.ToInt64() + 4));
                }
                finally { Marshal.FreeHGlobal(detail); }

                if (string.IsNullOrEmpty(path)) continue;

                IntPtr h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
                    IntPtr.Zero, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                if (h == new IntPtr(-1)) continue;

                bool keep = false;
                try
                {
                    HIDD_ATTRIBUTES attr = new HIDD_ATTRIBUTES();
                    attr.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                    if (!HidD_GetAttributes(h, ref attr)) continue;
                    if (attr.VendorID != 0x048D) continue;

                    IntPtr pp;
                    if (!HidD_GetPreparsedData(h, out pp)) continue;
                    try
                    {
                        HIDP_CAPS caps = new HIDP_CAPS();
                        HidP_GetCaps(pp, ref caps);
                        log.Append(string.Format("PID_{0:X4}/len{1} ", attr.ProductID, caps.FeatureReportByteLength));

                        if (caps.FeatureReportByteLength == 0x21 || caps.FeatureReportByteLength == 0x3C0)
                        {
                            MatchedFeatureLength = caps.FeatureReportByteLength;
                            MatchedProductId = attr.ProductID;
                            found = h;
                            keep = true;
                        }
                    }
                    finally { HidD_FreePreparsedData(pp); }
                }
                finally { if (!keep) CloseHandle(h); }

                if (found != IntPtr.Zero) break;
            }
        }
        finally { SetupDiDestroyDeviceInfoList(devInfo); }

        ScanLog = (log.Length == 0) ? "no Lenovo (VID_048D) HID interfaces present" : log.ToString().Trim();
        return found;
    }
}
'@

# ---------------------------------------------------------------
# UI
# ---------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Lenovo Control" Width="448" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        FontFamily="Segoe UI Variable Display, Segoe UI"
        TextOptions.TextFormattingMode="Ideal"
        TextOptions.TextRenderingMode="ClearType">

    <Window.Resources>

        <Style x:Key="PillStyle" TargetType="RadioButton">
            <Setter Property="Foreground" Value="#9C9CAD"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="pill" Background="Transparent" CornerRadius="9" Padding="0,8" Margin="2,0">
                            <TextBlock Text="{TemplateBinding Content}"
                                       Foreground="{TemplateBinding Foreground}"
                                       FontSize="{TemplateBinding FontSize}"
                                       FontWeight="{TemplateBinding FontWeight}"
                                       HorizontalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="pill" Property="Background" Value="#282833"/>
                                <Setter Property="Foreground" Value="#DCDCE6"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="pill" Property="Background" Value="#E63950"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#4C4C58"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SwatchStyle" TargetType="Button">
            <Setter Property="Width" Value="34"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,0,9,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Ellipse x:Name="ring" Stroke="#3A3A48" StrokeThickness="1.5"/>
                            <Ellipse x:Name="dot" Fill="{TemplateBinding Background}" Margin="4"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ring" Property="Stroke" Value="#FFFFFF"/>
                                <Setter TargetName="dot" Property="Margin" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- The "+" swatch that opens the custom colour picker -->
        <Style x:Key="CustomSwatchStyle" TargetType="Button">
            <Setter Property="Width" Value="34"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,0,9,0"/>
            <Setter Property="ToolTip" Value="Custom colour"/>
            <Setter Property="Background" Value="#20202B"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Ellipse x:Name="ring" Stroke="#4A4A5A" StrokeThickness="1.5" StrokeDashArray="2 2"/>
                            <Ellipse x:Name="fill" Margin="4" Fill="{TemplateBinding Background}"/>
                            <TextBlock x:Name="plus" Text="+" Foreground="#9C9CAD" FontSize="16"
                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ring" Property="Stroke" Value="#FFFFFF"/>
                                <Setter TargetName="plus" Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PickerButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bg" Background="#E63950" CornerRadius="8" Padding="14,7">
                            <TextBlock Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"
                                       FontSize="{TemplateBinding FontSize}" FontWeight="{TemplateBinding FontWeight}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bg" Property="Background" Value="#FF5C72"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SwitchStyle" TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Width="48" Height="27">
                            <Border x:Name="track" CornerRadius="13.5" Background="#31313E"
                                    BorderBrush="#3E3E4C" BorderThickness="1"/>
                            <Ellipse x:Name="thumb" Width="21" Height="21" Fill="#9C9CAD"
                                     HorizontalAlignment="Left" Margin="3,0,0,0"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="track" Property="Background" Value="#E63950"/>
                                <Setter TargetName="track" Property="BorderBrush" Value="#FF5C72"/>
                                <Setter TargetName="thumb" Property="Fill" Value="#FFFFFF"/>
                                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="track" Property="Opacity" Value="0.4"/>
                                <Setter TargetName="thumb" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ChromeButtonStyle" TargetType="Button">
            <Setter Property="Width" Value="30"/>
            <Setter Property="Height" Value="26"/>
            <Setter Property="Foreground" Value="#8A8A99"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bg" Background="Transparent" CornerRadius="7">
                            <TextBlock Text="{TemplateBinding Content}"
                                       Foreground="{TemplateBinding Foreground}"
                                       FontSize="{TemplateBinding FontSize}"
                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bg" Property="Background" Value="#2C2C38"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SectionLabelStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#6E6E80"/>
            <Setter Property="FontSize" Value="10.5"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Margin" Value="0,0,0,9"/>
        </Style>

        <Style x:Key="CardStyle" TargetType="Border">
            <Setter Property="Background" Value="#1B1B24"/>
            <Setter Property="BorderBrush" Value="#2A2A36"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="14"/>
            <Setter Property="Padding" Value="16,13"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>

        <Style x:Key="SegmentTrackStyle" TargetType="Border">
            <Setter Property="Background" Value="#121219"/>
            <Setter Property="BorderBrush" Value="#2A2A36"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="11"/>
            <Setter Property="Padding" Value="3"/>
        </Style>

        <Style x:Key="BatteryBarStyle" TargetType="ProgressBar">
            <Setter Property="Height" Value="6"/>
            <Setter Property="Minimum" Value="0"/>
            <Setter Property="Maximum" Value="100"/>
            <Setter Property="Foreground" Value="#E63950"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="#121219" CornerRadius="3"
                                BorderBrush="#2A2A36" BorderThickness="1">
                            <Grid>
                                <Border x:Name="PART_Track"/>
                                <Border x:Name="PART_Indicator" CornerRadius="3"
                                        Background="{TemplateBinding Foreground}"
                                        HorizontalAlignment="Left"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="NoteStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#63636F"/>
            <Setter Property="FontSize" Value="10.5"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>

    </Window.Resources>

    <Grid Margin="16">
        <Border CornerRadius="20" BorderThickness="1" BorderBrush="#33333F">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0.4,1">
                    <GradientStop Offset="0"   Color="#1A1A23"/>
                    <GradientStop Offset="0.5" Color="#15151C"/>
                    <GradientStop Offset="1"   Color="#101016"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.Effect>
                <DropShadowEffect BlurRadius="26" ShadowDepth="5" Direction="270" Opacity="0.65" Color="#000000"/>
            </Border.Effect>

            <StackPanel>

                <!-- Title bar -->
                <Border x:Name="HeaderBar" Background="Transparent" CornerRadius="20,20,0,0" Padding="18,14,10,10">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Viewbox Grid.Column="0" Width="31" Height="31" Margin="0,0,11,0">
                            <Grid Width="256" Height="256">
                                <Path Data="M128 14 L226 70 L226 186 L128 242 L30 186 L30 70 Z"
                                      Stroke="#7E1226" StrokeThickness="4" StrokeLineJoin="Round">
                                    <Path.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
                                            <GradientStop Offset="0"   Color="#FF6377"/>
                                            <GradientStop Offset="0.5" Color="#E63950"/>
                                            <GradientStop Offset="1"   Color="#B81E38"/>
                                        </LinearGradientBrush>
                                    </Path.Fill>
                                </Path>
                                <Path Data="M128 62 L196 122 L166 122 L128 89 L90 122 L60 122 Z" Fill="#FFFFFF"/>
                                <Path Data="M128 122 L196 182 L166 182 L128 149 L90 182 L60 182 Z" Fill="#FFFFFF" Opacity="0.72"/>
                            </Grid>
                        </Viewbox>

                        <StackPanel Grid.Column="1" VerticalAlignment="Center">
                            <TextBlock Text="Lenovo Control" Foreground="#F2F2F7" FontSize="14" FontWeight="SemiBold"/>
                            <!-- Shown only when something is wrong -->
                            <StackPanel x:Name="RowStatus" Orientation="Horizontal" Margin="0,2,0,0" Visibility="Collapsed">
                                <Ellipse x:Name="DotStatus" Width="7" Height="7" Fill="#E63950" VerticalAlignment="Center"/>
                                <TextBlock x:Name="TxtStatus" Text="" Foreground="#FF8A9B"
                                           FontSize="10.5" Margin="6,0,0,0" VerticalAlignment="Center"/>
                            </StackPanel>
                        </StackPanel>

                        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
                            <Button x:Name="BtnPin" Content="&#x1F4CC;" Style="{StaticResource ChromeButtonStyle}" ToolTip="Always on top"/>
                            <Button x:Name="BtnClose" Content="&#x2715;" Style="{StaticResource ChromeButtonStyle}" ToolTip="Hide to tray (right-click the tray icon to quit)"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Border x:Name="WarnBar" Background="#3A1720" BorderBrush="#7A2436" BorderThickness="1"
                        CornerRadius="12" Padding="13,10" Margin="16,2,16,10" Visibility="Collapsed">
                    <TextBlock x:Name="TxtWarn" Style="{StaticResource NoteStyle}" Foreground="#FFB3BF"/>
                </Border>

                <StackPanel Margin="16,4,16,10">

                    <!-- Charging -->
                    <Border x:Name="CardBattery" Style="{StaticResource CardStyle}">
                        <StackPanel>
                            <!-- Live battery level -->
                            <StackPanel x:Name="RowBattery" Margin="0,0,0,12">
                                <Grid Margin="0,0,0,6">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock x:Name="TxtBatteryPct" Text="--%" Foreground="#E63950"
                                                   FontSize="20" FontWeight="Bold"/>
                                        <TextBlock x:Name="TxtBatteryState" Text="" Foreground="#6E6E80"
                                                   FontSize="10.5" FontWeight="SemiBold"
                                                   VerticalAlignment="Bottom" Margin="7,0,0,3"/>
                                    </StackPanel>
                                </Grid>
                                <ProgressBar x:Name="PbBattery" Style="{StaticResource BatteryBarStyle}" Value="0"/>
                            </StackPanel>

                            <!-- Charging-mode controls hide independently of the level
                                 readout, so a machine with a battery but no energy
                                 driver still shows its percentage. -->
                            <StackPanel x:Name="RowChargeMode">
                                <Grid Margin="0,0,0,9">
                                    <TextBlock Text="CHARGING MODE" Style="{StaticResource SectionLabelStyle}" Margin="0"/>
                                    <TextBlock x:Name="TxtBatteryNow" Foreground="#E63950" FontSize="10.5"
                                               FontWeight="SemiBold" HorizontalAlignment="Right"/>
                                </Grid>
                                <Border Style="{StaticResource SegmentTrackStyle}">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbConservation" Grid.Column="0" Content="Conservation" GroupName="Charge" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbNormal"       Grid.Column="1" Content="Normal"       GroupName="Charge" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbRapid"        Grid.Column="2" Content="Rapid"        GroupName="Charge" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                                <TextBlock x:Name="TxtBatteryNote" Text="Conservation caps the charge to protect the battery."
                                           Style="{StaticResource NoteStyle}" Margin="2,9,0,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <!-- Lighting: one of four panels is shown, chosen by what the hardware reports -->
                    <Border x:Name="CardLight" Style="{StaticResource CardStyle}">
                        <StackPanel>
                            <Grid Margin="0,0,0,9">
                                <TextBlock Text="KEYBOARD LIGHTING" Style="{StaticResource SectionLabelStyle}" Margin="0"/>
                                <TextBlock x:Name="TxtLightNow" Foreground="#E63950" FontSize="10.5"
                                           FontWeight="SemiBold" HorizontalAlignment="Right"/>
                            </Grid>

                            <!-- No supported lighting found -->
                            <StackPanel x:Name="PnlLightNone" Visibility="Collapsed">
                                <TextBlock x:Name="TxtLightNone" Style="{StaticResource NoteStyle}"/>
                            </StackPanel>

                            <!-- Single colour backlight: brightness only -->
                            <StackPanel x:Name="PnlLightWhite" Visibility="Collapsed">
                                <Border Style="{StaticResource SegmentTrackStyle}">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbWhiteOff"  Grid.Column="0" Content="Off"  GroupName="White" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbWhiteLow"  Grid.Column="1" Content="Low"  GroupName="White" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbWhiteHigh" Grid.Column="2" Content="High" GroupName="White" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                                <TextBlock Text="This keyboard has a single-colour backlight, so only brightness is adjustable."
                                           Style="{StaticResource NoteStyle}" Margin="2,9,0,0"/>
                            </StackPanel>

                            <!-- 4-zone RGB -->
                            <StackPanel x:Name="PnlLightZone" Visibility="Collapsed">
                                <TextBlock Text="ZONE" Style="{StaticResource SectionLabelStyle}" Margin="0,0,0,6"/>
                                <Border Style="{StaticResource SegmentTrackStyle}" Margin="0,0,0,7">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbZoneAll" Grid.Column="0" Content="All" GroupName="Zone" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZone1"   Grid.Column="1" Content="1"   GroupName="Zone" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZone2"   Grid.Column="2" Content="2"   GroupName="Zone" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZone3"   Grid.Column="3" Content="3"   GroupName="Zone" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZone4"   Grid.Column="4" Content="4"   GroupName="Zone" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                                <Grid Margin="3,0,3,10">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Border x:Name="ChipZ1" Grid.Column="0" Height="5" CornerRadius="3" Margin="2,0" Background="#FFFFFF"/>
                                    <Border x:Name="ChipZ2" Grid.Column="1" Height="5" CornerRadius="3" Margin="2,0" Background="#FFFFFF"/>
                                    <Border x:Name="ChipZ3" Grid.Column="2" Height="5" CornerRadius="3" Margin="2,0" Background="#FFFFFF"/>
                                    <Border x:Name="ChipZ4" Grid.Column="3" Height="5" CornerRadius="3" Margin="2,0" Background="#FFFFFF"/>
                                </Grid>

                                <StackPanel Orientation="Horizontal" Margin="0,0,0,11">
                                    <Button x:Name="BtnZ1" Style="{StaticResource SwatchStyle}" Background="#FF3B30" Tag="FF3B30"/>
                                    <Button x:Name="BtnZ2" Style="{StaticResource SwatchStyle}" Background="#FF9500" Tag="FF9500"/>
                                    <Button x:Name="BtnZ3" Style="{StaticResource SwatchStyle}" Background="#FFD60A" Tag="FFD60A"/>
                                    <Button x:Name="BtnZ4" Style="{StaticResource SwatchStyle}" Background="#32D74B" Tag="32D74B"/>
                                    <Button x:Name="BtnZ5" Style="{StaticResource SwatchStyle}" Background="#0A84FF" Tag="0A84FF"/>
                                    <Button x:Name="BtnZ6" Style="{StaticResource SwatchStyle}" Background="#BF5AF2" Tag="BF5AF2"/>
                                    <Button x:Name="BtnZ7" Style="{StaticResource SwatchStyle}" Background="#FFFFFF" Tag="FFFFFF"/>
                                    <Button x:Name="BtnZCustom" Style="{StaticResource CustomSwatchStyle}" Margin="0"/>
                                </StackPanel>

                                <TextBlock Text="EFFECT" Style="{StaticResource SectionLabelStyle}" Margin="0,0,0,6"/>
                                <Border Style="{StaticResource SegmentTrackStyle}" Margin="0,0,0,10">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbZFxStatic" Grid.Column="0" Content="Static" GroupName="ZFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZFxBreath" Grid.Column="1" Content="Breath" GroupName="ZFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZFxWave"   Grid.Column="2" Content="Wave"   GroupName="ZFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZFxSmooth" Grid.Column="3" Content="Smooth" GroupName="ZFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZFxOff"    Grid.Column="4" Content="Off"    GroupName="ZFx" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                                <TextBlock Text="BRIGHTNESS" Style="{StaticResource SectionLabelStyle}" Margin="0,0,0,6"/>
                                <Border Style="{StaticResource SegmentTrackStyle}">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbZBrLow"  Grid.Column="0" Content="Low"  GroupName="ZBr" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbZBrHigh" Grid.Column="1" Content="High" GroupName="ZBr" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                            </StackPanel>

                            <!-- Per-key Spectrum -->
                            <StackPanel x:Name="PnlLightSpectrum" Visibility="Collapsed">
                                <TextBlock Text="APPLY TO" Style="{StaticResource SectionLabelStyle}" Margin="0,0,0,6"/>
                                <Border Style="{StaticResource SegmentTrackStyle}" Margin="0,0,0,5">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbTgtAll"   Grid.Column="0" Content="All"    GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbTgtKeys"  Grid.Column="1" Content="Keys"   GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbTgtPerim" Grid.Column="2" Content="Edges"  GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbTgtLogo"  Grid.Column="3" Content="Logo"   GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                                <Border Style="{StaticResource SegmentTrackStyle}" Margin="0,0,0,12">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbTgtWasd"   Grid.Column="0" Content="WASD"   GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbTgtArrows" Grid.Column="1" Content="Arrows" GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbTgtFRow"   Grid.Column="2" Content="F-row"  GroupName="Tgt" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>

                                <StackPanel Orientation="Horizontal" Margin="0,0,0,11">
                                    <Button x:Name="BtnS1" Style="{StaticResource SwatchStyle}" Background="#FF3B30" Tag="FF3B30"/>
                                    <Button x:Name="BtnS2" Style="{StaticResource SwatchStyle}" Background="#FF9500" Tag="FF9500"/>
                                    <Button x:Name="BtnS3" Style="{StaticResource SwatchStyle}" Background="#FFD60A" Tag="FFD60A"/>
                                    <Button x:Name="BtnS4" Style="{StaticResource SwatchStyle}" Background="#32D74B" Tag="32D74B"/>
                                    <Button x:Name="BtnS5" Style="{StaticResource SwatchStyle}" Background="#0A84FF" Tag="0A84FF"/>
                                    <Button x:Name="BtnS6" Style="{StaticResource SwatchStyle}" Background="#BF5AF2" Tag="BF5AF2"/>
                                    <Button x:Name="BtnS7" Style="{StaticResource SwatchStyle}" Background="#FFFFFF" Tag="FFFFFF"/>
                                    <Button x:Name="BtnSCustom" Style="{StaticResource CustomSwatchStyle}" Margin="0"/>
                                </StackPanel>

                                <TextBlock Text="EFFECT" Style="{StaticResource SectionLabelStyle}" Margin="0,0,0,6"/>
                                <Border Style="{StaticResource SegmentTrackStyle}" Margin="0,0,0,10">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <RadioButton x:Name="RbSFxStatic"  Grid.Column="0" Content="Static"  GroupName="SFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbSFxRainbow" Grid.Column="1" Content="Rainbow" GroupName="SFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbSFxPulse"   Grid.Column="2" Content="Pulse"   GroupName="SFx" Style="{StaticResource PillStyle}"/>
                                        <RadioButton x:Name="RbSFxSmooth"  Grid.Column="3" Content="Smooth"  GroupName="SFx" Style="{StaticResource PillStyle}"/>
                                    </Grid>
                                </Border>
                                <Grid Margin="0,0,0,4">
                                    <TextBlock Text="BRIGHTNESS" Style="{StaticResource SectionLabelStyle}" Margin="0"/>
                                    <TextBlock x:Name="TxtSpecBright" Foreground="#9C9CAD" FontSize="10.5"
                                               FontWeight="SemiBold" HorizontalAlignment="Right"/>
                                </Grid>
                                <Slider x:Name="SldSpecBright" Minimum="0" Maximum="9" Value="5"
                                        IsSnapToTickEnabled="True" TickFrequency="1" Margin="0,0,0,4"/>
                                <TextBlock x:Name="TxtSpecNote" Style="{StaticResource NoteStyle}" Margin="2,6,0,0"/>
                            </StackPanel>

                            <!-- Shared custom colour picker, revealed by the + swatch -->
                            <Border x:Name="PnlPicker" Visibility="Collapsed" Background="#15151D" CornerRadius="11"
                                    BorderBrush="#2A2A36" BorderThickness="1" Padding="11" Margin="0,12,0,0">
                                <StackPanel>
                                    <Grid Height="104" Margin="0,0,0,9">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>

                                        <Border Grid.Column="0" CornerRadius="8" ClipToBounds="True"
                                                BorderBrush="#3A3A48" BorderThickness="1">
                                            <Grid x:Name="SvArea" Background="Transparent">
                                                <Rectangle x:Name="SvHue" Fill="#FF0000"/>
                                                <Rectangle>
                                                    <Rectangle.Fill>
                                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                                            <GradientStop Offset="0" Color="#FFFFFFFF"/>
                                                            <GradientStop Offset="1" Color="#00FFFFFF"/>
                                                        </LinearGradientBrush>
                                                    </Rectangle.Fill>
                                                </Rectangle>
                                                <Rectangle>
                                                    <Rectangle.Fill>
                                                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                                            <GradientStop Offset="0" Color="#00000000"/>
                                                            <GradientStop Offset="1" Color="#FF000000"/>
                                                        </LinearGradientBrush>
                                                    </Rectangle.Fill>
                                                </Rectangle>
                                                <Canvas x:Name="SvCanvas" IsHitTestVisible="False">
                                                    <Ellipse x:Name="SvCursor" Width="13" Height="13"
                                                             Stroke="#FFFFFF" StrokeThickness="2"/>
                                                </Canvas>
                                            </Grid>
                                        </Border>

                                        <Border Grid.Column="1" Width="21" Margin="9,0,0,0" CornerRadius="6"
                                                ClipToBounds="True" BorderBrush="#3A3A48" BorderThickness="1">
                                            <Grid x:Name="HueArea" Background="Transparent">
                                                <Rectangle>
                                                    <Rectangle.Fill>
                                                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                                            <GradientStop Offset="0.00" Color="#FF0000"/>
                                                            <GradientStop Offset="0.17" Color="#FFFF00"/>
                                                            <GradientStop Offset="0.33" Color="#00FF00"/>
                                                            <GradientStop Offset="0.50" Color="#00FFFF"/>
                                                            <GradientStop Offset="0.67" Color="#0000FF"/>
                                                            <GradientStop Offset="0.83" Color="#FF00FF"/>
                                                            <GradientStop Offset="1.00" Color="#FF0000"/>
                                                        </LinearGradientBrush>
                                                    </Rectangle.Fill>
                                                </Rectangle>
                                                <Canvas x:Name="HueCanvas" IsHitTestVisible="False">
                                                    <Rectangle x:Name="HueCursor" Width="21" Height="3" Fill="#FFFFFF"/>
                                                </Canvas>
                                            </Grid>
                                        </Border>
                                    </Grid>

                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="Auto"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <Border x:Name="PreviewSwatch" Grid.Column="0" Width="30" Height="28"
                                                CornerRadius="7" Background="#FFFFFF" BorderBrush="#3A3A48" BorderThickness="1"/>
                                        <TextBox x:Name="TxtHex" Grid.Column="1" Text="FFFFFF" Margin="8,0,8,0"
                                                 Background="#0E0E14" Foreground="#DCDCE6" CaretBrush="#DCDCE6"
                                                 BorderBrush="#2A2A36" BorderThickness="1" Padding="7,5"
                                                 FontFamily="Consolas" FontSize="12" VerticalContentAlignment="Center"/>
                                        <Button x:Name="BtnPickApply" Grid.Column="2" Content="Apply"
                                                Style="{StaticResource PickerButtonStyle}"/>
                                    </Grid>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </Border>

                    <!-- Fn Lock -->
                    <Border x:Name="CardFn" Style="{StaticResource CardStyle}" Margin="0">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                <TextBlock Text="FN LOCK" Style="{StaticResource SectionLabelStyle}" Margin="0,0,0,4"/>
                                <TextBlock x:Name="TxtFnNote" Style="{StaticResource NoteStyle}" Margin="0,0,10,0"/>
                            </StackPanel>
                            <CheckBox x:Name="SwFnLock" Grid.Column="1" Style="{StaticResource SwitchStyle}" VerticalAlignment="Center"/>
                        </Grid>
                    </Border>

                    <!-- Mini settings -->
                    <Border Style="{StaticResource CardStyle}" Margin="0,10,0,0">
                        <StackPanel>
                            <TextBlock Text="SETTINGS" Style="{StaticResource SectionLabelStyle}"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,10,0">
                                    <TextBlock Text="Start with Windows" Foreground="#DCDCE6" FontSize="12.5" FontWeight="SemiBold"/>
                                    <TextBlock x:Name="TxtStartupNote" Style="{StaticResource NoteStyle}"
                                               Text="Launches minimised to the tray at sign-in, elevated, with no UAC prompt."/>
                                </StackPanel>
                                <CheckBox x:Name="SwStartup" Grid.Column="1" Style="{StaticResource SwitchStyle}" VerticalAlignment="Center"/>
                            </Grid>
                            <Grid Margin="0,10,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,10,0">
                                    <TextBlock Text="Always show in tray" Foreground="#DCDCE6" FontSize="12.5" FontWeight="SemiBold"/>
                                    <TextBlock x:Name="TxtTrayNote" Style="{StaticResource NoteStyle}"
                                               Text="Keeps the battery icon next to the clock instead of inside the hidden-icons arrow."/>
                                </StackPanel>
                                <CheckBox x:Name="SwTray" Grid.Column="1" Style="{StaticResource SwitchStyle}" VerticalAlignment="Center"/>
                            </Grid>
                        </StackPanel>
                    </Border>

                </StackPanel>

                <!-- Detected machine -->
                <Border Background="#101016" CornerRadius="0,0,20,20" Padding="18,10,18,12" BorderBrush="#242430" BorderThickness="0,1,0,0">
                    <StackPanel>
                        <TextBlock x:Name="TxtModel" Foreground="#8A8A99" FontSize="11" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="TxtCaps" Foreground="#55555F" FontSize="10" Margin="0,2,0,0" TextWrapping="Wrap"/>
                        <TextBlock Text="Made by Divya Abhishek" Foreground="#45454F" FontSize="10"
                                   Margin="0,7,0,0" HorizontalAlignment="Right" FontWeight="SemiBold"/>
                    </StackPanel>
                </Border>

            </StackPanel>
        </Border>
    </Grid>
</Window>
'@

[xml]$xamlDoc = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    'HeaderBar', 'RowStatus', 'DotStatus', 'TxtStatus', 'BtnPin', 'BtnClose', 'WarnBar', 'TxtWarn',
    'SwStartup', 'TxtStartupNote', 'SwTray', 'TxtTrayNote',
    'CardBattery', 'TxtBatteryNow', 'RbConservation', 'RbNormal', 'RbRapid', 'TxtBatteryNote',
    'RowBattery', 'TxtBatteryPct', 'TxtBatteryState', 'PbBattery', 'RowChargeMode',
    'CardLight', 'TxtLightNow',
    'PnlLightNone', 'TxtLightNone',
    'PnlLightWhite', 'RbWhiteOff', 'RbWhiteLow', 'RbWhiteHigh',
    'PnlLightZone', 'BtnZ1', 'BtnZ2', 'BtnZ3', 'BtnZ4', 'BtnZ5', 'BtnZ6', 'BtnZ7', 'BtnZCustom',
    'RbZoneAll', 'RbZone1', 'RbZone2', 'RbZone3', 'RbZone4',
    'ChipZ1', 'ChipZ2', 'ChipZ3', 'ChipZ4',
    'RbZFxStatic', 'RbZFxBreath', 'RbZFxWave', 'RbZFxSmooth', 'RbZFxOff', 'RbZBrLow', 'RbZBrHigh',
    'PnlLightSpectrum', 'BtnS1', 'BtnS2', 'BtnS3', 'BtnS4', 'BtnS5', 'BtnS6', 'BtnS7', 'BtnSCustom',
    'RbTgtAll', 'RbTgtKeys', 'RbTgtPerim', 'RbTgtLogo', 'RbTgtWasd', 'RbTgtArrows', 'RbTgtFRow',
    'RbSFxStatic', 'RbSFxRainbow', 'RbSFxPulse', 'RbSFxSmooth', 'TxtSpecBright', 'SldSpecBright', 'TxtSpecNote',
    'PnlPicker', 'SvArea', 'SvHue', 'SvCanvas', 'SvCursor', 'HueArea', 'HueCanvas', 'HueCursor',
    'PreviewSwatch', 'TxtHex', 'BtnPickApply',
    'CardFn', 'TxtFnNote', 'SwFnLock',
    'TxtModel', 'TxtCaps'
)
$ctrl = @{}
foreach ($n in $names) { $ctrl[$n] = $window.FindName($n) }

# ---------------------------------------------------------------
# State
# ---------------------------------------------------------------
$script:Suppress = $true

$script:EnergyHandle = [IntPtr]::Zero
$script:LightHandle = [IntPtr]::Zero

$script:IoctlBattery  = [uint32]::Parse('831020F8', [System.Globalization.NumberStyles]::HexNumber)
$script:IoctlSettings = [uint32]::Parse('831020E8', [System.Globalization.NumberStyles]::HexNumber)
$script:IoctlKeyboard = [uint32]::Parse('83102144', [System.Globalization.NumberStyles]::HexNumber)
$script:BatteryRegPath = 'HKCU:\Software\Lenovo\VantageService\AddinData\IdeaNotebookAddin'
$script:PrefsPath = "$env:APPDATA\LenovoControl\preferences.json"

# Capability map, filled in by the probe at startup. Nothing is
# assumed from the model name - only from what actually replies.
$script:Caps = @{
    Model     = 'Unknown Lenovo'
    MTM       = ''
    Battery   = $false
    FnLock    = $false
    Light     = 'None'   # None | White | FourZone | Spectrum
    LightInfo = ''
}

# 4-zone state. Each zone keeps its own colour, like Vantage does.
$script:RapidUnsupported = $false
$script:ZoneEffect = 1
$script:ZoneSpeed = 2
$script:ZoneBright = 2
$script:ZoneColors = @(@(255,255,255), @(255,255,255), @(255,255,255), @(255,255,255))
$script:ZoneTarget = 0        # 0 = all zones, 1..4 = that zone only

# Spectrum state
$script:SpecEffect = 11       # 11 = static
$script:SpecColor = @(255, 255, 255)
$script:SpecTarget = 'All'

# Picker state (hue 0..360, sat 0..1, val 0..1) and where Apply sends the
# result - set by whichever "+" swatch opened it.
$script:PickHue = 0.0
$script:PickSat = 0.0
$script:PickVal = 1.0
$script:PickerMode = 'Zone'   # Zone | Spectrum

# Spectrum keycode groups. 0x0065 is the protocol's special "all lights"
# code and is model-independent; the rest come from a Legion Pro 7 key map,
# so they are offered as convenience groups and may land differently on
# other layouts. "All" is always the safe one.
$script:SpecKeyGroups = @{
    'All'    = @(0x0065)
    'Logo'   = @(0x05DD)
    'Wasd'   = @(0x0043, 0x006D, 0x006E, 0x0058)
    'Arrows' = @(0x008E, 0x009D, 0x009C, 0x009F)
    'FRow'   = @(0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007,
                 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D)
    'Perim'  = @(0x03E9, 0x03EA, 0x03EB, 0x03EC, 0x03ED, 0x03EE, 0x03EF,
                 0x03F0, 0x03F1, 0x03F2, 0x03F3, 0x03F4, 0x03F5, 0x03F6,
                 0x03F7, 0x03F8, 0x03F9, 0x03FA,
                 0x01F5, 0x01F6, 0x01F7, 0x01F8, 0x01F9, 0x01FA,
                 0x01FB, 0x01FC, 0x01FD, 0x01FE)
    'Keys'   = @(0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008,
                 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F, 0x0010,
                 0x0011, 0x0012, 0x0013, 0x0014, 0x0016, 0x0017, 0x0018, 0x0019,
                 0x001A, 0x001B, 0x001C, 0x001D, 0x001E, 0x001F, 0x0020, 0x0021,
                 0x0022, 0x0026, 0x0027, 0x0028, 0x0029, 0x0038, 0x0040, 0x0042,
                 0x0043, 0x0044, 0x0045, 0x0046, 0x0047, 0x0048, 0x0049, 0x004A,
                 0x004B, 0x004C, 0x004D, 0x004E, 0x004F, 0x0050, 0x0051, 0x0055,
                 0x0058, 0x0059, 0x005A, 0x005B, 0x005C, 0x005D, 0x005F, 0x0068,
                 0x006A, 0x006D, 0x006E, 0x006F, 0x0070, 0x0071, 0x0072, 0x0073,
                 0x0074, 0x0075, 0x0076, 0x0077, 0x0079, 0x007B, 0x007C, 0x007F,
                 0x0080, 0x0082, 0x0083, 0x0087, 0x0088, 0x008D, 0x008E, 0x0090,
                 0x0092, 0x0096, 0x0097, 0x0098, 0x009A, 0x009B, 0x009C, 0x009D,
                 0x009F, 0x00A1, 0x00A3, 0x00A5, 0x00A7)
}

# ---------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------
function Convert-HsvToRgb {
    param([double]$H, [double]$S, [double]$V)
    $h = (($H % 360) + 360) % 360
    $c = $V * $S
    $x = $c * (1 - [Math]::Abs((($h / 60.0) % 2) - 1))
    $m = $V - $c
    switch ([Math]::Floor($h / 60.0)) {
        0 { $r1 = $c; $g1 = $x; $b1 = 0 }
        1 { $r1 = $x; $g1 = $c; $b1 = 0 }
        2 { $r1 = 0;  $g1 = $c; $b1 = $x }
        3 { $r1 = 0;  $g1 = $x; $b1 = $c }
        4 { $r1 = $x; $g1 = 0;  $b1 = $c }
        default { $r1 = $c; $g1 = 0; $b1 = $x }
    }
    return @(
        [int][Math]::Round(($r1 + $m) * 255),
        [int][Math]::Round(($g1 + $m) * 255),
        [int][Math]::Round(($b1 + $m) * 255)
    )
}

function Convert-RgbToHsv {
    param([int]$R, [int]$G, [int]$B)
    $r = $R / 255.0; $g = $G / 255.0; $b = $B / 255.0
    $max = [Math]::Max($r, [Math]::Max($g, $b))
    $min = [Math]::Min($r, [Math]::Min($g, $b))
    $d = $max - $min
    $h = 0.0
    if ($d -gt 0) {
        if ($max -eq $r)      { $h = 60 * ((($g - $b) / $d) % 6) }
        elseif ($max -eq $g)  { $h = 60 * ((($b - $r) / $d) + 2) }
        else                  { $h = 60 * ((($r - $g) / $d) + 4) }
    }
    if ($h -lt 0) { $h += 360 }
    $s = if ($max -eq 0) { 0 } else { $d / $max }
    return @($h, $s, $max)
}

function ConvertTo-HexString {
    param([int[]]$Rgb)
    return ('{0:X2}{1:X2}{2:X2}' -f $Rgb[0], $Rgb[1], $Rgb[2])
}

function ConvertFrom-HexString {
    param([string]$Hex)
    $h = $Hex.Trim().TrimStart('#')
    if ($h -notmatch '^[0-9A-Fa-f]{6}$') { return $null }
    return @(
        [Convert]::ToInt32($h.Substring(0,2), 16),
        [Convert]::ToInt32($h.Substring(2,2), 16),
        [Convert]::ToInt32($h.Substring(4,2), 16)
    )
}

function New-Brush {
    param([int[]]$Rgb)
    return New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.Color]::FromRgb([byte]$Rgb[0], [byte]$Rgb[1], [byte]$Rgb[2]))
}

function Set-Status {
    # The header sub-line is for PROBLEMS only. Ordinary state (charging,
    # mode, level) is already shown by the battery row and the cards, so
    # narrating it up here was just noise.
    param([string]$Text, [switch]$Ok)
    if ($Ok -or [string]::IsNullOrWhiteSpace($Text)) {
        $ctrl['RowStatus'].Visibility = 'Collapsed'
        return
    }
    $ctrl['RowStatus'].Visibility = 'Visible'
    $ctrl['TxtStatus'].Text = $Text
    $ctrl['TxtStatus'].Foreground = '#FF8A9B'
    $ctrl['DotStatus'].Fill = '#E63950'
}

# ---------------------------------------------------------------
# Energy driver
# ---------------------------------------------------------------
function Get-EnergyHandle {
    if ($script:EnergyHandle -ne [IntPtr]::Zero -and $script:EnergyHandle.ToInt64() -ne -1) {
        return $script:EnergyHandle
    }
    $h = [LenovoHw]::OpenEnergyDriver()
    if ($h.ToInt64() -eq -1 -or $h -eq [IntPtr]::Zero) { return $null }
    $script:EnergyHandle = $h
    return $h
}

function Invoke-EnergyIoctl {
    param([uint32]$IoctlCode, [uint32]$Command)
    $handle = Get-EnergyHandle
    if (-not $handle) { return $null }
    try {
        $inBuffer = [BitConverter]::GetBytes($Command)
        $outBuffer = New-Object byte[] 4
        [uint32]$returned = 0
        $ok = [LenovoHw]::DeviceIoControl($handle, $IoctlCode, $inBuffer, 4, $outBuffer, 4, [ref]$returned, [IntPtr]::Zero)
        if (-not $ok) { return $null }
        return [BitConverter]::ToUInt32($outBuffer, 0)
    } catch { return $null }
}

# ---------------------------------------------------------------
# Preference persistence (charging mode, lighting settings)
# ---------------------------------------------------------------
function Load-Preferences {
    try {
        if (Test-Path $script:PrefsPath) {
            return Get-Content $script:PrefsPath | ConvertFrom-Json
        }
    } catch {
        # Corrupt JSON or read error; silently ignore and use defaults
    }
    return @{
        BatteryMode = 'Normal'
        WhiteBacklight = 'Off'
        ZoneEffect = 1
        ZoneBright = 2
        ZoneColors = @(@(255,255,255), @(255,255,255), @(255,255,255), @(255,255,255))
        SpecEffect = 11
        SpecColor = @(255,255,255)
    }
}

function Save-Preferences {
    try {
        $dir = Split-Path $script:PrefsPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }

        $curBatteryMode = Get-BatteryMode
        if ($null -eq $curBatteryMode) { $curBatteryMode = 'Normal' }
        $curWhiteBacklight = Get-WhiteBacklight
        if ($null -eq $curWhiteBacklight) { $curWhiteBacklight = 'Off' }

        $prefs = @{
            BatteryMode = $curBatteryMode
            WhiteBacklight = $curWhiteBacklight
            ZoneEffect = $script:ZoneEffect
            ZoneBright = $script:ZoneBright
            ZoneColors = $script:ZoneColors
            SpecEffect = $script:SpecEffect
            SpecColor = $script:SpecColor
        }
        $prefs | ConvertTo-Json | Set-Content $script:PrefsPath -Force
    } catch {
        # Silently fail; preferences are not load-bearing
    }
}

function Get-BatteryMode {
    $raw = Invoke-EnergyIoctl -IoctlCode $script:IoctlBattery -Command ([uint32]0xFF)
    if ($null -eq $raw) { return $null }
    # Battery status is byte-reversed before the bits mean anything.
    $v = [uint64]$raw
    $state = [uint64]((($v -band 0xFF) -shl 24) -bor
                      ((($v -band 0xFF00) -shr 8) -shl 16) -bor
                      ((($v -band 0xFF0000) -shr 16) -shl 8) -bor
                      (($v -shr 24) -band 0xFF))
    if ((($state -shr 17) -band 1) -eq 1) {
        if ((($state -shr 26) -band 1) -eq 1) { return 'RapidCharge' } else { return 'Normal' }
    }
    if ((($state -shr 29) -band 1) -eq 1) { return 'Conservation' }
    return $null
}

function Set-BatteryRegistryValue {
    param([string]$Mode)
    $regValue = switch ($Mode) {
        'Normal'       { 'Normal' }
        'RapidCharge'  { 'Quick' }
        'Conservation' { 'Storage' }
    }
    try {
        if (-not (Test-Path $script:BatteryRegPath)) {
            New-Item -Path $script:BatteryRegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $script:BatteryRegPath -Name 'BatteryChargeMode' -Value $regValue -ErrorAction Stop
    } catch { }
}

function Set-BatteryMode {
    param([ValidateSet('Conservation', 'Normal', 'RapidCharge')][string]$TargetMode)
    $current = Get-BatteryMode
    if ($null -eq $current) { Set-Status 'charging mode unavailable'; return }

    # CRITICAL: Write to registry FIRST. LenovoSmartService reads this value and will
    # override the IOCTL if the registry doesn't match. This prevents the service from
    # resetting your mode back to Rapid after the widget sets it.
    Set-BatteryRegistryValue -Mode $TargetMode
    Start-Sleep -Milliseconds 100

    $sequence = switch ($TargetMode) {
        'Conservation' { if ($current -eq 'RapidCharge') { @(0x8, 0x3) } else { @(0x3) } }
        'Normal'       { if ($current -eq 'Conservation') { @(0x5) } else { @(0x8) } }
        'RapidCharge'  { if ($current -eq 'Conservation') { @(0x5, 0x7) } else { @(0x7) } }
    }
    foreach ($cmd in $sequence) {
        Invoke-EnergyIoctl -IoctlCode $script:IoctlBattery -Command ([uint32]$cmd) | Out-Null
        Start-Sleep -Milliseconds 180
    }
    Start-Sleep -Milliseconds 350
    $after = Get-BatteryMode
    Update-BatteryUi
    # Switching mode changes what "charging" means, so refresh the readout
    # rather than leaving stale wording until the next timer tick.
    Update-BatteryReadout

    # Persist immediately, not just on app exit. A reboot or shutdown kills this
    # process before $app.Add_Exit gets a chance to run, so relying on exit-time
    # saving meant the "last mode" on disk was often still the install-time
    # default and got re-applied (wrongly) on every subsequent boot.
    Save-Preferences

    if ($after -eq $TargetMode) {
        Set-Status -Ok
        return
    }

    # Rapid Charge does not exist on every Lenovo - plenty of IdeaPads only
    # have Conservation and Normal. There is no documented capability bit to
    # read up front, so the honest approach is to find out the first time it
    # is used and then stop offering it, rather than leaving a dead button.
    if ($TargetMode -eq 'RapidCharge') {
        $script:RapidUnsupported = $true
        Set-Pref -Name 'RapidUnsupported' -Value 1
        Disable-RapidCharge
        Set-Status -Ok
        return
    }

    Set-Status "mode did not stick (still $after)"
}

function Disable-RapidCharge {
    $script:Suppress = $true
    try {
        $ctrl['RbRapid'].IsEnabled = $false
        $ctrl['RbRapid'].Content = 'Rapid n/a'
        $mode = Get-BatteryMode
        $ctrl['RbConservation'].IsChecked = ($mode -eq 'Conservation')
        $ctrl['RbNormal'].IsChecked       = ($mode -eq 'Normal')
        $ctrl['RbRapid'].IsChecked        = $false
    } finally { $script:Suppress = $false }
    $ctrl['TxtBatteryNote'].Text = 'Conservation caps the charge to protect the battery. ' +
        'This model does not support Rapid Charge.'
}

function Update-BatteryUi {
    $mode = Get-BatteryMode
    $script:Suppress = $true
    try {
        $ctrl['RbConservation'].IsChecked = ($mode -eq 'Conservation')
        $ctrl['RbNormal'].IsChecked       = ($mode -eq 'Normal')
        $ctrl['RbRapid'].IsChecked        = ($mode -eq 'RapidCharge')
        $ctrl['TxtBatteryNow'].Text = switch ($mode) {
            'Conservation' { 'CONSERVATION' }
            'Normal'       { 'NORMAL' }
            'RapidCharge'  { 'RAPID' }
            default        { 'unavailable' }
        }
    } finally { $script:Suppress = $false }
}

# Bit 10 is what Legion Toolkit uses, but this generation is known to
# differ (there is even a Linux kernel patch titled "Fix Legion 5 Fn lock
# LED"). Rather than hard-code a guess, the first toggle diffs the raw
# value before and after and adopts whichever bit actually moved.
$script:FnBit = 10
$script:FnBitLearned = $false

function Get-FnLockRaw {
    return (Invoke-EnergyIoctl -IoctlCode $script:IoctlSettings -Command ([uint32]0x2))
}

function Get-SingleBitIndex {
    param([uint32]$Value)
    if ($Value -eq 0) { return -1 }
    if (($Value -band ($Value - 1)) -ne 0) { return -1 }   # more than one bit moved
    $i = 0
    $v = [uint64]$Value
    while ($v -gt 1) { $v = $v -shr 1; $i++ }
    return $i
}

function Get-FnLock {
    $raw = Get-FnLockRaw
    if ($null -eq $raw) { return $null }
    # Unlike battery, this value is NOT byte-reversed - the bit is read directly.
    return ((([uint64]$raw) -shr $script:FnBit) -band 1) -eq 1
}

function Set-FnLock {
    param([bool]$On)

    $rawBefore = Get-FnLockRaw
    $cmd = if ($On) { 0xE } else { 0xF }
    Invoke-EnergyIoctl -IoctlCode $script:IoctlSettings -Command ([uint32]$cmd) | Out-Null

    # Watch the RAW value, not just our assumed bit - that way a model which
    # reports Fn Lock somewhere else still registers as "something happened".
    $rawAfter = $rawBefore
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 50
        $r = Get-FnLockRaw
        if ($null -ne $r -and $r -ne $rawBefore) { $rawAfter = $r; break }
    }

    if ($null -ne $rawBefore -and $null -ne $rawAfter -and $rawAfter -ne $rawBefore) {
        # Something moved. Work out which bit, and adopt it if we had the
        # wrong one - measured from the hardware rather than assumed.
        $idx = Get-SingleBitIndex -Value ([uint32]($rawBefore -bxor $rawAfter))
        if ($idx -ge 0 -and $idx -ne $script:FnBit) {
            $script:FnBit = $idx
            $script:FnBitLearned = $true
        }
        Update-FnUi
        if ($script:FnBitLearned) {
            $ctrl['TxtFnNote'].Text += "  (matched this model on bit $($script:FnBit))"
        }
        return
    }

    # Nothing in the raw value changed at all: the driver took the call but
    # the hardware ignored it. Put the switch back and say so plainly rather
    # than leaving a toggle that lies about reality.
    $script:Suppress = $true
    try { $ctrl['SwFnLock'].IsChecked = ((Get-FnLock) -eq $true) } finally { $script:Suppress = $false }
    $bTxt = if ($null -eq $rawBefore) { 'no response' } else { '0x' + $rawBefore.ToString('X8') }
    $ctrl['TxtFnNote'].Text = "This model ignored the Fn Lock command (driver value stayed $bTxt). " +
        "Use Fn+Esc on the keyboard. Send me that value and I can find the right call for your model."
}

function Update-FnUi {
    $state = Get-FnLock
    $script:Suppress = $true
    try {
        if ($null -eq $state) {
            $ctrl['SwFnLock'].IsEnabled = $false
            $ctrl['TxtFnNote'].Text = 'Fn Lock is not exposed on this model.'
        } else {
            $ctrl['SwFnLock'].IsChecked = $state
            $ctrl['TxtFnNote'].Text = if ($state) {
                'On: F1-F12 act as media keys; hold Fn for real F-keys.'
            } else {
                'Off: F1-F12 act as normal function keys.'
            }
        }
    } finally { $script:Suppress = $false }
}

# ---------------------------------------------------------------
# Single-colour backlight (most IdeaPads, some Legions)
# ---------------------------------------------------------------
function Get-WhiteBacklight {
    # Try to open energy driver even if Get-EnergyHandle failed earlier
    # (some models have transient driver issues on first access)
    $attempt = 0
    while ($attempt -lt 3) {
        $raw = Invoke-EnergyIoctl -IoctlCode $script:IoctlKeyboard -Command ([uint32]0x22)
        if ($null -ne $raw) {
            switch ($raw) {
                1 { return 'Off' }
                3 { return 'Low' }
                5 { return 'High' }
                default { return $null }
            }
        }
        $attempt++
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 100 }
    }
    return $null
}

function Set-WhiteBacklight {
    param([ValidateSet('Off', 'Low', 'High')][string]$Level)
    $cmd = switch ($Level) {
        'Off'  { 0x00023 }
        'Low'  { 0x10023 }
        'High' { 0x20023 }
    }
    Invoke-EnergyIoctl -IoctlCode $script:IoctlKeyboard -Command ([uint32]$cmd) | Out-Null
    # The controller takes a moment to settle; poll rather than assume.
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 50
        if ((Get-WhiteBacklight) -eq $Level) { break }
    }
    Update-WhiteUi
    Save-Preferences
}

function Update-WhiteUi {
    $level = Get-WhiteBacklight
    $script:Suppress = $true
    try {
        $ctrl['RbWhiteOff'].IsChecked  = ($level -eq 'Off')
        $ctrl['RbWhiteLow'].IsChecked  = ($level -eq 'Low')
        $ctrl['RbWhiteHigh'].IsChecked = ($level -eq 'High')
        $ctrl['TxtLightNow'].Text = if ($level) { $level.ToUpper() } else { 'unknown' }
    } finally { $script:Suppress = $false }
}

# ---------------------------------------------------------------
# 4-zone RGB (33-byte HID feature report)
# ---------------------------------------------------------------
function Get-LightHandle {
    if ($script:LightHandle -ne [IntPtr]::Zero -and $script:LightHandle.ToInt64() -ne -1) {
        return $script:LightHandle
    }
    $h = [LenovoHw]::FindLightingDevice()
    if ($h -eq [IntPtr]::Zero -or $h.ToInt64() -eq -1) { return $null }
    $script:LightHandle = $h
    return $h
}

function Send-ZoneState {
    $handle = Get-LightHandle
    if (-not $handle) { $ctrl['TxtLightNow'].Text = 'no keyboard'; return }
    $payload = New-Object byte[] 33
    $payload[0] = 0xCC
    $payload[1] = 0x16
    $payload[2] = [byte]$script:ZoneEffect
    $payload[3] = [byte]$script:ZoneSpeed
    $payload[4] = [byte]$script:ZoneBright
    if ($script:ZoneEffect -eq 4) { $payload[18] = 1 }
    if ($script:ZoneEffect -eq 1 -or $script:ZoneEffect -eq 3) {
        # Every zone carries its own colour - bytes 5..16 are zone1..zone4 RGB.
        for ($z = 0; $z -lt 4; $z++) {
            $b = 5 + ($z * 3)
            $c = $script:ZoneColors[$z]
            $payload[$b]     = [byte]$c[0]
            $payload[$b + 1] = [byte]$c[1]
            $payload[$b + 2] = [byte]$c[2]
        }
    }
    if ([LenovoHw]::HidD_SetFeature($handle, $payload, 33)) {
        $ctrl['TxtLightNow'].Text = switch ($script:ZoneEffect) {
            1 { 'STATIC' } 3 { 'BREATH' } 4 { 'WAVE' } 6 { 'SMOOTH' } default { '' }
        }
        Save-Preferences
    } else {
        $script:LightHandle = [IntPtr]::Zero
        $ctrl['TxtLightNow'].Text = 'write rejected'
        Set-Status 'lighting blocked - close Lenovo Vantage'
    }
}

function Send-ZoneOff {
    $handle = Get-LightHandle
    if (-not $handle) { return }
    $payload = New-Object byte[] 33
    $payload[0] = 0xCC
    $payload[1] = 0x16
    if ([LenovoHw]::HidD_SetFeature($handle, $payload, 33)) {
        $ctrl['TxtLightNow'].Text = 'OFF'
    } else {
        $script:LightHandle = [IntPtr]::Zero
        $ctrl['TxtLightNow'].Text = 'write rejected'
    }
}

# ---------------------------------------------------------------
# Per-key Spectrum (960-byte HID feature report)
#
# Header is [0x07, opcode, 0xC0, 0x03]; a colour is applied to every
# LED at once using the special "all lights" keycode 0x0065 inside a
# static effect, which avoids needing a per-model key map.
# ---------------------------------------------------------------
function New-SpectrumReport {
    param([byte]$Op, [byte[]]$Payload)
    $buf = New-Object byte[] 960
    $buf[0] = 0x07
    $buf[1] = $Op
    $buf[2] = 0xC0
    $buf[3] = 0x03
    if ($Payload -and $Payload.Length -gt 0) {
        [Array]::Copy($Payload, 0, $buf, 4, [Math]::Min($Payload.Length, 956))
    }
    return $buf
}

function Send-SpectrumReport {
    param([byte]$Op, [byte[]]$Payload)
    $handle = Get-LightHandle
    if (-not $handle) { return $false }
    $buf = New-SpectrumReport -Op $Op -Payload $Payload
    $ok = [LenovoHw]::HidD_SetFeature($handle, $buf, 960)
    if (-not $ok) { $script:LightHandle = [IntPtr]::Zero }
    return $ok
}

function Read-SpectrumByte {
    # Every read is "ask, then fetch": send the request opcode, then pull
    # the 960-byte feature report back and take the value at index 4.
    param([byte]$Op)
    if (-not (Send-SpectrumReport -Op $Op -Payload @())) { return $null }
    $handle = Get-LightHandle
    if (-not $handle) { return $null }
    $buf = New-Object byte[] 960
    $buf[0] = 0x07
    if (-not [LenovoHw]::HidD_GetFeature($handle, $buf, 960)) { return $null }
    return $buf[4]
}

function Get-SpectrumProfile {
    $p = Read-SpectrumByte -Op 0xCA
    if ($null -eq $p -or $p -lt 1 -or $p -gt 6) { return 1 }
    return $p
}

function Set-SpectrumBrightness {
    param([int]$Level)
    $lvl = [Math]::Max(0, [Math]::Min(9, $Level))
    Send-SpectrumReport -Op 0xCE -Payload @([byte]$lvl) | Out-Null
    $ctrl['TxtSpecBright'].Text = "$lvl / 9"
    Save-Preferences
}

function Send-SpectrumEffect {
    # Builds one effect covering every LED. Layout, verbatim from the
    # reference implementation:
    #   payload  = [profile, 0x01, 0x01] + effect blob
    #   blob     = [effectNo] + header + colourCount + RGB... + keyCount + keycodes(LE u16)
    #   header   = 06 01 <type> 02 <speed> 03 <clockwise> 04 <direction> 05 <colourMode> 06 00
    param([int]$EffectType, [int[]]$Color, [int]$Speed = 2, [int]$Direction = 0, [string]$Target = 'All')

    $keycodes = $script:SpecKeyGroups[$Target]
    if (-not $keycodes) { $keycodes = $script:SpecKeyGroups['All'] }

    $useColor = ($null -ne $Color -and $EffectType -eq 11)
    $colorMode = if ($useColor) { 0x02 } elseif ($EffectType -ne 11) { 0x01 } else { 0x00 }

    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.Add([byte]1)                       # effect number
    $bytes.AddRange([byte[]]@(0x06, 0x01, [byte]$EffectType,
                              0x02, [byte]$Speed,
                              0x03, 0x00,
                              0x04, [byte]$Direction,
                              0x05, [byte]$colorMode,
                              0x06, 0x00))
    if ($useColor) {
        $bytes.Add([byte]1)
        $bytes.AddRange([byte[]]@([byte]$Color[0], [byte]$Color[1], [byte]$Color[2]))
    } else {
        $bytes.Add([byte]0)
    }
    $bytes.Add([byte]$keycodes.Count)
    foreach ($kc in $keycodes) {
        # keycodes are little-endian u16
        $bytes.Add([byte]($kc -band 0xFF))
        $bytes.Add([byte](($kc -shr 8) -band 0xFF))
    }

    $specProfile = Get-SpectrumProfile
    $payload = New-Object System.Collections.Generic.List[byte]
    $payload.AddRange([byte[]]@([byte]$specProfile, 0x01, 0x01))
    $payload.AddRange($bytes)

    if (Send-SpectrumReport -Op 0xCB -Payload $payload.ToArray()) {
        $ctrl['TxtLightNow'].Text = switch ($EffectType) {
            11 { 'STATIC' } 2 { 'RAINBOW' } 4 { 'PULSE' } 6 { 'SMOOTH' } default { '' }
        }
        Save-Preferences
    } else {
        $ctrl['TxtLightNow'].Text = 'write rejected'
        Set-Status 'lighting blocked - close Lenovo Vantage'
    }
}

function Set-SpectrumColor {
    param([int]$R, [int]$G, [int]$B)
    $script:SpecColor = @($R, $G, $B)
    $script:SpecEffect = 11
    $script:Suppress = $true
    try { $ctrl['RbSFxStatic'].IsChecked = $true } finally { $script:Suppress = $false }
    Send-SpectrumEffect -EffectType 11 -Color $script:SpecColor -Target $script:SpecTarget
}

# ---------------------------------------------------------------
# Custom colour picker
# ---------------------------------------------------------------
function Get-PickerRgb {
    return Convert-HsvToRgb -H $script:PickHue -S $script:PickSat -V $script:PickVal
}

function Update-PickerPreview {
    $rgb = Get-PickerRgb
    $ctrl['PreviewSwatch'].Background = New-Brush -Rgb $rgb
    $script:Suppress = $true
    try { $ctrl['TxtHex'].Text = ConvertTo-HexString -Rgb $rgb } finally { $script:Suppress = $false }

    # The saturation/value square is tinted by the pure hue behind it.
    $pure = Convert-HsvToRgb -H $script:PickHue -S 1 -V 1
    $ctrl['SvHue'].Fill = New-Brush -Rgb $pure

    $w = $ctrl['SvArea'].ActualWidth
    $h = $ctrl['SvArea'].ActualHeight
    if ($w -gt 0 -and $h -gt 0) {
        [System.Windows.Controls.Canvas]::SetLeft($ctrl['SvCursor'], ($script:PickSat * $w) - 6.5)
        [System.Windows.Controls.Canvas]::SetTop($ctrl['SvCursor'], ((1 - $script:PickVal) * $h) - 6.5)
    }
    $hh = $ctrl['HueArea'].ActualHeight
    if ($hh -gt 0) {
        [System.Windows.Controls.Canvas]::SetTop($ctrl['HueCursor'], (($script:PickHue / 360.0) * $hh) - 1.5)
    }
}

function Set-PickerFromRgb {
    param([int[]]$Rgb)
    $hsv = Convert-RgbToHsv -R $Rgb[0] -G $Rgb[1] -B $Rgb[2]
    $script:PickHue = $hsv[0]
    $script:PickSat = $hsv[1]
    $script:PickVal = $hsv[2]
    Update-PickerPreview
}

function Hide-Picker {
    $ctrl['PnlPicker'].Visibility = 'Collapsed'
}

function Show-Picker {
    param([string]$Mode)
    # The "+" swatch toggles: clicking it again closes the picker.
    if ($ctrl['PnlPicker'].Visibility -eq 'Visible' -and $script:PickerMode -eq $Mode) {
        Hide-Picker
        return
    }
    $script:PickerMode = $Mode
    # Seed the picker with whatever colour is currently in effect, so it
    # opens where the user left off rather than snapping to white.
    if ($Mode -eq 'Zone') {
        $idx = if ($script:ZoneTarget -eq 0) { 0 } else { $script:ZoneTarget - 1 }
        Set-PickerFromRgb -Rgb $script:ZoneColors[$idx]
    } else {
        Set-PickerFromRgb -Rgb $script:SpecColor
    }
    $ctrl['PnlPicker'].Visibility = 'Visible'
    # Positions need real layout sizes, which only exist after a pass.
    $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded,
        [action]{ Update-PickerPreview }) | Out-Null
}

function Apply-PickedColor {
    # Applies without closing - this also runs on every drag-release, where
    # closing the picker mid-adjustment would be maddening.
    $rgb = Get-PickerRgb
    if ($script:PickerMode -eq 'Zone') {
        Set-ZoneColor -Rgb $rgb
        $ctrl['BtnZCustom'].Background = New-Brush -Rgb $rgb
    } else {
        Set-SpectrumColor -R $rgb[0] -G $rgb[1] -B $rgb[2]
        $ctrl['BtnSCustom'].Background = New-Brush -Rgb $rgb
    }
}

# ---------------------------------------------------------------
# Zone colour handling
# ---------------------------------------------------------------
function Set-ZoneColor {
    param([int[]]$Rgb)
    if ($script:ZoneTarget -eq 0) {
        for ($i = 0; $i -lt 4; $i++) { $script:ZoneColors[$i] = $Rgb }
    } else {
        $script:ZoneColors[$script:ZoneTarget - 1] = $Rgb
    }
    # Per-zone colour only renders on Static/Breath, so snap to Static
    # otherwise the click looks ignored.
    if ($script:ZoneEffect -ne 1 -and $script:ZoneEffect -ne 3) {
        $script:ZoneEffect = 1
        $script:Suppress = $true
        try { $ctrl['RbZFxStatic'].IsChecked = $true } finally { $script:Suppress = $false }
    }
    Update-ZoneChips
    Send-ZoneState
}

function Update-ZoneChips {
    for ($i = 0; $i -lt 4; $i++) {
        $ctrl["ChipZ$($i + 1)"].Background = New-Brush -Rgb $script:ZoneColors[$i]
    }
}

# ---------------------------------------------------------------
# Hardware probe
# ---------------------------------------------------------------
function Get-MachineIdentity {
    try {
        $prod = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
        $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        # Lenovo puts the marketing name ("Legion 5 15IMH05") in Version and
        # the machine type ("82AU") in Model - the opposite of most vendors.
        $friendly = $prod.Version
        if ([string]::IsNullOrWhiteSpace($friendly) -or $friendly -match 'To be filled|Default string|System Version') {
            $friendly = $cs.SystemFamily
        }
        if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = $prod.Name }
        if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = 'Unknown Lenovo' }
        $script:Caps.Model = $friendly.Trim()
        $script:Caps.MTM = if ($cs.Model) { $cs.Model.Trim() } else { '' }
    } catch {
        $script:Caps.Model = 'Unknown Lenovo'
    }
}

function Invoke-HardwareProbe {
    Get-MachineIdentity

    # --- energy driver features ---
    if (Get-EnergyHandle) {
        $script:Caps.Battery = ($null -ne (Get-BatteryMode))
        $script:Caps.FnLock  = ($null -ne (Get-FnLock))
    }

    # --- lighting ---
    # HID first: report length tells us which protocol this keyboard speaks.
    $h = Get-LightHandle
    if ($h) {
        $len = [LenovoHw]::MatchedFeatureLength
        $devPid = [LenovoHw]::MatchedProductId
        if ($len -eq 0x3C0) {
            $script:Caps.Light = 'Spectrum'
            $script:Caps.LightInfo = ('per-key Spectrum (048D:{0:X4})' -f $devPid)
        } elseif ($len -eq 0x21) {
            $script:Caps.Light = 'FourZone'
            $script:Caps.LightInfo = ('4-zone RGB (048D:{0:X4})' -f $devPid)
        }
    }
    # No RGB controller: fall back to the single-colour backlight IOCTL.
    if ($script:Caps.Light -eq 'None') {
        if ($null -ne (Get-WhiteBacklight)) {
            $script:Caps.Light = 'White'
            $script:Caps.LightInfo = 'single-colour backlight'
        } else {
            $script:Caps.LightInfo = 'none detected'
        }
    }

    # --- Load saved preferences ---
    $prefs = Load-Preferences
    $script:RestorePrefs = $prefs

    # --- Ensure registry has a default value ---
    # LenovoSmartService reads the registry and will force "Rapid" if BatteryChargeMode
    # is not set. Initialize it to avoid unwanted mode switches.
    if ($script:Caps.Battery) {
        try {
            $regPath = 'HKCU:\Software\Lenovo\VantageService\AddinData\IdeaNotebookAddin'
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null }
            $current = Get-ItemProperty -Path $regPath -Name 'BatteryChargeMode' -ErrorAction SilentlyContinue
            if (-not $current.BatteryChargeMode) {
                # No registry value set: initialize to "Storage" (Conservation) as safe default
                # This prevents LenovoSmartService from forcing "Rapid" on startup
                Set-ItemProperty -Path $regPath -Name 'BatteryChargeMode' -Value 'Storage' -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

function Check-LenovoServiceConflict {
    # LenovoSmartService and LenovoVantageService can override charging mode via registry
    $services = @('LenovoSmartService', 'LenovoVantageService', 'lvcomserv')
    $running = @()
    foreach ($svc in $services) {
        try {
            $status = (Get-Service $svc -ErrorAction SilentlyContinue).Status
            if ($status -eq 'Running') { $running += $svc }
        } catch { }
    }
    return $running
}

function Show-DetectedUi {
    # Charging. The card itself survives if there is a battery to report on,
    # even when the driver cannot change modes - the level readout is still
    # worth showing.
    if (-not $script:Caps.Battery) {
        $ctrl['RowChargeMode'].Visibility = 'Collapsed'
        if ($null -eq (Get-BatteryStatus)) { $ctrl['CardBattery'].Visibility = 'Collapsed' }
    } else {
        Update-BatteryUi
        # Remember a previous finding that this model has no Rapid Charge.
        if ($script:RapidUnsupported) { Disable-RapidCharge }
    }

    # Fn Lock
    if (-not $script:Caps.FnLock) {
        $ctrl['CardFn'].Visibility = 'Collapsed'
    } else {
        Update-FnUi
    }

    # Lighting: exactly one sub-panel is revealed.
    switch ($script:Caps.Light) {
        'White' {
            $ctrl['PnlLightWhite'].Visibility = 'Visible'
            Update-WhiteUi
        }
        'FourZone' {
            $ctrl['PnlLightZone'].Visibility = 'Visible'
            $script:Suppress = $true
            try {
                $ctrl['RbZoneAll'].IsChecked = $true
                $ctrl['RbZFxStatic'].IsChecked = $true
                $ctrl['RbZBrHigh'].IsChecked = $true
            } finally { $script:Suppress = $false }
            Update-ZoneChips
            $ctrl['TxtLightNow'].Text = 'ready'
        }
        'Spectrum' {
            $ctrl['PnlLightSpectrum'].Visibility = 'Visible'
            $script:Suppress = $true
            try {
                $ctrl['RbTgtAll'].IsChecked = $true
                $ctrl['RbSFxStatic'].IsChecked = $true
                $b = Read-SpectrumByte -Op 0xCD
                if ($null -ne $b -and $b -le 9) { $ctrl['SldSpecBright'].Value = $b }
                $ctrl['TxtSpecBright'].Text = "$([int]$ctrl['SldSpecBright'].Value) / 9"
            } finally { $script:Suppress = $false }
            $ctrl['TxtSpecNote'].Text = 'All targets every LED and is model-independent. ' +
                'The named groups use one model key map, so on a different layout they may light the wrong keys - ' +
                'tell me which and I can correct the codes.'
            $ctrl['TxtLightNow'].Text = 'ready'
        }
        default {
            $ctrl['PnlLightNone'].Visibility = 'Visible'
            $ctrl['TxtLightNone'].Text = 'No controllable keyboard lighting was found on this laptop. ' +
                'Devices seen: ' + [LenovoHw]::ScanLog
            $ctrl['TxtLightNow'].Text = 'none'
        }
    }

    # Footer
    $model = $script:Caps.Model
    if ($script:Caps.MTM) { $model += "   |   $($script:Caps.MTM)" }
    $ctrl['TxtModel'].Text = $model

    $bits = @()
    $bits += if ($script:Caps.Battery) { 'charging: yes' } else { 'charging: no' }
    $bits += if ($script:Caps.FnLock)  { 'Fn Lock: yes' }  else { 'Fn Lock: no' }
    $bits += 'lighting: ' + $script:Caps.LightInfo
    $ctrl['TxtCaps'].Text = $bits -join '    '

    # Check for conflicting services
    $conflicts = Check-LenovoServiceConflict
    if ($conflicts.Count -gt 0 -and $script:Caps.Battery) {
        $ctrl['WarnBar'].Visibility = 'Visible'
        $ctrl['TxtWarn'].Text = "WARNING: $($conflicts -join ', ') is running. This service may override your charging mode settings via the Windows registry. " +
            "If your charging mode doesn't stick, close this service or set it to Disabled in Services.msc (services.msc). " +
            "The widget writes to the registry to prevent overrides, but the service takes precedence if running."
    }

    # If literally nothing responded, say so plainly instead of showing
    # an empty shell.
    if (-not $script:Caps.Battery -and -not $script:Caps.FnLock -and $script:Caps.Light -eq 'None') {
        $ctrl['WarnBar'].Visibility = 'Visible'
        $ctrl['TxtWarn'].Text = 'Nothing responded on this machine. The Lenovo energy driver is probably not installed - ' +
            'install "Lenovo Energy Management" (or Lenovo Vantage once, then close it) and try again.'
        Set-Status 'no supported hardware found'
    } else {
        Set-Status -Ok
    }
}

function Restore-SavedSettings {
    if (-not $script:RestorePrefs) { return }
    $p = $script:RestorePrefs

    # Restore battery mode
    if ($script:Caps.Battery -and $p.BatteryMode) {
        try { Set-BatteryMode $p.BatteryMode } catch { }
    }

    # Restore white backlight
    if ($script:Caps.Light -eq 'White' -and $p.WhiteBacklight) {
        try { Set-WhiteBacklight $p.WhiteBacklight } catch { }
    }

    # Restore 4-zone settings
    if ($script:Caps.Light -eq 'FourZone') {
        $script:ZoneEffect = if ($null -ne $p.ZoneEffect) { $p.ZoneEffect } else { 1 }
        $script:ZoneBright = if ($null -ne $p.ZoneBright) { $p.ZoneBright } else { 2 }
        if ($p.ZoneColors -and $p.ZoneColors.Count -eq 4) {
            $script:ZoneColors = $p.ZoneColors
        }
        # UI update deferred until next event
    }

    # Restore spectrum settings
    if ($script:Caps.Light -eq 'Spectrum') {
        $script:SpecEffect = if ($null -ne $p.SpecEffect) { $p.SpecEffect } else { 11 }
        if ($p.SpecColor -and $p.SpecColor.Count -eq 3) {
            $script:SpecColor = $p.SpecColor
        }
        # UI update deferred until next event
    }
}

# ---------------------------------------------------------------
# System tray
# ---------------------------------------------------------------
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:IconB64 = @(
    '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'
) -join ''

$iconBytes = [Convert]::FromBase64String($script:IconB64)
$iconStream = New-Object System.IO.MemoryStream(, $iconBytes)
$trayIcon = New-Object System.Drawing.Icon($iconStream)
$window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
    $trayIcon.Handle, [System.Windows.Int32Rect]::Empty,
    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $trayIcon
$notifyIcon.Text = 'Lenovo Control'
$notifyIcon.Visible = $true

# ---------------------------------------------------------------
# Live battery readout - tray badge + in-app bar
#
# Reads GetSystemPowerStatus via SystemInformation.PowerStatus, which is
# cheap enough to poll and does not need WMI. The tray icon is redrawn as
# a small rounded badge with the percentage in it, the way Vantage does,
# but sized and coloured to our own taste.
# ---------------------------------------------------------------
$script:PrevHIcon = [IntPtr]::Zero

function Get-BatteryStatus {
    try {
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        $pct = $ps.BatteryLifePercent          # 0.0 .. 1.0, or 255 when unknown
        if ($pct -gt 1) { return $null }        # no battery / unknown
        $plugged = ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online)
        $charging = (([int]$ps.BatteryChargeStatus -band
                      [int][System.Windows.Forms.BatteryChargeStatus]::Charging) -ne 0)
        return @{
            Percent  = [int][Math]::Round([double]$pct * 100.0)
            Plugged  = $plugged
            Charging = $charging
        }
    } catch { return $null }
}

# Turns raw power state plus the selected charge mode into the words a
# person actually wants: plugged in but held at 60% by Conservation is
# NOT "charging", and Rapid mode is worth calling out.
function Get-ChargeStateText {
    param([int]$Percent, [bool]$Plugged, [bool]$Charging, [string]$Mode)
    if (-not $Plugged) { return 'on battery' }
    if ($Charging) {
        if ($Mode -eq 'RapidCharge') { return 'fast charging' }
        return 'charging'
    }
    if ($Percent -ge 99) { return 'fully charged' }
    if ($Mode -eq 'Conservation') { return 'held by conservation' }
    return 'not charging'
}

function Get-BatteryColor {
    param([int]$Percent, [bool]$Charging, [bool]$Plugged)
    if ($Charging)       { return @(50, 190, 70) }    # green, actively charging
    if ($Percent -le 15) { return @(255, 69, 58) }    # red, urgent
    if ($Percent -le 30) { return @(255, 149, 0) }    # amber, getting low
    if ($Plugged)        { return @(60, 170, 225) }   # blue, plugged but held
    return @(230, 57, 80)                             # brand crimson, on battery
}

function New-RoundedPath {
    param([double]$X0, [double]$Y0, [double]$X1, [double]$Y1, [double]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc([single]$X0, [single]$Y0, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($X1 - $d), [single]$Y0, [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]($X1 - $d), [single]($Y1 - $d), [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$X0, [single]($Y1 - $d), [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

# A solid horizontal battery cell with the percentage in white inside it -
# the same shape language as Lenovo's own tray gauge, in our colours.
#
# Two things keep it legible next to the stock Windows icons:
#  * it is drawn at the system's ACTUAL small-icon size (DPI aware), so
#    Windows never downscales a 32px bitmap into a 16px slot and smears it;
#  * the cell fills the canvas. An earlier version used only 62% of the
#    height, which is exactly why it looked half the size of its neighbours.
function New-BatteryTrayIcon {
    param([int]$Percent, [bool]$Charging, [bool]$Plugged)

    $S = 32
    try {
        $sz = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
        if ($sz -ge 16 -and $sz -le 64) { $S = $sz }
    } catch { }

    $bmp = New-Object System.Drawing.Bitmap($S, $S)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $rgb = Get-BatteryColor -Percent $Percent -Charging $Charging -Plugged $Plugged
        $accent = [System.Drawing.Color]::FromArgb(255, $rgb[0], $rgb[1], $rgb[2])
        $brush = New-Object System.Drawing.SolidBrush($accent)

        $bx0 = 0.01 * $S; $by0 = 0.10 * $S
        $bx1 = 0.83 * $S; $by1 = 0.90 * $S

        $body = New-RoundedPath -X0 $bx0 -Y0 $by0 -X1 $bx1 -Y1 $by1 -R (0.16 * $S)
        $g.FillPath($brush, $body)
        $body.Dispose()

        $nub = New-RoundedPath -X0 (0.86 * $S) -Y0 (0.34 * $S) -X1 (0.99 * $S) -Y1 (0.66 * $S) -R (0.05 * $S)
        $g.FillPath($brush, $nub)
        $nub.Dispose()

        # Fit the number to the cell rather than assuming a point size that
        # only happens to work at one DPI.
        $text = "$Percent"
        $bw = $bx1 - $bx0
        $bh = $by1 - $by0
        $fs = if ($text.Length -ge 3) { [int]($bh * 0.62) } else { [int]($bh * 0.86) }
        if ($fs -lt 5) { $fs = 5 }
        $font = $null
        while ($fs -gt 4) {
            $try = New-Object System.Drawing.Font('Segoe UI', $fs, [System.Drawing.FontStyle]::Bold,
                        [System.Drawing.GraphicsUnit]::Pixel)
            $m = $g.MeasureString($text, $try)
            if ($m.Width -le ($bw * 0.90) -and $m.Height -le ($bh * 1.06)) { $font = $try; break }
            $try.Dispose()
            $fs--
        }
        if ($null -eq $font) {
            $font = New-Object System.Drawing.Font('Segoe UI', 5, [System.Drawing.FontStyle]::Bold,
                        [System.Drawing.GraphicsUnit]::Pixel)
        }

        $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF([single]$bx0, [single]$by0, [single]$bw, [single]$bh)
        $g.DrawString($text, $font, $white, $rect, $fmt)

        $fmt.Dispose(); $white.Dispose(); $font.Dispose(); $brush.Dispose()
    } finally {
        $g.Dispose()
    }

    $hicon = $bmp.GetHicon()
    $bmp.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    return @{ Icon = $icon; Handle = $hicon }
}

function Update-BatteryReadout {
    $bat = Get-BatteryStatus

    if ($null -eq $bat) {
        # Desktop or no battery reported: keep the plain logo.
        $notifyIcon.Icon = $trayIcon
        $notifyIcon.Text = 'Lenovo Control'
        if ($ctrl['RowBattery']) { $ctrl['RowBattery'].Visibility = 'Collapsed' }
        return
    }

    $pct = $bat.Percent
    $chg = $bat.Charging
    $plg = $bat.Plugged

    # Charge mode changes what the state actually means, so read it back
    # rather than assuming "plugged in" equals "charging".
    $mode = $null
    if ($script:Caps.Battery) { $mode = Get-BatteryMode }
    $stateText = Get-ChargeStateText -Percent $pct -Plugged $plg -Charging $chg -Mode $mode

    # --- tray badge ---
    $made = New-BatteryTrayIcon -Percent $pct -Charging $chg -Plugged $plg
    $notifyIcon.Icon = $made.Icon
    # Free the handle from the PREVIOUS refresh, now that nothing uses it.
    if ($script:PrevHIcon -ne [IntPtr]::Zero) {
        [LenovoHw]::DestroyIcon($script:PrevHIcon) | Out-Null
    }
    $script:PrevHIcon = $made.Handle
    $notifyIcon.Text = "Lenovo Control - $pct%, $stateText"

    # --- in-app bar ---
    if ($ctrl['RowBattery']) {
        $ctrl['RowBattery'].Visibility = 'Visible'
        $ctrl['TxtBatteryPct'].Text = "$pct%"
        $ctrl['TxtBatteryState'].Text = $stateText
        $rgb = Get-BatteryColor -Percent $pct -Charging $chg -Plugged $plg
        $ctrl['PbBattery'].Value = $pct
        $ctrl['PbBattery'].Foreground = New-Brush -Rgb $rgb
        $ctrl['TxtBatteryPct'].Foreground = New-Brush -Rgb $rgb
    }
}

$batteryTimer = New-Object System.Windows.Threading.DispatcherTimer
$batteryTimer.Interval = [TimeSpan]::FromSeconds(20)
$script:PromoteTries = 0

# Windows raises this the moment the charger goes in or out, so the badge
# recolours immediately instead of waiting up to 20s for the next poll.
# The handler runs on a system thread, hence the Dispatcher hop.
$script:PowerHandler = {
    try {
        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Normal,
            [action]{
                # The power line status can lag the event by a moment.
                Update-BatteryReadout
                Start-Sleep -Milliseconds 600
                Update-BatteryReadout
            }) | Out-Null
    } catch { }
}
try { [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:PowerHandler) } catch { }

$batteryTimer.Add_Tick({
    Update-BatteryReadout
    # Windows writes the icon's registry entry a little after it first
    # appears, so the initial promotion attempt can be too early. Retry a
    # few times, then stop bothering.
    if ($script:PromoteTries -lt 4 -and [bool](Get-Pref -Name 'PromoteTray' -Default 1)) {
        $script:PromoteTries++
        if ((Set-TrayPromoted -Promote $true) -gt 0) { $script:PromoteTries = 99 }
    }
})

# ---------------------------------------------------------------
# Settings: start with Windows, show on taskbar
#
# Startup uses a scheduled task rather than the Run key or the Startup
# folder, because the widget needs Administrator to reach the energy
# driver and those routes would raise a UAC prompt on every single boot.
# A task with "run with highest privileges" starts elevated silently.
# ---------------------------------------------------------------
$script:StartupTaskName = 'Lenovo Control'
$script:PrefsKey = 'HKCU:\Software\LenovoControl'

function Get-SelfLaunchCommand {
    # Compiled .exe launches itself; a loose .ps1 needs powershell in front.
    $exe = $null
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if ($exe -and $exe -notmatch '(?i)\\(powershell|pwsh)\.exe$') {
        return "`"$exe`" -Hidden"
    }
    $script = $PSCommandPath
    if (-not $script) { return $null }
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Hidden"
}

function Invoke-SchTasks {
    param([string[]]$SchArgs)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'schtasks.exe'
        $psi.Arguments = ($SchArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardOutput.ReadToEnd() | Out-Null
        $p.StandardError.ReadToEnd() | Out-Null
        $p.WaitForExit(8000) | Out-Null
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

function Test-StartupTask {
    return (Invoke-SchTasks -SchArgs @('/Query', '/TN', "`"$($script:StartupTaskName)`""))
}

function Enable-StartupTask {
    $cmd = Get-SelfLaunchCommand
    if (-not $cmd) { return $false }
    # schtasks needs the inner quotes of /TR escaped with backslashes.
    $tr = '"' + ($cmd -replace '"', '\"') + '"'
    $base = @('/Create', '/TN', "`"$($script:StartupTaskName)`"", '/TR', $tr,
              '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/F')
    # Give the desktop a moment to settle first; older builds reject /DELAY.
    if (Invoke-SchTasks -SchArgs ($base + @('/DELAY', '0000:15'))) { return $true }
    return (Invoke-SchTasks -SchArgs $base)
}

function Disable-StartupTask {
    return (Invoke-SchTasks -SchArgs @('/Delete', '/TN', "`"$($script:StartupTaskName)`"", '/F'))
}

# ---------------------------------------------------------------
# Tray visibility
#
# Windows 11 files every new tray icon into the hidden overflow. The
# "always show" choice from Settings is stored per icon under
# HKCU\Control Panel\NotifyIconSettings\<id>\IsPromoted, and the subkey
# only exists once the icon has been shown at least once - so this runs
# after the NotifyIcon is live. Undocumented, so it is best-effort: if
# Windows ignores it, dragging the icon out once still works.
# ---------------------------------------------------------------
function Set-TrayPromoted {
    param([bool]$Promote)
    $root = 'HKCU:\Control Panel\NotifyIconSettings'
    if (-not (Test-Path $root)) { return 0 }

    # Match on whichever executable is actually hosting us.
    $self = $null
    try { $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if (-not $self) { return 0 }

    $count = 0
    foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        try {
            $props = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
            $exe = $props.ExecutablePath
            if ($exe -and ($exe -ieq $self)) {
                Set-ItemProperty -Path $k.PSPath -Name 'IsPromoted' `
                    -Value ([int]([bool]$Promote)) -Type DWord -ErrorAction Stop
                $count++
            }
        } catch { }
    }
    return $count
}

function Get-Pref {
    param([string]$Name, $Default)
    try {
        $v = Get-ItemProperty -Path $script:PrefsKey -Name $Name -ErrorAction Stop
        return $v.$Name
    } catch { return $Default }
}

function Set-Pref {
    param([string]$Name, $Value)
    try {
        if (-not (Test-Path $script:PrefsKey)) { New-Item -Path $script:PrefsKey -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $script:PrefsKey -Name $Name -Value $Value -ErrorAction Stop
    } catch { }
}

function Show-Widget {
    try {
        if (-not $window.IsVisible) { $window.Show(); $window.Activate() }
    } catch {
        # WPF can throw "root Visual cannot have a parent" if window reinit fails
        # This happens after sleep/wake or service conflicts. Recover by reinit.
        $window.Show()
        $window.Activate()
    }
}
function Hide-Widget { $window.Hide() }
function Exit-Widget {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $app.Shutdown()
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('Show widget')
$miShow.Add_Click({ Show-Widget })
$trayMenu.Items.Add('-') | Out-Null
$miExit = $trayMenu.Items.Add('Exit')
$miExit.Add_Click({ Exit-Widget })
$notifyIcon.ContextMenuStrip = $trayMenu

$notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($window.IsVisible) { Hide-Widget } else { Show-Widget }
    }
})

$window.Add_Closing({
    param($sender, $e)
    $e.Cancel = $true
    Hide-Widget
})

# ---------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------
$ctrl['HeaderBar'].Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$ctrl['BtnClose'].Add_Click({ Hide-Widget })
$ctrl['BtnPin'].Add_Click({
    $window.Topmost = -not $window.Topmost
    $ctrl['BtnPin'].Foreground = if ($window.Topmost) { '#E63950' } else { '#8A8A99' }
})

$ctrl['RbConservation'].Add_Checked({ if (-not $script:Suppress) { Set-BatteryMode -TargetMode 'Conservation' } })
$ctrl['RbNormal'].Add_Checked({       if (-not $script:Suppress) { Set-BatteryMode -TargetMode 'Normal' } })
$ctrl['RbRapid'].Add_Checked({        if (-not $script:Suppress) { Set-BatteryMode -TargetMode 'RapidCharge' } })

$ctrl['SwFnLock'].Add_Checked({   if (-not $script:Suppress) { Set-FnLock -On $true } })
$ctrl['SwFnLock'].Add_Unchecked({ if (-not $script:Suppress) { Set-FnLock -On $false } })

$ctrl['RbWhiteOff'].Add_Checked({  if (-not $script:Suppress) { Set-WhiteBacklight -Level 'Off' } })
$ctrl['RbWhiteLow'].Add_Checked({  if (-not $script:Suppress) { Set-WhiteBacklight -Level 'Low' } })
$ctrl['RbWhiteHigh'].Add_Checked({ if (-not $script:Suppress) { Set-WhiteBacklight -Level 'High' } })

$zoneSwatch = {
    param($sender, $e)
    if ($script:Suppress) { return }
    $rgb = ConvertFrom-HexString -Hex $sender.Tag
    if ($rgb) { Set-ZoneColor -Rgb $rgb }
}
foreach ($b in @('BtnZ1','BtnZ2','BtnZ3','BtnZ4','BtnZ5','BtnZ6','BtnZ7')) {
    $ctrl[$b].Add_Click($zoneSwatch)
}
$ctrl['BtnZCustom'].Add_Click({ Show-Picker -Mode 'Zone' })

$ctrl['RbZoneAll'].Add_Checked({ if (-not $script:Suppress) { $script:ZoneTarget = 0 } })
$ctrl['RbZone1'].Add_Checked({   if (-not $script:Suppress) { $script:ZoneTarget = 1 } })
$ctrl['RbZone2'].Add_Checked({   if (-not $script:Suppress) { $script:ZoneTarget = 2 } })
$ctrl['RbZone3'].Add_Checked({   if (-not $script:Suppress) { $script:ZoneTarget = 3 } })
$ctrl['RbZone4'].Add_Checked({   if (-not $script:Suppress) { $script:ZoneTarget = 4 } })

$ctrl['RbZFxStatic'].Add_Checked({ if (-not $script:Suppress) { $script:ZoneEffect = 1; Send-ZoneState } })
$ctrl['RbZFxBreath'].Add_Checked({ if (-not $script:Suppress) { $script:ZoneEffect = 3; Send-ZoneState } })
$ctrl['RbZFxWave'].Add_Checked({   if (-not $script:Suppress) { $script:ZoneEffect = 4; Send-ZoneState } })
$ctrl['RbZFxSmooth'].Add_Checked({ if (-not $script:Suppress) { $script:ZoneEffect = 6; Send-ZoneState } })
$ctrl['RbZFxOff'].Add_Checked({    if (-not $script:Suppress) { Send-ZoneOff } })
$ctrl['RbZBrLow'].Add_Checked({    if (-not $script:Suppress) { $script:ZoneBright = 1; Send-ZoneState } })
$ctrl['RbZBrHigh'].Add_Checked({   if (-not $script:Suppress) { $script:ZoneBright = 2; Send-ZoneState } })

$specSwatch = {
    param($sender, $e)
    if ($script:Suppress) { return }
    $rgb = ConvertFrom-HexString -Hex $sender.Tag
    if ($rgb) { Set-SpectrumColor -R $rgb[0] -G $rgb[1] -B $rgb[2] }
}
foreach ($b in @('BtnS1','BtnS2','BtnS3','BtnS4','BtnS5','BtnS6','BtnS7')) {
    $ctrl[$b].Add_Click($specSwatch)
}
$ctrl['BtnSCustom'].Add_Click({ Show-Picker -Mode 'Spectrum' })

$ctrl['RbTgtAll'].Add_Checked({    if (-not $script:Suppress) { $script:SpecTarget = 'All' } })
$ctrl['RbTgtKeys'].Add_Checked({   if (-not $script:Suppress) { $script:SpecTarget = 'Keys' } })
$ctrl['RbTgtPerim'].Add_Checked({  if (-not $script:Suppress) { $script:SpecTarget = 'Perim' } })
$ctrl['RbTgtLogo'].Add_Checked({   if (-not $script:Suppress) { $script:SpecTarget = 'Logo' } })
$ctrl['RbTgtWasd'].Add_Checked({   if (-not $script:Suppress) { $script:SpecTarget = 'Wasd' } })
$ctrl['RbTgtArrows'].Add_Checked({ if (-not $script:Suppress) { $script:SpecTarget = 'Arrows' } })
$ctrl['RbTgtFRow'].Add_Checked({   if (-not $script:Suppress) { $script:SpecTarget = 'FRow' } })

$ctrl['RbSFxStatic'].Add_Checked({  if (-not $script:Suppress) { Send-SpectrumEffect -EffectType 11 -Color $script:SpecColor -Target $script:SpecTarget } })
$ctrl['RbSFxRainbow'].Add_Checked({ if (-not $script:Suppress) { Send-SpectrumEffect -EffectType 2 -Color $null -Direction 4 -Target $script:SpecTarget } })
$ctrl['RbSFxPulse'].Add_Checked({   if (-not $script:Suppress) { Send-SpectrumEffect -EffectType 4 -Color $null -Target $script:SpecTarget } })
$ctrl['RbSFxSmooth'].Add_Checked({  if (-not $script:Suppress) { Send-SpectrumEffect -EffectType 6 -Color $null -Target $script:SpecTarget } })

$ctrl['SldSpecBright'].Add_ValueChanged({
    if ($script:Suppress) { return }
    Set-SpectrumBrightness -Level ([int]$ctrl['SldSpecBright'].Value)
})

# --- picker interaction ---
# Dragging only repaints the preview; the hardware write happens on
# release, so a drag across the square is not hundreds of HID writes.
#
# Clamping is done with plain comparisons rather than [Math]::Min/Max.
# Mixing an integer literal with a double there lets PowerShell pick the
# Min(int,int) overload, which ROUNDS the double - so 0.55 became 1 and
# every colour snapped to a corner of the square (pure white/red/black).
function Limit-Double {
    param([double]$Value, [double]$Low, [double]$High)
    if ($Value -lt $Low)  { return $Low }
    if ($Value -gt $High) { return $High }
    return $Value
}

function Update-SvFromPoint {
    param($Point)
    $w = [double]$ctrl['SvArea'].ActualWidth
    $h = [double]$ctrl['SvArea'].ActualHeight
    if ($w -le 0 -or $h -le 0) { return }
    $script:PickSat = Limit-Double -Value ([double]$Point.X / $w) -Low 0.0 -High 1.0
    $script:PickVal = Limit-Double -Value (1.0 - ([double]$Point.Y / $h)) -Low 0.0 -High 1.0
    Update-PickerPreview
}

function Update-HueFromPoint {
    param($Point)
    $h = [double]$ctrl['HueArea'].ActualHeight
    if ($h -le 0) { return }
    $script:PickHue = Limit-Double -Value (([double]$Point.Y / $h) * 360.0) -Low 0.0 -High 360.0
    Update-PickerPreview
}

$ctrl['SvArea'].Add_MouseLeftButtonDown({
    param($sender, $e)
    $sender.CaptureMouse() | Out-Null
    Update-SvFromPoint -Point $e.GetPosition($sender)
})
$ctrl['SvArea'].Add_MouseMove({
    param($sender, $e)
    if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        Update-SvFromPoint -Point $e.GetPosition($sender)
    }
})
$ctrl['SvArea'].Add_MouseLeftButtonUp({
    param($sender, $e)
    $sender.ReleaseMouseCapture()
    Apply-PickedColor
})

$ctrl['HueArea'].Add_MouseLeftButtonDown({
    param($sender, $e)
    $sender.CaptureMouse() | Out-Null
    Update-HueFromPoint -Point $e.GetPosition($sender)
})
$ctrl['HueArea'].Add_MouseMove({
    param($sender, $e)
    if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        Update-HueFromPoint -Point $e.GetPosition($sender)
    }
})
$ctrl['HueArea'].Add_MouseLeftButtonUp({
    param($sender, $e)
    $sender.ReleaseMouseCapture()
    Apply-PickedColor
})

$ctrl['BtnPickApply'].Add_Click({
    $rgb = ConvertFrom-HexString -Hex $ctrl['TxtHex'].Text
    if ($null -eq $rgb) {
        # Bad hex: put the current colour back rather than closing on an error.
        $ctrl['TxtHex'].Text = ConvertTo-HexString -Rgb (Get-PickerRgb)
        return
    }
    Set-PickerFromRgb -Rgb $rgb
    Apply-PickedColor
    Hide-Picker
})

# ---------------------------------------------------------------
# Startup
# ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Get-MachineIdentity
$script:RapidUnsupported = [bool](Get-Pref -Name 'RapidUnsupported' -Default 0)

if (-not $isAdmin) {
    $ctrl['WarnBar'].Visibility = 'Visible'
    $ctrl['TxtWarn'].Text = 'Not running as Administrator - the hardware controls cannot work. ' +
        'Close this and start it with Lenovo_Control.bat (or the compiled .exe).'
    # Battery LEVEL needs no admin, so keep that visible even here - only
    # the mode controls are actually blocked.
    $ctrl['RowChargeMode'].Visibility = 'Collapsed'
    $ctrl['CardFn'].Visibility = 'Collapsed'
    $ctrl['PnlLightNone'].Visibility = 'Visible'
    $ctrl['TxtLightNone'].Text = 'Unavailable without Administrator rights.'
    $model = $script:Caps.Model
    if ($script:Caps.MTM) { $model += "   |   $($script:Caps.MTM)" }
    $ctrl['TxtModel'].Text = $model
    $ctrl['TxtCaps'].Text = 'not probed - needs Administrator'
    Set-Status 'needs administrator'
} else {
    Invoke-HardwareProbe
    Show-DetectedUi
}

$script:Suppress = $false
$ctrl['BtnPin'].Foreground = '#E63950'

# --- settings ---
$script:Suppress = $true
try {
    $ctrl['SwStartup'].IsChecked = Test-StartupTask
    $ctrl['SwTray'].IsChecked = [bool](Get-Pref -Name 'PromoteTray' -Default 1)
} finally { $script:Suppress = $false }

# Apply the tray-visibility preference once the icon exists, since Windows
# only creates its registry entry after the icon has been shown.
if ([bool](Get-Pref -Name 'PromoteTray' -Default 1)) {
    $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
        [action]{ Set-TrayPromoted -Promote $true | Out-Null }) | Out-Null
}

$ctrl['SwTray'].Add_Checked({
    if ($script:Suppress) { return }
    Set-Pref -Name 'PromoteTray' -Value 1
    $n = Set-TrayPromoted -Promote $true
    $ctrl['TxtTrayNote'].Text = if ($n -gt 0) {
        'Set. If it is still behind the arrow, sign out and back in once - Windows caches the tray layout.'
    } else {
        'Windows has not registered the icon yet. Leave this on, restart the widget, or drag the icon out of the arrow once.'
    }
})
$ctrl['SwTray'].Add_Unchecked({
    if ($script:Suppress) { return }
    Set-Pref -Name 'PromoteTray' -Value 0
    Set-TrayPromoted -Promote $false | Out-Null
    $ctrl['TxtTrayNote'].Text = 'Off - Windows may tuck the icon into the hidden-icons arrow.'
})

$ctrl['SwStartup'].Add_Checked({
    if ($script:Suppress) { return }
    if (Enable-StartupTask) {
        $ctrl['TxtStartupNote'].Text = 'Enabled. It will start in the tray about 15 seconds after you sign in.'
    } else {
        $script:Suppress = $true
        try { $ctrl['SwStartup'].IsChecked = $false } finally { $script:Suppress = $false }
        $ctrl['TxtStartupNote'].Text = 'Could not create the startup task - Administrator is required for that.'
    }
})
$ctrl['SwStartup'].Add_Unchecked({
    if ($script:Suppress) { return }
    Disable-StartupTask | Out-Null
    $ctrl['TxtStartupNote'].Text = 'Off. The widget will not start automatically.'
})

# Paint the battery badge immediately, then keep it live.
Update-BatteryReadout
$batteryTimer.Start()

# Refresh the moment the panel is opened, so it is never showing a stale
# number from up to 20 seconds ago.
$window.Add_IsVisibleChanged({
    if ($window.IsVisible) { Update-BatteryReadout }
})

$window.Add_SourceInitialized({
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right - $window.Width - 12
    $window.Top  = $wa.Bottom - $window.ActualHeight - 12

    # Restore saved user preferences (charging mode, lighting) after UI is ready
    Restore-SavedSettings
})

$app.Add_Exit({
    # Save current settings before exit
    Save-Preferences

    $batteryTimer.Stop()
    # SystemEvents keeps a static reference; leaving it subscribed keeps the
    # process alive and can throw on shutdown.
    try { [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:PowerHandler) } catch { }
    if ($script:PrevHIcon -ne [IntPtr]::Zero) { [LenovoHw]::DestroyIcon($script:PrevHIcon) | Out-Null }
    if ($script:EnergyHandle -ne [IntPtr]::Zero) { [LenovoHw]::CloseHandle($script:EnergyHandle) | Out-Null }
    if ($script:LightHandle -ne [IntPtr]::Zero) { [LenovoHw]::CloseHandle($script:LightHandle) | Out-Null }
})

if ($Hidden) {
    $notifyIcon.ShowBalloonTip(3000, 'Lenovo Control', 'Running in the system tray.',
        [System.Windows.Forms.ToolTipIcon]::Info)
} else {
    $window.Show()
}

$app.Run() | Out-Null

} catch {
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "Lenovo Control failed to start:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)",
            'Startup Error', 'OK', 'Error') | Out-Null
    } catch { }
}
