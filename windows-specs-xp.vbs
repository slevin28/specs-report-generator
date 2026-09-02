Option Explicit

Const GB = 1073741824

Dim fso, shell, desktopPath, reportPath, reportFile
Dim cim, wmiStorage, computer, bios, operatingSystem, processor, enclosure
Dim manufacturer, model, serialNumber, computerName, osText, processorText
Dim formFactor, isLaptop, installedRamText, ramSlotsText, activationText
Dim memoryRows, memoryModules, memoryArrays, item, capacity, sizeGb
Dim memoryType, memorySpeed, memoryManufacturer, memoryPart, memoryLocator
Dim moduleCount, locatorCount, reportedSlots, totalModuleGb, useCode, slotCount
Dim graphicsRows, displayResolution, laptopDisplayRows, videoControllers
Dim activeVideoCount, activeRefresh, videoName, vramText
Dim pnpDevices, pnpName, pnpStatus, touchDevices, fingerprintDevices
Dim backlightDevices, touchStatus, fingerprintStatus, backlightStatus
Dim opticalRows, opticalDevices, opticalStatus, opticalCount
Dim networkAdapters, networkName, networkText, wifiStatus, ethernetStatus
Dim ethernetText, adapterType, adapterSpeed, adapterState
Dim diskRows, diskDrives, storagePredictions, diskCount, diskModel
Dim diskSize, diskType, diskBus, diskHealth, diskPnp
Dim batteryRows, batteries, batteryCount, designCapacity, fullCapacity
Dim domainStatus, mdmStatus, entraStatus, biosPasswordStatus, absoluteStatus
Dim absoluteAgent, services, serviceText, reportId

Function QuerySafe(service, queryText)
    On Error Resume Next
    Set QuerySafe = Nothing
    Err.Clear
    Set QuerySafe = service.ExecQuery(queryText)
    If Err.Number <> 0 Then
        Err.Clear
        Set QuerySafe = Nothing
    End If
    On Error GoTo 0
End Function

Function ConnectNamespace(namespacePath)
    On Error Resume Next
    Set ConnectNamespace = Nothing
    Err.Clear
    Set ConnectNamespace = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\" & namespacePath)
    If Err.Number <> 0 Then
        Err.Clear
        Set ConnectNamespace = Nothing
    End If
    On Error GoTo 0
End Function

Function FirstObject(service, queryText)
    Dim results, result
    Set FirstObject = Nothing
    Set results = QuerySafe(service, queryText)
    If results Is Nothing Then Exit Function
    For Each result In results
        Set FirstObject = result
        Exit Function
    Next
End Function

Function GetProp(objectValue, propertyName)
    On Error Resume Next
    Dim value
    GetProp = ""
    If objectValue Is Nothing Then Exit Function
    Err.Clear
    value = objectValue.Properties_.Item(propertyName).Value
    If Err.Number = 0 Then
        If Not IsNull(value) And Not IsEmpty(value) Then GetProp = value
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function Clean(value)
    On Error Resume Next
    Clean = ""
    If IsNull(value) Or IsEmpty(value) Or IsArray(value) Or IsObject(value) Then
        Clean = ""
    Else
        Clean = Trim(CStr(value))
    End If
    If Err.Number <> 0 Then
        Err.Clear
        Clean = ""
    End If
    On Error GoTo 0
End Function

Function Html(value)
    Dim text
    text = Clean(value)
    text = Replace(text, "&", "&amp;")
    text = Replace(text, "<", "&lt;")
    text = Replace(text, ">", "&gt;")
    text = Replace(text, Chr(34), "&quot;")
    Html = text
End Function

Function DisplayValue(value)
    If Len(Clean(value)) = 0 Then
        DisplayValue = "Unknown"
    Else
        DisplayValue = Clean(value)
    End If
End Function

Function FileSafe(value)
    Dim text, badChars, i
    text = Clean(value)
    badChars = "\/:*?" & Chr(34) & "<>|"
    For i = 1 To Len(badChars)
        text = Replace(text, Mid(badChars, i, 1), "_")
    Next
    If Len(text) = 0 Then text = "WindowsXP"
    FileSafe = text
End Function

Function FormatGb(numberValue)
    Dim roundedValue
    If Not IsNumeric(numberValue) Then
        FormatGb = "Unknown"
        Exit Function
    End If
    roundedValue = Round(CDbl(numberValue), 1)
    If Abs(roundedValue - Fix(roundedValue)) < 0.05 Then
        FormatGb = CStr(CLng(roundedValue)) & " GB"
    Else
        FormatGb = CStr(roundedValue) & " GB"
    End If
