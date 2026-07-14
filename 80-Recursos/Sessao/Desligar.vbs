Option Explicit

Dim resposta
Dim shell

resposta = MsgBox( _
    "Deseja realmente desligar o computador?", _
    vbQuestion + vbYesNo + vbDefaultButton2, _
    "Confirmar desligamento" _
)

If resposta = vbYes Then
    Set shell = CreateObject("WScript.Shell")
    shell.Run "shutdown.exe /s /t 0", 0, False
End If
