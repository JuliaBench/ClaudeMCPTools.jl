@testset "BashTool" begin
    # Import functions for testing
    using ClaudeMCPTools: tool_schema, execute
    
    # Create a bash tool
    bash = BashTool()
    
    @testset "Schema" begin
        schema = tool_schema(bash)
        @test schema["name"] == "bash"
        @test haskey(schema, "description")
        @test haskey(schema, "inputSchema")
        @test schema["inputSchema"]["required"] == ["command"]
    end
    
    @testset "Simple command execution" begin
        # Test echo command
        result = execute(bash, Dict("command" => "echo 'Hello World'"))
        @test haskey(result, "content")
        @test result["content"][1]["type"] == "text"
        @test occursin("Hello World", result["content"][1]["text"])
    end
    
    @testset "Exit codes" begin
        # Test successful command (exit 0)
        result = execute(bash, Dict("command" => "exit 0"))
        @test haskey(result, "content")
        text = result["content"][1]["text"]
        @test occursin("successfully", text) || !occursin("Exit code:", text)
        
        # Test failed command (exit 1)
        result = execute(bash, Dict("command" => "exit 42"))
        @test haskey(result, "content")
        @test occursin("Exit code: 42", result["content"][1]["text"])
    end
    
    @testset "Stderr capture" begin
        # Test stderr output
        result = execute(bash, Dict("command" => "echo 'error' >&2"))
        @test haskey(result, "content")
        text = result["content"][1]["text"]
        @test occursin("error", text)
        @test occursin("stderr", text) || occursin("error", text)
    end
    
    @testset "Working directory" begin
        mktempdir() do tmpdir
            # Create bash tool with custom working directory
            bash_custom = BashTool(working_dir=tmpdir)
            
            # Create a test file in the temp directory
            test_file = joinpath(tmpdir, "test.txt")
            write(test_file, "test content")
            
            # List files should show our test file
            result = execute(bash_custom, Dict("command" => "ls"))
            @test haskey(result, "content")
            @test occursin("test.txt", result["content"][1]["text"])
        end
    end
    
    @testset "Environment variables" begin
        # Test with custom environment
        bash_env = BashTool(env=Dict("TEST_VAR" => "test_value"))
        result = execute(bash_env, Dict("command" => "echo \$TEST_VAR"))
        @test haskey(result, "content")
        @test occursin("test_value", result["content"][1]["text"])
    end
    
    @testset "Error handling" begin
        # Test missing command
        result = execute(bash, Dict())
        @test haskey(result, "content")
        @test occursin("Error", result["content"][1]["text"])
        @test occursin("No command", result["content"][1]["text"])
    end
end