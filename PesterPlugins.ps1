function New-PesterPlugin {
    param (
        # do I need the test setups?
        [String] $Name,
        [String] $Version,
        [ScriptBlock[]] $FrameworkSetupOneTime,
        [ScriptBlock[]] $FrameworkSetupEveryTime,
        [ScriptBlock[]] $TestSetupOneTime,
        [ScriptBlock[]] $TestSetupEveryTime,
        [ScriptBlock[]] $TestTeardownEveryTime,
        [ScriptBlock[]] $TestTeardownOneTime,
        [ScriptBlock[]] $FrameworkTeardownEveryTime,
        [ScriptBlock[]] $FrameworkTeardownOneTime
    )

    New-Object -TypeName PSObject -Property @{
        Name                       = $Name
        Version                    = $Version
        FrameworkSetupOneTime      = $FrameworkSetupOneTime
        FrameworkSetupEveryTime    = $FrameworkSetupEveryTime
        TestSetupOneTime           = $TestSetupOneTime
        TestSetupEveryTime         = $TestSetupEveryTime
        TestTeardownEveryTime      = $TestTeardownEveryTime
        TestTeardownOneTime        = $TestTeardownOneTime
        FrameworkTeardownEveryTime = $FrameworkTeardownEveryTime
        FrameworkTeardownOneTime   = $FrameworkTeardownOneTime
    }
}


function New-TestDrivePlugin {
    $oneTimeSetup = { New-TestDrive }
    $blockSetup = { $TestDriveContent = Get-TestDriveChildItem }
    $blockTeardown = { Clear-TestDrive -Exclude ($TestDriveContent | & $SafeCommands['Select-Object'] -ExpandProperty FullName) }
    $oneTimeTeardown = { Remove-TestDrive }

    New-PesterPlugin -Name "TestDrive" `
        -Version "0.1.0" `
        -FrameworkSetupOneTime $oneTimeSetup `
        -FrameworkSetupEveryTime $blockSetup `
        -FrameworkTeardownEveryTime $blockTeardown `
        -FrameworkTeardownOneTime $oneTimeTeardown
}

function Invoke-Block {
    param (
        [ScriptBlock[]] $FrameworkSetupOneTime, # <- gets, anyFailed (to see id anythig failed) and callNext (which is boolean set to true by  default, should also get block info)
        [ScriptBlock[]] $FrameworkSetupEveryTime,
        [ScriptBlock[]] $TestSetupOneTime,
        [ScriptBlock[]] $TestSetupEveryTime,
        [ScriptBlock] $ScriptBlock,
        [ScriptBlock[]] $TestTeardownEveryTime,
        [ScriptBlock[]] $TestTeardownOneTime,
        [ScriptBlock[]] $FrameworkTeardownEveryTime,
        [ScriptBlock[]] $FrameworkTeardownOneTime
    )
    try {
        try {
            $result = Invoke-ScriptBlockSafely $FrameworkSetupOneTime
            try {
                Invoke-ScriptBlockSafely $FrameworkSetupEveryTime -Context 
                try {
                    Invoke-ScriptBlockSafely $TestSetupOneTime
                    try {
                        Invoke-ScriptBlockSafely $TestSetupEveryTime
                        try {
                            $testResult = Invoke-ScriptBlockSafely $Test
                        }
                        finally {}
                    }
                    finally {
                        Invoke-ScriptBlockSafely $TestTeardownEveryTime
                    }
                }
                finally {
                    Invoke-ScriptBlockSafely $TestTeardownOneTime
                }
            }
            finally {
                Invoke-ScriptBlockSafely $FrameworkTeardownEveryTime
            }
        }
        finally {
            Invoke-ScriptBlockSafely $FrameworkTeardownOneTime
        }
    }
    catch {
        throw $_
    }
}

function Test-NoneFailed {
    param (
        [Parameter(ValueFromPipeline)]
        [PSObject[]]$Result
    )
    0 -eq ($Result | where { $null -ne $_.Error })
}

function Invoke-ScriptBlockSafely {
    param (
        [ScriptBlock[]] $ScriptBlock,
        $Context,
        $State
    )
    $run = foreach ($sb in $ScriptBlock) {
        $result = $null
        $err = @()
        # pipelining stuff we don't need this yet, and might not need it at all
        # $state = New-Object -TypeName PSObject -Property @{ AnyFailed = [bool]$err.Count; <# CallNext = $true #>}
        try {
            do {
                # let's not do anything with the output for the moment
                $result = &$sb $Context, $State
            }
            until ($true)
   
            # shortcutting the circle might not be needed
            # if (-not $state.callNext) {
            #     Write-Verbose "ScriptBlock $ScriptBlock stopped the execution by setting CallNext to `$false."
            #     break
            # }
        }
        catch {
            $err += $_
        }

        New-Object -TypeName PSObject -Property @{
            ScriptBlock = $ScriptBlock
            Result      = $result
            Error       = $err
        }
    }

    $failed = @($run | where { 0 -ne $_.Error.Count })
    if (0 -ne $failed.Count) {
        throw  "" + $failed.Count + " tasks failed"
    }
}

Invoke-Block `
    -FrameworkSetupOneTime { Write-Host "fmw setup one time" }, { Write-Host "fmw setup one time" }`
    -FrameworkSetupEveryTime { Write-Host "fmw setup every time" }, { Write-Host "fmw setup every time" }`
    -TestSetupOneTime { Write-Host "test setup one time" }, { Write-Host "test setup one time" }`
    -TestSetupEveryTime { Write-Host "test setup every time" }, { Write-Host "test setup every time" }`
    -Test { Write-Host "test" }`
    -TestTeardownEveryTime { Write-Host "test teardown every time" }, { Write-Host "test teardown every time" }`
    -TestTeardownOneTime { Write-Host "test teardown one time" }, { Write-Host "test teardown one time" }`
    -FrameworkTeardownEveryTime { Write-Host "fmw teardown every time" }, { Write-Host "fmw teardown every time" }`
    -FrameworkTeardownOneTime { Write-Host "fmw teardown one time" }, { Write-Host "fmw teardown one time" }



New-TestDrivePlugin 