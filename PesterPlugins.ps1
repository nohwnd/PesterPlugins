$VerbosePreference = 'Continue'
# setup 
Get-Module Stack | Remove-Module -Force
New-Module -Name Stack {
    $_scope = 'stack'
    [Collections.Stack]$script:scopeStack = New-Object 'Collections.Stack';

    function New-Scope ([string]$Name, [string]$Hint, [string]$Id = [Guid]::NewGuid().ToString('N')) { 
        Write-Verbose -Message "Creating new scope $Id - $Hint - $Name"
        New-Object -TypeName PsObject -Property @{
            Id   = $Id
            Name = $Name
            Hint = $Hint
        }
    }

    function Push-Scope ($Scope) {
        $script:scopeStack.Push($Scope)
        Write-Verbose -Message "Pushed scope $($Scope.Id) - $($Scope.Hint) - $($Scope.Name)"
    }
    
    function Pop-Scope {
        $scope = $script:scopeStack.Pop()
        Write-Verbose -Message "Popped scope $($scope.Id) - $($scope.Hint) - $($scope.Name)"
    }

    function Get-Scope ($Scope = 0) {
        if ($Scope -eq 0) {
            $s = $script:scopeStack.Peek()
            Write-Verbose -Message "Getting scope $Scope -> $($s.Id) - $($s.Hint) - $($s.Name)"
            $s
        }
    }

    function Get-Parent {
        $s = $script:scopeStack.ToArray()[1]
        Write-Verbose -Message "Getting parent scope -> $($s.Id) - $($s.Hint) - $($s.Name)"
        $s
    }

    function Get-ScopeHistory {
        $history = $script:scopeStack.ToArray()
        [Array]::Reverse($history)
        $history
    }
} | Import-Module -Force
#

function New-PesterPlugin {
    param (
        [String] $Name,
        [String] $Version,
        $DefaultConfig,
        [ScriptBlock] $OneTimeSetup,
        [ScriptBlock] $BlockSetup,
        [ScriptBlock] $BlockTeardown,
        [ScriptBlock] $OneTimeTeardown
    )

    New-Object -TypeName PSObject -Property @{
        Name            = $Name
        Version         = $Version
        DefaultConfig          = $DefaultConfig
        OneTimeSetup    = $OneTimeSetup
        BlockSetup      = $BlockSetup
        BlockTeardown   = $BlockTeardown
        OneTimeTeardown = $OneTimeTeardown
    }
}

# function New-TestDrivePlugin {
#     $oneTimeSetup = { New-TestDrive }
#     $blockSetup = { $TestDriveContent = Get-TestDriveChildItem }
#     $blockTeardown = { Clear-TestDrive -Exclude ($TestDriveContent | & $SafeCommands['Select-Object'] -ExpandProperty FullName) }
#     $oneTimeTeardown = { Remove-TestDrive }

#     New-PesterPlugin -Name "TestDrive" `
#         -Version "0.1.0" `
#         -OneTimeSetup $oneTimeSetup `
#         -BlockSetup $blockSetup `
#         -BlockTeardown $blockTeardown `
#         -OneTimeTeardown $oneTimeTeardown
# }

function New-TestDrivePlugin {
    $oneTimeSetup = { param($State, $Context) Write-Host "New-TestDrive in $($Context)"  }
    $blockSetup = { Write-host "settings state to a,b,1" ; "a", "b", 1 }
    $blockTeardown = { param($State, $Context) Write-Host "teardown '$($State | Out-String)'" }
    $oneTimeTeardown = { "removing test drive" }

    New-PesterPlugin -Name "TestDrive" `
        -Version "0.1.0" `
        -OneTimeSetup $oneTimeSetup `
        -BlockSetup $blockSetup `
        -BlockTeardown $blockTeardown `
        -OneTimeTeardown $oneTimeTeardown ` 
}

