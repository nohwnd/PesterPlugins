$VerbosePreference = 'Continue'
$objects = Get-Content $PSScriptRoot\Objects.cs | Out-String
Add-Type -TypeDefinition $objects

# setup 
Get-Module Stack | Remove-Module -Force
New-Module -Name Stack {
    $_scope = 'stack'
    [Collections.Stack]$script:scopeStack = New-Object 'Collections.Stack';

    function New-Scope ([string]$Name, [string]$Hint, [string]$Id = [Guid]::NewGuid().ToString('N')) { 
        Write-Verbose -Message "Creating new scope $Id - $Hint - $Name"
        New-Object -TypeName Pester.Scope -Property @{
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

    function Get-ScopeParent {
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
        [Version] $Version,
        [PSObject] $DefaultConfig,
        [ScriptBlock] $OneTimeSetup,
        [ScriptBlock] $BlockSetup,
        [ScriptBlock] $BlockTeardown,
        [ScriptBlock] $OneTimeTeardown
    )

    New-Object -TypeName 'Pester.Plugin' -Property @{
        Name            = $Name
        Version         = $Version
        DefaultConfig   = $DefaultConfig
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

function New-PluginStep {
    param(
        [Pester.Plugin] $Plugin,        
        [Pester.StepType] $Step,
        [ScriptBlock]  $ScriptBlock
    )

    New-Object -TypeName Pester.Step -Property @{
        Plugin      = $Plugin
        Step        = $Step
        ScriptBlock = $ScriptBlock
    }
}

function Get-Plugin {
    param (
        [Parameter(Mandatory = $True)]
        [Pester.Scope] $Scope
    )

    @($script:plugins[$Scope.Id])
}

function Load-PluginState {
    param (
        [Parameter(Mandatory = $True)]
        [Pester.Scope] $Scope,
        [Parameter(Mandatory = $True)]
        [Pester.Plugin] $Plugin
    )

    $pluginState[($Scope.Id + "|" + $Plugin.Name)]
}

function Save-PluginState {
    param (
        [Parameter(Mandatory = $True)]
        [Pester.Scope] $Scope,
        [Parameter(Mandatory = $True)]
        [Pester.Plugin] $Plugin,
        [Parameter(Mandatory = $True)]
        [PSObject] $State
    )

    $pluginState[($Scope.Id + "|" + $Plugin.Name)] = $State
}

function Test-PluginHasStep {
    param(
        [Parameter(Mandatory = $true)]
        [Pester.Plugin] $Plugin,
        [Parameter(Mandatory = $true)]
        [Pester.StepType] $Step
    ) 
    
    $null -ne $Plugin.$Step
}

function Invoke-Block {
    param (
        $Name,
        $Hint,
        $ScriptBlock
    )
    Write-Verbose -Message "Running block '$Hint - $($Name)'"
    $scope = New-Scope -Name $Name -Hint $Hint
    Push-Scope $scope
    
    
    
    $plugins = Get-Plugin -Scope $scope.Parent
    try {
        try {
            $Plugins | Invoke-Plugin -Step 'OneTimeSetup' | Assert-PluginStepSuccess

            try {
                $Plugins | Invoke-Plugin -Step 'BlockSetup' | Assert-PluginStepSuccess
                
                try {
                    # remove one time setups from the plugin
                    Set-Plugin -Scope $scope = $plugins | foreach { New-PesterPlugin -Name $_.Name -Version $_.Version -BlockSetup $_.BlockSetup -BlockTeardown $_.BlockTeardown }
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

function New-PluginStepResult {
    param(
        [Pester.Step] $Step,
        [PSObject] $State,
        [Management.Automation.ErrorRecord] $ErrorRecord
    )

    New-Object -TypeName Pester.StepResult -Property @{
        Step        = $Step
        State       = $State
        ErrorRecord = $ErrorRecord
    }   
}

function Assert-PluginStepSuccess {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Plugin.StepResult[]] $StepResult
    )

    $failed = @( $StepResult | where { $null -ne $_.ErrorRecord } )
    $anyFailed = $failed.Count -ne 0
    if ($anyFailed) {
        throw "$($failed.Count) tasks failed "
    }

} 
function Invoke-Plugin {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Pester.Plugin[]] $Plugin,
        [Parameter(Mandatory = $true)]
        [Pester.StepType] $Step,
        [Parameter(Mandatory = $true)]
        [Pester.Scope] $Scope
    )

    process {
        if (-not (Test-PluginHasStep -Plugin $Plugin -Step $Step)) {
            return
        }
    
        $step = New-PluginStep -Plugin $Plugin -Step $Step -ScriptBlock $Plugin.$Step
        $pluginState = Load-PluginState -PluginName $Plugin.Name -Scope $Scope.Parent

        $newState = Invoke-PluginStep `
            -Step $step `
            -PluginConfig $Plugin.DefaultConfig `
            -PluginState $pluginState `
            -Scope $Scope

        Save-PluginState -ScopeId $id -PluginName $Plugin.Name -State $newState
    }
}

function Invoke-PluginStep {
    param (
        [Parameter(Mandatory = $true)]
        [Pester.PluginStep] $Step,
        [Parameter(Mandatory = $true)]
        [PSObject] $PluginConfig,
        [Parameter(Mandatory = $true)]
        [PSObject] $PluginState,
        [Parameter(Mandatory = $true)]
        [Pester.Scope] $Scope
    )

    $output = $null
    $err = $null
    # pipelining stuff we don't need this yet, and might not need it at all
    # $state = New-Object -TypeName PSObject -Property @{ AnyFailed = [bool]$err.Count; <# CallNext = $true #>}
    try {
        do {
            $output = &($s.ScriptBlock) $s.State $Context $s.PluginConfig
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

    New-PluginStepResult -Step $Step -State $output -ErrorRecord $err
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

$script:plugins = @{}
$scope = New-Scope -Hint "top"
Push-Scope $scope
$id = $scope.Id

[PSObject[]] $Plugin = (New-OutputPlugin), (New-TestDrivePlugin)
$script:plugins[$id] = $Plugin
$script:state = @{}

Invoke-Block -Name "a" -Hint "describe" -ScriptBlock {
  
    Write-host "Sb" 
    Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
        write-host "tests" 
    }
}
