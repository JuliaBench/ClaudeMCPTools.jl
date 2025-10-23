@testset "Bash tool timeout" begin
    tool = BashTool()
    
    @testset "Quick command completes normally" begin
        # Command that completes quickly
        result = execute(tool, Dict(
            "command" => "echo 'Hello'",
            "timeout" => 5
        ))
        @test !result["isError"]
        @test occursin("Hello", result["content"][1]["text"])
    end
    
    @testset "Long-running command times out" begin
        # Command that would run for 10 seconds but timeout is 2 seconds
        result = execute(tool, Dict(
            "command" => "sleep 10 && echo 'Should not see this'",
            "timeout" => 2
        ))
        @test result["isError"]
        @test occursin("timed out after 2 seconds", result["content"][1]["text"])
    end
    
    @testset "Default timeout (120 seconds)" begin
        # Test that default timeout is applied
        result = execute(tool, Dict(
            "command" => "echo 'Testing default timeout'"
        ))
        @test !result["isError"]
        @test occursin("Testing default timeout", result["content"][1]["text"])
    end
    
    @testset "Invalid timeout values" begin
        # Timeout too small
        result = execute(tool, Dict(
            "command" => "echo 'test'",
            "timeout" => 0
        ))
        @test result["isError"]
        @test occursin("Timeout must be between 1 and 600 seconds", result["content"][1]["text"])
        
        # Timeout too large
        result = execute(tool, Dict(
            "command" => "echo 'test'",
            "timeout" => 700
        ))
        @test result["isError"]
        @test occursin("Timeout must be between 1 and 600 seconds", result["content"][1]["text"])
    end
    
    @testset "Command with output before timeout" begin
        # Command that produces output then sleeps (should capture output before timeout)
        result = execute(tool, Dict(
            "command" => "echo 'Started' && sleep 10",
            "timeout" => 2
        ))
        @test result["isError"]
        @test occursin("timed out", result["content"][1]["text"])
        # Note: Output might not be captured due to buffering
    end
    
    @testset "Long sleep (120s) with short timeout (2s)" begin
        # This test ensures that even very long-running commands get cancelled properly
        # The sleep is for 120 seconds but should be killed after 2 seconds
        start_time = time()
        result = execute(tool, Dict(
            "command" => "sleep 120",
            "timeout" => 2
        ))
        elapsed_time = time() - start_time
        
        @test result["isError"]
        @test occursin("timed out after 2 seconds", result["content"][1]["text"])
        # The command should be killed within approximately 2 seconds (plus some overhead)
        # We allow up to 5 seconds total to account for process startup/cleanup overhead
        @test elapsed_time < 5.0
        @test elapsed_time >= 2.0
    end
end