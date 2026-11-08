Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Cred2 {
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CREDENTIAL { public int Flags; public int Type; public string TargetName; public string Comment; public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist; public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName; }
}
"@
$p=[IntPtr]::Zero
[void][Cred2]::CredReadW('git:https://github.com',1,0,[ref]$p)
$c=[System.Runtime.InteropServices.Marshal]::PtrToStructure($p,[type][Cred2+CREDENTIAL])
$blob=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($c.CredentialBlob, $c.CredentialBlobSize/2)
[IO.File]::WriteAllText("$env:TEMP\.gh_token_tmp", $blob)
Write-Host "saved; user=$($c.UserName)"
