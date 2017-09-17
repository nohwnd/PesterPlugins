using System;
using System.Management.Automation;

namespace Pester {
    public class Scope { 
        public string Id;
        public string Name;
        public string Hint;
        public Scope Parent;
    }
    
    public class Plugin {
        public string Name;
        public Version Version;
        public PSObject DefaultConfig;
        public ScriptBlock OneTimeSetup;
        public ScriptBlock BlockSetup;
        public ScriptBlock BlockTeardown;
        public ScriptBlock OneTimeTeardown;
    }

    public enum StepType {
        OneTimeSetup = 0,
        BlockSetup,
        BlockTeardown,
        OneTimeTeardown 
    }

    public class Step { 
        public Plugin Plugin;
        public StepType StepType;
        public ScriptBlock ScriptBlock;
    }

    public class StepResult {
        public bool Success; 
        public Step Step;
        public PSObject State;
        public ErrorRecord ErrorRecord;
    }

    public class PesterInvocation { 
        public string RootPath;
        public Scope Block;
    }


    public class TestDriveConfig { 
        public string Path;
    }
}
