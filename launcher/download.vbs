Option Explicit
Dim h, s, lastError
Function Fetch(url)
    On Error Resume Next
    Fetch = False
    Err.Clear
    Set h = CreateObject("WinHttp.WinHttpRequest.5.1")
    h.SetTimeouts 15000, 15000, 30000, 30000
    h.Open "GET", url, False
    If Err.Number <> 0 Then
        lastError = Err.Description
        Exit Function
    End If
    If Left(url, 6) = "https:" Then
        h.Option(9) = 2048
        Err.Clear
    End If
    h.Send
    If Err.Number <> 0 Then
        lastError = Err.Description
        Exit Function
    End If
    If h.Status <> 200 Then
        lastError = "HTTP " & h.Status
        Exit Function
    End If
    Set s = CreateObject("ADODB.Stream")
    s.Type = 1
    s.Open
    s.Write h.ResponseBody
    s.SaveToFile WScript.Arguments(0), 2
    s.Close
    If Err.Number <> 0 Then
        lastError = Err.Description
        Exit Function
    End If
    Fetch = True
End Function
If Fetch("https://raw.githubusercontent.com/Abestreid/pc/refs/heads/main/PcSaleInventory.ps1") Then WScript.Quit 0
If Fetch("https://test.abeslab.by/pc/PcSaleInventory.ps1") Then WScript.Quit 0
If Fetch("http://test.abeslab.by/pc/PcSaleInventory.ps1") Then WScript.Quit 0
WScript.Echo "Download failed: " & lastError
WScript.Quit 1
