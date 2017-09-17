# $VerbosePreference = 'Continue'
$VerbosePreference = 'SilentlyContinue'
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

    function Push-Scope ($Name, $Hint) {
        $scope = New-Scope -Name $Name -Hint $Hint
        $scope.Parent = Get-Scope
        $script:scopeStack.Push($Scope)
        Write-Verbose -Message "Pushed scope $($Scope.Id) - $($Scope.Hint) - $($Scope.Name)"
        $Scope
    }
    
    function Pop-Scope {
        $scope = $script:scopeStack.Pop()
        Write-Verbose -Message "Popped scope $($scope.Id) - $($scope.Hint) - $($scope.Name)"
    }

    function Get-Scope ($Scope = 0) {
        if ($script:scopeStack.Count -eq 0) { 
            return $null
        }
        
        if ($Scope -eq 0) {
            $s = $script:scopeStack.Peek()
            Write-Verbose -Message "Getting scope $Scope -> $($s.Id) - $($s.Hint) - $($s.Name)"
            $s
        }
    }

    function Get-ScopeHistory {
        $history = $script:scopeStack.ToArray()
        [Array]::Reverse($history)
        $history
    }
} | Import-Module -Force
#

$script:stepResults = @{}
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

function New-Step {
    param(
        [Pester.Plugin] $Plugin,        
        [Pester.StepType] $StepType,
        [ScriptBlock]  $ScriptBlock
    )

    New-Object -TypeName Pester.Step -Property @{
        Plugin      = $Plugin
        StepType    = $StepType
        ScriptBlock = $ScriptBlock
    }
}

function Get-Plugin {
    @($script:plugins)
}

function Load-StepResult {
    param (
        [Parameter(Mandatory = $True)]
        [Pester.Scope] $Scope,
        [Parameter(Mandatory = $True)]
        [Pester.Plugin] $Plugin
    )

    $script:stepResults[($Plugin.Name + "|" + $Scope.Id)]
}

function Save-StepResult {
    param (
        [Parameter(Mandatory = $True)]
        [Pester.Scope] $Scope,
        [Parameter(Mandatory = $True)]
        [Pester.Plugin] $Plugin,
        [Pester.StepResult] $StepResult
    )

    $script:stepResults[($Plugin.Name + "|" + $Scope.Id)] = $StepResult
}

function Test-PluginHasStep {
    param(
        [Parameter(Mandatory = $true)]
        [Pester.Plugin] $Plugin,
        [Parameter(Mandatory = $true)]
        [Pester.StepType] $StepType
    ) 
    
    $null -ne $Plugin.$StepType
}

function Invoke-Block {
    param (
        $Name,
        $Hint,
        $ScriptBlock
    )

    $blockSetupSuccess = $false

    $isTopLevelScope = $null -eq $scope.Parent
    $oneTimeSetupSuccess = $false    

    Write-Verbose -Message "Running block '$Hint - $($Name)'"
    $scope = Push-Scope -Name $Name -Hint $Hint
    try {

        $plugins = Get-Plugin
        try {
            if ($isTopLevelScope) {
                Write-Verbose -Message "Running one time setup"
                $plugins | Invoke-Plugin -Step 'OneTimeSetup' -Scope $scope | Assert-StepSuccess
                Write-Verbose -Message "One time setup succeeded"
                $oneTimeSetupSuccess = $true
            }

            try {
                Write-Verbose -Message "Running block setup"
                $plugins | Invoke-Plugin -Step 'BlockSetup' -Scope $scope | Assert-StepSuccess
                Write-Verbose -Message "Block setup succeeded"
                $blockSetupSuccess = $true
                
                try {
                    Write-Verbose -Message "Running script block"
                    do {
                        $null = & $ScriptBlock
                    }
                    until ($true)
                    Write-Verbose -Message "Script block success"
                }
                finally {}
            }
            finally {
                if (-not $blockSetupSuccess) {
                    Write-Verbose -Message "Block setup failed"    
                }
                Write-Verbose -Message "Running block teardown"
                $plugins | Invoke-Plugin -Step 'BlockTeardown' -Scope $scope | Assert-StepSuccess
                Write-Verbose -Message "Block teardown success"
            }
        }
        finally {
            if ($isTopLevelScope) {
                if (-not $oneTimeSetupSuccess) {
                    Write-Verbose -Message "Block setup failed"    
                }
                Write-Verbose -Message "Running one time teardown"
                $plugins | Invoke-Plugin -Step 'OneTimeTeardown' -Scope $scope | Assert-StepSuccess
                Write-Verbose -Message "One time teardown success"
            }
        }
    }
    catch {
        # Write-Host ($_ | Fl -Force * | Out-String)
        throw $_
    }
    finally {
        $null = Pop-Scope
    }
}

