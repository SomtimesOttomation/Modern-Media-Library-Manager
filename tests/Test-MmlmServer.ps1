# The media server layer (MMLM.Server) without a server. Run: pwsh -File tests\Test-MmlmServer.ps1
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Server.psm1') { Import-Module (Join-Path $root "modules\$m") -DisableNameChecking }
$fail = 0
function Check($ok, $what) { if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:fail++ } }
function Throws($sb) { try { & $sb; '' } catch { $_.Exception.Message } }
Check ((Get-MmlmServerKinds) -contains 'plex') 'Plex is a server kind'
Check ((Throws { New-MmlmServer -Kind 'nope' -BaseUrl 'http://x:1' -Token 't' }) -match 'Unknown media server kind') 'an unknown kind is refused'
Check ((Throws { New-MmlmServer -Kind 'plex' -BaseUrl '' -Token 't' }) -eq 'No Plex server address is set yet. Add it in Settings.') 'no address: the same message as before'
Check ((Throws { New-MmlmServer -Kind 'plex' -BaseUrl 'http://x:1' -Token '' }) -eq 'No Plex token is saved yet. Add it in Settings.') 'no token: the same message as before'
$s = New-MmlmServer -BaseUrl 'http://x:32400' -Token 'abc'
Check ($s.Kind -eq 'plex' -and $s.Name -eq 'Plex') 'the kind defaults to Plex (settings from before have none)'
Check ((Throws { Invoke-MmlmServerScan -Server @{ Kind = 'nope' } -Movies $true }) -eq 'No media server is set up.') 'jobs refuse a server that is not set up'
Check ((Get-MmlmServerArtworkKey -Server $s -Record ([pscustomobject]@{ PlexThumb = '/library/metadata/7/thumb/1' })) -eq '/library/metadata/7/thumb/1') 'artwork is keyed per title (Plex: its thumb)'
if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) { Check ((Unprotect-MmlmSecret (Protect-MmlmSecret 'secret')) -eq 'secret') 'secrets round-trip' }
"Done: $fail problem(s)."
exit ([int]($fail -gt 0))
