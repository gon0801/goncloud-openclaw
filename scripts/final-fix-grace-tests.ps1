param([string]$ProductionPath = 'C:\Users\ehven\.openclaw\scripts\restore-console.ps1')
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText($ProductionPath)
# External session mutation and wall clock are replaced only in this test harness.
# The real script's parsing, event selection, timing and restoration branches execute.
$source = $source.Replace('"$env:SystemRoot\System32\quser.exe"', 'Test-Quser').Replace('"$env:SystemRoot\System32\tscon.exe"', 'Test-Tscon').Replace('exit 0','return')
$base = [datetime]'2026-09-08T14:42:00Z'
function Event($Second, $Id=1, $User='OPENCLAW\ehven', $Address='100.69.39.115') {
    [pscustomobject]@{Second=$Second;Id=$Id;User=$User;Address=$Address}
}
# Each expectation catches a too-early tscon, wrong user/session, or missed re-evaluation.
$cases = @(
    @{Name='Earlier LOCAL timer cannot restore a 2.6-second-old remote disconnect';Start=8.34;Events=@((Event -24.527 1 'OPENCLAW\ehven' 'LOCAL'),(Event 5.74));Want=35.74},
    @{Name='Repeated remote disconnect restarts grace while worker waits';Start=10;Events=@((Event 0),(Event 20),(Event 40));Want=70},
    @{Name='LOCAL event during waiting cannot shorten remote grace';Start=10;Events=@((Event 0),(Event 15 1 'OPENCLAW\ehven' 'LOCAL'));Want=30},
    @{Name='Other user and session events cannot authorize ehven restore';Start=10;Events=@((Event -60 2),(Event -60 1 'OPENCLAW\other'));Want=$null},
    @{Name='Newer foreign event does not replace exact-session remote timestamp';Start=10;Events=@((Event 0),(Event 5 2),(Event 8 1 'OPENCLAW\other'));Want=30},
    @{Name='Already active ehven is a no-op';Start=40;Events=@((Event 0));ActiveAt=0;Want=$null},
    @{Name='Reconnect while worker waits is a no-op';Start=10;Events=@((Event 0));ActiveAt=15;Want=$null},
    @{Name='29.999 seconds is too early';Start=29.999;Events=@((Event 0));Want=30},
    @{Name='Exactly 30 seconds is eligible';Start=30;Events=@((Event 0));Want=30},
    @{Name='No remote event fails closed';Start=40;Events=@((Event 0 1 'OPENCLAW\ehven' 'LOCAL'));Want=$null},
    @{Name='Repeated disconnects beyond task budget never restore early';Start=10;Events=@((Event 0),(Event 20),(Event 40),(Event 60),(Event 80),(Event 100),(Event 120));Want=$null}
)
$failed=0
foreach($case in $cases) {
    $state=@{Now=$base.AddSeconds($case.Start);Calls=[Collections.Generic.List[object]]::new();Logs=[Collections.Generic.List[string]]::new();Case=$case;Base=$base}
    $shell=[powershell]::Create()
    $shell.Runspace.SessionStateProxy.SetVariable('fixture',$state)
    $setup=@'
function Get-Date { param([string]$Format) if($Format){$fixture.Now.ToString($Format)}else{$fixture.Now} }
function Start-Sleep { param([int]$Milliseconds,[int]$Seconds) $fixture.Now=$fixture.Now.AddMilliseconds($Milliseconds).AddSeconds($Seconds) }
function New-Item { param($ItemType,$Path,[switch]$Force) }
function Add-Content { param($Path,$Encoding,$Value) $fixture.Logs.Add([string]$Value) }
function Test-Quser {
    $global:LASTEXITCODE=0
    ' USERNAME SESSIONNAME ID STATE IDLE TIME LOGON TIME'
    if($fixture.Case.ContainsKey('ActiveAt') -and ($fixture.Now-$fixture.Base).TotalSeconds -ge $fixture.Case.ActiveAt){' ehven console 1 Active none 9/8/2026 10:12 AM'}else{' ehven 1 Disc 1 9/8/2026 10:12 AM'}
}
function Test-Tscon { param($SessionId,$Destination) $fixture.Calls.Add(@{At=($fixture.Now-$fixture.Base).TotalSeconds;Id=$SessionId;Destination=$Destination});$global:LASTEXITCODE=0 }
function Get-WinEvent {
    param($FilterHashtable,$FilterXPath,$LogName,$MaxEvents,$ErrorAction)
    foreach($e in @($fixture.Case.Events | Sort-Object Second -Descending)) {
        if($fixture.Base.AddSeconds($e.Second) -gt $fixture.Now){continue}
        $xml="<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><EventID>24</EventID></System><UserData><EventXML xmlns='Event_NS'><User>$($e.User)</User><SessionID>$($e.Id)</SessionID><Address>$($e.Address)</Address></EventXML></UserData></Event>"
        $record=[pscustomobject]@{TimeCreated=$fixture.Base.AddSeconds($e.Second);RecordId=1000+$e.Second;Xml=$xml}
        $record | Add-Member ScriptMethod ToXml { $this.Xml }
        $record
    }
}
'@
    try {
        [void]$shell.AddScript($setup + "`n" + $source)
        [void]$shell.Invoke()
        if($shell.HadErrors){throw ($shell.Streams.Error | Out-String)}
        if($null -eq $case.Want) {
            if($state.Calls.Count -ne 0){throw "Expected no restoration; got tscon at $($state.Calls[0].At)s"}
        } else {
            if($state.Calls.Count -ne 1){throw "Expected one restoration; got $($state.Calls.Count)"}
            $call=$state.Calls[0]
            if($call.At -lt $case.Want -or $call.At -gt ($case.Want+1.01)){throw "Expected restoration at/after $($case.Want)s (within polling interval); got $($call.At)s"}
            if($call.Id -ne 1 -or $call.Destination -ne '/dest:console'){throw 'Wrong tscon target'}
        }
        if(($state.Now-$base).TotalSeconds -gt ($case.Start+111)){throw 'Exceeded bounded worker budget'}
        "PASS: $($case.Name)"
    } catch { $failed++; "FAIL: $($case.Name): $_" } finally { $shell.Dispose() }
}
"TOTAL: $($cases.Count-$failed) passed, $failed failed"
if($failed){exit 1}
