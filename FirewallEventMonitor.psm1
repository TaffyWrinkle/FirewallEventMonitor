<#################################################################
 #                                                               #
 #  Copyright (c) Microsoft Corporation. All rights reserved.    #
 #  Licensed under the MIT License.                              #
 #  See License.txt in the project root for license information. #
 #                                                               #
 #################################################################>

<#
    .SYNOPSIS
    Captures Firewall rules as they are applied to traffic.
    Runs continiously until user enters Ctrl-C.

    .PARAMETER EventSourceIdentifier
    The souce identifier of the NetEventSession.

    .PARAMETER TraceSessionName
    Name of the NetEventSession.
    
    .PARAMETER TimerInterval
    Interval (in Miliseconds) on which Events will be processed.
    
    .PARAMETER TraceMaxFileSize
    File size limit (in megabytles) of the NetEventSession trace file.
        0 == No maximum. Default is 250.
    
    .PARAMETER TraceBufferSize
    Buffer size (in kilobytes) of the NetEventSession.
        Max is 1024. Computer may override.
    
    .PARAMETER TraceMaxBuffers
    Maximum number of buffers of the NetEventSession.
        Computer may override.
    
    .PARAMETER TraceFilePath
    Path to the generated trace file.
    
    .PARAMETER IP
    Show only NetEvents effecting IP Addresses in this list.
        Empty list means all NetEvents are displayed.
    
    .OUTPUTS
    ETL trace file at the TraceFilePath.
    
    .EXAMPLE Output
    [01/31/2017 18:20:10] Allowrule with ID 391e5f07-0039-42dc-9734-abb5d633aadd processed outboundpackets on port 8 (Name = 38222F79-1C3B-41F2-83B3-9FE0337AD548, FriendlyName = NULL) with status = STATUS_SUCCESS: flow id {src ip = 192.168.0.22, dst ip = 192.168.0.21, protocol = 1, icmp type = V4EchoRequest}, rule {layer = FW_ADMIN_LAYER_ID, group = FW_GROUP_IPv4_OUT_ID, rule id = 391e5f07-0039-42dc-9734-abb5d633aadd, gftFlags = 0}
    
    .EXAMPLE Calling Trace-FirewallRules
    ipmo .\FirewallEventMonitor.psm1
    Trace-FirewallRules -IP "192.168.0.21"
    
    .EXAMPLE Creating a FirewallEventMonitor object.
    using module .\FirewallEventMonitor.psm1
    $fire = [FirewallEventMonitor]::new("FirewallEventMonitor", "Firewall", 2000, 250, 1, 1, "C:\Temp", "192.168.0.21")
#>
function Trace-FirewallRules
{
    param 
    (
        [parameter(Mandatory = $false)]
        [String] $EventSourceIdentifier = "FirewallEventMonitor",
        [parameter(Mandatory = $false)]
        [String] $TraceSessionName = "FirewallTrace",
        [parameter(Mandatory = $false)]
        [Int] $TimerInterval = 2000,
        [parameter(Mandatory = $false)]
        [Int] $TraceMaxFileSize = 250,
        [parameter(Mandatory = $false)]
        [Int] $TraceBufferSize = 1,
        [parameter(Mandatory = $false)]
        [Int] $TraceMaxBuffers = 1,
        [parameter(Mandatory = $false)]
        [String] $TraceFilePath = $env:Windir+"\system32\config\systemprofile\AppData\Local",
        [parameter(Mandatory = $false)]
        [String[]] $IP = @()
    )
    
    return [FirewallEventMonitor]::new( `
        $EventSourceIdentifier, `
        $TraceSessionName, `
        $TimerInterval, `
        $TraceMaxFileSize, `
        $TraceBufferSize, `
        $TraceMaxBuffers, `
        $TraceFilePath, `
        $IP);
}


<#
    .SYNOPSIS
    FirewallEventMonitor encapsulates a NetEvent capture session.
#>
class FirewallEventMonitor
{
    #####################################################
    #
    # Internal Vars
    #
    
    ### Timer
    [System.Timers.Timer] $Timer
    [DateTime] $LastEventTime
    [Int] $TimerInterval = 2000
    
    ### Events
    [String] $EventFilter
    [String[]] $Providers = @()
    [String] $EventSourceIdentifier = "FirewallEventMonitor"
    
    ### Tracing
    [String] $TraceFileName
    [String] $TraceSessionName = "FirewallTrace"
    [String] $TraceFilePath = $env:Windir+"\system32\config\systemprofile\AppData\Local"
    [Int] $TraceMaxFileSize = 250
    [Int] $TraceBufferSize = 1
    [Int] $TraceMaxBuffers = 1
    