End Function

Function FormatBytes(byteValue)
    If Not IsNumeric(byteValue) Then
        FormatBytes = "Unknown"
    ElseIf CDbl(byteValue) >= 1E+12 Then
        FormatBytes = CStr(Round(CDbl(byteValue) / 1E+12, 2)) & " TB"
    Else
        FormatBytes = CStr(Round(CDbl(byteValue) / 1E+9, 1)) & " GB"
    End If
End Function

Function FormatLinkSpeed(bitsPerSecond)
    If Not IsNumeric(bitsPerSecond) Then
        FormatLinkSpeed = "unknown speed"
    ElseIf CDbl(bitsPerSecond) <= 0 Then
        FormatLinkSpeed = "unknown speed"
    ElseIf CDbl(bitsPerSecond) >= 1E+9 Then
        FormatLinkSpeed = CStr(Round(CDbl(bitsPerSecond) / 1E+9, 1)) & " Gbps"
    ElseIf CDbl(bitsPerSecond) >= 1E+6 Then
        FormatLinkSpeed = CStr(Round(CDbl(bitsPerSecond) / 1E+6, 0)) & " Mbps"
    Else
        FormatLinkSpeed = CStr(Round(CDbl(bitsPerSecond) / 1E+3, 0)) & " Kbps"
    End If
End Function

Function WmiInteger(value)
    On Error Resume Next
    Dim numberValue
    ' Legacy BIOS providers may return malformed values or the UINT16 unknown
    ' sentinel (65535). Treat those as unavailable instead of aborting the report.
    WmiInteger = -1
    If Not IsNumeric(value) Then Exit Function
    Err.Clear
    numberValue = CDbl(value)
    If Err.Number <> 0 Then
        Err.Clear
        Exit Function
    End If
    If numberValue < 0 Or numberValue > 32767 Then Exit Function
    WmiInteger = CInt(numberValue)
    If Err.Number <> 0 Then
        Err.Clear
        WmiInteger = -1
    End If
    On Error GoTo 0
End Function

Function MemoryTypeName(typeCode)
    Dim integerCode
    integerCode = WmiInteger(typeCode)
    If integerCode < 0 Then
        MemoryTypeName = "Unknown"
        Exit Function
    End If
    Select Case integerCode
        Case 17: MemoryTypeName = "SDRAM"
        Case 18: MemoryTypeName = "SGRAM"
        Case 19: MemoryTypeName = "RDRAM"
        Case 20: MemoryTypeName = "DDR"
        Case 21: MemoryTypeName = "DDR2"
        Case 22: MemoryTypeName = "DDR2 FB-DIMM"
        Case 24: MemoryTypeName = "DDR3"
        Case 26: MemoryTypeName = "DDR4"
        Case Else: MemoryTypeName = "Unknown"
    End Select
End Function

Function IsPortable(enclosureObject, computerObject)
    Dim chassisValues, chassisValue, pcSystemType
    IsPortable = False
    If Not enclosureObject Is Nothing Then
        chassisValues = GetProp(enclosureObject, "ChassisTypes")
        If IsArray(chassisValues) Then
            For Each chassisValue In chassisValues
                Select Case WmiInteger(chassisValue)
                    Case 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
                        IsPortable = True
                        Exit Function
                End Select
            Next
        Else
            Select Case WmiInteger(chassisValues)
                Case 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
                    IsPortable = True
                    Exit Function
            End Select
        End If
    End If
    pcSystemType = GetProp(computerObject, "PCSystemType")
    If WmiInteger(pcSystemType) = 2 Or WmiInteger(pcSystemType) = 8 Then IsPortable = True
End Function

Function DictText(dictionaryObject)
    Dim keys, i, result
    result = ""
    If dictionaryObject.Count > 0 Then
        keys = dictionaryObject.Keys
        For i = 0 To UBound(keys)
            If Len(result) > 0 Then result = result & ", "
            result = result & CStr(keys(i))
        Next
    End If
    DictText = result
End Function

Sub AddUnique(dictionaryObject, value)
    Dim text
    text = Clean(value)
    If Len(text) = 0 Then Exit Sub
    If Not dictionaryObject.Exists(text) Then dictionaryObject.Add text, True
End Sub

