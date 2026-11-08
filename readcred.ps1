Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Cred {
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CREDENTIAL { public int Flags; public int Type; public string TargetName; public string Comment; public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist; public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName; }
}
"@
foreach ($t in @('git:https://github.com','git:https://imiuim@github.com','git:https://ignored@github.com','git:https://x-access-token@github.com')) {
  $p=[IntPtr]::Zero
  if ([Cred]::CredReadW($t,1,0,[ref]$p)) {
    $c=[System.Runtime.InteropServices.Marshal]::PtrToStructure($p,[type][Cred+CREDENTIAL])
    $blob=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($c.CredentialBlob, $c.CredentialBlobSize/2)
    Write-Host ("target=$t user=$($c.UserName) passlen=$($blob.Length) prefix=$($blob.Substring(0,[Math]::Min(8,$blob.Length)))...")
  } else { Write-Host "target=$t NOT-READABLE" }
}