    ### IP Addresses to show
    [String[]] $IP = @()
    
    #####################################################
    #
    # Callback
    #

    <#
        .SYNOPSIS
        This callback method processes all the NetEvents written to an *.ETL file.
        Each event more recent than LastEventTime will be written to the console.
        Each event will output the Allow or Block rule applied to the traffic.
        Finally, LastEventTime is updated and the Timer is reset.
        
        .PARAMETER EventFilter
        The list of events to report.
        
        .PARAMETER TraceFileName
        .ETL file with stored NetEvents being processed.

        .PARAMETER LastEventTime
        The EventTime of the last event processed. 
        Used to determine which events are more recent.
        
        .PARAMETER Timer
        The interval timer that controls when ProcessNewEvents will run again.
    #>
    hidden [ScriptBlock] $ProcessNewEvents = {
        # Parameters are passed in MessageData
        $eventFilter = $event.MessageData.EventFilter
        $traceFileName = $event.MessageData.TraceFileName
        $ipAddresses = $event.MessageData.IP
        $lastEventTime = $event.MessageData.LastEventTime
        
        $utcTime = $lastEventTime.ToUniversalTime().ToString("o")
        
        $filter = "*[System[$($eventFilter)][TimeCreated[@SystemTime>'$utcTime']]]"
        $events = Get-WinEvent -Path $traceFileName -FilterXPath $filter -Oldest -ErrorAction SilentlyContinue

        if ($events.Count -gt 0)
        {
            foreach($fwEvent in $events)
            {
                # If IP Addresses were supplied and the event does not contain one of them, ignore the event.
                $matches = $ipAddresses | Where-Object {$fwEvent.Message.Contains($_)}
                if($ipAddresses.Count -gt 0 -AND $matches.Count -eq 0)
                {
                    continue;
                }
                
                Write-Host "[$($fwEvent.TimeCreated)] " -NoNewLine
        
                $color = "Green"
                if ($fwEvent.Message -like "Blockrule*")
                {
                    $color = "Red"
                }
                
                Write-Host "$($fwEvent.Message)`n" -ForegroundColor $color
            }

            $event.MessageData.LastEventTime = $events[$events.Count-1].TimeCreated
        }

        $event.MessageData.Timer.Start()
    }
    
    #####################################################
    #
    # Constructor
    #
    
    FirewallEventMonitor (
           [String] $EventSourceIdentifier = "FirewallEventMonitor",
           [String] $TraceSessionName = "FirewallTrace",
           [Int] $TimerInterval = 2000,
           [Int] $TraceMaxFileSize = 250,
           [Int] $TraceBufferSize = 1,
           [Int] $TraceMaxBuffers = 1,
           [String] $TraceFilePath = $env:Windir+"\system32\config\systemprofile\AppData\Local",
           [String[]] $IP = @()
        )
    {
        ### Handle parameters.
        $this.EventSourceIdentifier = $EventSourceIdentifier
        $this.TraceSessionName = $TraceSessionName
        $this.TimerInterval = $TimerInterval
        $this.TraceMaxFileSize = $TraceMaxFileSize
        $this.TraceBufferSize = $TraceBufferSize
        $this.TraceMaxBuffers = $TraceMaxBuffers
        $this.TraceFilePath = $TraceFilePath
        # Split comma-delimited strings into array.
        $this.IP = $IP | foreach { $_ -Split ',' }
        
        # Software Defined Networking Rules (Virtual Filter Protocol)
        $this.Providers = @("Microsoft-Windows-Hyper-V-VfpExt")
        # 400 IPv4 Rule Match, 401 IPv6 Rule Match, 402 IPv4 ICMP Rule Match
        $this.EventFilter = "EventID=400 or EventID=401 or EventID=402"
        
        $this.CaptureFirewallEvents()
    }
    
    #####################################################
    #
    # Visible Functions
    #
    