Function WifiGeneration(adapterDescription)
    Dim text
    text = LCase(Clean(adapterDescription))
    If InStr(text, "802.11be") > 0 Then
        WifiGeneration = "Wi-Fi 7 (802.11be)"
    ElseIf InStr(text, "802.11ax") > 0 Then
        WifiGeneration = "Wi-Fi 6 class (802.11ax)"
    ElseIf InStr(text, "802.11ac") > 0 Then
        WifiGeneration = "Wi-Fi 5 (802.11ac)"
    ElseIf InStr(text, "802.11n") > 0 Then
        WifiGeneration = "Wi-Fi 4 (802.11n)"
    ElseIf InStr(text, "802.11") > 0 Or InStr(text, "wireless") > 0 Then
        WifiGeneration = "Legacy Wi-Fi; exact generation not exposed by Windows XP"
    Else
        WifiGeneration = ""
    End If
End Function

Function NormalizeIdentifier(value)
    Dim text, result, i, character
    text = UCase(Clean(value))
    result = ""
    For i = 1 To Len(text)
        character = Mid(text, i, 1)
        If (character >= "A" And character <= "Z") Or (character >= "0" And character <= "9") Then
            result = result & character
        End If
    Next
    NormalizeIdentifier = result
End Function

Function SmartStatusForDisk(predictions, pnpIdentifier)
    Dim prediction, diskId, predictionId, predictFailure
    SmartStatusForDisk = "Not reported"
    If predictions Is Nothing Then Exit Function
    diskId = NormalizeIdentifier(pnpIdentifier)
    If Len(diskId) < 9 Then Exit Function
    For Each prediction In predictions
        predictionId = NormalizeIdentifier(GetProp(prediction, "InstanceName"))
        If Len(predictionId) >= 9 Then
            If InStr(predictionId, diskId) > 0 Or InStr(diskId, predictionId) > 0 Then
                predictFailure = GetProp(prediction, "PredictFailure")
                If CStr(predictFailure) = "True" Or CStr(predictFailure) = "-1" Then
                    SmartStatusForDisk = "Warning (predictive failure)"
                Else
                    SmartStatusForDisk = "OK"
                End If
                Exit Function
            End If
        End If
    Next
End Function

Function XpActivationStatus(service)
    Dim activations, activation, required
    XpActivationStatus = "Unknown (activation provider not available)"
    Set activations = QuerySafe(service, "SELECT ActivationRequired FROM Win32_WindowsProductActivation")
    If activations Is Nothing Then Exit Function
    For Each activation In activations
        required = GetProp(activation, "ActivationRequired")
        If WmiInteger(required) >= 0 Then
            If WmiInteger(required) = 0 Then
                XpActivationStatus = "Activated"
            Else
                XpActivationStatus = "Not activated"
            End If
            Exit Function
        End If
    Next
End Function

Function VendorBiosPasswordStatus(manufacturerName)
    Dim service, settings, setting, stateValue, settingName, settingValue
    VendorBiosPasswordStatus = "Not exposed by installed firmware WMI provider"

    If InStr(LCase(manufacturerName), "lenovo") > 0 Then
        Set service = ConnectNamespace("root\wmi")
        If service Is Nothing Then Exit Function
        Set settings = QuerySafe(service, "SELECT PasswordState FROM Lenovo_BiosPasswordSettings")
        If settings Is Nothing Then Exit Function
        For Each setting In settings
            stateValue = GetProp(setting, "PasswordState")
            If WmiInteger(stateValue) >= 0 Then
                If WmiInteger(stateValue) = 0 Then
                    VendorBiosPasswordStatus = "Not configured"
                Else
                    VendorBiosPasswordStatus = "Configured"
                End If
                Exit Function
            End If
        Next
    ElseIf InStr(LCase(manufacturerName), "hp") > 0 Or InStr(LCase(manufacturerName), "hewlett") > 0 Then
        Set service = ConnectNamespace("root\HP\InstrumentedBIOS")
        If service Is Nothing Then Exit Function
        Set settings = QuerySafe(service, "SELECT Name, IsSet FROM HP_BIOSSetting")
        If settings Is Nothing Then Exit Function
        For Each setting In settings
            settingName = LCase(Clean(GetProp(setting, "Name")))
            If InStr(settingName, "setup password") > 0 Or InStr(settingName, "administrator password") > 0 Then
                stateValue = GetProp(setting, "IsSet")
                If WmiInteger(stateValue) >= 0 Then
                    If WmiInteger(stateValue) > 0 Then
                        VendorBiosPasswordStatus = "Configured"
                    Else
                        VendorBiosPasswordStatus = "Not configured"
                    End If
                Else
                    VendorBiosPasswordStatus = "Firmware setting present; state unclear"
                End If
                Exit Function
            End If
        Next
    ElseIf InStr(LCase(manufacturerName), "dell") > 0 Then
        Set service = ConnectNamespace("root\dcim\sysman\biosattributes")
        If service Is Nothing Then Exit Function
        Set settings = QuerySafe(service, "SELECT AttributeName, CurrentValue FROM EnumerationAttribute")
        If settings Is Nothing Then Exit Function
        For Each setting In settings
            settingName = LCase(Clean(GetProp(setting, "AttributeName")))
            If InStr(settingName, "admin") > 0 And InStr(settingName, "password") > 0 Then
                settingValue = LCase(Clean(GetProp(setting, "CurrentValue")))
                If settingValue = "not set" Or settingValue = "disabled" Or settingValue = "none" Then
                    VendorBiosPasswordStatus = "Not configured"
                ElseIf Len(settingValue) > 0 Then
                    VendorBiosPasswordStatus = "Configured"
                Else
                    VendorBiosPasswordStatus = "Firmware setting present; state unclear"
                End If
                Exit Function
            End If
        Next
    End If