function New-StepResult {
    param(
        [Pester.Step] $Step,
        [PSObject] $State,
        [Management.Automation.ErrorRecord] $ErrorRecord
    )
    
    New-Object -TypeName Pester.StepResult -Property @{
        Step        = $Step
        State       = $State
        ErrorRecord = $ErrorRecord
        Success     = $null -eq $ErrorRecord
    }   
}

function Assert-StepSuccess {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Pester.StepResult] $StepResult
    )

    begin {
        $results = @()
    }
    process {
        $results += $StepResult
    }
    end {
        $count = $results.Count
        $pluginNames = ($results | Select -ExpandProperty Step | Select -ExpandProperty Plugin | Select -ExpandProperty Name) -join ', '
        $stepName = $results | Select -ExpandProperty Step | Select -ExpandProperty StepType | Sort-Object -Unique
        Write-Verbose -Message "Ensuring step $stepName passed, from $count plugins: $pluginNames"
        $failed = @( $results | where { $null -ne $_.ErrorRecord } )
        $anyFailed = $failed.Count -ne 0
        if ($anyFailed) {
            $m = $failed | foreach { 
                $_.Step.Plugin.Name
                $_.Step.StepType
                $_.ErrorRecord | Format-List -Force * | Out-String
                "`n"
            }

            throw "$($failed.Count) tasks failed - `n $m"
        }
    }
} 
function Invoke-Plugin {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Pester.Plugin] $Plugin,
        [Parameter(Mandatory = $true)]
        [Pester.StepType] $StepType,
        [Parameter(Mandatory = $true)]
        [Pester.Scope] $Scope
    )

    process {
        if (-not (Test-PluginHasStep -Plugin $Plugin -StepType $StepType)) {
            return
        }
    
        $step = New-Step -Plugin $Plugin -StepType $StepType -ScriptBlock $Plugin.$StepType
                
        $previousStepResult = Load-StepResult -Plugin $Plugin -Scope $scope
        $isSetupStep = ($StepType -eq 'OneTimeSetup') -or ($StepType -eq 'BlockSetup')
        $hasPreviousStepResult = $null -ne $previousStepResult
        if (-not $hasPreviousStepResult) {
            if ($isSetupStep) {
                $previousStepResult = Load-StepResult -Plugin $Plugin -Scope $Scope.Parent
            }
        }

        $previousResultIsStillNull = $null -eq $previousStepResult 
        if ($previousResultIsStillNull) { 
            $previousStepResult = New-StepResult -Step $Step -State $null -ErrorRecord $null
        }
        
        $newStepResult = Invoke-PluginStep `
            -Step $step `
            -Scope $Scope `
            -PluginConfig $Plugin.DefaultConfig `
            -StepResult $previousStepResult

        Save-StepResult -Scope $Scope -Plugin $Plugin -StepResult $newStepResult

        $newStepResult
    }
}