function New-OutputPlugin {
    $oneTimeSetup = { 
        param($State, $Context, $PluginConfig, $PesterConfig) 
        Write-Host -ForegroundColor $PluginConfig.HeaderColor "Running all tests in $($Context.RootPath)" 
    }
    $blockSetup = { 
        param($State, $Context, $PluginConfig, $PesterConfig) 
        Write-Host -ForegroundColor $PluginConfig.BlockColor "$($PluginConfig.Margin * $State)$($Context.Hint) - $($Context.Name)"
    }

    $defaultConfig = New-Object -TypeName PSObject -Property @{
        HeaderColor = "Magenta"
        BlockColor  = "Green"
        Margin      = "-"
    }

    New-PesterPlugin `
        -Name "Output" `
        -Version "0.1.0" `
        -DefaultConfig $defaultConfig `
        -OneTimeSetup $oneTimeSetup `
        -BlockSetup $blockSetup
}

function New-PluginStepInvocation {
    param(
        $PluginName,        
        $Step,
        $ScriptBlock,
        $State,
        $PluginConfig,
        $PesterConfig,
        $Exception
    )

    New-Object -TypeName PSObject -Property @{
        PluginName   = [String] $PluginName
        Step         = [String] $Step
        ScriptBlock  = [ScriptBlock] $ScriptBlock
        State        = $State
        PluginConfig = $PluginConfig
        PesterConfig = $PesterConfig
        Exception    = $Exception
    }
}

function Invoke-Block {
    param (
        $Name,
        $Hint,
        $ScriptBlock
    )
    Write-Verbose -Message "Running block '$Hint - $($Name)'"
    $context = $scope = New-Scope -Name $Name -Hint $Hint
    
    Push-Scope $scope
    $id = $scope.Id
    
    $parentId = (Get-Parent).Id
    $plugins = $script:plugin[$parentId]
   
    try {
        try {
            $oneTimeSetups = $plugins | where { $_.OneTimeSetup } | foreach { New-PluginStepInvocation -PluginName $_.Name -State $script:state[$_.Name] -ScriptBlock $_.OneTimeSetup -Step "OneTimeSetup" -PluginConfig $_.DefaultConfig }
            $s = Invoke-PluginStep -PluginStepInvocation $oneTimeSetups -Context $context
            $s | foreach { $script:state[$_.PluginName] = $_.State } 
            try {
                $blockSetups = $plugins | where { $_.BlockSetup} | foreach { New-PluginStepInvocation -PluginName $_.Name -State $script:state[$_.Name] -ScriptBlock $_.BlockSetup -Step "BlockSetup" -PluginConfig $_.DefaultConfig }
                $s = Invoke-PluginStep -PluginStepInvocation $blockSetups -Context $context
                $s | foreach { $script:state[$_.PluginName] = $_.State } 
                try {
                    # remove one time setups from the plugin
                    $script:plugin[$id] = $plugins | foreach { New-PesterPlugin -Name $_.Name -Version $_.Version -BlockSetup $_.BlockSetup -BlockTeardown $_.BlockTeardown }
                    $null = & $ScriptBlock
                }
                finally {}
            }
            finally {
                $blockSetups = $plugins | where { $_.BlockTeardown } | foreach { New-PluginStepInvocation -PluginName $_.Name -State $script:state[$_.Name] -ScriptBlock $_.BlockTeardown -Step "BlockTeardown" -PluginConfig $_.DefaultConfig }
                $s = Invoke-PluginStep -PluginStepInvocation $blockSetups -Context $context
                $s | foreach { $script:state[$_.PluginName] = $_.State } 
            }
        }
        finally {
            $blockSetups = $plugins | where { $_.OneTimeTeardown } | foreach { New-PluginStepInvocation -PluginName $_.Name -State $script:state[$_.Name] -ScriptBlock $_.OneTimeTeardown -Step "OneTimeTeardown" -PluginConfig $_.DefaultConfig }
            $s = Invoke-PluginStep -PluginStepInvocation $blockSetups -Context $context
            $s | foreach { $script:state[$_.PluginName] = $_.State } 
        }
    }
    catch {
        throw $_
    }
    finally {
        $null = Pop-Scope
    }
}

function Invoke-PluginStep {
    param (
        [PSObject[]]$PluginStepInvocation,
        $Context
    )
    $run = foreach ($s in $PluginStepInvocation) {
        $result = $null
        $err = $null
        # pipelining stuff we don't need this yet, and might not need it at all
        # $state = New-Object -TypeName PSObject -Property @{ AnyFailed = [bool]$err.Count; <# CallNext = $true #>}
        try {
            do {
                # let's not do anything with the output for the moment
                $result = &($s.ScriptBlock) $s.State $Context $s.PluginConfig
            }
            until ($true)
   
            # shortcutting the circle might not be needed
            # if (-not $state.callNext) {
            #     Write-Verbose "ScriptBlock $ScriptBlock stopped the execution by setting CallNext to `$false."
            #     break
            # }
        }
        catch {
            $err = $_
        }

        New-PluginStepInvocation -PluginName $s.PluginName -Step $s.Step -ScripBlock $s.ScriptBlock -State $result -Exception $err    
    }

    $failed = @($run | where { $null -ne $_.Exception })
    if (0 -ne $failed.Count) {
        throw  "" + $failed.Count + " tasks failed"
    }
    $run
}

# Invoke-Block `
#     -OneTimeSetup { Write-Host "fmw setup one time" }, { Write-Host "fmw setup one time" }`
#     -BlockSetup { Write-Host "fmw setup every time" }, { Write-Host "fmw setup every time" }`
#     -TestSetupOneTime { Write-Host "test setup one time" }, { Write-Host "test setup one time" }`
#     -TestSetupEveryTime { Write-Host "test setup every time" }, { Write-Host "test setup every time" }`
#     -Test { Write-Host "test" }`
#     -TestTeardownEveryTime { Write-Host "test teardown every time" }, { Write-Host "test teardown every time" }`
#     -TestTeardownOneTime { Write-Host "test teardown one time" }, { Write-Host "test teardown one time" }`
#     -BlockTeardown { Write-Host "fmw teardown every time" }, { Write-Host "fmw teardown every time" }`
#     -OneTimeTeardown { Write-Host "fmw teardown one time" }, { Write-Host "fmw teardown one time" }

$script:plugin = @{}
$scope = New-Scope -Hint "top"
Push-Scope $scope
$id = $scope.Id

[PSObject[]] $p = (New-OutputPlugin), (New-TestDrivePlugin)
$script:plugin[$id] = $p
$script:state = @{}

Invoke-Block -Name "a" -Hint "describe" -ScriptBlock {
  
    Write-host "Sb" 
    Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
        write-host "tests" 
    }
}