End Function

Sub WriteLine(text)
    reportFile.WriteLine text
End Sub

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
Set cim = ConnectNamespace("root\cimv2")
If cim Is Nothing Then
    WScript.Echo "Unable to connect to Windows Management Instrumentation (WMI)."
    WScript.Quit 1
End If

Set computer = FirstObject(cim, "SELECT * FROM Win32_ComputerSystem")
Set bios = FirstObject(cim, "SELECT * FROM Win32_BIOS")
Set operatingSystem = FirstObject(cim, "SELECT * FROM Win32_OperatingSystem")
Set processor = FirstObject(cim, "SELECT * FROM Win32_Processor")
Set enclosure = FirstObject(cim, "SELECT * FROM Win32_SystemEnclosure")

manufacturer = DisplayValue(GetProp(computer, "Manufacturer"))
model = DisplayValue(GetProp(computer, "Model"))
serialNumber = DisplayValue(GetProp(bios, "SerialNumber"))
computerName = DisplayValue(GetProp(computer, "Name"))
processorText = DisplayValue(GetProp(processor, "Name"))
osText = DisplayValue(GetProp(operatingSystem, "Caption"))
If Len(Clean(GetProp(operatingSystem, "Version"))) > 0 Then
    osText = osText & " " & Clean(GetProp(operatingSystem, "Version"))
End If
If Len(Clean(GetProp(operatingSystem, "CSDVersion"))) > 0 Then
    osText = osText & " " & Clean(GetProp(operatingSystem, "CSDVersion"))
End If

isLaptop = IsPortable(enclosure, computer)
If isLaptop Then
    formFactor = "Laptop / Portable"
Else
    formFactor = "Desktop"
End If

memoryRows = ""
moduleCount = 0
locatorCount = 0
reportedSlots = 0
totalModuleGb = 0
Set memoryModules = QuerySafe(cim, "SELECT * FROM Win32_PhysicalMemory")
If Not memoryModules Is Nothing Then
    For Each item In memoryModules
        capacity = GetProp(item, "Capacity")
        If IsNumeric(capacity) Then
            If CDbl(capacity) > 0 Then
                moduleCount = moduleCount + 1
                sizeGb = CDbl(capacity) / GB
                totalModuleGb = totalModuleGb + sizeGb
                memoryLocator = Clean(GetProp(item, "DeviceLocator"))
                If Len(memoryLocator) > 0 Then locatorCount = locatorCount + 1
                memoryType = GetProp(item, "SMBIOSMemoryType")
                If WmiInteger(memoryType) <= 0 Then memoryType = GetProp(item, "MemoryType")
                memorySpeed = DisplayValue(GetProp(item, "Speed"))
                memoryManufacturer = DisplayValue(GetProp(item, "Manufacturer"))
                memoryPart = DisplayValue(GetProp(item, "PartNumber"))
                memoryRows = memoryRows & "<tr><td>" & CStr(moduleCount) & "</td><td>" & Html(FormatGb(sizeGb)) & "</td><td>" & Html(MemoryTypeName(memoryType)) & "</td><td>" & Html(memorySpeed) & " MHz</td><td>" & Html(memoryManufacturer) & "</td><td>" & Html(memoryPart) & "</td></tr>"
            End If
        End If
    Next
End If
If moduleCount = 0 Then
    memoryRows = "<tr><td colspan='6'>Memory-module details not reported by WMI</td></tr>"
End If