    <#
        .SYNOPSIS
        Creates a timer and starts a trace session.
        Runs continiously until user enters Ctrl-C.
    #>
    [void] CaptureFirewallEvents()
    {
        [console]::TreatControlCAsInput = $true
        try
        {
            $this.TraceFileName = "{0}\{1}.etl" -f $this.TraceFilePath, $this.TraceSessionName
            
            $this.Timer = New-Object System.Timers.Timer
            $this.Timer.Interval = $this.TimerInterval
            $this.Timer.AutoReset = $false
            
            $this.LastEventTime = Get-Date

            $this.StartTraceSession()
            $this.StartTimerCallback()

            # Loop here so that the script does not exit. 'Finally' block executes once ctrl+c is pressed.
            while($true)
            {
                # Since this method is called from the Constructor, capture Ctrl-C and break.
                # Otherwise, halting execution would prevent the FirewallEventMonitor object from being returned.
                if ([console]::KeyAvailable)
                {
                    $key = [system.console]::readkey($true)
                    if (($key.modifiers -band [consolemodifiers]"control") -and ($key.key -eq "C"))
                    {
                        Write-Host "User input Ctrl-C. Exiting."
                        break
                    }
                }
            }
        }
        catch [Exception]
        {
            Write-Error -Message $_.Exception.Message.ToString()
        }
        finally
        {
            $this.StopTimerCallback()
            $this.StopTraceSession()
        }
    }
    
    <#
        .SYNOPSIS
        Removes the NetEvent session if one exists.
    #>
    [void] RemoveTraceSession()
    {
        $existingSession = Get-NetEventSession -Name $this.TraceSessionName -ErrorAction Ignore
        if (($null -ne $existingSession))
        {
            Write-Host "Removing the trace."
            Remove-NetEventSession -Name $this.TraceSessionName
        }
    }
    
    #####################################################
    #
    # Hidden Functions
    #
    
    <#
        .SYNOPSIS
        Begins a Trace Session. NetEvents will be saved to file.
    #>
    hidden [void] StartTraceSession()
    {
        Write-Host "StartTraceSession"
        $this.StopTraceSession()

        # Only create a new trace session if one does not already exist.
        $existingSession = Get-NetEventSession -Name $this.TraceSessionName -ErrorAction Ignore
        if ($null -eq $existingSession)
        {
            Write-Host "Creating a new trace session: $($this.TraceSessionName)"

            New-NetEventSession -Name $this.TraceSessionName -CaptureMode SaveToFile -LocalFilePath $this.TraceFileName -MaxFileSize $this.TraceMaxFileSize -TraceBufferSize $this.TraceBufferSize -MaxNumberOfBuffers $this.TraceMaxBuffers -ErrorAction Stop
            
            foreach($provider in $this.Providers)
            {
                Write-Host "Adding provider: $($provider)"
                Add-NetEventProvider -Name $provider -SessionName $this.TraceSessionName -ErrorAction Stop
            }
        }

        Write-Host "Starting the trace."
        Start-NetEventSession -Name $this.TraceSessionName -ErrorAction Stop
    }

    <#
        .SYNOPSIS
        Ends a Trace Session. NetEvents will no longer be saved to file.
    #>
    hidden [void] StopTraceSession()
    {
        $existingSession = Get-NetEventSession -Name $this.TraceSessionName -ErrorAction Ignore
        if (($null -ne $existingSession) -and ($existingSession.SessionStatus -eq "Running"))
        {
            Write-Host "Stopping the trace."
            Stop-NetEventSession -Name $this.TraceSessionName
        }
    }

    <#
        .SYNOPSIS
        Starts the Timer which controls how often the captured NetEvents in the file are processed (printed to screen).
    #>
    hidden [void] StartTimerCallback()
    {
        Write-Host "Registering a timer callback."
        
        # Parameters are passed into the ProcessNewEvents scriptblock using MessageData.
        $parameters = New-Object PSObject -Property `
            @{ EventFilter = $this.EventFilter; `
               TraceFileName = $this.TraceFileName; `
               IP = $this.IP; `
               LastEventTime = $this.LastEventTime; `
               Timer = $this.Timer }

        Register-ObjectEvent -InputObject $($this.Timer) -EventName Elapsed -SourceIdentifier $this.EventSourceIdentifier -Action $this.ProcessNewEvents -MessageData $parameters -ErrorAction Stop
        
        $this.Timer.Start()

        Write-Host "`nEvents will appear below. Press Ctrl+C to end the session...`n"
    }

    <#
        .SYNOPSIS
        Stops the Timer which controls how often the captured NetEvents in the file are processed (printed to screen).
    #>
    hidden [void] StopTimerCallback()
    {
        $existingSubscription = Get-EventSubscriber -SourceIdentifier $this.EventSourceIdentifier -ErrorAction Ignore
        if ($null -ne $existingSubscription)
        {
            Write-Host "Stopping the timer callback."

            $this.Timer.Stop()
            Unregister-Event -SourceIdentifier $this.EventSourceIdentifier
        }
    }
}