function Invoke-PluginStep {
    param (
        [Parameter(Mandatory = $true)]
        [Pester.Step] $Step,
        [Parameter(Mandatory = $true)]
        [Pester.Scope] $Scope,
        [Parameter(Mandatory = $true)]
        [PSObject] $PluginConfig,
        [Pester.StepResult] $StepResult
    )

    $output = $null
    $err = $null
    # pipelining stuff we don't need this yet, and might not need it at all
    # $state = New-Object -TypeName PSObject -Property @{ AnyFailed = [bool]$err.Count; <# CallNext = $true #>}
    try {
        do {
            # param($Step, $State, $Config, $Pester, $SetupResult)
            #todo: replace scope with Pester invocation
            $output = &($Step.ScriptBlock) $Step $StepResult.State $PluginConfig $Scope $StepResult
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

    New-StepResult -Step $Step -State $output -ErrorRecord $err
}

function ConvertTo-Object {
    param (
        [Parameter(Mandatory = $true)]
        [Type] $Type, 
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSObject] $InputObject
    )
    $properties = $InputObject.PSObject.Properties | foreach -Begin { $h = @{} } -Process {$h.Add($_.Name, $_.Value) } -End {$h}
    New-Object -TypeName $Type.FullName -Property $properties
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


# -----------------------------------------

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
    $oneTimeSetup = { param($Step, $State, $Config, $Pester) 
        $Config = $Config | ConvertTo-Object -Type ([Pester.TestDriveConfig])
        Write-Host "Create test drive in $($Config.Path)"  
    }
    $blockSetup = { param($Step, $State, $Config, $Pester) Write-host "settings state to a,b,1" ; "a", "b", 1 }
    $blockTeardown = { param($Step, $State, $Config, $Pester, $SetupResult) Write-Host "teardown '$($State | Out-String)'" }
    $oneTimeTeardown = { param($Step, $State, $Config, $Pester, $SetupResult) Write-Host "Teardown test drive in $($Config.Path)" }

    New-PesterPlugin -Name "TestDrive" `
        -Version "0.1.0" `
        -OneTimeSetup $oneTimeSetup `
        -BlockSetup $blockSetup `
        -BlockTeardown $blockTeardown `
        -OneTimeTeardown $oneTimeTeardown `
        -DefaultConfig ([PSCustomObject]@{Path = (Join-Path -Path $env:Temp -ChildPath ([Guid]::NewGuid().ToString("N"))) })
}

function New-OutputPlugin {
    $oneTimeSetup = { 
        param($Step, $State, $Config, $Pester) 
        Write-Host -ForegroundColor $Config.HeaderColor "Running all tests in $($Pester.RootPath)" 
        $State + 1
    }

    $blockSetup = { 
        param($Step, $State, $Config, $Pester)

        Write-Host -ForegroundColor $Config.BlockColor "$($Config.Margin * $State)$($Pester.Hint) - $($Pester.Name) {"
        $State + 1
    }

    $blockTeardown = {
        param($Step, $State, $Config, $Pester, $SetupResult)
        if (-not $SetupResult.Success) {
            return
        }
        $margin = $State - 1
        Write-Host -ForegroundColor $Config.BlockColor "$($Config.Margin * $margin)}"
        $margin
    }

    $oneTimeTeardown = {
        param($Step, $State, $Config, $Pester, $SetupResult)
        Write-Host -ForegroundColor $Config.HeaderColor "Test summary"
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
        -BlockSetup $blockSetup `
        -BlockTeardown $blockTeardown `
        -OneTimeTeardown $oneTimeTeardown
}


# -----------------------------------------


[Pester.Plugin[]] $script:plugins = @((New-OutputPlugin), (New-TestDrivePlugin)) 


Push-Scope -Hint 'top' | Out-Null

Invoke-Block -Name "a" -Hint "describe" -ScriptBlock {
    Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
        write-host "tests" 
    }

    Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
        
        Invoke-Block -Name "b" -Hint "context" -ScriptBlock {
            Invoke-Block -Name "b" -Hint "context" -ScriptBlock {  
                Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
                    Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
                        Write-host "tests"
                    }        
                }        
            }
        
        }
            
    }

    Invoke-Block -Name "b" -Hint "context" -ScriptBlock { 
        write-host "tests" 
    }
}