Set memoryArrays = QuerySafe(cim, "SELECT Use, MemoryDevices FROM Win32_PhysicalMemoryArray")
If Not memoryArrays Is Nothing Then
    For Each item In memoryArrays
        useCode = GetProp(item, "Use")
        slotCount = WmiInteger(GetProp(item, "MemoryDevices"))
        If WmiInteger(useCode) = 3 And slotCount >= 0 Then reportedSlots = reportedSlots + slotCount
    Next
    If reportedSlots = 0 Then
        For Each item In memoryArrays
            slotCount = WmiInteger(GetProp(item, "MemoryDevices"))
            If slotCount >= 0 Then reportedSlots = reportedSlots + slotCount
        Next
    End If
End If

If moduleCount > 0 And reportedSlots >= moduleCount And locatorCount = moduleCount Then
    ramSlotsText = CStr(moduleCount) & " used / " & CStr(reportedSlots) & " total / " & CStr(reportedSlots - moduleCount) & " free"
Else
    ramSlotsText = "Unknown (SMBIOS slot count was not reliable)"
End If
If totalModuleGb > 0 Then
    installedRamText = FormatGb(totalModuleGb)
ElseIf IsNumeric(GetProp(computer, "TotalPhysicalMemory")) Then
    installedRamText = FormatGb(CDbl(GetProp(computer, "TotalPhysicalMemory")) / GB)
Else
    installedRamText = "Unknown"
End If

graphicsRows = ""
displayResolution = "Unknown"
activeVideoCount = 0
activeRefresh = ""
Set videoControllers = QuerySafe(cim, "SELECT * FROM Win32_VideoController")
If Not videoControllers Is Nothing Then
    For Each item In videoControllers
        videoName = DisplayValue(GetProp(item, "Name"))
        If IsNumeric(GetProp(item, "AdapterRAM")) Then
            vramText = FormatGb(CDbl(GetProp(item, "AdapterRAM")) / GB)
        Else
            vramText = "Unknown"
        End If
        graphicsRows = graphicsRows & "<tr><td>" & Html(videoName) & "</td><td>" & Html(vramText) & "</td><td>" & Html(DisplayValue(GetProp(item, "VideoProcessor"))) & "</td><td>" & Html(DisplayValue(GetProp(item, "DriverVersion"))) & "</td></tr>"
        If IsNumeric(GetProp(item, "CurrentHorizontalResolution")) And IsNumeric(GetProp(item, "CurrentVerticalResolution")) Then
            If CDbl(GetProp(item, "CurrentHorizontalResolution")) > 0 And CDbl(GetProp(item, "CurrentVerticalResolution")) > 0 Then
                activeVideoCount = activeVideoCount + 1
                displayResolution = CStr(GetProp(item, "CurrentHorizontalResolution")) & " x " & CStr(GetProp(item, "CurrentVerticalResolution"))
                If IsNumeric(GetProp(item, "CurrentRefreshRate")) Then activeRefresh = CStr(GetProp(item, "CurrentRefreshRate")) & " Hz"
            End If
        End If
    Next
End If
If Len(graphicsRows) = 0 Then graphicsRows = "<tr><td colspan='4'>Graphics details not reported by WMI</td></tr>"
laptopDisplayRows = ""
If isLaptop Then
    laptopDisplayRows = "<tr><td class='label'>Built-in Display Size</td><td>Unknown (not exposed by Windows XP)</td></tr>"
    If activeVideoCount = 1 And Len(activeRefresh) > 0 Then
        laptopDisplayRows = laptopDisplayRows & "<tr><td class='label'>Built-in Refresh Rate</td><td>" & Html(activeRefresh) & "</td></tr>"
    Else
        laptopDisplayRows = laptopDisplayRows & "<tr><td class='label'>Built-in Refresh Rate</td><td>Unknown (multiple or unreported displays)</td></tr>"
    End If
End If

Set touchDevices = CreateObject("Scripting.Dictionary")
Set fingerprintDevices = CreateObject("Scripting.Dictionary")
Set backlightDevices = CreateObject("Scripting.Dictionary")
touchDevices.CompareMode = 1
fingerprintDevices.CompareMode = 1
backlightDevices.CompareMode = 1
Set pnpDevices = QuerySafe(cim, "SELECT * FROM Win32_PnPEntity")
If Not pnpDevices Is Nothing Then
    For Each item In pnpDevices
        pnpName = Clean(GetProp(item, "Name"))
        pnpStatus = LCase(Clean(GetProp(item, "Status")))
        If pnpStatus = "ok" Or Len(pnpStatus) = 0 Then
            networkText = LCase(pnpName & " " & Clean(GetProp(item, "PNPClass")))
            If InStr(networkText, "touch screen") > 0 Or InStr(networkText, "touchscreen") > 0 Then AddUnique touchDevices, pnpName
            If InStr(networkText, "fingerprint") > 0 Or InStr(networkText, "biometric") > 0 Then AddUnique fingerprintDevices, pnpName
            If InStr(networkText, "backlit keyboard") > 0 Or InStr(networkText, "keyboard backlight") > 0 Or InStr(networkText, "illuminated keyboard") > 0 Then AddUnique backlightDevices, pnpName
        End If
    Next
