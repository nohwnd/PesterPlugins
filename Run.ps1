$objects = Get-Content $PSScriptRoot\Objects.cs | Out-String
Add-Type -TypeDefinition $objects

$p = [Pester.Plugin]::New()
$p.DefaultConfig = [pscustomObject]@{a="b"}
$p.Name = @{}
$p.GetType()