End If
If touchDevices.Count > 0 Then
    touchStatus = "Yes (" & DictText(touchDevices) & ")"
Else
    touchStatus = "No touchscreen detected"
End If
If fingerprintDevices.Count > 0 Then
    fingerprintStatus = "Detected (" & DictText(fingerprintDevices) & ")"
Else
    fingerprintStatus = "Not detected"
End If
If backlightDevices.Count > 0 Then
    backlightStatus = "Detected (" & DictText(backlightDevices) & ")"
Else
    backlightStatus = "Unknown (not exposed by standard Windows XP hardware data)"
End If

opticalRows = ""
opticalCount = 0
Set opticalDevices = QuerySafe(cim, "SELECT Name, PNPDeviceID FROM Win32_CDROMDrive")
If Not opticalDevices Is Nothing Then
    For Each item In opticalDevices
        pnpName = Clean(GetProp(item, "Name"))
        If InStr(LCase(pnpName), "virtual") = 0 Then
            opticalCount = opticalCount + 1
            If Len(opticalRows) > 0 Then opticalRows = opticalRows & ", "
            opticalRows = opticalRows & pnpName
        End If
    Next
End If
If opticalCount > 0 Then
    opticalStatus = "Detected (" & opticalRows & ")"
Else
    opticalStatus = "Not detected"
End If

wifiStatus = "Not detected"
ethernetText = ""
Set networkAdapters = QuerySafe(cim, "SELECT * FROM Win32_NetworkAdapter")
If Not networkAdapters Is Nothing Then
    For Each item In networkAdapters
        networkName = Clean(GetProp(item, "NetConnectionID"))
        If Len(networkName) = 0 Then networkName = Clean(GetProp(item, "Name"))
        networkText = LCase(networkName & " " & Clean(GetProp(item, "Description")))
        If Len(Clean(GetProp(item, "MACAddress"))) > 0 Then
            If InStr(networkText, "wireless") > 0 Or InStr(networkText, "wi-fi") > 0 Or InStr(networkText, "wifi") > 0 Or InStr(networkText, "802.11") > 0 Then
                If Len(WifiGeneration(networkText)) > 0 Then wifiStatus = WifiGeneration(networkText)
            Else
                adapterType = LCase(Clean(GetProp(item, "AdapterType")))
                If InStr(adapterType, "ethernet") > 0 And InStr(networkText, "bluetooth") = 0 And InStr(networkText, "virtual") = 0 And InStr(networkText, "vpn") = 0 Then
                    adapterSpeed = FormatLinkSpeed(GetProp(item, "Speed"))
                    adapterState = GetProp(item, "NetConnectionStatus")
                    If WmiInteger(adapterState) >= 0 Then
                        If WmiInteger(adapterState) = 2 Then
                            adapterState = "connected"
                        Else
                            adapterState = "disconnected"
                        End If
                    Else
                        adapterState = "state unknown"
                    End If
                    If Len(ethernetText) > 0 Then ethernetText = ethernetText & "; "
                    ethernetText = ethernetText & networkName & ": " & adapterSpeed & " " & adapterState
                End If
            End If
        End If
    Next
End If
If Len(ethernetText) > 0 Then
    ethernetStatus = ethernetText
Else
    ethernetStatus = "Not detected"
End If

Set wmiStorage = ConnectNamespace("root\wmi")
If wmiStorage Is Nothing Then
    Set storagePredictions = Nothing
Else
    Set storagePredictions = QuerySafe(wmiStorage, "SELECT InstanceName, PredictFailure FROM MSStorageDriver_FailurePredictStatus")
End If
diskRows = ""
diskCount = 0
Set diskDrives = QuerySafe(cim, "SELECT * FROM Win32_DiskDrive")
If Not diskDrives Is Nothing Then
    For Each item In diskDrives
        diskBus = Clean(GetProp(item, "InterfaceType"))
        If InStr(LCase(diskBus), "usb") = 0 And InStr(LCase(diskBus), "1394") = 0 Then
            diskCount = diskCount + 1
            diskModel = DisplayValue(GetProp(item, "Model"))
            diskSize = FormatBytes(GetProp(item, "Size"))
            If InStr(LCase(diskModel), "ssd") > 0 Or InStr(LCase(diskModel), "solid state") > 0 Then
                diskType = "Solid State"
            ElseIf Len(Clean(GetProp(item, "MediaType"))) > 0 Then
                diskType = Clean(GetProp(item, "MediaType"))
            Else
                diskType = "Unknown"
            End If
            diskPnp = GetProp(item, "PNPDeviceID")
            diskHealth = SmartStatusForDisk(storagePredictions, diskPnp)
            diskRows = diskRows & "<tr><td>Disk " & Html(GetProp(item, "Index")) & "</td><td>" & Html(diskModel) & "</td><td>" & Html(diskSize) & "</td><td>" & Html(diskType) & "</td><td>" & Html(DisplayValue(diskBus)) & "</td><td>" & Html(diskHealth) & "</td></tr>"
        End If
    Next
End If
If diskCount = 0 Then diskRows = "<tr><td colspan='6'>No internal storage drives detected</td></tr>"

batteryRows = ""
batteryCount = 0
If isLaptop Then
    Set batteries = QuerySafe(cim, "SELECT * FROM Win32_Battery")
    If Not batteries Is Nothing Then
        For Each item In batteries
            batteryCount = batteryCount + 1
            designCapacity = GetProp(item, "DesignCapacity")
            fullCapacity = GetProp(item, "FullChargeCapacity")
            batteryRows = batteryRows & "<tr><td>Battery " & CStr(batteryCount) & "</td><td>" & Html(DisplayValue(GetProp(item, "Name"))) & "</td><td>" & Html(DisplayValue(designCapacity)) & " mWh</td><td>" & Html(DisplayValue(fullCapacity)) & " mWh</td></tr>"
        Next
    End If
    If batteryCount = 0 Then batteryRows = "<tr><td colspan='4'>Battery details not reported by WMI</td></tr>"
End If

activationText = XpActivationStatus(cim)
If CStr(GetProp(computer, "PartOfDomain")) = "True" Or CStr(GetProp(computer, "PartOfDomain")) = "-1" Then
    domainStatus = "Joined"
Else
    domainStatus = "Not joined"
End If
mdmStatus = "Not supported on Windows XP"
entraStatus = "Not supported on Windows XP"
biosPasswordStatus = VendorBiosPasswordStatus(manufacturer)

absoluteAgent = ""
Set services = QuerySafe(cim, "SELECT Name, DisplayName FROM Win32_Service")
If Not services Is Nothing Then
    For Each item In services
        serviceText = LCase(Clean(GetProp(item, "Name")) & " " & Clean(GetProp(item, "DisplayName")))
        If InStr(serviceText, "rpcnet") > 0 Or InStr(serviceText, "computrace") > 0 Or InStr(serviceText, "absolute") > 0 Then
            absoluteAgent = DisplayValue(GetProp(item, "DisplayName"))
            Exit For
        End If
    Next
End If
If Len(absoluteAgent) > 0 Then
    absoluteStatus = "Software agent detected (" & absoluteAgent & "); firmware state not exposed"
Else
    absoluteStatus = "No software agent detected; firmware state not exposed"
End If

desktopPath = shell.SpecialFolders("Desktop")
reportId = serialNumber
If reportId = "Unknown" Then reportId = computerName
reportPath = fso.BuildPath(desktopPath, FileSafe(reportId) & "_SystemReport.html")
Set reportFile = fso.CreateTextFile(reportPath, True, False)

WriteLine "<!DOCTYPE html>"
WriteLine "<html><head><meta http-equiv='Content-Type' content='text/html; charset=windows-1252'>"
WriteLine "<title>Windows XP System Specification Report</title>"
WriteLine "<style type='text/css'>"
WriteLine "body{font-family:Arial,sans-serif;margin:0;background:#eef1f4;color:#20252b;font-size:12px} .page{width:900px;margin:16px auto;background:#fff;border:1px solid #aab2bb} .header{background:#17324d;color:#fff;padding:18px 22px} .header h1{margin:0;font-size:24px} .header p{margin:5px 0 0;color:#dce8f2} .content{padding:14px 20px 22px} .section{margin:0 0 14px} h2{font-size:16px;color:#17324d;border-bottom:2px solid #d6dde4;padding:0 0 5px;margin:0 0 7px} table{border-collapse:collapse;width:100%;table-layout:fixed} th{background:#e7edf2;text-align:left} th,td{border:1px solid #cbd2d9;padding:5px;vertical-align:top;word-wrap:break-word} .info{border:1px solid #cbd2d9} .info td{border:0;border-bottom:1px solid #e4e8ec} .info .label{width:180px;font-weight:bold;background:#f3f5f7} .note{color:#59636d;font-size:11px} .footer{padding:10px 20px;background:#eef1f4;color:#59636d;border-top:1px solid #cbd2d9}"
WriteLine "</style></head><body><div class='page'>"
WriteLine "<div class='header'><h1>Windows XP System Specification Report</h1><p>Generated " & Html(Now) & "</p></div><div class='content'>"

WriteLine "<div class='section'><h2>General System</h2><table class='info'>"
WriteLine "<tr><td class='label'>Manufacturer</td><td>" & Html(manufacturer) & "</td><td class='label'>Model</td><td>" & Html(model) & "</td></tr>"
WriteLine "<tr><td class='label'>Form Factor</td><td>" & Html(formFactor) & "</td><td class='label'>Serial Number</td><td>" & Html(serialNumber) & "</td></tr>"
WriteLine "<tr><td class='label'>Processor</td><td>" & Html(processorText) & "</td><td class='label'>Installed RAM</td><td>" & Html(installedRamText) & "</td></tr>"
WriteLine "<tr><td class='label'>RAM Slots</td><td>" & Html(ramSlotsText) & "</td><td class='label'>Windows Version</td><td>" & Html(osText) & "</td></tr>"
WriteLine "<tr><td class='label'>Computer Name</td><td>" & Html(computerName) & "</td><td class='label'>Windows Activation</td><td>" & Html(activationText) & "</td></tr>"
WriteLine "<tr><td class='label'>Touchscreen</td><td colspan='3'>" & Html(touchStatus) & "</td></tr></table></div>"

WriteLine "<div class='section'><h2>Memory Modules</h2><table><tr><th>#</th><th>Size</th><th>Type</th><th>Speed</th><th>Manufacturer</th><th>Part Number</th></tr>" & memoryRows & "</table></div>"

WriteLine "<div class='section'><h2>Connectivity &amp; Features</h2><table class='info'>"
WriteLine "<tr><td class='label'>Wi-Fi Generation</td><td>" & Html(wifiStatus) & "</td><td class='label'>Ethernet</td><td>" & Html(ethernetStatus) & "</td></tr>"
WriteLine "<tr><td class='label'>Fingerprint Reader</td><td>" & Html(fingerprintStatus) & "</td><td class='label'>Optical Drive</td><td>" & Html(opticalStatus) & "</td></tr>"
WriteLine "<tr><td class='label'>Keyboard Backlight</td><td colspan='3'>" & Html(backlightStatus) & "</td></tr></table></div>"

WriteLine "<div class='section'><h2>Display &amp; Graphics</h2><table class='info'><tr><td class='label'>Resolution</td><td>" & Html(displayResolution) & "</td></tr>" & laptopDisplayRows & "</table>"
WriteLine "<table><tr><th>GPU</th><th>VRAM</th><th>Processor</th><th>Driver</th></tr>" & graphicsRows & "</table></div>"

WriteLine "<div class='section'><h2>Storage Drives</h2><table><tr><th>Drive</th><th>Model</th><th>Size</th><th>Type</th><th>Bus</th><th>Health</th></tr>" & diskRows & "</table></div>"

If isLaptop Then
    WriteLine "<div class='section'><h2>Battery</h2><table><tr><th>Battery</th><th>Name</th><th>Design Capacity</th><th>Full Charge Capacity</th></tr>" & batteryRows & "</table></div>"
End If

WriteLine "<div class='section'><h2>Management &amp; Security</h2><table class='info'>"
WriteLine "<tr><td class='label'>Windows Domain</td><td>" & Html(domainStatus) & "</td><td class='label'>MDM Enrollment</td><td>" & Html(mdmStatus) & "</td></tr>"
WriteLine "<tr><td class='label'>Entra ID</td><td>" & Html(entraStatus) & "</td><td class='label'>BIOS Password</td><td>" & Html(biosPasswordStatus) & "</td></tr>"
WriteLine "<tr><td class='label'>Absolute / Computrace</td><td colspan='3'>" & Html(absoluteStatus) & "</td></tr></table></div>"

WriteLine "<p class='note'>Windows XP exposes fewer standardized hardware and management APIs than current Windows releases. Unknown and unsupported values are intentionally not reported as negative results.</p>"
WriteLine "</div><div class='footer'>System Specs Report Generator - Windows XP compatibility mode</div></div></body></html>"
reportFile.Close

shell.Run Chr(34) & reportPath & Chr(34), 1, False
WScript.Echo "Report saved to: " & reportPath
WScript.Quit 0
